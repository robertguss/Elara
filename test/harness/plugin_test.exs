defmodule Harness.PluginTest do
  use ExUnit.Case, async: false

  alias Harness.Message
  alias Harness.Message.{ToolCall, ToolResult}
  alias Harness.Plugin.Loader
  alias Harness.Tool
  alias Harness.Tool.PluginRef

  setup do
    dir = Path.join(System.tmp_dir!(), "harness-plugin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: Path.join(dir, "counter.exs")}
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Harness.Provider.Scripted, agent}
  end

  defp asst(text, calls \\ []) do
    {:ok, assistant} = Message.assistant(text, calls)
    assistant
  end

  defp call(id, args \\ %{}) do
    %ToolCall{id: id, name: "counter", args: {:ok, args}}
  end

  defp start_session(opts) do
    {:ok, session} = Harness.start_session(Keyword.merge([persist: false, tools: []], opts))
    {:ok, pid} = Harness.session_pid(session)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    session
  end

  defp session_pid(session) do
    {:ok, pid} = Harness.session_pid(session)
    pid
  end

  defp module_name do
    "CounterPlugin#{System.unique_integer([:positive])}"
  end

  defp write_counter(path, module, version, opts \\ []) do
    id = Keyword.get(opts, :id, "counter")
    tool_name = Keyword.get(opts, :tool_name, "counter")

    sleep =
      case Keyword.get(opts, :sleep_ms) do
        nil -> ""
        milliseconds -> "Process.sleep(#{milliseconds})"
      end

    state = Keyword.get(opts, :state, :integer)

    {init, body, migration} =
      case state do
        :integer ->
          {
            "{:ok, 0}",
            """
            next = count + 1
            {{:ok, "#{version} count=\#{next}"}, next}
            """,
            ""
          }

        :map ->
          {
            "{:ok, %{count: 0}}",
            """
            next = state.count + 1
            {{:ok, "#{version} count=\#{next}"}, %{state | count: next}}
            """,
            """
            @impl true
            def migrate(count, %{version: "1"}), do: {:ok, %{count: count}}
            """
          }
      end

    state_pattern = if state == :integer, do: "count", else: "state"

    File.write!(
      path,
      """
      defmodule #{module} do
        @behaviour Harness.Plugin

        alias Harness.Plugin.ToolSpec

        @impl true
        def metadata, do: %{id: "#{id}", version: "#{version}"}

        @impl true
        def tools do
          [
            %ToolSpec{
              name: "#{tool_name}",
              description: "Increment a counter.",
              parameters: %{"type" => "object", "properties" => %{}}
            }
          ]
        end

        @impl true
        def init(_ctx), do: #{init}

        @impl true
        def handle_tool("#{tool_name}", _args, _ctx, #{state_pattern}) do
          #{sleep}
          #{body}
        end

        #{migration}
      end
      """
    )
  end

  defp tool_outcomes(session) do
    session
    |> Harness.transcript()
    |> Enum.filter(&is_struct(&1, ToolResult))
    |> Enum.map(& &1.outcome)
  end

  defp await_reload(session, attempts \\ 100)

  defp await_reload(_session, 0), do: flunk("plugin did not become reloadable")

  defp await_reload(session, attempts) do
    case Harness.reload_plugins(session) do
      {:error, {:plugin_reload_failed, _path, :busy}} ->
        Process.sleep(10)
        await_reload(session, attempts - 1)

      result ->
        result
    end
  end

  test "reload changes code without changing the session, state process, state, or history", %{
    path: path,
    dir: dir
  } do
    module = module_name()
    write_counter(path, module, "1")

    provider =
      script([
        {:ok, asst(nil, [call("one")])},
        {:ok, asst("first done")},
        {:ok, asst(nil, [call("two")])},
        {:ok, asst("second done")}
      ])

    session = start_session(provider: provider, plugins: [path], cwd: dir)
    [before] = Harness.plugins(session)

    assert %PluginRef{version: "1", generation: 1, server: server} =
             :sys.get_state(session_pid(session)).core.config.tools["counter"].plugin

    assert server == before.pid

    assert {:ok, "first done"} = Harness.ask(session, "first")
    prior_history = Harness.transcript(session)
    assert tool_outcomes(session) == [{:ok, "1 count=1"}]

    write_counter(path, module, "2")

    assert {:ok, [after_reload]} = Harness.reload_plugins(session)
    assert Process.alive?(session_pid(session))
    assert after_reload.pid == before.pid
    assert after_reload.module != before.module
    assert after_reload.version == "2"
    assert after_reload.generation == 2
    assert Harness.transcript(session) == prior_history

    assert %PluginRef{version: "2", generation: 2, server: server} =
             :sys.get_state(session_pid(session)).core.config.tools["counter"].plugin

    assert server == before.pid

    assert {:ok, "second done"} = Harness.ask(session, "second")
    assert tool_outcomes(session) == [{:ok, "1 count=1"}, {:ok, "2 count=2"}]

    recording = Harness.recording(session)
    assert Enum.map(recording.segments, & &1.reason) == [:init, :plugins_reloaded]
    assert {:ok, %Harness.FlightRecorder.Report{status: :match}} = Harness.replay(recording)
  end

  test "a broken replacement leaves the previous code, generation, and state active", %{
    path: path,
    dir: dir
  } do
    module = module_name()
    write_counter(path, module, "1")

    provider =
      script([
        {:ok, asst(nil, [call("one")])},
        {:ok, asst("first done")},
        {:ok, asst(nil, [call("two")])},
        {:ok, asst("second done")}
      ])

    session = start_session(provider: provider, plugins: [path], cwd: dir)
    assert {:ok, "first done"} = Harness.ask(session, "first")
    [before] = Harness.plugins(session)

    File.write!(path, "defmodule Broken do")

    assert {:error, {:plugin_reload_failed, ^path, {:parse_error, _reason}}} =
             Harness.reload_plugins(session)

    assert Harness.plugins(session) == [before]

    write_counter(path, module, "1")
    assert {:ok, "second done"} = Harness.ask(session, "second")
    assert tool_outcomes(session) == [{:ok, "1 count=1"}, {:ok, "1 count=2"}]
  end

  test "a failed multi-plugin reload aborts every prepared candidate", %{
    path: path,
    dir: dir
  } do
    other_path = Path.join(dir, "other.exs")
    write_counter(path, module_name(), "1")
    write_counter(other_path, module_name(), "1", id: "other", tool_name: "other")

    provider =
      script([
        {:ok, asst(nil, [call("one")])},
        {:ok, asst("first done")},
        {:ok, asst(nil, [call("two")])},
        {:ok, asst("second done")}
      ])

    session = start_session(provider: provider, plugins: [path, other_path], cwd: dir)
    assert {:ok, "first done"} = Harness.ask(session, "first")

    before_infos = Harness.plugins(session)
    before_tools = :sys.get_state(session_pid(session)).core.config.tools

    before_states =
      Map.new(before_infos, fn info ->
        {info.id, :sys.get_state(info.pid).plugin_state}
      end)

    write_counter(path, module_name(), "2")
    File.write!(other_path, "defmodule Broken do")

    assert {:error, {:plugin_reload_failed, ^other_path, {:parse_error, _reason}}} =
             Harness.reload_plugins(session)

    assert Harness.plugins(session) == before_infos
    assert :sys.get_state(session_pid(session)).core.config.tools == before_tools

    assert Map.new(before_infos, fn info ->
             {info.id, :sys.get_state(info.pid).plugin_state}
           end) == before_states

    assert Enum.all?(before_infos, fn info ->
             :sys.get_state(info.pid).pending == nil
           end)

    assert {:ok, "second done"} = Harness.ask(session, "second")
    assert tool_outcomes(session) == [{:ok, "1 count=1"}, {:ok, "1 count=2"}]
  end

  test "state migration activates atomically and a failed migration does not", %{
    path: path,
    dir: dir
  } do
    module = module_name()
    write_counter(path, module, "1")

    provider =
      script([
        {:ok, asst(nil, [call("one")])},
        {:ok, asst("first done")},
        {:ok, asst(nil, [call("two")])},
        {:ok, asst("second done")}
      ])

    session = start_session(provider: provider, plugins: [path], cwd: dir)
    assert {:ok, "first done"} = Harness.ask(session, "first")

    write_counter(path, module, "2", state: :map)
    assert {:ok, [%{version: "2", generation: 2}]} = Harness.reload_plugins(session)
    assert {:ok, "second done"} = Harness.ask(session, "second")
    assert tool_outcomes(session) == [{:ok, "1 count=1"}, {:ok, "2 count=2"}]

    failed =
      path
      |> File.read!()
      |> String.replace("version: \"2\"", "version: \"3\"")
      |> String.replace(
        "def migrate(count, %{version: \"1\"}), do: {:ok, %{count: count}}",
        "def migrate(_state, _metadata), do: {:error, :nope}"
      )

    File.write!(path, failed)

    assert {:error, {:plugin_reload_failed, ^path, {:migration_failed, :nope}}} =
             Harness.reload_plugins(session)

    assert [%{version: "2", generation: 2}] = Harness.plugins(session)
  end

  test "reload stays busy after interrupt until the checked-out plugin call ends", %{
    path: path,
    dir: dir
  } do
    module = module_name()
    write_counter(path, module, "1", sleep_ms: 500)
    provider = script([{:ok, asst(nil, [call("one")])}])
    session = start_session(provider: provider, plugins: [path], cwd: dir)
    :ok = Harness.subscribe(session)

    assert :ok = Harness.ask_async(session, "start")
    assert_receive {:harness, ^session, {:tool_started, %ToolCall{name: "counter"}}}

    [plugin] = Harness.plugins(session)

    Enum.reduce_while(1..100, nil, fn _, _ ->
      case :sys.get_state(plugin.pid).active do
        nil ->
          Process.sleep(5)
          {:cont, nil}

        _active ->
          {:halt, :checked_out}
      end
    end) || flunk("plugin call was not checked out")

    assert {:error, :busy} = Harness.reload_plugins(session)

    Harness.interrupt(session)
    assert_receive {:harness, ^session, {:turn_ended, :interrupted}}
    write_counter(path, module, "2")

    assert {:error, {:plugin_reload_failed, ^path, :busy}} = Harness.reload_plugins(session)
    assert {:ok, [%{version: "2", generation: 2}]} = await_reload(session)
  end

  test "tool timeout releases the plugin lease without committing state", %{path: path, dir: dir} do
    module = module_name()
    write_counter(path, module, "1", sleep_ms: 500)

    provider =
      script([
        {:ok, asst(nil, [call("one")])},
        {:ok, asst("timed out")},
        {:ok, asst(nil, [call("two")])},
        {:ok, asst("after reload")}
      ])

    session =
      start_session(
        provider: provider,
        plugins: [path],
        cwd: dir,
        tool_timeout_ms: 20
      )

    assert {:ok, "timed out"} = Harness.ask(session, "first")
    assert tool_outcomes(session) == [{:error, "timed out"}]

    write_counter(path, module, "2")
    assert {:ok, [%{version: "2", generation: 2}]} = Harness.reload_plugins(session)
    assert {:ok, "after reload"} = Harness.ask(session, "second")
    assert List.last(tool_outcomes(session)) == {:ok, "2 count=1"}
  end

  test "a queued deadline wins without committing a completed invocation", %{
    path: path,
    dir: dir
  } do
    module = module_name()
    coordinator_name = String.to_atom("plugin-timeout-#{System.unique_integer([:positive])}")
    test_pid = self()

    coordinator =
      spawn_link(fn ->
        Process.register(self(), coordinator_name)
        send(test_pid, :coordinator_ready)

        receive do
          {:callback_started, callback} ->
            send(test_pid, {:callback_started, callback})

            receive do
              :release -> send(callback, :finish)
            end
        end
      end)

    assert_receive :coordinator_ready

    File.write!(
      path,
      """
      defmodule #{module} do
        @behaviour Harness.Plugin

        alias Harness.Plugin.ToolSpec

        @impl true
        def metadata, do: %{id: "counter", version: "1"}

        @impl true
        def tools do
          [
            %ToolSpec{
              name: "counter",
              description: "Increment a counter.",
              parameters: %{"type" => "object", "properties" => %{}}
            }
          ]
        end

        @impl true
        def init(_ctx), do: {:ok, 0}

        @impl true
        def handle_tool("counter", args, _ctx, count) do
          if Map.get(args, "block", false) do
            send(Process.whereis(#{inspect(coordinator_name)}), {:callback_started, self()})

            receive do
              :finish -> :ok
            end
          end

          next = count + 1
          {{:ok, "1 count=\#{next}"}, next}
        end
      end
      """
    )

    provider =
      script([
        {:ok, asst(nil, [call("one", %{"block" => true})])},
        {:ok, asst("timed out")},
        {:ok, asst(nil, [call("two")])},
        {:ok, asst("after timeout")}
      ])

    session =
      start_session(
        provider: provider,
        plugins: [path],
        cwd: dir,
        tool_timeout_ms: 60_000
      )

    :ok = Harness.subscribe(session)
    assert :ok = Harness.ask_async(session, "first")
    assert_receive {:callback_started, task_pid}

    [plugin] = Harness.plugins(session)

    {:running_tool, core_ref, _call, _rest, _iteration} =
      :sys.get_state(session_pid(session)).core.phase

    task_monitor = Process.monitor(task_pid)

    :ok = :sys.suspend(session_pid(session))

    try do
      send(session_pid(session), {:tool_deadline, core_ref})
      send(coordinator, :release)
      assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, :normal}
      assert :sys.get_state(plugin.pid).plugin_state == 0
    after
      :ok = :sys.resume(session_pid(session))
    end

    assert_receive {:harness, ^session,
                    {:message_appended, %ToolResult{outcome: {:error, "timed out"}}}}

    assert_receive {:harness, ^session, {:turn_ended, {:completed, "timed out"}}}

    assert {:ok, "after timeout"} = Harness.ask(session, "second")
    assert tool_outcomes(session) == [{:error, "timed out"}, {:ok, "1 count=1"}]
  end

  test "two sessions keep independent code revisions and state", %{path: path, dir: dir} do
    module = module_name()
    write_counter(path, module, "1")

    replies = fn prefix ->
      [
        {:ok, asst(nil, [call("#{prefix}-one")])},
        {:ok, asst("first")},
        {:ok, asst(nil, [call("#{prefix}-two")])},
        {:ok, asst("second")}
      ]
    end

    first = start_session(provider: script(replies.("a")), plugins: [path], cwd: dir)
    second = start_session(provider: script(replies.("b")), plugins: [path], cwd: dir)

    assert {:ok, "first"} = Harness.ask(first, "first")
    assert {:ok, "first"} = Harness.ask(second, "first")

    [first_v1] = Harness.plugins(first)
    [second_v1] = Harness.plugins(second)
    assert first_v1.module == second_v1.module
    assert first_v1.pid != second_v1.pid

    write_counter(path, module, "2")
    assert {:ok, [first_v2]} = Harness.reload_plugins(first)
    assert first_v2.module != second_v1.module

    assert {:ok, "second"} = Harness.ask(first, "second")
    assert {:ok, "second"} = Harness.ask(second, "second")
    assert List.last(tool_outcomes(first)) == {:ok, "2 count=2"}
    assert List.last(tool_outcomes(second)) == {:ok, "1 count=2"}
  end

  test "a tool-name collision leaves the old registry generation active", %{
    path: path,
    dir: dir
  } do
    module = module_name()
    write_counter(path, module, "1")
    [read | _] = Tool.builtins()

    provider = script([{:ok, asst(nil, [call("one")])}, {:ok, asst("done")}])

    session =
      start_session(provider: provider, plugins: [path], tools: [read], cwd: dir)

    [before] = Harness.plugins(session)

    conflicting =
      path
      |> File.read!()
      |> String.replace("version: \"1\"", "version: \"2\"")
      |> String.replace("name: \"counter\"", "name: \"read\"")

    File.write!(path, conflicting)

    assert {:error, {:plugin_reload_failed, ^path, "duplicate tool name: read"}} =
             Harness.reload_plugins(session)

    assert Harness.plugins(session) == [before]
    assert {:ok, "done"} = Harness.ask(session, "use the old tool")
    assert tool_outcomes(session) == [{:ok, "1 count=1"}]
  end

  test "default discovery loads plugins and the state process follows the session lifecycle", %{
    dir: dir
  } do
    plugin_dir = Path.join([dir, ".harness", "plugins"])
    File.mkdir_p!(plugin_dir)
    path = Path.join(plugin_dir, "counter.exs")
    write_counter(path, module_name(), "1")

    session = start_session(provider: script([]), cwd: dir)
    [%{path: ^path, pid: plugin_pid}] = Harness.plugins(session)
    monitor = Process.monitor(plugin_pid)

    GenServer.stop(session_pid(session))

    assert_receive {:DOWN, ^monitor, :process, ^plugin_pid, :normal}
  end

  test "a rejected multi-module plugin remains rejected on subsequent loads", %{path: path} do
    File.write!(
      path,
      """
      defmodule #{module_name()} do
        @behaviour Harness.Plugin

        alias Harness.Plugin.ToolSpec

        defprotocol NestedProtocol do
          def value(term)
        end

        @impl true
        def metadata, do: %{id: "counter", version: "1"}

        @impl true
        def tools do
          [
            %ToolSpec{
              name: "counter",
              description: "Increment a counter.",
              parameters: %{"type" => "object", "properties" => %{}}
            }
          ]
        end

        @impl true
        def init(_ctx), do: {:ok, 0}

        @impl true
        def handle_tool("counter", _args, _ctx, count) do
          {{:ok, "count=\#{count + 1}"}, count + 1}
        end
      end
      """
    )

    assert {:error, :plugin_must_compile_to_exactly_one_module} = Loader.load(path)
    assert {:error, :plugin_must_compile_to_exactly_one_module} = Loader.load(path)
  end
end
