defmodule Elara.ServerTest do
  use ExUnit.Case, async: false

  alias Elara.Message
  alias Elara.Message.ToolCall
  alias Elara.Protocol

  defp asst(text, calls \\ []) do
    {:ok, assistant} = Message.assistant(text, calls)
    assistant
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        port,
        [:binary, packet: :line, packet_size: 16 * 1_024 * 1_024, active: false]
      )

    socket
  end

  defp send_json(socket, message), do: :gen_tcp.send(socket, Protocol.encode(message))

  defp recv_json(socket, timeout \\ 2_000) do
    {:ok, line} = recv_line(socket, timeout)
    {:ok, message} = Protocol.decode(line)
    message
  end

  defp recv_line(socket, timeout, line_buffer \\ {[], 0}) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, timeout)

    case Protocol.push_line(line_buffer, chunk) do
      {:ok, line} -> {:ok, line}
      {:more, line_buffer} -> recv_line(socket, timeout, line_buffer)
    end
  end

  defp attach(socket, session, mode) do
    :ok =
      send_json(socket, %{
        "version" => 2,
        "command" => "attach",
        "session_id" => session,
        "mode" => mode
      })

    recv_json(socket)
  end

  defp projector(%{"snapshot" => snapshot, "incarnation" => incarnation, "head" => head}),
    do: Elara.Protocol.Projector.new(snapshot, incarnation, head)

  # Apply patches until the view satisfies `done?`; command replies are skipped.
  defp ingest_until(socket, projector, done?) do
    if done?.(projector.view) do
      projector
    else
      case recv_json(socket, 5_000) do
        %{"type" => "patch", "incarnation" => incarnation, "seq" => seq, "ops" => ops} ->
          {:applied, projector} =
            Elara.Protocol.Projector.ingest_patch(projector, incarnation, seq, ops)

          ingest_until(socket, projector, done?)

        %{"type" => type} when type in ["ok", "error"] ->
          ingest_until(socket, projector, done?)
      end
    end
  end

  # Unnegotiated attachments omit provider_view and inbox; compare the rest.
  defp core(view), do: Map.take(view, ["messages", "tool_calls", "turn"])

  defp tool_running?(view), do: Enum.any?(view["tool_calls"], &(&1["status"] == "running"))

  defp finished?(view),
    do:
      view["turn"]["state"] == "idle" and
        Enum.any?(view["messages"], &(&1["text"] == "continued"))

  test "stable IDs resolve to live sessions while PID compatibility remains" do
    {:ok, session} =
      Elara.start_session(provider: script([{:ok, asst("hello")}]), tools: [], persist: false)

    assert is_binary(session)
    assert {:ok, pid} = Elara.session_pid(session)
    assert {:ok, ^pid} = Elara.session_pid(pid)
    assert {:ok, "hello"} = Elara.ask(session, "hi")
    assert Elara.transcript(pid) == Elara.transcript(session)
  end

  test "client detaches during a tool; reattachers get the current state and observers cannot control" do
    call = %ToolCall{
      id: "slow-1",
      name: "bash",
      args: {:ok, %{"command" => "sleep 0.2; printf finished"}}
    }

    provider = script([{:ok, asst(nil, [call])}, {:ok, asst("continued")}])
    {:ok, server} = Elara.Server.start_link(port: 0, provider: provider)
    port = Elara.Server.port(server)

    controller = connect(port)

    :ok =
      send_json(controller, %{
        "version" => 2,
        "command" => "create",
        "mode" => "control",
        "cwd" => File.cwd!()
      })

    attached = recv_json(controller)

    assert %{"type" => "attached", "version" => 2, "session_id" => session, "head" => 0} =
             attached

    :ok = send_json(controller, %{"version" => 2, "command" => "ask", "prompt" => "run it"})
    ingest_until(controller, projector(attached), &tool_running?/1)

    :ok = :gen_tcp.close(controller)
    {:ok, session_pid} = Elara.session_pid(session)
    assert Process.alive?(session_pid)

    observer = connect(port)
    observed = attach(observer, session, "observe")
    assert %{"type" => "attached", "mode" => "observe"} = observed

    :ok = send_json(observer, %{"version" => 2, "command" => "ask", "prompt" => "not allowed"})
    projection = ingest_until(observer, projector(observed), &finished?/1)
    assert core(projection.view) == core(Elara.materialized_view(session))
    refute Enum.any?(projection.view["messages"], &(&1["text"] == "not allowed"))

    # A later reattacher sees the finished turn in its snapshot alone.
    second_observer = connect(port)

    assert %{"type" => "attached", "snapshot" => snapshot} =
             attach(second_observer, session, "observe")

    assert finished?(snapshot)
    assert core(snapshot) == core(Elara.materialized_view(session))

    :ok = :gen_tcp.close(observer)
    :ok = :gen_tcp.close(second_observer)
  end

  test "an observer command is refused as not_controller" do
    {:ok, session} =
      Elara.start_session(provider: script([{:ok, asst("done")}]), tools: [], persist: false)

    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]))
    observer = connect(Elara.Server.port(server))
    assert %{"type" => "attached"} = attach(observer, session, "observe")
    :ok = send_json(observer, %{"version" => 2, "command" => "ask", "prompt" => "not allowed"})

    assert %{"type" => "error", "version" => 2, "error" => "not_controller"} =
             recv_json(observer)

    :gen_tcp.close(observer)
  end

  test "control is exclusive and observers may attach alongside it" do
    {:ok, session} =
      Elara.start_session(provider: script([{:ok, asst("done")}]), tools: [], persist: false)

    assert {:ok, _snapshot} = Elara.attach(session, :control)

    assert {:error, :control_taken} =
             Task.async(fn -> Elara.attach(session, :control) end) |> Task.await()

    assert {:ok, _snapshot} =
             Task.async(fn -> Elara.attach(session, :observe) end) |> Task.await()
  end

  test "v2 lifecycle names, lists, resumes, and deletes a stable saved session" do
    root = Path.join(System.tmp_dir!(), "elara-lifecycle-#{System.unique_integer([:positive])}")
    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)
    previous_root = Application.get_env(:elara, :sessions_root)
    Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))

    on_exit(fn ->
      if previous_root,
        do: Application.put_env(:elara, :sessions_root, previous_root),
        else: Application.delete_env(:elara, :sessions_root)

      File.rm_rf!(root)
    end)

    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]), lifetime: :embedded)
    socket = connect(Elara.Server.port(server))
    send_json(socket, %{"version" => 2, "command" => "create", "cwd" => cwd})

    assert %{"type" => "attached", "session_id" => id, "lifetime" => "embedded"} =
             recv_json(socket)

    send_json(socket, %{"version" => 2, "command" => "session_name", "name" => "first"})
    assert %{"type" => "session_result", "command" => "session_name"} = recv_json(socket)
    send_json(socket, %{"version" => 2, "command" => "session_list"})
    assert %{"type" => "session_list", "sessions" => sessions} = recv_json(socket)

    assert %{"id" => ^id, "name" => "first", "state" => "idle"} =
             Enum.find(sessions, &(&1["id"] == id))

    listing = connect(Elara.Server.port(server))
    send_json(listing, %{"version" => 2, "command" => "list", "cwd" => cwd})
    assert %{"type" => "sessions", "sessions" => legacy_sessions} = recv_json(listing)
    assert %{"incarnation" => incarnation} = Enum.find(legacy_sessions, &(&1["id"] == id))
    assert is_binary(incarnation)

    {:ok, pid} = Elara.session_pid(id)
    :ok = DynamicSupervisor.terminate_child(Elara.SessionSup, pid)
    :gen_tcp.close(socket)

    resumed = connect(Elara.Server.port(server))
    send_json(resumed, %{"version" => 2, "command" => "attach", "session_id" => id, "cwd" => cwd})
    assert %{"type" => "attached", "session_id" => ^id} = recv_json(resumed)
    send_json(resumed, %{"version" => 2, "command" => "session_create"})
    assert %{"type" => "session_created", "session_id" => disposable} = recv_json(resumed)

    send_json(resumed, %{
      "version" => 2,
      "command" => "session_delete",
      "session_id" => disposable
    })

    assert %{
             "type" => "session_result",
             "command" => "session_delete",
             "session_id" => ^disposable
           } =
             recv_json(resumed)

    assert {:error, :session_not_found} = Elara.Session.Store.find(cwd, disposable)

    send_json(resumed, %{"version" => 2, "command" => "session_delete", "session_id" => id})
    assert %{"type" => "session_error", "error" => "switch_first"} = recv_json(resumed)
  end

  test "a workspace alias can list and delete an uncontrolled live session" do
    root =
      Path.join(System.tmp_dir!(), "elara-alias-delete-#{System.unique_integer([:positive])}")

    cwd = Path.join(root, "workspace")
    alias_path = Path.join(root, "alias")
    File.mkdir_p!(cwd)
    File.ln_s!(cwd, alias_path)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, target} =
      Elara.start_session(cwd: cwd, provider: script([]), tools: [], home: root, skill_paths: [])

    :ok = Elara.name_session(target, "delete through alias")
    {:ok, target_pid} = Elara.session_pid(target)
    on_exit(fn -> if Process.alive?(target_pid), do: GenServer.stop(target_pid) end)
    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]))
    socket = connect(Elara.Server.port(server))
    send_json(socket, %{"version" => 2, "command" => "create", "cwd" => alias_path})
    assert %{"type" => "attached", "session_id" => current} = recv_json(socket)
    {:ok, current_pid} = Elara.session_pid(current)
    on_exit(fn -> if Process.alive?(current_pid), do: GenServer.stop(current_pid) end)
    send_json(socket, %{"version" => 2, "command" => "session_list"})
    assert %{"type" => "session_list", "sessions" => sessions} = recv_json(socket)
    assert %{"state" => "idle"} = Enum.find(sessions, &(&1["id"] == target))
    send_json(socket, %{"version" => 2, "command" => "session_delete", "session_id" => target})
    assert %{"type" => "session_result", "command" => "session_delete"} = recv_json(socket)
    assert {:error, :session_not_found} = Elara.session_pid(target)
    assert {:error, :session_not_found} = Elara.Session.Store.find(alias_path, target)
    :gen_tcp.close(socket)
  end

  test "observers can list and tree but cannot mutate" do
    assistant = asst("done")
    provider = script([{:stream, [{:sleep, 300}], {:ok, assistant}}])
    {:ok, server} = Elara.Server.start_link(port: 0, provider: provider)
    port = Elara.Server.port(server)
    owner = connect(port)
    send_json(owner, %{"version" => 2, "command" => "create", "cwd" => File.cwd!()})
    assert %{"session_id" => id} = recv_json(owner)

    observer = connect(port)

    send_json(observer, %{
      "version" => 2,
      "command" => "attach",
      "session_id" => id,
      "mode" => "observe",
      "cwd" => File.cwd!()
    })

    assert %{"type" => "attached"} = recv_json(observer)
    send_json(observer, %{"version" => 2, "command" => "session_list"})
    assert %{"type" => "session_list"} = recv_json(observer)
    send_json(observer, %{"version" => 2, "command" => "session_tree"})
    assert %{"type" => "session_tree", "entries" => []} = recv_json(observer)
    send_json(observer, %{"version" => 2, "command" => "session_create"})

    assert %{
             "type" => "session_error",
             "command" => "session_create",
             "error" => "not_controller"
           } = recv_json(observer)

    send_json(observer, %{"version" => 2, "command" => "session_clone"})

    assert %{
             "type" => "session_error",
             "command" => "session_clone",
             "error" => "not_controller"
           } = recv_json(observer)
  end

  test "live deletion is workspace-scoped and empty unnamed sessions remain discoverable" do
    root = Path.join(System.tmp_dir!(), "elara-workspaces-#{System.unique_integer([:positive])}")
    cwd_a = Path.join(root, "a")
    cwd_b = Path.join(root, "b")
    File.mkdir_p!(cwd_a)
    File.mkdir_p!(cwd_b)
    previous_root = Application.get_env(:elara, :sessions_root)
    Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))

    on_exit(fn ->
      if previous_root,
        do: Application.put_env(:elara, :sessions_root, previous_root),
        else: Application.delete_env(:elara, :sessions_root)

      File.rm_rf!(root)
    end)

    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]))
    a = connect(Elara.Server.port(server))
    send_json(a, %{"version" => 2, "command" => "create", "cwd" => cwd_a})
    assert %{"session_id" => a_id} = recv_json(a)
    b = connect(Elara.Server.port(server))
    send_json(b, %{"version" => 2, "command" => "create", "cwd" => cwd_b})
    assert %{"session_id" => b_id} = recv_json(b)

    # Detaching the target removes controller authority but leaves it live.
    :gen_tcp.close(b)
    Process.sleep(20)
    send_json(a, %{"version" => 2, "command" => "session_delete", "session_id" => b_id})
    assert %{"type" => "session_error", "error" => "session_not_found"} = recv_json(a)
    assert {:ok, _pid} = Elara.session_pid(b_id)

    {:ok, a_pid} = Elara.session_pid(a_id)
    :ok = DynamicSupervisor.terminate_child(Elara.SessionSup, a_pid)
    :gen_tcp.close(a)
    assert {:ok, _info} = Elara.Session.Store.find(cwd_a, a_id)

    resumed = connect(Elara.Server.port(server))

    send_json(resumed, %{
      "version" => 2,
      "command" => "attach",
      "session_id" => a_id,
      "cwd" => cwd_a
    })

    assert %{"type" => "attached", "session_id" => ^a_id} = recv_json(resumed)
  end

  test "invalid cwd values return invalid_cwd" do
    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]))

    for request <- [
          %{"version" => 2, "command" => "list", "cwd" => 1},
          %{"version" => 2, "command" => "create", "cwd" => []},
          %{"version" => 2, "command" => "attach", "session_id" => "missing", "cwd" => %{}}
        ] do
      socket = connect(Elara.Server.port(server))
      send_json(socket, request)
      assert %{"type" => "error", "error" => "invalid_cwd"} = recv_json(socket)
    end
  end
end
