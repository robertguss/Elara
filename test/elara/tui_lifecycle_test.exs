defmodule Elara.TuiLifecycleTest do
  use ExUnit.Case, async: false

  alias Elara.Message

  defp assistant(text) do
    {:ok, message} = Message.assistant(text, [])
    message
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp run(binary, state, cwd, port, target, options \\ []) do
    System.cmd(binary, options ++ ["--port", Integer.to_string(port), "--", target],
      cd: cwd,
      env: [{"ELARA_TUI_STATE_DIR", state}],
      stderr_to_stdout: true
    )
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "elara-tui-lifecycle-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:elara, :sessions_root)
    Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))
    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:elara, :sessions_root, previous),
        else: Application.delete_env(:elara, :sessions_root)

      File.rm_rf!(root)
    end)

    %{
      binary: Mix.Tasks.Elara.Tui.binary!(),
      state: Path.join(root, "client"),
      cwd: cwd
    }
  end

  test "actual Rust observer lists and reads two named sessions but cannot submit", context do
    {:ok, first} =
      Elara.start_session(
        cwd: context.cwd,
        provider: script([{:ok, assistant("FIRST authoritative answer")}]),
        tools: [],
        persist: true
      )

    {:ok, second} =
      Elara.start_session(
        cwd: context.cwd,
        provider: script([{:ok, assistant("SECOND authoritative answer")}]),
        tools: [],
        persist: true
      )

    assert :ok = Elara.name_session(first, "alpha lifecycle")
    assert :ok = Elara.name_session(second, "beta lifecycle")
    assert {:ok, "FIRST authoritative answer"} = Elara.ask(first, "first transcript marker")
    assert {:ok, "SECOND authoritative answer"} = Elara.ask(second, "second transcript marker")

    # Simulate VM restart: no session process survives; only persisted files do.
    for id <- [first, second] do
      {:ok, pid} = Elara.session_pid(id)
      :ok = DynamicSupervisor.terminate_child(Elara.SessionSup, pid)
    end

    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]), lifetime: :long_lived)
    port = Elara.Server.port(server)

    assert {listing, 0} = run(context.binary, context.state, context.cwd, port, "list")
    assert listing =~ first
    assert listing =~ second
    assert listing =~ "saved"

    assert {first_view, 0} =
             run(context.binary, context.state, context.cwd, port, first, [
               "--observe",
               "--headless"
             ])

    assert first_view =~ "first transcript marker"
    assert first_view =~ "FIRST authoritative answer"
    refute first_view =~ "second transcript marker"

    before = Elara.transcript(first)

    assert {rejected, 1} =
             run(context.binary, context.state, context.cwd, port, first, [
               "--observe",
               "--headless",
               "--ask",
               "observer mutation must not land"
             ])

    assert rejected =~ "observing client cannot ask"
    assert Elara.transcript(first) == before

    assert {second_view, 0} =
             run(context.binary, context.state, context.cwd, port, second, [
               "--observe",
               "--headless"
             ])

    assert second_view =~ "second transcript marker"
    assert second_view =~ "SECOND authoritative answer"
    refute second_view =~ "observer mutation must not land"
  end

  defp request(socket, command) do
    :ok = :gen_tcp.send(socket, Elara.Protocol.encode(Map.put(command, "version", 2)))
    response(socket)
  end

  defp response(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    {:ok, frame} = Elara.Protocol.decode(line)
    if frame["type"] == "patch", do: response(socket), else: frame
  end

  defp socket(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])

    socket
  end

  test "fork and clone preserve the source, and detached running work cannot be deleted",
       context do
    provider =
      script([
        {:ok, assistant("source answer")},
        {:stream, [{:sleep, 5_000}], {:ok, assistant("late")}}
      ])

    {:ok, server} = Elara.Server.start_link(port: 0, provider: provider)
    port = Elara.Server.port(server)
    owner = socket(port)
    %{"session_id" => id} = request(owner, %{"command" => "create", "cwd" => context.cwd})
    assert {:ok, "source answer"} = Elara.ask(id, "source question")
    history = Elara.transcript(id)
    %{"entries" => [%{"id" => entry}]} = request(owner, %{"command" => "session_tree"})
    %{"session_id" => cloned} = request(owner, %{"command" => "session_clone"})
    assert cloned != id
    assert Elara.transcript(id) == history

    %{"session_id" => forked, "prompt" => "source question"} =
      request(owner, %{"command" => "session_fork", "entry_id" => entry})

    assert forked != id
    assert Elara.transcript(id) == history
    clone_socket = socket(port)

    %{"session_id" => ^cloned} =
      request(clone_socket, %{"command" => "attach", "session_id" => cloned, "cwd" => context.cwd})

    assert Elara.transcript(cloned) == history
    fork_socket = socket(port)

    %{"session_id" => ^forked} =
      request(fork_socket, %{
        "command" => "attach",
        "session_id" => forked,
        "cwd" => context.cwd,
        "mode" => "observe"
      })

    assert Elara.transcript(forked) == []

    assert %{"type" => "ok"} =
             request(owner, %{"command" => "ask", "prompt" => "running question"})

    :gen_tcp.close(owner)
    # Observe running work after detaching the controlling socket.
    resumed = socket(port)

    assert %{"type" => "attached"} =
             request(resumed, %{
               "command" => "attach",
               "session_id" => id,
               "cwd" => context.cwd,
               "mode" => "observe"
             })

    assert %{"error" => error} =
             request(clone_socket, %{"command" => "session_delete", "session_id" => id})

    assert error == "active_stop_first"
    assert Elara.status(id).phase != :idle
    Elara.interrupt(id)

    assert %{"type" => "session_result"} =
             request(clone_socket, %{"command" => "session_delete", "session_id" => forked})

    assert {:error, :closed} = :gen_tcp.recv(fork_socket, 0, 2_000)
    :gen_tcp.close(clone_socket)
    :gen_tcp.close(fork_socket)
    :gen_tcp.close(resumed)
  end
end
