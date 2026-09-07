defmodule Elara.PluginReloadProtocolTest do
  use ExUnit.Case, async: false

  @tag timeout: 30_000
  test "actual Rust TUI discovers a plugin and reports a rejected revision" do
    dir = Path.join(System.tmp_dir!(), "plugin-pty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {:ok, agent} = Agent.start_link(fn -> [] end)
    provider = {Elara.Provider.Scripted, agent}

    {:ok, session} =
      Elara.start_session(
        cwd: dir,
        home: dir,
        skill_paths: [],
        tools: [],
        persist: false,
        provider: provider
      )

    {:ok, pid} = Elara.session_pid(session)
    server = start_supervised!({Elara.Server, port: 0, provider: provider})

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(dir)
    end)

    {output, status} =
      System.cmd(
        "python3",
        [
          Path.expand("../support/plugin_reload_pty.py", __DIR__),
          Mix.Tasks.Elara.Tui.binary!(),
          Integer.to_string(Elara.Server.port(server)),
          session,
          dir,
          Path.expand("../../.elara/plugins/elixir_project.exs", __DIR__)
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "PTY passed"
    assert [%{id: "elixir_project", version: "3", generation: 1}] = Elara.plugins(session)
    assert Elara.transcript(session) == []
  end

  test "reload requires negotiation and controller ownership; snapshot refresh is unchanged" do
    dir = Path.join(System.tmp_dir!(), "plugin-protocol-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".elara/plugins"))
    {:ok, agent} = Agent.start_link(fn -> [] end)
    provider = {Elara.Provider.Scripted, agent}

    {:ok, session} =
      Elara.start_session(
        cwd: dir,
        home: dir,
        skill_paths: [],
        tools: [],
        persist: false,
        provider: provider
      )

    {:ok, pid} = Elara.session_pid(session)
    server = start_supervised!({Elara.Server, port: 0, provider: provider})
    port = Elara.Server.port(server)
    controller = attach(port, session, "control", ["plugin_reload_v1"])
    observer = attach(port, session, "observe", ["plugin_reload_v1"])
    legacy = attach(port, session, "observe", [])

    on_exit(fn ->
      Enum.each([controller, observer, legacy], &:gen_tcp.close/1)
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(dir)
    end)

    command = %{"command" => "plugins_reload", "extension" => "plugin_reload_v1"}
    assert request(observer, command)["error"] == "not_controller"
    assert request(legacy, command)["error"] == "unsupported_extension"
    assert request(controller, %{"command" => "plugins_reload"})["type"] == "error"

    plugin = Path.join(dir, ".elara/plugins/project.exs")
    File.cp!(Path.expand("../../.elara/plugins/elixir_project.exs", __DIR__), plugin)
    assert request(controller, %{"command" => "session_reload"})["type"] == "snapshot"
    assert Elara.plugins(session) == []

    assert %{"type" => "plugins_reloaded", "plugins" => [%{"id" => "elixir_project"}]} =
             request(controller, command)

    [active] = Elara.plugins(session)
    File.write!(plugin, "defmodule Broken do")
    assert request(controller, command)["error"] =~ "plugin_reload_failed"
    assert Elara.plugins(session) == [active]
  end

  @tag timeout: 15_000
  test "slow migration returns its result without disconnecting the controller" do
    dir = Path.join(System.tmp_dir!(), "plugin-slow-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "slow.exs")
    original = File.read!(Path.expand("../../.elara/plugins/elixir_project.exs", __DIR__))
    File.write!(path, original)
    {:ok, agent} = Agent.start_link(fn -> [] end)
    provider = {Elara.Provider.Scripted, agent}

    {:ok, session} =
      Elara.start_session(
        cwd: dir,
        home: dir,
        skill_paths: [],
        plugins: [path],
        tools: [],
        persist: false,
        provider: provider
      )

    {:ok, pid} = Elara.session_pid(session)
    server = start_supervised!({Elara.Server, port: 0, provider: provider})
    socket = attach(Elara.Server.port(server), session, "control", ["plugin_reload_v1"])

    on_exit(fn ->
      :gen_tcp.close(socket)
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(dir)
    end)

    revised =
      String.replace(
        original,
        "def migrate(%{last_run: nil} = state, _metadata), do: {:ok, state}",
        "def migrate(%{last_run: nil} = state, _metadata) do Process.sleep(5_200); {:ok, state} end"
      )

    File.write!(path, revised)

    assert %{"type" => "plugins_reloaded", "plugins" => [%{"generation" => 2}]} =
             request(
               socket,
               %{"command" => "plugins_reload", "extension" => "plugin_reload_v1"},
               10_000
             )

    assert request(socket, %{"command" => "session_reload"})["type"] == "snapshot"
  end

  defp attach(port, session, mode, extensions) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])

    response =
      request(socket, %{
        "command" => "attach",
        "session_id" => session,
        "mode" => mode,
        "extensions" => extensions
      })

    assert response["type"] == "attached"
    assert response["extensions"] == extensions
    socket
  end

  defp request(socket, command, timeout \\ 5_000) do
    :ok = :gen_tcp.send(socket, Elara.Protocol.encode(Map.put(command, "version", 2)))
    {:ok, line} = :gen_tcp.recv(socket, 0, timeout)
    {:ok, message} = Elara.Protocol.decode(line)
    message
  end
end
