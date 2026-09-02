defmodule Elara.ChatTest do
  use ExUnit.Case, async: false

  alias Elara.Message
  alias Elara.Session.Store

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp asst(text, calls \\ []) do
    {:ok, a} = Message.assistant(text, calls)
    a
  end

  defp unique_cwd do
    Path.join(
      Application.fetch_env!(:elara, :sessions_root),
      "chat-cwd-#{System.unique_integer([:positive])}"
    )
  end

  defp session_pid(session) do
    {:ok, pid} = Elara.session_pid(session)
    pid
  end

  defp stored_turn(cwd, prompt, answer) do
    store = Store.new(cwd)
    user = Message.user(prompt)
    assistant = asst(answer)
    {:ok, store} = Store.append(store, user)
    {:ok, store} = Store.append(store, assistant)
    {store, [user, assistant]}
  end

  defp await_output(out, snippet, attempts \\ 100) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      {_input, body} = StringIO.contents(out)

      if String.contains?(body, snippet) do
        {:halt, body}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end) || flunk("did not see #{inspect(snippet)} in output")
  end

  defp await_idle_after(out, snippet, attempts \\ 100) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      {_input, body} = StringIO.contents(out)

      if String.contains?(body, snippet) and String.ends_with?(body, "> ") do
        {:halt, body}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end) || flunk("did not return to prompt after #{inspect(snippet)}")
  end

  test "two scripted turns then /quit" do
    provider = script([{:ok, asst("alpha")}, {:ok, asst("beta")}])
    {:ok, session} = Elara.start_session(provider: provider, tools: [])
    {:ok, out} = StringIO.open("")

    task = Task.async(fn -> Elara.Chat.run(session, out) end)
    chat = task.pid

    banner = await_output(out, "> ")
    assert banner =~ "/resume"
    send(chat, {:stdin, "first\n"})
    assert await_idle_after(out, "alpha")
    send(chat, {:stdin, "second\n"})
    assert await_idle_after(out, "beta")
    send(chat, {:stdin, "/quit\n"})

    assert 0 = Task.await(task, 5_000)

    {_input, body} = StringIO.contents(out)
    assert body =~ ~r/alpha.*beta/s
    assert body =~ "  you\n  first\n"
    assert body =~ "  you\n  second\n"
    refute body =~ ">   you"
    refute body =~ "\e["
  end

  test "prints scripted content deltas before the final assistant is available" do
    provider =
      script([
        {:stream, ["hel", {:sleep, 150}, "lo", {:sleep, 150}], {:ok, asst("hello")}}
      ])

    {:ok, session} = Elara.start_session(provider: provider, tools: [], persist: false)
    {:ok, out} = StringIO.open("")
    task = Task.async(fn -> Elara.Chat.run(session, out) end)
    chat = task.pid

    assert await_output(out, "> ")
    send(chat, {:stdin, "stream\n"})

    partial = await_output(out, "hel")
    refute partial =~ "hello\n"

    complete = await_idle_after(out, "hello\n")
    assert complete =~ "hello\n\n> "
    assert Elara.transcript(session) == [Message.user("stream"), asst("hello")]

    send(chat, {:stdin, "/quit\n"})
    assert 0 = Task.await(task, 5_000)
  end

  test "interrupt marks streamed partial text and never presents it as complete" do
    provider =
      script([
        {:stream, ["partial", {:sleep, 5_000}, " stale"], {:ok, asst("partial stale")}}
      ])

    {:ok, session} = Elara.start_session(provider: provider, tools: [], persist: false)
    {:ok, out} = StringIO.open("")
    task = Task.async(fn -> Elara.Chat.run(session, out) end)
    chat = task.pid

    assert await_output(out, "> ")
    send(chat, {:stdin, "stop\n"})
    assert await_output(out, "partial")
    send(chat, {:stdin, "/interrupt\n"})

    interrupted = await_idle_after(out, "interrupted")
    assert interrupted =~ "partial\n    interrupted\n"
    refute interrupted =~ "partial stale"
    assert Elara.transcript(session) == [Message.user("stop")]

    send(chat, {:stdin, "/quit\n"})
    assert 0 = Task.await(task, 5_000)
  end

  test "/reload reports when no plugins are loaded" do
    {:ok, session} = Elara.start_session(provider: script([]), tools: [], plugins: [])
    {:ok, out} = StringIO.open("")
    task = Task.async(fn -> Elara.Chat.run(session, out) end)
    chat = task.pid

    banner = await_output(out, "> ")
    assert banner =~ "/reload"
    send(chat, {:stdin, "/reload\n"})
    assert await_idle_after(out, "no plugins loaded")
    send(chat, {:stdin, "/quit\n"})

    assert 0 = Task.await(task, 5_000)
  end

  test "killed session returns status 1" do
    provider = script([{:ok, asst("hello")}])
    {:ok, session} = Elara.start_session(provider: provider, tools: [])
    {:ok, out} = StringIO.open("")

    task = Task.async(fn -> Elara.Chat.run(session, out) end)
    assert await_output(out, "elara")
    Process.exit(session_pid(session), :kill)

    assert 1 = Task.await(task, 5_000)
  end

  test "/resume lists absolute times, re-derives, resumes in place, and reprints history" do
    cwd = unique_cwd()
    {older, _older_history} = stored_turn(cwd, "old question", "old answer")
    {listed, _listed_history} = stored_turn(cwd, "listed question", "listed answer")
    File.touch!(older.path, 1_700_000_100)
    File.touch!(listed.path, 1_700_000_200)

    {:ok, session} = Elara.start_session(provider: script([]), tools: [], cwd: cwd)
    {:ok, out} = StringIO.open("")
    task = Task.async(fn -> Elara.Chat.run(session, out) end)
    chat = task.pid

    assert await_output(out, "> ")
    send(chat, {:stdin, "/resume\n"})
    listing = await_idle_after(out, listed.id)
    assert listing =~ "2023-11-14T22:16:40Z"
    assert listing =~ older.id

    {newest, newest_history} = stored_turn(cwd, "new question", "new answer")
    File.touch!(newest.path, 1_700_000_300)

    same_pid = session
    send(chat, {:stdin, "/resume 1\n"})
    resumed = await_idle_after(out, "new answer")

    assert session == same_pid
    assert Process.alive?(session_pid(session))
    assert Elara.transcript(session) == newest_history
    assert resumed =~ "  you\n  new question\n"
    assert resumed =~ "new answer\n"

    send(chat, {:stdin, "/quit\n"})
    assert 0 = Task.await(task, 5_000)
  end

  test "boot recaps continued history and bad resume index preserves it" do
    cwd = unique_cwd()
    {store, history} = stored_turn(cwd, "saved question", "saved answer")

    {:ok, session} =
      Elara.start_session(provider: script([]), tools: [], cwd: cwd, resume: store.path)

    {:ok, out} = StringIO.open("")
    task = Task.async(fn -> Elara.Chat.run(session, out) end)
    chat = task.pid

    recap = await_idle_after(out, "saved answer")
    assert recap =~ "  you\n  saved question\n"

    send(chat, {:stdin, "/resume 99\n"})
    failure = await_idle_after(out, "no saved session at index 99")
    assert failure =~ "no saved session at index 99\n> "
    assert Elara.transcript(session) == history

    send(chat, {:stdin, "/quit\n"})
    assert 0 = Task.await(task, 5_000)
  end

  test "/tree lists turns and re-submits a selected turn on a new branch" do
    cwd = unique_cwd()
    provider = script([{:ok, asst("a1")}, {:ok, asst("a2")}, {:ok, asst("alternate")}])
    {:ok, session} = Elara.start_session(provider: provider, tools: [], cwd: cwd)
    {:ok, out} = StringIO.open("")
    task = Task.async(fn -> Elara.Chat.run(session, out) end)
    chat = task.pid

    assert await_output(out, "> ")
    send(chat, {:stdin, "q1\n"})
    assert await_idle_after(out, "a1")
    send(chat, {:stdin, "q2\n"})
    assert await_idle_after(out, "a2")
    send(chat, {:stdin, "/tree\n"})

    listing = await_idle_after(out, "choose with /tree N")
    assert listing =~ "1  q1\n"
    assert listing =~ "2  q2\n"

    send(chat, {:stdin, "/tree 2\n"})
    assert await_idle_after(out, "alternate")

    assert Elara.transcript(session) == [
             Message.user("q1"),
             asst("a1"),
             Message.user("q2"),
             asst("alternate")
           ]

    [info] = Store.list(cwd)
    {:ok, store} = Store.open(info.path, cwd)
    assert length(store.entries) == 6

    send(chat, {:stdin, "/quit\n"})
    assert 0 = Task.await(task, 5_000)
  end

  test "/clone and /name create and label a separate session" do
    cwd = unique_cwd()

    {:ok, session} =
      Elara.start_session(provider: script([{:ok, asst("answer")}]), tools: [], cwd: cwd)

    {:ok, out} = StringIO.open("")
    task = Task.async(fn -> Elara.Chat.run(session, out) end)
    chat = task.pid

    assert await_output(out, "> ")
    send(chat, {:stdin, "question\n"})
    assert await_idle_after(out, "answer")
    [source] = Store.list(cwd)

    send(chat, {:stdin, "/clone\n"})
    assert await_idle_after(out, "cloned session")
    send(chat, {:stdin, "/name alternate\n"})
    assert await_idle_after(out, "session named")
    send(chat, {:stdin, "/resume\n"})
    listing = await_idle_after(out, "alternate")

    assert listing =~ "alternate"
    assert length(Store.list(cwd)) == 2
    assert Enum.any?(Store.list(cwd), &(&1.path == source.path))

    send(chat, {:stdin, "/quit\n"})
    assert 0 = Task.await(task, 5_000)
  end
end
