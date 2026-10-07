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

  test "explicit cwd drives native creation, listing and saved reopen from another directory",
       context do
    other = Path.join(Path.dirname(context.cwd), "other workspace")
    File.mkdir_p!(other)
    invoking = File.cwd!()
    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]))
    port = Elara.Server.port(server)

    on_exit(fn ->
      if Process.alive?(server), do: GenServer.stop(server)

      for session <- Elara.live_sessions(), session.cwd in [context.cwd, other] do
        {:ok, pid} = Elara.session_pid(session.id)
        DynamicSupervisor.terminate_child(Elara.SessionSup, pid)
      end
    end)

    relative = Path.relative_to(context.cwd, invoking, force: true)

    assert {created, 0} =
             run(context.binary, context.state, invoking, port, "new", [
               "--headless",
               "--cwd",
               relative
             ])

    assert [_, id] = Regex.run(~r/summary session=([^ ]+)/, created)
    assert Elara.cwd(id) == context.cwd
    assert :ok = Elara.name_session(id, "selected native session")
    # The default path still selects the executable's actual invoking directory.
    assert {default_created, 0} =
             run(context.binary, context.state, other, port, "new", ["--headless"])

    assert [_, other_id] = Regex.run(~r/summary session=([^ ]+)/, default_created)
    assert Elara.cwd(other_id) == other

    assert {listing, 0} =
             run(context.binary, context.state, invoking, port, "list", ["--cwd", context.cwd])

    assert listing =~ id
    refute listing =~ other_id
    {:ok, pid} = Elara.session_pid(id)
    :ok = DynamicSupervisor.terminate_child(Elara.SessionSup, pid)

    assert {reopened, 0} =
             run(context.binary, context.state, invoking, port, id, [
               "--headless",
               "--cwd",
               context.cwd
             ])

    assert reopened =~ "summary session=#{id}"
    assert Elara.cwd(id) == context.cwd
    # Live-ID attachment retains the original workspace despite a different selection.
    assert {attached, 0} =
             run(context.binary, context.state, invoking, port, id, [
               "--observe",
               "--headless",
               "--cwd",
               other
             ])

    assert attached =~ "summary session=#{id}"
    assert Elara.cwd(id) == context.cwd
    :ok = DynamicSupervisor.terminate_child(Elara.SessionSup, elem(Elara.session_pid(id), 1))

    assert {rejected, 1} =
             run(context.binary, context.state, invoking, port, id, ["--headless", "--cwd", other])

    assert rejected =~ "session_not_found"

    for cwd <- ["", __ENV__.file, Path.join(context.cwd, "missing")] do
      assert {error, 1} =
               run(context.binary, context.state, invoking, port, "new", [
                 "--headless",
                 "--cwd",
                 cwd
               ])

      assert error =~ "--cwd must name an existing directory"
    end

    assert File.cwd!() == invoking
  end

  test "native tilde expansion distinguishes home from a literal tilde directory", context do
    home = Path.join(context.cwd, "fake home")
    child = Path.join(home, "existing directory")
    literal = Path.join(context.cwd, "~")
    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]))
    port = Elara.Server.port(server)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    sessions =
      for {selection, expected} <- [
            {"~", home},
            {"~/existing directory", child},
            {"./~", literal}
          ] do
        File.mkdir_p!(expected)
        {:ok, id} = Elara.start_session(cwd: expected, provider: script([]))

        on_exit(fn ->
          case Elara.session_pid(id) do
            {:ok, pid} -> DynamicSupervisor.terminate_child(Elara.SessionSup, pid)
            _ -> :ok
          end
        end)

        {selection, id}
      end

    for {selection, id} <- sessions do
      assert {listing, 0} =
               System.cmd(
                 context.binary,
                 ["--cwd", selection, "--port", Integer.to_string(port), "list"],
                 cd: context.cwd,
                 env: [{"HOME", home}, {"ELARA_TUI_STATE_DIR", context.state}],
                 stderr_to_stdout: true
               )

      assert listing =~ id
      for {_, other_id} <- sessions, other_id != id, do: refute(listing =~ other_id)
    end
  end

  defp request(socket, command) do
    :ok =
      :gen_tcp.send(
        socket,
        Elara.Protocol.encode(
          command
          |> Map.put("version", 2)
          |> Map.put_new("token", System.fetch_env!("ELARA_SERVER_TOKEN"))
        )
      )

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
