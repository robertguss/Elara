defmodule Harness.PluginTest do
  use ExUnit.Case, async: false

  alias Harness.Message
  alias Harness.Message.{ToolCall, ToolResult}
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

  defp call(id) do
    %ToolCall{id: id, name: "counter", args: {:ok, %{}}}
  end

  defp start_session(opts) do
    {:ok, session} = Harness.start_session(Keyword.merge([persist: false, tools: []], opts))
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
    session
  end

  defp module_name do
    "CounterPlugin#{System.unique_integer([:positive])}"
  end

  defp write_counter(path, module, version, opts \\ []) do
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
        def metadata, do: %{id: "counter", version: "#{version}"}

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
        def init(_ctx), do: #{init}

        @impl true
        def handle_tool("counter", _args, _ctx, #{state_pattern}) do
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
             :sys.get_state(session).core.config.tools["counter"].plugin

    assert server == before.pid

    assert {:ok, "first done"} = Harness.ask(session, "first")
    prior_history = Harness.transcript(session)
    assert tool_outcomes(session) == [{:ok, "1 count=1"}]

    write_counter(path, module, "2")

    assert {:ok, [after_reload]} = Harness.reload_plugins(session)
    assert Process.alive?(session)
    assert after_reload.pid == before.pid
    assert after_reload.module != before.module
    assert after_reload.version == "2"
    assert after_reload.generation == 2
    assert Harness.transcript(session) == prior_history

    assert %PluginRef{version: "2", generation: 2, server: server} =
             :sys.get_state(session).core.config.tools["counter"].plugin

    assert server == before.pid

    assert {:ok, "second done"} = Harness.ask(session, "second")
    assert tool_outcomes(session) == [{:ok, "1 count=1"}, {:ok, "2 count=2"}]
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
    assert {:ok, [%{version: "2", generation: 2}]} = await_reload(session)
    assert {:ok, "after reload"} = Harness.ask(session, "second")
    assert List.last(tool_outcomes(session)) == {:ok, "2 count=1"}
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

    GenServer.stop(session)

    assert_receive {:DOWN, ^monitor, :process, ^plugin_pid, :normal}
  end
end
