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

  defmodule GatedMutation do
    def run(_args, _ctx) do
      send(Process.whereis(Elara.SessionTest), {:mutation_running, self()})

      receive do
        :finish -> {:ok, "running mutation finished"}
      end
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

  test "read-only toggles mid-turn, preserves running calls, fences later calls and persists" do
    Process.register(self(), __MODULE__)
    cwd = Path.join(System.tmp_dir!(), "read-only-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    File.write!(Path.join(cwd, "note"), "original")
    on_exit(fn -> File.rm_rf!(cwd) end)

    call = fn id, name, args -> %ToolCall{id: id, name: name, args: {:ok, args}} end

    attempts = [
      call.("write", "write", %{"path" => "new", "content" => "bad"}),
      call.("edit", "edit", %{"path" => "note", "old_text" => "original", "new_text" => "bad"}),
      call.("bash", "bash", %{"command" => "printf bad > shell-output"}),
      call.("read", "read", %{"path" => "note"})
    ]

    gate = %Tool{
      name: "gate",
      parameters: %{},
      description: "test mutation",
      run: {GatedMutation, :run},
      mutating: true
    }

    provider =
      script([
        {:ok, asst(nil, [call.("gate", "gate", %{}) | attempts])},
        {:ok, asst("protected")},
        {:ok, asst(nil, [call.("restored", "write", %{"path" => "new", "content" => "good"})])},
        {:ok, asst("restored")}
      ])

    {:ok, session} =
      Elara.start_session(
        cwd: cwd,
        provider: provider,
        tools: [gate | Tool.builtins()],
        plugins: []
      )

    :ok = Elara.subscribe(session)
    :ok = Elara.ask_async(session, "inspect")
    assert_receive {:mutation_running, running}, 1_000
    assert {:ok, true} = Elara.set_read_only(session, true)
    assert Elara.snapshot(session).snapshot["inbox"]["execution"]["read_only"]
    send(running, :finish)
    assert_receive {:elara, ^session, {:turn_ended, {:completed, "protected"}}}, 2_000
    outcomes = for %Message.ToolResult{outcome: result} <- Elara.transcript(session), do: result

    assert [
             {:ok, "running mutation finished"},
             {:error, w},
             {:error, e},
             {:error, b},
             {:ok, "original"}
           ] = outcomes

    assert Enum.all?([w, e, b], &String.contains?(&1, "session is read-only"))
    assert File.read!(Path.join(cwd, "note")) == "original"
    refute File.exists?(Path.join(cwd, "new"))
    refute File.exists?(Path.join(cwd, "shell-output"))
    assert {:ok, %{status: :match}} = Elara.replay(Elara.recording(session))

    {:ok, info} = Store.newest(cwd)
    {:ok, stored} = Store.open(info.path)

    assert [
             %{
               "read_only" => true,
               "turn" => %{"state" => "running_tool", "tool_call_id" => "gate"}
             }
           ] = stored.context["read_only_changes"]

    assert Elara.child_config(session).read_only
    assert {:ok, copy, _, _} = Elara.clone_session(session)
    assert copy != session
    assert Elara.snapshot(copy).snapshot["inbox"]["execution"]["read_only"]
    GenServer.stop(session_pid(copy))
    GenServer.stop(session_pid(session))

    {:ok, reopened} =
      Elara.start_session(cwd: cwd, resume: info.path, provider: provider, plugins: [])

    assert Elara.snapshot(reopened).snapshot["inbox"]["execution"]["read_only"]
    assert {:ok, false} = Elara.set_read_only(reopened, false)
    assert {:ok, "restored"} = Elara.ask(reopened, "write now")
    assert File.read!(Path.join(cwd, "new")) == "good"
    GenServer.stop(session_pid(reopened))
  end

  test "turning read-only off during a provider call restores its next mutation" do
    cwd = Path.join(System.tmp_dir!(), "read-only-off-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)

    {:ok, session} =
      Elara.start_session(
        cwd: cwd,
        read_only: true,
        provider: {BlockingProvider, self()},
        plugins: []
      )

    :ok = Elara.subscribe(session)
    assert :ok = Elara.ask_async(session, "write")
    assert_receive {:provider_blocked, provider, _}, 1_000
    assert {:ok, false} = Elara.set_read_only(session, false)

    send(
      provider,
      {:reply,
       asst(nil, [
         %ToolCall{
           id: "write",
           name: "write",
           args: {:ok, %{"path" => "note", "content" => "restored mid-turn"}}
         }
       ])}
    )

    assert_receive {:provider_blocked, provider, _}, 1_000
    assert File.read!(Path.join(cwd, "note")) == "restored mid-turn"
    send(provider, {:reply, asst("done")})
    assert_receive {:elara, ^session, {:turn_ended, {:completed, "done"}}}, 1_000
    assert {:ok, %{status: :match}} = Elara.replay(Elara.recording(session))
    GenServer.stop(session_pid(session))
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

  test "default turn budget reaches 100 provider calls and an explicit limit reaches 50" do
    for opts <- [[], [max_iterations: 50]] do
      limit = Keyword.get(opts, :max_iterations, 100)

      replies =
        for n <- 1..(limit - 1) do
          {:ok, asst(nil, [%ToolCall{id: "call-#{n}", name: "absent", args: {:ok, %{}}}])}
        end

      provider = script(replies ++ [{:ok, asst("finished #{limit}")}])

      {:ok, session} =
        Elara.start_session([provider: provider, tools: [], persist: false] ++ opts)

      assert {:ok, "finished #{limit}"} == Elara.ask(session, "continue until finished")
      assert Enum.count(Elara.transcript(session), &match?(%Message.Assistant{}, &1)) == limit
    end
  end

  @tag :tmp_dir
  test "bash per-call deadline replaces the default but respects the ceiling", %{tmp_dir: cwd} do
    calls = [
      %{"command" => "sleep 0.15; printf completed", "timeout_ms" => 1_000},
      %{"command" => "touch rejected", "timeout_ms" => 1_001},
      %{"command" => "sleep 2", "timeout_ms" => 20}
    ]

    replies =
      for {args, n} <- Enum.with_index(calls) do
        {:ok, asst(nil, [%ToolCall{id: "bash-#{n}", name: "bash", args: {:ok, args}}])}
      end

    {:ok, session} =
      Elara.start_session(
        provider: script(replies ++ [{:ok, asst("finished")}]),
        tools: [Enum.find(Tool.builtins(), &(&1.name == "bash"))],
        cwd: cwd,
        persist: false,
        tool_timeout_ms: 50,
        max_tool_timeout_ms: 1_000
      )

    assert {:ok, "finished"} = Elara.ask(session, "run commands")
    results = for %Message.ToolResult{outcome: outcome} <- Elara.transcript(session), do: outcome
    assert [{:ok, "completed"}, {:error, rejected}, {:indeterminate, timed_out}] = results
    assert rejected =~ "1 to 1000"
    refute File.exists?(Path.join(cwd, "rejected"))
    assert timed_out =~ "timed out"
    assert timed_out =~ "longer timeout_ms"
    assert timed_out =~ "partially changed"
  end

  @tag :tmp_dir
  test "pending limits compose without changing remaining calls or tools in the active turn", %{
    tmp_dir: cwd
  } do
    {:ok, session} =
      Elara.start_session(
        provider: {BlockingProvider, self()},
        cwd: cwd,
        tools: [Enum.find(Tool.builtins(), &(&1.name == "bash"))],
        persist: false,
        max_iterations: 3,
        tool_timeout_ms: 2_000
      )

    {:ok, _} = Elara.attach(session, :control)
    task = Task.async(fn -> Elara.ask(session, "active") end)
    assert_receive {:provider_blocked, provider, _}, 2_000
    assert {:ok, true} = Elara.attached_command(session, {:runtime_limits, %{max_iterations: 1}})

    assert {:ok, true} =
             Elara.attached_command(session, {:runtime_limits, %{tool_timeout_ms: 50}})

    limits = Elara.materialized_view(session)["runtime_limits"]
    assert limits["next_turn"]["max_iterations"] == 1
    assert limits["next_turn"]["tool_timeout_ms"] == 50
    assert limits["active_turn"]["max_iterations"] == 3
    assert limits["active_turn"]["tool_timeout_ms"] == 2_000
    assert limits["sources"]["max_iterations"] == "session"
    assert limits["sources"]["tool_timeout_ms"] == "session"
    {:ok, pid} = Elara.session_pid(session)
    assert %{max_iterations: 1, tool_timeout_ms: 50} = GenServer.call(pid, :child_config)

    call = %ToolCall{
      id: "active-bash",
      name: "bash",
      args: {:ok, %{"command" => "sleep 0.15; printf survived"}}
    }

    send(provider, {:reply, asst(nil, [call])})
    assert_receive {:provider_blocked, provider, _}, 2_000
    send(provider, {:reply, asst("active finished")})
    assert {:ok, "active finished"} = Task.await(task)

    assert Enum.any?(
             Elara.transcript(session),
             &match?(%Message.ToolResult{outcome: {:ok, "survived"}}, &1)
           )

    task = Task.async(fn -> Elara.ask(session, "next") end)
    assert_receive {:provider_blocked, provider, _}, 2_000
    send(provider, {:reply, asst(nil, [%ToolCall{call | id: "next-bash"}])})
    assert {:error, :turn_limit} = Task.await(task)

    assert Enum.any?(
             Elara.transcript(session),
             &match?(%Message.ToolResult{outcome: {:indeterminate, _}}, &1)
           )

    assert {:ok, %{status: :match}} = Elara.replay(Elara.recording(session))
  end

  @tag :tmp_dir
  test "session overrides reattach but are not restored from the transcript after restart", %{
    tmp_dir: cwd
  } do
    {:ok, session} =
      Elara.start_session(
        provider: script([{:ok, asst("done")}]),
        cwd: cwd,
        tools: [],
        max_iterations: 7,
        tool_timeout_ms: 60_000
      )

    {:ok, _} = Elara.attach(session, :control)
    assert {:ok, false} = Elara.attached_command(session, {:runtime_limits, %{max_iterations: 2}})

    assert {:error, {:timeout_exceeds_ceiling, 3_600_000}} =
             Elara.attached_command(session, {:runtime_limits, %{tool_timeout_ms: 3_600_001}})

    for invalid <- [
          %{},
          %{max_iterations: 0},
          %{tool_timeout_ms: "20m"},
          %{max_tool_timeout_ms: 7_200_000}
        ] do
      assert {:error, :invalid_runtime_limits} =
               Elara.attached_command(session, {:runtime_limits, invalid})
    end

    observer =
      Task.async(fn ->
        {:ok, attachment} = Elara.attach(session, :observe)
        assert attachment.snapshot["runtime_limits"]["next_turn"]["max_iterations"] == 2
        Elara.attached_command(session, {:runtime_limits, %{max_iterations: 9}})
      end)

    assert {:error, :not_controller} = Task.await(observer)
    assert {:ok, "done"} = Elara.ask(session, "recorded turn")
    {:ok, info} = Store.newest(cwd)
    {:ok, pid} = Elara.session_pid(session)
    :ok = DynamicSupervisor.terminate_child(Elara.SessionSup, pid)

    {:ok, reopened} =
      Elara.start_session(
        provider: script([]),
        cwd: cwd,
        tools: [],
        resume: info.path,
        max_iterations: 7,
        tool_timeout_ms: 60_000
      )

    limits = Elara.materialized_view(reopened)["runtime_limits"]
    assert limits["next_turn"]["max_iterations"] == 7
    assert limits["next_turn"]["tool_timeout_ms"] == 60_000
    assert limits["sources"]["max_iterations"] == "config"
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

  @restarted "session restarted while this call may have been running; " <>
               "its outcome is unknown and it may have partially changed the workspace"

  test "resume without an executor keeps the possibly running call indeterminate" do
    cwd = unique_cwd()
    first = %ToolCall{id: "call-1", name: "mark", args: {:ok, %{"label" => "a"}}}
    second = %ToolCall{id: "call-2", name: "mark", args: {:ok, %{"label" => "b"}}}
    {:ok, assistant} = Message.assistant(nil, [first, second])

    store = Store.new(cwd)
    assert {:ok, store} = Store.append(store, Message.user("write both"))
    assert {:ok, store} = Store.append(store, assistant)

    next_provider = recording_script([{:ok, asst("after")}], cwd)

    assert {:ok, session} =
             Elara.start_session(
               provider: next_provider,
               tools: [
                 %Elara.Tool{
                   name: "mark",
                   description: "mutating test tool, never run here",
                   parameters: %{"type" => "object"},
                   mutating: true,
                   run: {Elara.Tools, :write}
                 }
               ],
               cwd: cwd,
               resume: store.path
             )

    prior = [
      Message.user("write both"),
      assistant,
      Message.tool_result(first, {:indeterminate, @restarted}),
      Message.tool_result(second, {:error, "interrupted"})
    ]

    assert Elara.transcript(session) == prior
    {:ok, on_disk} = Store.open(store.path, cwd)
    assert Store.history(on_disk) == prior

    assert {:ok, "after"} = Elara.ask(session, "next")
    assert_receive {:provider_observed, %Provider.Request{messages: request_messages}, _}
    assert request_messages == prior ++ [Message.user("next")]
    GenServer.stop(session_pid(session))
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

    repaired = Message.tool_result(second, {:indeterminate, @restarted})
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
