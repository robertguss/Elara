defmodule Harness.ExecutorTest do
  use ExUnit.Case, async: false

  alias Harness.Executor.{Remote, Request, Router}
  alias Harness.Message
  alias Harness.Message.{ToolCall, ToolResult}
  alias Harness.Tool
  alias Harness.Worker.Server, as: WorkerServer

  setup do
    root = Path.join(System.tmp_dir!(), "harness-worker-#{System.unique_integer([:positive])}")
    brain = Path.join(root, "brain")
    worker = Path.join(root, "worker")
    File.mkdir_p!(brain)
    File.mkdir_p!(worker)
    on_exit(fn -> File.rm_rf!(root) end)
    %{brain: brain, worker: worker, workspace_id: "test-workspace"}
  end

  defp asst(text, calls \\ []) do
    {:ok, assistant} = Message.assistant(text, calls)
    assistant
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Harness.Provider.Scripted, agent}
  end

  defp tool(name, placement \\ :remote) do
    Tool.builtins()
    |> Enum.find(&(&1.name == name))
    |> Map.put(:placement, placement)
  end

  defp start_router(worker_pid, workspace_id, token) do
    {:ok, router} = Router.start_link()

    :ok =
      Router.register(router,
        id: "worker-1",
        executor: {Remote, %{port: WorkerServer.port(worker_pid), token: token}},
        capabilities: WorkerServer.capabilities(worker_pid),
        workspaces: [workspace_id]
      )

    router
  end

  defp start_worker(
         dir,
         workspace_id,
         token,
         capabilities \\ [
           "filesystem:read",
           "filesystem:write",
           "shell"
         ]
       ) do
    {:ok, worker} =
      WorkerServer.start_link(
        port: 0,
        token: token,
        capabilities: capabilities,
        workspaces: %{workspace_id => dir}
      )

    Process.unlink(worker)
    worker
  end

  test "request wire value contains identity, deadline, cancellation, capabilities, and placement" do
    request = %Request{
      tool_call_id: "call",
      session_id: "session",
      tool_name: "read",
      tool_version: "1",
      arguments: %{"path" => "a.txt"},
      workspace_id: "workspace",
      deadline_ms: 123,
      cancellation_id: "cancel",
      required_capabilities: ["filesystem:read"],
      placement: :remote,
      mutating: false
    }

    encoded = Request.to_map(request)
    refute Map.has_key?(encoded, "cwd")
    assert {:ok, ^request} = Request.from_map(encoded)
    assert is_binary(JSON.encode!(encoded))
  end

  test "filesystem and shell tools execute in an authenticated remote workspace", context do
    token = "worker-secret"
    worker = start_worker(context.worker, context.workspace_id, token)
    router = start_router(worker, context.workspace_id, token)
    File.write!(Path.join(context.worker, "remote.txt"), "from worker")

    read_call = %ToolCall{id: "read-1", name: "read", args: {:ok, %{"path" => "remote.txt"}}}

    write_call = %ToolCall{
      id: "write-1",
      name: "write",
      args: {:ok, %{"path" => "made.txt", "content" => "remote write"}}
    }

    provider =
      script([
        {:ok, asst(nil, [read_call, write_call])},
        {:ok, asst("done")}
      ])

    {:ok, session} =
      Harness.start_session(
        provider: provider,
        cwd: context.brain,
        persist: false,
        plugins: [],
        tools: [tool("read"), tool("write")],
        router: router,
        workspace_id: context.workspace_id
      )

    assert {:ok, "done"} = Harness.ask(session, "remote work")

    results = Enum.filter(Harness.transcript(session), &is_struct(&1, ToolResult))
    assert [%ToolResult{outcome: {:ok, "from worker"}}, %ToolResult{outcome: {:ok, _}}] = results
    assert File.read!(Path.join(context.worker, "made.txt")) == "remote write"
    refute File.exists?(Path.join(context.brain, "made.txt"))
  end

  test "read-only requests retry once on another healthy matching worker", context do
    token = "worker-secret"
    dead = start_worker(context.worker, context.workspace_id, token)
    dead_port = WorkerServer.port(dead)
    Process.exit(dead, :kill)
    Process.sleep(20)

    healthy = start_worker(context.worker, context.workspace_id, token)
    File.write!(Path.join(context.worker, "retry.txt"), "retried")
    {:ok, router} = Router.start_link()

    :ok =
      Router.register(router,
        id: "a-dead",
        executor: {Remote, %{port: dead_port, token: token}},
        capabilities: ["filesystem:read"],
        workspaces: [context.workspace_id]
      )

    :ok =
      Router.register(router,
        id: "b-healthy",
        executor: {Remote, %{port: WorkerServer.port(healthy), token: token}},
        capabilities: ["filesystem:read"],
        workspaces: [context.workspace_id]
      )

    request = %Request{
      tool_call_id: "read-retry",
      session_id: "session",
      tool_name: "read",
      tool_version: "1",
      arguments: %{"path" => "retry.txt"},
      workspace_id: context.workspace_id,
      deadline_ms: System.system_time(:millisecond) + 2_000,
      cancellation_id: "cancel",
      required_capabilities: ["filesystem:read"],
      placement: :remote,
      mutating: false
    }

    assert {:ok, "retried"} = Router.execute(router, request, tool("read"), context.brain)
    assert Enum.any?(Router.workers(router), &(&1.id == "a-dead" and not &1.healthy?))
  end

  test "worker death yields one indeterminate mutation result and replacement continues",
       context do
    token = "worker-secret"
    worker = start_worker(context.worker, context.workspace_id, token)
    router = start_router(worker, context.workspace_id, token)

    first_call = %ToolCall{
      id: "bash-1",
      name: "bash",
      args: {:ok, %{"command" => "printf side-effect > marker; sleep 5"}}
    }

    second_call = %ToolCall{
      id: "bash-2",
      name: "bash",
      args: {:ok, %{"command" => "printf replacement"}}
    }

    provider =
      script([
        {:ok, asst(nil, [first_call])},
        {:ok, asst("survived")},
        {:ok, asst(nil, [second_call])},
        {:ok, asst("continued")}
      ])

    {:ok, session} =
      Harness.start_session(
        provider: provider,
        cwd: context.brain,
        persist: false,
        plugins: [],
        tools: [tool("bash")],
        router: router,
        workspace_id: context.workspace_id,
        tool_timeout_ms: 10_000
      )

    :ok = Harness.subscribe(session)
    :ok = Harness.ask_async(session, "first")
    assert_receive {:harness, ^session, {:tool_started, %ToolCall{id: "bash-1"}}}, 1_000
    Process.sleep(100)
    Process.exit(worker, :kill)

    assert_receive {:harness, ^session,
                    {:message_appended,
                     %ToolResult{call_id: "bash-1", outcome: {:indeterminate, _}}}},
                   2_000

    assert_receive {:harness, ^session, {:turn_ended, {:completed, "survived"}}}, 1_000
    {:ok, session_pid} = Harness.session_pid(session)
    assert Process.alive?(session_pid)

    first_results =
      Harness.transcript(session)
      |> Enum.filter(&match?(%ToolResult{call_id: "bash-1"}, &1))

    assert length(first_results) == 1
    assert File.read!(Path.join(context.worker, "marker")) == "side-effect"
    assert Enum.any?(Router.workers(router), &(&1.id == "worker-1" and not &1.healthy?))

    replacement = start_worker(context.worker, context.workspace_id, token)

    :ok =
      Router.register(router,
        id: "worker-1",
        executor: {Remote, %{port: WorkerServer.port(replacement), token: token}},
        capabilities: WorkerServer.capabilities(replacement),
        workspaces: [context.workspace_id]
      )

    assert {:ok, "continued"} = Harness.ask(session, "second")

    assert %ToolResult{call_id: "bash-2", outcome: {:ok, "replacement"}} =
             Enum.find(Harness.transcript(session), &match?(%ToolResult{call_id: "bash-2"}, &1))
  end

  test "capability permissions deny execution before routing", context do
    call = %ToolCall{
      id: "write-1",
      name: "write",
      args: {:ok, %{"path" => "x", "content" => "x"}}
    }

    provider = script([{:ok, asst(nil, [call])}, {:ok, asst("denied")}])

    {:ok, session} =
      Harness.start_session(
        provider: provider,
        cwd: context.brain,
        persist: false,
        plugins: [],
        tools: [tool("write", :any)],
        allowed_capabilities: ["filesystem:read"]
      )

    assert {:ok, "denied"} = Harness.ask(session, "write")

    assert Enum.any?(Harness.transcript(session), fn
             %ToolResult{outcome: {:error, "permission denied:" <> _}} -> true
             _ -> false
           end)

    refute File.exists?(Path.join(context.brain, "x"))
  end
end
