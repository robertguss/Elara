defmodule Elara.ExecutorTest do
  use ExUnit.Case, async: false

  alias Elara.Executor.{Remote, Request, Router}
  alias Elara.Message
  alias Elara.Message.{ToolCall, ToolResult}
  alias Elara.Tool
  alias Elara.Worker.Server, as: WorkerServer

  setup do
    root = Path.join(System.tmp_dir!(), "elara-worker-#{System.unique_integer([:positive])}")
    brain = Path.join(root, "brain")
    worker = Path.join(root, "worker")
    File.mkdir_p!(brain)
    File.mkdir_p!(worker)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, brain: brain, worker: worker, workspace_id: "test-workspace"}
  end

  defp asst(text, calls \\ []) do
    {:ok, assistant} = Message.assistant(text, calls)
    assistant
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
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

  test "request wire value contains identity, deadline, output cap, cancellation, capabilities, and placement" do
    request = %Request{
      job_id: "er1j_v1_job",
      operation_digest: String.duplicate("a", 64),
      tool_call_id: "call",
      session_id: "session",
      tool_name: "read",
      tool_version: "1",
      arguments: %{"path" => "a.txt"},
      workspace_id: "workspace",
      deadline_ms: 123,
      max_output_bytes: 16_384,
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
      Elara.start_session(
        provider: provider,
        cwd: context.brain,
        persist: false,
        plugins: [],
        tools: [tool("read"), tool("write")],
        router: router,
        workspace_id: context.workspace_id
      )

    assert {:ok, "done"} = Elara.ask(session, "remote work")

    results = Enum.filter(Elara.transcript(session), &is_struct(&1, ToolResult))
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
      max_output_bytes: 16_384,
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
      Elara.start_session(
        provider: provider,
        cwd: context.brain,
        persist: false,
        plugins: [],
        tools: [tool("bash")],
        router: router,
        workspace_id: context.workspace_id,
        tool_timeout_ms: 10_000
      )

    :ok = Elara.subscribe(session)
    :ok = Elara.ask_async(session, "first")
    assert_receive {:elara, ^session, {:tool_started, %ToolCall{id: "bash-1"}}}, 1_000
    Process.sleep(100)
    Process.exit(worker, :kill)

    assert_receive {:elara, ^session,
                    {:message_appended,
                     %ToolResult{call_id: "bash-1", outcome: {:indeterminate, _}}}},
                   2_000

    assert_receive {:elara, ^session, {:turn_ended, {:completed, "survived"}}}, 1_000
    {:ok, session_pid} = Elara.session_pid(session)
    assert Process.alive?(session_pid)

    first_results =
      Elara.transcript(session)
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

    assert {:ok, "continued"} = Elara.ask(session, "second")

    assert %ToolResult{call_id: "bash-2", outcome: {:ok, "replacement"}} =
             Enum.find(Elara.transcript(session), &match?(%ToolResult{call_id: "bash-2"}, &1))
  end

  test "capability permissions deny execution before routing", context do
    call = %ToolCall{
      id: "write-1",
      name: "write",
      args: {:ok, %{"path" => "x", "content" => "x"}}
    }

    provider = script([{:ok, asst(nil, [call])}, {:ok, asst("denied")}])

    {:ok, session} =
      Elara.start_session(
        provider: provider,
        cwd: context.brain,
        persist: false,
        plugins: [],
        tools: [tool("write", :any)],
        allowed_capabilities: ["filesystem:read"]
      )

    assert {:ok, "denied"} = Elara.ask(session, "write")

    assert Enum.any?(Elara.transcript(session), fn
             %ToolResult{outcome: {:error, "permission denied:" <> _}} -> true
             _ -> false
           end)

    refute File.exists?(Path.join(context.brain, "x"))
  end

  test "router and worker reject forged canonical tool metadata", context do
    token = "worker-secret"
    worker = start_worker(context.worker, context.workspace_id, token, ["filesystem:read"])
    write = tool("write")

    forged = %Request{
      tool_call_id: "forged-write",
      session_id: "session",
      tool_name: "write",
      tool_version: "1",
      arguments: %{"path" => "forged.txt", "content" => "forged"},
      workspace_id: context.workspace_id,
      deadline_ms: System.system_time(:millisecond) + 2_000,
      max_output_bytes: 16_384,
      cancellation_id: "cancel",
      required_capabilities: [],
      placement: :remote,
      mutating: false
    }

    {:ok, router} = Router.start_link()

    assert {:error, "executor request metadata does not match tool"} =
             Router.execute(router, forged, write, context.brain)

    assert {:executor_error, :rejected, "tool_metadata_mismatch"} =
             Remote.execute(%{port: WorkerServer.port(worker), token: token}, forged, write)

    refute File.exists?(Path.join(context.worker, "forged.txt"))

    canonical = %{
      forged
      | required_capabilities: ["filesystem:write"],
        mutating: true,
        deadline_ms: System.system_time(:millisecond) + 2_000
    }

    assert {:executor_error, :rejected, "capability_denied"} =
             Remote.execute(%{port: WorkerServer.port(worker), token: token}, canonical, write)

    refute File.exists?(Path.join(context.worker, "forged.txt"))
  end

  test "remote filesystem tools reject absolute traversal and symlink escapes", context do
    token = "worker-secret"
    worker = start_worker(context.worker, context.workspace_id, token)
    write = tool("write")
    read = tool("read")
    outside = Path.join(context.root, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "secret")
    File.ln_s!(outside, Path.join(context.worker, "escape"))
    config = %{port: WorkerServer.port(worker), token: token}

    write_request = fn path ->
      %Request{
        tool_call_id: "confined-write",
        session_id: "session",
        tool_name: "write",
        tool_version: "1",
        arguments: %{"path" => path, "content" => "escaped"},
        workspace_id: context.workspace_id,
        deadline_ms: System.system_time(:millisecond) + 2_000,
        max_output_bytes: 16_384,
        cancellation_id: "cancel",
        required_capabilities: ["filesystem:write"],
        placement: :remote,
        mutating: true
      }
    end

    for path <- [Path.join(outside, "absolute.txt"), "../traversal.txt", "escape/new.txt"] do
      assert {:executor_error, :rejected, "path_outside_workspace"} =
               Remote.execute(config, write_request.(path), write)
    end

    read_request = %Request{
      tool_call_id: "confined-read",
      session_id: "session",
      tool_name: "read",
      tool_version: "1",
      arguments: %{"path" => "escape/secret.txt"},
      workspace_id: context.workspace_id,
      deadline_ms: System.system_time(:millisecond) + 2_000,
      max_output_bytes: 16_384,
      cancellation_id: "cancel",
      required_capabilities: ["filesystem:read"],
      placement: :remote,
      mutating: false
    }

    assert {:executor_error, :rejected, "path_outside_workspace"} =
             Remote.execute(config, read_request, read)

    refute File.exists?(Path.join(outside, "absolute.txt"))
    refute File.exists?(Path.join(context.root, "traversal.txt"))
    refute File.exists?(Path.join(outside, "new.txt"))
  end
end
