defmodule Harness.SessionTest do
  use ExUnit.Case, async: false

  alias Harness.Message
  alias Harness.Message.ToolCall
  alias Harness.Provider
  alias Harness.Provider.Error
  alias Harness.Session.Store
  alias Harness.Tool

  defmodule CrashTool do
    def run(_args, _ctx), do: raise("boom")
  end

  defmodule SlowTool do
    def run(_args, _ctx) do
      Process.sleep(5_000)
      {:ok, "late"}
    end
  end

  defmodule RecordingProvider do
    alias Harness.Provider
    alias Harness.Session.Store

    @behaviour Provider

    @impl true
    def chat(agent, %Provider.Request{} = request) do
      %{cwd: cwd, parent: parent, reply: reply} =
        Agent.get_and_update(agent, fn %{replies: [reply | rest]} = state ->
          {%{cwd: state.cwd, parent: state.parent, reply: reply}, %{state | replies: rest}}
        end)

      persisted =
        with {:ok, info} <- Store.newest(cwd),
             {:ok, store} <- Store.open(info.path, cwd) do
          Store.history(store)
        end

      send(parent, {:provider_observed, request, persisted})

      case reply do
        {:ok, assistant} -> {:ok, assistant, agent}
        {:error, error} -> {:error, error, agent}
      end
    end
  end

  defmodule BlockingProvider do
    alias Harness.Provider

    @behaviour Provider

    @impl true
    def chat(parent, %Provider.Request{} = request) do
      send(parent, {:provider_blocked, self(), request})

      receive do
        {:reply, assistant} -> {:ok, assistant, parent}
      end
    end
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Harness.Provider.Scripted, agent}
  end

  defp recording_script(replies, cwd) do
    parent = self()

    {:ok, agent} =
      Agent.start_link(fn ->
        %{replies: replies, cwd: cwd, parent: parent}
      end)

    {RecordingProvider, agent}
  end

  defp asst(text, calls \\ []) do
    {:ok, a} = Message.assistant(text, calls)
    a
  end

  defp unique_cwd do
    Path.join(
      Application.fetch_env!(:harness, :sessions_root),
      "cwd-#{System.unique_integer([:positive])}"
    )
  end

  defp session_pid(session) do
    {:ok, pid} = Harness.session_pid(session)
    pid
  end

  test "sync ask returns final text and fans events" do
    provider = script([{:ok, asst("hello")}])
    {:ok, session} = Harness.start_session(provider: provider, tools: [])
    :ok = Harness.subscribe(session)

    task = Task.async(fn -> Harness.ask(session, "hi") end)

    assert_receive {:harness, ^session, {:turn_started, "hi"}}, 1_000
    assert_receive {:harness, ^session, {:message_appended, %Message.User{}}}, 1_000

    assert_receive {:harness, ^session, {:message_appended, %Message.Assistant{text: "hello"}}},
                   1_000

    assert_receive {:harness, ^session, {:turn_ended, {:completed, "hello"}}}, 1_000

    assert {:ok, "hello"} = Task.await(task)
  end

  test "busy rejection" do
    provider =
      script([
        {:ok, asst(nil, [%ToolCall{id: "1", name: "slow", args: {:ok, %{}}}])}
      ])

    tools = [
      %Tool{
        name: "slow",
        description: "slow",
        parameters: %{"type" => "object", "properties" => %{}},
        run: {SlowTool, :run}
      }
    ]

    {:ok, session} =
      Harness.start_session(provider: provider, tools: tools, tool_timeout_ms: 10_000)

    assert :ok = Harness.ask_async(session, "go")
    assert {:error, :busy} = Harness.ask_async(session, "again")
  end

  test "tool crash isolates and continues" do
    provider =
      script([
        {:ok, asst(nil, [%ToolCall{id: "1", name: "crash", args: {:ok, %{}}}])},
        {:ok, asst("recovered")}
      ])

    tools = [
      %Tool{
        name: "crash",
        description: "crash",
        parameters: %{"type" => "object", "properties" => %{}},
        run: {CrashTool, :run}
      }
    ]

    {:ok, session} = Harness.start_session(provider: provider, tools: tools)
    assert {:ok, "recovered"} = Harness.ask(session, "go")
    assert Process.alive?(session_pid(session))
  end

  test "tool timeout becomes error and continues" do
    provider =
      script([
        {:ok, asst(nil, [%ToolCall{id: "1", name: "slow", args: {:ok, %{}}}])},
        {:ok, asst("after timeout")}
      ])

    tools = [
      %Tool{
        name: "slow",
        description: "slow",
        parameters: %{"type" => "object", "properties" => %{}},
        run: {SlowTool, :run}
      }
    ]

    {:ok, session} = Harness.start_session(provider: provider, tools: tools, tool_timeout_ms: 50)

    assert {:ok, "after timeout"} = Harness.ask(session, "go")
  end

  test "provider error surfaces" do
    err = %Error{kind: :http, message: "nope"}
    provider = script([{:error, err}])
    {:ok, session} = Harness.start_session(provider: provider, tools: [])
    assert {:error, {:provider_error, ^err}} = Harness.ask(session, "go")
  end

  test "provider invocation observes the user append already durable" do
    cwd = unique_cwd()
    provider = recording_script([{:ok, asst("answer")}], cwd)
    {:ok, session} = Harness.start_session(provider: provider, tools: [], cwd: cwd)

    assert {:ok, "answer"} = Harness.ask(session, "question")

    assert_receive {:provider_observed, %Provider.Request{messages: request_messages},
                    persisted_messages}

    assert request_messages == [Message.user("question")]
    assert persisted_messages == request_messages
  end

  test "explicit resume carries two prior turns into the next provider request" do
    cwd = unique_cwd()
    first_provider = recording_script([{:ok, asst("a1")}, {:ok, asst("a2")}], cwd)
    {:ok, first_session} = Harness.start_session(provider: first_provider, tools: [], cwd: cwd)

    assert {:ok, "a1"} = Harness.ask(first_session, "q1")
    assert_receive {:provider_observed, %Provider.Request{}, _}
    assert {:ok, "a2"} = Harness.ask(first_session, "q2")
    assert_receive {:provider_observed, %Provider.Request{}, _}

    prior = Harness.transcript(first_session)
    assert {:ok, info} = Store.newest(cwd)
    GenServer.stop(session_pid(first_session))

    next_provider = recording_script([{:ok, asst("a3")}], cwd)

    assert {:ok, resumed} =
             Harness.start_session(
               provider: next_provider,
               tools: [],
               cwd: cwd,
               resume: info.path
             )

    assert Harness.transcript(resumed) == prior
    assert {:ok, "a3"} = Harness.ask(resumed, "q3")

    assert_receive {:provider_observed, %Provider.Request{messages: request_messages},
                    persisted_messages}

    assert request_messages == prior ++ [Message.user("q3")]
    assert persisted_messages == request_messages
  end

  test "start_session rejects missing and invalid resume targets" do
    cwd = unique_cwd()
    provider = script([])

    assert {:error, :no_session} =
             Harness.start_session(provider: provider, tools: [], cwd: cwd, resume: :latest)

    assert {:error, :invalid_resume} =
             Harness.start_session(provider: provider, tools: [], cwd: cwd, resume: 1)
  end

  test "resume: :latest opens the newest usable store by mtime" do
    cwd = unique_cwd()
    older = Store.new(cwd)
    newer = Store.new(cwd)
    assert {:ok, older} = Store.append(older, Message.user("older"))
    assert {:ok, newer} = Store.append(newer, Message.user("newer"))
    File.touch!(older.path, 1_700_000_100)
    File.touch!(newer.path, 1_700_000_200)

    assert {:ok, session} =
             Harness.start_session(provider: script([]), tools: [], cwd: cwd, resume: :latest)

    assert Harness.transcript(session) == [Message.user("newer")]
  end

  test "in-place resume keeps the pid and failed resume leaves history unchanged" do
    cwd = unique_cwd()
    target = Store.new(cwd)
    user = Message.user("saved")
    assistant = asst("answer")
    assert {:ok, target} = Store.append(target, user)
    assert {:ok, target} = Store.append(target, assistant)

    assert {:ok, session} = Harness.start_session(provider: script([]), tools: [], cwd: cwd)

    same_pid = session
    assert {:ok, history} = Harness.resume(session, target.path)
    assert session == same_pid
    assert history == [user, assistant]
    assert Harness.transcript(session) == [user, assistant]

    missing = Path.join(Path.dirname(target.path), "missing.jsonl")
    assert {:error, :enoent} = Harness.resume(session, missing)
    assert Harness.transcript(session) == [user, assistant]
  end

  test "in-place resume refuses while busy" do
    cwd = unique_cwd()
    target = Store.new(cwd)
    assert {:ok, target} = Store.append(target, Message.user("saved"))

    assert {:ok, session} =
             Harness.start_session(
               provider: {BlockingProvider, self()},
               tools: [],
               cwd: cwd
             )

    assert :ok = Harness.ask_async(session, "busy")
    assert_receive {:provider_blocked, worker, %Provider.Request{}}
    assert {:error, :busy} = Harness.resume(session, target.path)
    send(worker, {:reply, asst("done")})
  end

  test "a stale provider response cannot complete a turn after a tree rebase" do
    cwd = unique_cwd()

    assert {:ok, session} =
             Harness.start_session(
               provider: {BlockingProvider, self()},
               tools: [],
               cwd: cwd
             )

    :ok = Harness.subscribe(session)
    assert :ok = Harness.ask_async(session, "question")
    assert_receive {:provider_blocked, stale_worker, %Provider.Request{}}

    Harness.interrupt(session)
    assert_receive {:harness, ^session, {:turn_ended, :interrupted}}

    [%{id: user_id}] = Harness.user_entries(session)
    assert {:ok, "question", []} = Harness.tree(session, user_id)
    assert :ok = Harness.ask_async(session, "question")
    assert_receive {:provider_blocked, current_worker, %Provider.Request{}}

    send(stale_worker, {:reply, asst("stale")})

    refute_receive {:harness, ^session, {:message_appended, %Message.Assistant{text: "stale"}}},
                   100

    send(current_worker, {:reply, asst("current")})
    assert_receive {:harness, ^session, {:turn_ended, {:completed, "current"}}}
    assert Harness.transcript(session) == [Message.user("question"), asst("current")]
  end

  test "persist: false never writes a session file" do
    cwd = unique_cwd()

    assert {:ok, session} =
             Harness.start_session(
               provider: script([{:ok, asst("answer")}]),
               tools: [],
               cwd: cwd,
               persist: false
             )

    assert {:ok, "answer"} = Harness.ask(session, "question")
    assert Store.list(cwd) == []
  end

  test "a named session is listable before any user turn" do
    cwd = unique_cwd()

    assert {:ok, _session} =
             Harness.start_session(provider: script([]), tools: [], cwd: cwd, name: "startup")

    [info] = Harness.list_sessions(cwd)
    assert info.name == "startup"
  end

  test "a second writer cannot open the same session file" do
    cwd = unique_cwd()
    store = Store.new(cwd)
    assert {:ok, store} = Store.append(store, Message.user("held"))

    assert {:ok, _session} =
             Harness.start_session(
               provider: script([]),
               tools: [],
               cwd: cwd,
               resume: store.path
             )

    assert {:error, :locked} =
             Harness.start_session(
               provider: script([]),
               tools: [],
               cwd: cwd,
               resume: store.path
             )
  end

  test "resume persists interrupted tool results before the next turn" do
    cwd = unique_cwd()
    first = %ToolCall{id: "call-1", name: "read", args: {:ok, %{"path" => "a"}}}
    second = %ToolCall{id: "call-2", name: "read", args: {:ok, %{"path" => "b"}}}
    {:ok, assistant} = Message.assistant(nil, [first, second])
    completed = Message.tool_result(first, {:ok, "a"})

    store = Store.new(cwd)
    assert {:ok, store} = Store.append(store, Message.user("read both"))
    assert {:ok, store} = Store.append(store, assistant)
    assert {:ok, store} = Store.append(store, completed)

    next_provider = recording_script([{:ok, asst("after")}], cwd)

    assert {:ok, session} =
             Harness.start_session(
               provider: next_provider,
               tools: [],
               cwd: cwd,
               resume: store.path
             )

    repaired = Message.tool_result(second, {:error, "interrupted"})
    prior = [Message.user("read both"), assistant, completed, repaired]
    assert Harness.transcript(session) == prior

    {:ok, on_disk} = Store.open(store.path, cwd)
    assert Store.history(on_disk) == prior

    assert {:ok, "after"} = Harness.ask(session, "next")

    assert_receive {:provider_observed, %Provider.Request{messages: request_messages},
                    persisted_messages}

    assert request_messages == prior ++ [Message.user("next")]
    assert persisted_messages == request_messages

    GenServer.stop(session_pid(session))
    {:ok, reopened} = Store.open(store.path, cwd)
    assert Store.history(reopened) == request_messages ++ [asst("after")]
  end

  test "tree moves the leaf and the provider receives only the selected path" do
    cwd = unique_cwd()

    provider =
      recording_script([{:ok, asst("a1")}, {:ok, asst("a2")}, {:ok, asst("alternate")}], cwd)

    {:ok, session} = Harness.start_session(provider: provider, tools: [], cwd: cwd)

    assert {:ok, "a1"} = Harness.ask(session, "q1")
    assert_receive {:provider_observed, %Provider.Request{}, _}
    assert {:ok, "a2"} = Harness.ask(session, "q2")
    assert_receive {:provider_observed, %Provider.Request{}, _}

    [%{id: _first}, %{id: second}] = Harness.user_entries(session)
    assert {:ok, "q2", prior} = Harness.tree(session, second)
    assert prior == [Message.user("q1"), asst("a1")]
    assert {:ok, "alternate"} = Harness.ask(session, "q2")

    assert_receive {:provider_observed, %Provider.Request{messages: request_messages},
                    persisted_messages}

    assert request_messages == prior ++ [Message.user("q2")]
    assert persisted_messages == request_messages

    {:ok, info} = Store.newest(cwd)
    {:ok, reopened} = Store.open(info.path, cwd)
    assert length(reopened.entries) == 6

    [old_second, new_second] = Enum.filter(reopened.entries, &(&1.message == Message.user("q2")))

    assert old_second.parent_id == new_second.parent_id
  end

  test "fork switches to a second file without changing the source tree" do
    cwd = unique_cwd()
    provider = recording_script([{:ok, asst("a1")}, {:ok, asst("a2")}], cwd)
    {:ok, session} = Harness.start_session(provider: provider, tools: [], cwd: cwd)

    assert {:ok, "a1"} = Harness.ask(session, "q1")
    assert_receive {:provider_observed, %Provider.Request{}, _}
    assert {:ok, "a2"} = Harness.ask(session, "q2")
    assert_receive {:provider_observed, %Provider.Request{}, _}

    [source_info] = Store.list(cwd)
    {:ok, source_before} = Store.open(source_info.path, cwd)
    [%{id: _first}, %{id: second}] = Harness.user_entries(session)

    assert {:ok, "q2", copied_history} = Harness.fork(session, second)
    assert copied_history == [Message.user("q1"), asst("a1")]

    infos = Store.list(cwd)
    assert length(infos) == 2
    fork_info = Enum.find(infos, &(&1.path != source_info.path))
    {:ok, fork} = Store.open(fork_info.path, cwd)
    {:ok, source_after} = Store.open(source_info.path, cwd)

    assert fork.parent_session == source_info.path
    assert Store.history(fork) == copied_history
    assert source_after.entries == source_before.entries
  end
end
