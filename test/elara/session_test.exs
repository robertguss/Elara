defmodule Elara.SessionTest do
  use ExUnit.Case, async: false

  alias Elara.Message
  alias Elara.Message.ToolCall
  alias Elara.Provider
  alias Elara.Provider.Error
  alias Elara.Session.Store
  alias Elara.Tool

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
    alias Elara.Provider
    alias Elara.Session.Store

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
    alias Elara.Provider

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
    {Elara.Provider.Scripted, agent}
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
      Application.fetch_env!(:elara, :sessions_root),
      "cwd-#{System.unique_integer([:positive])}"
    )
  end

  defp session_pid(session) do
    {:ok, pid} = Elara.session_pid(session)
    pid
  end

  defp fresh_vm(code) do
    System.cmd(
      System.find_executable("mix"),
      ["run", "--no-compile", "--no-deps-check", "-e", code],
      cd: Path.expand("../..", __DIR__),
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  test "sync ask returns final text and fans events" do
    provider = script([{:ok, asst("hello")}])
    {:ok, session} = Elara.start_session(provider: provider, tools: [])
    :ok = Elara.subscribe(session)

    task = Task.async(fn -> Elara.ask(session, "hi") end)

    assert_receive {:elara, ^session, {:turn_started, "hi"}}, 1_000
    assert_receive {:elara, ^session, {:message_appended, %Message.User{}}}, 1_000

    assert_receive {:elara, ^session, {:message_appended, %Message.Assistant{text: "hello"}}},
                   1_000

    assert_receive {:elara, ^session, {:turn_ended, {:completed, "hello"}}}, 1_000

    assert {:ok, "hello"} = Task.await(task)
  end

  test "scripted streaming emits ordered deltas before one durable final assistant" do
    provider = script([{:stream, ["hel", "lo"], {:ok, asst("hello")}}])
    {:ok, session} = Elara.start_session(provider: provider, tools: [], persist: false)
    :ok = Elara.subscribe(session)

    assert :ok = Elara.ask_async(session, "hi")
    assert_receive {:elara, ^session, {:turn_started, "hi"}}
    assert_receive {:elara, ^session, {:message_appended, %Message.User{}}}
    assert_receive {:elara, ^session, {:content_delta, "assistant-1", "hel"}}
    assert_receive {:elara, ^session, {:content_delta, "assistant-1", "lo"}}

    assert_receive {:elara, ^session,
                    {:message_appended, %Message.Assistant{text: "hello"}, :streamed}}

    assert_receive {:elara, ^session, {:turn_ended, {:completed, "hello"}}}
    assert Elara.transcript(session) == [Message.user("hi"), asst("hello")]
  end

  test "interrupt midstream reports partial text as interrupted and drops stale deltas" do
    provider =
      script([
        {:stream, ["partial", {:sleep, 5_000}, " stale"], {:ok, asst("partial stale")}}
      ])

    {:ok, session} = Elara.start_session(provider: provider, tools: [], persist: false)
    :ok = Elara.subscribe(session)

    assert :ok = Elara.ask_async(session, "stop it")
    assert_receive {:elara, ^session, {:turn_started, "stop it"}}
    assert_receive {:elara, ^session, {:message_appended, %Message.User{}}}
    assert_receive {:elara, ^session, {:content_delta, "assistant-1", "partial"}}

    assert Elara.materialized_view(session)["content_deltas"] == %{
             "assistant-1" => "partial"
           }

    Elara.interrupt(session)
    assert_receive {:elara, ^session, {:turn_ended, :interrupted, :streamed}}
    assert Elara.transcript(session) == [Message.user("stop it")]
    assert Elara.materialized_view(session)["content_deltas"] == %{}

    refute_receive {:elara, ^session, {:content_delta, _, " stale"}}, 100
    refute_receive {:elara, ^session, {:message_appended, %Message.Assistant{}, :streamed}}, 100
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
      Elara.start_session(provider: provider, tools: tools, tool_timeout_ms: 10_000)

    assert :ok = Elara.ask_async(session, "go")
    assert {:error, :busy} = Elara.ask_async(session, "again")
    Elara.interrupt(session)
    assert Elara.status(session).phase == :idle
  end

  test "interrupt kills the running tool task immediately" do
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
      Elara.start_session(provider: provider, tools: tools, persist: false)

    :ok = Elara.subscribe(session)
    assert :ok = Elara.ask_async(session, "go")
    assert_receive {:elara, ^session, {:tool_started, %ToolCall{id: "1"}}}, 1_000

    Elara.interrupt(session)
    assert_receive {:elara, ^session, {:turn_ended, :interrupted}}, 1_000

    status = Elara.status(session)
    assert status.phase == :idle
    assert status.current_effect == nil
    assert status.task_count == 0

    refute_receive {:elara, ^session,
                    {:message_appended, %Message.ToolResult{outcome: {:ok, "late"}}}},
                   100
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

    {:ok, session} = Elara.start_session(provider: provider, tools: tools)
    assert {:ok, "recovered"} = Elara.ask(session, "go")
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

    {:ok, session} = Elara.start_session(provider: provider, tools: tools, tool_timeout_ms: 50)

    assert {:ok, "after timeout"} = Elara.ask(session, "go")
  end

  test "provider error surfaces" do
    err = %Error{kind: :http, message: "nope"}
    provider = script([{:error, err}])
    {:ok, session} = Elara.start_session(provider: provider, tools: [])
    assert {:error, {:provider_error, ^err}} = Elara.ask(session, "go")
  end

  test "provider invocation observes the user append already durable" do
    cwd = unique_cwd()
    provider = recording_script([{:ok, asst("answer")}], cwd)
    {:ok, session} = Elara.start_session(provider: provider, tools: [], cwd: cwd)

    assert {:ok, "answer"} = Elara.ask(session, "question")

    assert_receive {:provider_observed, %Provider.Request{messages: request_messages},
                    persisted_messages}

    assert request_messages == [Message.user("question")]
    assert persisted_messages == request_messages
  end

  test "explicit resume carries two prior turns into the next provider request" do
    cwd = unique_cwd()
    first_provider = recording_script([{:ok, asst("a1")}, {:ok, asst("a2")}], cwd)
    {:ok, first_session} = Elara.start_session(provider: first_provider, tools: [], cwd: cwd)

    assert {:ok, "a1"} = Elara.ask(first_session, "q1")
    assert_receive {:provider_observed, %Provider.Request{}, _}
    assert {:ok, "a2"} = Elara.ask(first_session, "q2")
    assert_receive {:provider_observed, %Provider.Request{}, _}

    prior = Elara.transcript(first_session)
    assert {:ok, info} = Store.newest(cwd)
    GenServer.stop(session_pid(first_session))

    next_provider = recording_script([{:ok, asst("a3")}], cwd)

    assert {:ok, resumed} =
             Elara.start_session(
               provider: next_provider,
               tools: [],
               cwd: cwd,
               resume: info.path
             )

    assert Elara.transcript(resumed) == prior
    assert {:ok, "a3"} = Elara.ask(resumed, "q3")

    assert_receive {:provider_observed, %Provider.Request{messages: request_messages},
                    persisted_messages}

    assert request_messages == prior ++ [Message.user("q3")]
    assert persisted_messages == request_messages
  end

  test "a fresh VM resumes a completed session after read and bash tools" do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-fresh-vm-resume-#{System.unique_integer([:positive])}"
      )

    sessions_root = Path.join(root, "sessions")
    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)
    File.write!(Path.join(cwd, "input.txt"), "input")
    on_exit(fn -> File.rm_rf!(root) end)

    create = """
    Application.put_env(:elara, :sessions_root, #{inspect(sessions_root)})
    alias Elara.Message
    alias Elara.Message.ToolCall

    calls = [
      %ToolCall{id: "read-1", name: "read", args: {:ok, %{"path" => "input.txt"}}},
      %ToolCall{id: "bash-1", name: "bash", args: {:ok, %{"command" => "printf shell"}}}
    ]

    {:ok, tool_turn} = Message.assistant(nil, calls)
    {:ok, final} = Message.assistant("done", [])
    {:ok, agent} = Agent.start_link(fn -> [{:ok, tool_turn}, {:ok, final}] end)
    {:ok, session} =
      Elara.start_session(provider: {Elara.Provider.Scripted, agent}, cwd: #{inspect(cwd)}, plugins: [])

    {:ok, "done"} = Elara.ask(session, "use both tools")
    {:ok, pid} = Elara.session_pid(session)
    :ok = GenServer.stop(pid)
    """

    assert {"", 0} = fresh_vm(create)

    resume = """
    Application.put_env(:elara, :sessions_root, #{inspect(sessions_root)})
    {:ok, agent} = Agent.start_link(fn -> [] end)
    {:ok, session} =
      Elara.start_session(
        provider: {Elara.Provider.Scripted, agent},
        cwd: #{inspect(cwd)},
        plugins: [],
        resume: :latest
      )

    results = Enum.filter(Elara.transcript(session), &is_struct(&1, Elara.Message.ToolResult))
    true = Enum.map(results, & &1.name) == ["read", "bash"]
    IO.puts("resumed read and bash")
    """

    assert {"resumed read and bash\n", 0} = fresh_vm(resume)
  end

  test "start_session rejects missing and invalid resume targets" do
    cwd = unique_cwd()
    provider = script([])

    assert {:error, :no_session} =
             Elara.start_session(provider: provider, tools: [], cwd: cwd, resume: :latest)

    assert {:error, :invalid_resume} =
             Elara.start_session(provider: provider, tools: [], cwd: cwd, resume: 1)
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
             Elara.start_session(provider: script([]), tools: [], cwd: cwd, resume: :latest)

    assert Elara.transcript(session) == [Message.user("newer")]
  end

  test "in-place resume keeps the pid and failed resume leaves history unchanged" do
    cwd = unique_cwd()
    target = Store.new(cwd)
    user = Message.user("saved")
    assistant = asst("answer")
    assert {:ok, target} = Store.append(target, user)
    assert {:ok, target} = Store.append(target, assistant)

    assert {:ok, session} = Elara.start_session(provider: script([]), tools: [], cwd: cwd)

    same_pid = session
    assert {:ok, history} = Elara.resume(session, target.path)
    assert session == same_pid
    assert history == [user, assistant]
    assert Elara.transcript(session) == [user, assistant]

    missing = Path.join(Path.dirname(target.path), "missing.jsonl")
    assert {:error, :enoent} = Elara.resume(session, missing)
    assert Elara.transcript(session) == [user, assistant]
  end

  test "in-place resume refuses while busy" do
    cwd = unique_cwd()
    target = Store.new(cwd)
    assert {:ok, target} = Store.append(target, Message.user("saved"))

    assert {:ok, session} =
             Elara.start_session(
               provider: {BlockingProvider, self()},
               tools: [],
               cwd: cwd
             )

    assert :ok = Elara.ask_async(session, "busy")
    assert_receive {:provider_blocked, worker, %Provider.Request{}}
    assert {:error, :busy} = Elara.resume(session, target.path)
    send(worker, {:reply, asst("done")})
  end

  test "a stale provider response cannot complete a turn after a tree rebase" do
    cwd = unique_cwd()

    assert {:ok, session} =
             Elara.start_session(
               provider: {BlockingProvider, self()},
               tools: [],
               cwd: cwd
             )

    :ok = Elara.subscribe(session)
    assert :ok = Elara.ask_async(session, "question")
    assert_receive {:provider_blocked, stale_worker, %Provider.Request{}}

    Elara.interrupt(session)
    assert_receive {:elara, ^session, {:turn_ended, :interrupted}}

    [%{id: user_id}] = Elara.user_entries(session)
    assert {:ok, "question", []} = Elara.tree(session, user_id)
    assert :ok = Elara.ask_async(session, "question")
    assert_receive {:provider_blocked, current_worker, %Provider.Request{}}

    send(stale_worker, {:reply, asst("stale")})

    refute_receive {:elara, ^session, {:message_appended, %Message.Assistant{text: "stale"}}},
                   100

    send(current_worker, {:reply, asst("current")})
    assert_receive {:elara, ^session, {:turn_ended, {:completed, "current"}}}
    assert Elara.transcript(session) == [Message.user("question"), asst("current")]
  end

  test "persist: false never writes a session file" do
    cwd = unique_cwd()

    assert {:ok, session} =
             Elara.start_session(
               provider: script([{:ok, asst("answer")}]),
               tools: [],
               cwd: cwd,
               persist: false
             )

    assert {:ok, "answer"} = Elara.ask(session, "question")
    assert Store.list(cwd) == []
  end

  test "a named session is listable before any user turn" do
    cwd = unique_cwd()

    assert {:ok, _session} =
             Elara.start_session(provider: script([]), tools: [], cwd: cwd, name: "startup")

    [info] = Elara.list_sessions(cwd)
    assert info.name == "startup"
  end

  test "a second writer cannot open the same session file" do
    cwd = unique_cwd()
    store = Store.new(cwd)
    assert {:ok, store} = Store.append(store, Message.user("held"))

    assert {:ok, _session} =
             Elara.start_session(
               provider: script([]),
               tools: [],
               cwd: cwd,
               resume: store.path
             )

    assert {:error, :locked} =
             Elara.start_session(
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
             Elara.start_session(
               provider: next_provider,
               tools: [],
               cwd: cwd,
               resume: store.path
             )

    repaired = Message.tool_result(second, {:error, "interrupted"})
    prior = [Message.user("read both"), assistant, completed, repaired]
    assert Elara.transcript(session) == prior

    {:ok, on_disk} = Store.open(store.path, cwd)
    assert Store.history(on_disk) == prior

    assert {:ok, "after"} = Elara.ask(session, "next")

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

    {:ok, session} = Elara.start_session(provider: provider, tools: [], cwd: cwd)

    assert {:ok, "a1"} = Elara.ask(session, "q1")
    assert_receive {:provider_observed, %Provider.Request{}, _}
    assert {:ok, "a2"} = Elara.ask(session, "q2")
    assert_receive {:provider_observed, %Provider.Request{}, _}

    [%{id: _first}, %{id: second}] = Elara.user_entries(session)
    assert {:ok, "q2", prior} = Elara.tree(session, second)
    assert prior == [Message.user("q1"), asst("a1")]
    assert {:ok, "alternate"} = Elara.ask(session, "q2")

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
    {:ok, session} = Elara.start_session(provider: provider, tools: [], cwd: cwd)

    assert {:ok, "a1"} = Elara.ask(session, "q1")
    assert_receive {:provider_observed, %Provider.Request{}, _}
    assert {:ok, "a2"} = Elara.ask(session, "q2")
    assert_receive {:provider_observed, %Provider.Request{}, _}

    [source_info] = Store.list(cwd)
    {:ok, source_before} = Store.open(source_info.path, cwd)
    [%{id: _first}, %{id: second}] = Elara.user_entries(session)

    assert {:ok, "q2", copied_history} = Elara.fork(session, second)
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

  test "persisted transcripts and fork history are identical with or without deltas" do
    streamed_cwd = unique_cwd()
    plain_cwd = unique_cwd()

    {:ok, streamed} =
      Elara.start_session(
        provider:
          script([
            {:stream, ["a", "1"], {:ok, asst("a1")}},
            {:stream, ["a", "2"], {:ok, asst("a2")}}
          ]),
        tools: [],
        cwd: streamed_cwd
      )

    {:ok, plain} =
      Elara.start_session(
        provider: script([{:ok, asst("a1")}, {:ok, asst("a2")}]),
        tools: [],
        cwd: plain_cwd
      )

    for session <- [streamed, plain] do
      assert {:ok, "a1"} = Elara.ask(session, "q1")
      assert {:ok, "a2"} = Elara.ask(session, "q2")
    end

    assert Elara.transcript(streamed) == Elara.transcript(plain)
    [%{id: _}, %{id: streamed_second}] = Elara.user_entries(streamed)
    [%{id: _}, %{id: plain_second}] = Elara.user_entries(plain)

    assert {:ok, "q2", streamed_history} = Elara.fork(streamed, streamed_second)
    assert {:ok, "q2", plain_history} = Elara.fork(plain, plain_second)
    assert streamed_history == plain_history
    assert streamed_history == [Message.user("q1"), asst("a1")]

    streamed_store =
      streamed_cwd
      |> Store.list()
      |> Enum.map(fn info ->
        {:ok, store} = Store.open(info.path, streamed_cwd)
        store
      end)
      |> Enum.find(& &1.parent_session)

    plain_store =
      plain_cwd
      |> Store.list()
      |> Enum.map(fn info ->
        {:ok, store} = Store.open(info.path, plain_cwd)
        store
      end)
      |> Enum.find(& &1.parent_session)

    assert Store.history(streamed_store) == Store.history(plain_store)
  end
end
