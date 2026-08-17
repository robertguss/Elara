defmodule Harness.ChatTest do
  use ExUnit.Case, async: false

  alias Harness.Message
  alias Harness.Session.Store

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Harness.Provider.Scripted, agent}
  end

  defp asst(text, calls \\ []) do
    {:ok, a} = Message.assistant(text, calls)
    a
  end

  defp unique_cwd do
    Path.join(
      Application.fetch_env!(:harness, :sessions_root),
      "chat-cwd-#{System.unique_integer([:positive])}"
    )
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
    {:ok, session} = Harness.start_session(provider: provider, tools: [])
    {:ok, out} = StringIO.open("")

    task = Task.async(fn -> Harness.Chat.run(session, out) end)
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

  test "killed session returns status 1" do
    provider = script([{:ok, asst("hello")}])
    {:ok, session} = Harness.start_session(provider: provider, tools: [])
    {:ok, out} = StringIO.open("")

    task = Task.async(fn -> Harness.Chat.run(session, out) end)
    assert await_output(out, "harness")
    Process.exit(session, :kill)

    assert 1 = Task.await(task, 5_000)
  end

  test "/resume lists absolute times, re-derives, resumes in place, and reprints history" do
    cwd = unique_cwd()
    {older, _older_history} = stored_turn(cwd, "old question", "old answer")
    {listed, _listed_history} = stored_turn(cwd, "listed question", "listed answer")
    File.touch!(older.path, 1_700_000_100)
    File.touch!(listed.path, 1_700_000_200)

    {:ok, session} = Harness.start_session(provider: script([]), tools: [], cwd: cwd)
    {:ok, out} = StringIO.open("")
    task = Task.async(fn -> Harness.Chat.run(session, out) end)
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
    assert Process.alive?(session)
    assert Harness.transcript(session) == newest_history
    assert resumed =~ "  you\n  new question\n"
    assert resumed =~ "new answer\n"

    send(chat, {:stdin, "/quit\n"})
    assert 0 = Task.await(task, 5_000)
  end

  test "boot recaps continued history and bad resume index preserves it" do
    cwd = unique_cwd()
    {store, history} = stored_turn(cwd, "saved question", "saved answer")

    {:ok, session} =
      Harness.start_session(provider: script([]), tools: [], cwd: cwd, resume: store.path)

    {:ok, out} = StringIO.open("")
    task = Task.async(fn -> Harness.Chat.run(session, out) end)
    chat = task.pid

    recap = await_idle_after(out, "saved answer")
    assert recap =~ "  you\n  saved question\n"

    send(chat, {:stdin, "/resume 99\n"})
    failure = await_idle_after(out, "no saved session at index 99")
    assert failure =~ "no saved session at index 99\n> "
    assert Harness.transcript(session) == history

    send(chat, {:stdin, "/quit\n"})
    assert 0 = Task.await(task, 5_000)
  end
end
