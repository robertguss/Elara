defmodule Elara.TuiTest do
  use ExUnit.Case, async: false

  alias Elara.Message
  alias Elara.Message.ToolCall

  defp asst(text, calls \\ []) do
    {:ok, assistant} = Message.assistant(text, calls)
    assistant
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp run_tui(binary, state_dir, port, args) do
    System.cmd(binary, args ++ ["--port", Integer.to_string(port)],
      env: [{"ELARA_TUI_STATE_DIR", state_dir}],
      stderr_to_stdout: true
    )
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp stop_sessions_except(existing) do
    Elara.live_sessions()
    |> Enum.reject(&MapSet.member?(existing, &1.id))
    |> Enum.each(fn session ->
      {:ok, pid} = Elara.session_pid(session.id)
      :ok = DynamicSupervisor.terminate_child(Elara.SessionSup, pid)
    end)
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp await_output(port, needle, output \\ "") do
    receive do
      {^port, {:data, data}} ->
        output = output <> data

        if output =~ needle do
          output
        else
          await_output(port, needle, output)
        end

      {^port, {:exit_status, status}} ->
        flunk("TUI exited with #{status} before emitting #{inspect(needle)}:\n#{output}")
    after
      5_000 -> flunk("TUI did not emit #{inspect(needle)}:\n#{output}")
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "elara-tui-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    previous_root = Application.get_env(:elara, :sessions_root)
    Application.put_env(:elara, :sessions_root, Path.join(tmp, "sessions"))

    on_exit(fn ->
      if previous_root do
        Application.put_env(:elara, :sessions_root, previous_root)
      else
        Application.delete_env(:elara, :sessions_root)
      end

      File.rm_rf!(tmp)
    end)

    binary = Mix.Tasks.Elara.Tui.binary!()
    %{binary: binary, state_dir: Path.join(tmp, "state")}
  end

  test "mix task starts an embedded server for new and reuses an existing server", context do
    env_names = ["ELARA_API_KEY", "ELARA_PROVIDER", "ELARA_SERVER_PORT", "ELARA_TUI_STATE_DIR"]
    previous_env = Map.new(env_names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    existing_sessions = Elara.live_sessions() |> Enum.map(& &1.id) |> MapSet.new()
    embedded_port = available_port()
    System.put_env("ELARA_API_KEY", "test-key")
    System.delete_env("ELARA_PROVIDER")
    System.put_env("ELARA_SERVER_PORT", Integer.to_string(embedded_port))
    System.put_env("ELARA_TUI_STATE_DIR", context.state_dir)

    assert :ok = Mix.Tasks.Elara.Tui.run(["new", "--headless"])
    embedded = Process.whereis(Elara.Server)
    assert is_pid(embedded)
    assert Elara.Server.port(embedded) == embedded_port
    GenServer.stop(embedded)
    stop_sessions_except(existing_sessions)

    {:ok, external} = Elara.Server.start_link(port: 0, provider: script([]))
    external_port = Elara.Server.port(external)

    assert :ok =
             Mix.Tasks.Elara.Tui.run([
               "new",
               "--headless",
               "--port",
               Integer.to_string(external_port)
             ])

    assert Process.alive?(external)
    assert Process.whereis(Elara.Server) == nil
    stop_sessions_except(existing_sessions)
    GenServer.stop(external)
  end

  test "cold snapshot, create, and live session list use the Rust client", context do
    {:ok, session} =
      Elara.start_session(
        provider: script([{:ok, asst("already complete")}]),
        tools: [],
        persist: false
      )

    assert {:ok, "already complete"} = Elara.ask(session, "earlier prompt")
    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]))
    port = Elara.Server.port(server)

    assert {snapshot, 0} =
             run_tui(context.binary, context.state_dir, port, [session, "--headless"])

    assert snapshot =~ "earlier prompt"
    assert snapshot =~ "already complete"
    assert snapshot =~ "head 4 · idle"

    assert {created, 0} =
             run_tui(context.binary, context.state_dir, port, ["new", "--headless"])

    assert [_, created_session] = Regex.run(~r/summary session=([^ ]+)/, created)
    assert created =~ "No messages yet."

    assert {sessions, 0} =
             run_tui(context.binary, context.state_dir, port, ["list"])

    assert sessions =~ "SESSION\tSTATE\tHEAD\tCWD"
    assert sessions =~ session
    assert sessions =~ created_session
  end

  test "a killed client detaches without cancellation and reattaches from an exact snapshot",
       context do
    provider =
      script([
        {:stream, ["part one ", {:sleep, 500}, "part two"], {:ok, asst("part one part two")}},
        {:stream, ["live ", {:sleep, 25}, "latency"], {:ok, asst("live latency")}}
      ])

    {:ok, session} = Elara.start_session(provider: provider, tools: [], persist: false)
    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]))
    port_number = Elara.Server.port(server)

    port =
      Port.open({:spawn_executable, String.to_charlist(context.binary)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args:
          Enum.map(
            [
              session,
              "--headless",
              "--event-dump",
              "--ask",
              "detached prompt",
              "--port",
              Integer.to_string(port_number)
            ],
            &String.to_charlist/1
          ),
        env: [
          {~c"ELARA_TUI_STATE_DIR", String.to_charlist(context.state_dir)}
        ]
      ])

    first_output = await_output(port, "append_content_delta")
    assert first_output =~ ~r/event_ms=\d+\.\d+ frame=/
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {_output, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])

    receive do
      {^port, {:exit_status, status}} -> assert status != 0
    after
      2_000 -> flunk("killed TUI did not exit")
    end

    assert {:ok, session_pid} = Elara.session_pid(session)
    assert Process.alive?(session_pid)
    eventually(fn -> Elara.status(session).phase == :idle end)

    assert {reattached, 0} =
             run_tui(context.binary, context.state_dir, port_number, [session, "--headless"])

    assert length(Regex.scan(~r/part one part two/, reattached)) == 1
    assert reattached =~ "detached prompt"
    assert [_, saved] = Regex.run(~r/saved_cursor=(\d+)/, reattached)
    assert String.to_integer(saved) > 0
    assert reattached =~ "head=#{Elara.status(session).event_head}"

    assert {latency, 0} =
             run_tui(context.binary, context.state_dir, port_number, [
               session,
               "--headless",
               "--event-dump",
               "--ask",
               "measure latency"
             ])

    assert latency =~ "live latency"
    assert latency =~ ~r/ask_to_active_ms=\d+\.\d+/
    assert latency =~ ~r/ask_to_first_delta_ms=\d+\.\d+/
    assert latency =~ "append_content_delta"
  end

  test "the headless client can explicitly interrupt a running tool", context do
    call = %ToolCall{
      id: "tui-interrupt",
      name: "bash",
      args: {:ok, %{"command" => "sleep 10"}}
    }

    {:ok, session} =
      Elara.start_session(
        provider: script([{:ok, asst(nil, [call])}]),
        persist: false
      )

    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]))

    assert {output, 0} =
             run_tui(context.binary, context.state_dir, Elara.Server.port(server), [
               session,
               "--headless",
               "--ask",
               "start a long tool",
               "--interrupt-after-ms",
               "150"
             ])

    assert output =~ "bash · failed"
    assert output =~ "outcome interrupted"
    assert Elara.status(session).phase == :idle
  end
end
