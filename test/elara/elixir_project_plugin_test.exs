defmodule Elara.ElixirProjectPluginTest do
  use ExUnit.Case, async: false

  alias Elara.Plugin.Loader
  alias Elara.Tool.Ctx

  @plugin Path.expand("../../.elara/plugins/elixir_project.exs", __DIR__)

  test "loads the repository plugin and records a compact format check" do
    project =
      Path.join(
        System.tmp_dir!(),
        "elixir-project-plugin-#{System.unique_integer([:positive])}"
      )

    bin = Path.join(project, "bin")
    mix = Path.join(bin, "mix")
    File.mkdir_p!(bin)
    File.write!(mix, "#!/bin/sh\nprintf 'fake mix %s\\n' \"$*\"\n")
    File.chmod!(mix, 0o755)

    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      File.rm_rf!(project)
    end)

    assert {:ok, candidate} = Loader.load(@plugin)

    assert Enum.map(candidate.tools, & &1.name) == [
             "elixir_project_info",
             "elixir_check",
             "elixir_test",
             "elixir_last_run",
             "elixir_rerun_last"
           ]

    ctx = %Ctx{cwd: project}
    assert {:ok, {:ok, initial_state}} = Loader.call(candidate.module, :init, [ctx])

    assert {{:ok, output}, state} =
             candidate.module.handle_tool(
               "elixir_check",
               %{"check" => "format"},
               ctx,
               initial_state
             )

    assert output =~ "check:format ok"
    assert state.run_count == 1

    assert {{:ok, last_run}, ^state} =
             candidate.module.handle_tool("elixir_last_run", %{}, ctx, state)

    assert last_run =~ "run=1 command=check:format status=ok"

    assert {{:ok, rerun}, rerun_state} =
             candidate.module.handle_tool("elixir_rerun_last", %{}, ctx, state)

    assert rerun =~ "check:format ok"
    assert rerun_state.run_count == 2

    assert {{:error, _}, ^initial_state} =
             candidate.module.handle_tool("elixir_rerun_last", %{}, ctx, initial_state)

    # A literal target named "all" must not turn into the whole suite on rerun.
    assert {{:ok, _}, target_state} =
             candidate.module.handle_tool("elixir_test", %{"target" => "all"}, ctx, initial_state)

    assert {{:ok, output}, _} =
             candidate.module.handle_tool("elixir_rerun_last", %{}, ctx, target_state)

    assert output =~ "fake mix test all"
  end

  @tag timeout: 60_000
  test "discover, fail a real focused test, fix, upgrade, and rerun remembered state" do
    project =
      Path.join(System.tmp_dir!(), "plugin-workflow-#{System.unique_integer([:positive])}")

    for subdir <- ["lib", "test", ".elara/plugins"], do: File.mkdir_p!(Path.join(project, subdir))

    File.write!(Path.join(project, "mix.exs"), """
    defmodule PluginWorkflow.MixProject do
      use Mix.Project
      def project, do: [app: :plugin_workflow, version: "0.1.0"]
    end
    """)

    source = Path.join(project, "lib/example.ex")
    File.write!(source, "defmodule Example, do: def(answer, do: :wrong)\n")
    File.write!(Path.join(project, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(project, "test/example_test.exs"), """
    defmodule ExampleTest do
      use ExUnit.Case
      test "answer", do: assert(Example.answer() == :correct)
    end
    """)

    {:ok, script} = Agent.start_link(fn -> [] end)

    {:ok, session} =
      Elara.start_session(
        cwd: project,
        home: project,
        skill_paths: [],
        provider: {Elara.Provider.Scripted, script},
        persist: false
      )

    {:ok, session_pid} = Elara.session_pid(session)

    on_exit(fn ->
      if Process.alive?(session_pid), do: GenServer.stop(session_pid)
      File.rm_rf!(project)
    end)

    assert Elara.plugins(session) == []
    plugin = Path.join(project, ".elara/plugins/elixir_project.exs")
    File.cp!(Path.expand("../support/fixtures/elixir_project_v1.exs", __DIR__), plugin)
    assert {:ok, [version1]} = Elara.reload_plugins(session)
    assert version1.version == "1"

    assert {:error, failure} =
             invoke(session, script, "elixir_test", %{"target" => "test/example_test.exs:3"})

    assert failure =~ "test:test/example_test.exs:3 error"
    assert failure =~ "Example.answer()"

    assert {:ok, _} =
             invoke(session, script, "edit", %{
               "path" => "lib/example.ex",
               "old_text" => ":wrong",
               "new_text" => ":correct"
             })

    assert File.read!(source) =~ ":correct"
    before_history = Elara.transcript(session)

    File.cp!(@plugin, plugin)
    assert {:ok, [version2]} = Elara.reload_plugins(session)
    assert version2.version == "2"
    assert version2.pid == version1.pid
    assert version2.generation == 2
    assert Elara.transcript(session) == before_history
    assert {:ok, last} = invoke(session, script, "elixir_last_run", %{})
    assert last =~ "run=1 command=test:test/example_test.exs:3 status=error"
    assert {:ok, success} = invoke(session, script, "elixir_rerun_last", %{})
    assert success =~ "test:test/example_test.exs:3 ok"
    assert success =~ ~r/(1 test|1 passed)/

    File.write!(plugin, "defmodule Broken do")
    assert {:error, {:plugin_reload_failed, ^plugin, _}} = Elara.reload_plugins(session)
    assert Elara.plugins(session) == [version2]
    assert {:ok, last} = invoke(session, script, "elixir_last_run", %{})
    assert last =~ "run=2 command=test:test/example_test.exs:3 status=ok"
    assert {:ok, _} = invoke(session, script, "elixir_rerun_last", %{})
    assert {:ok, last} = invoke(session, script, "elixir_last_run", %{})
    assert last =~ "run=3 "

    assert {:ok, %Elara.FlightRecorder.Report{status: :match}} =
             Elara.replay(Elara.recording(session))
  end

  @tag timeout: 60_000
  test "one turn rereads edited source and reruns the identical real Mix test" do
    project = Path.join(System.tmp_dir!(), "plugin-repeat-#{System.unique_integer([:positive])}")
    for subdir <- ["lib", "test"], do: File.mkdir_p!(Path.join(project, subdir))

    File.write!(Path.join(project, "mix.exs"), """
    defmodule RepeatWorkflow.MixProject do
      use Mix.Project
      def project, do: [app: :repeat_workflow, version: "0.1.0"]
    end
    """)

    File.write!(
      Path.join(project, "lib/example.ex"),
      "defmodule Example, do: def(answer, do: :wrong)\n"
    )

    File.write!(Path.join(project, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(project, "test/example_test.exs"), """
    defmodule ExampleTest do
      use ExUnit.Case
      test "answer", do: assert(Example.answer() == :correct)
    end
    """)

    read_args = %{"path" => "lib/example.ex"}
    test_args = %{"target" => "test/example_test.exs:3"}
    edit_args = %{"path" => "lib/example.ex", "old_text" => ":wrong", "new_text" => ":correct"}

    replies =
      for {id, name, args} <- [
            {"read-before", "read", read_args},
            {"test-before", "elixir_test", test_args},
            {"fix", "edit", edit_args},
            {"read-after", "read", read_args},
            {"test-after", "elixir_test", test_args}
          ] do
        call = %Elara.Message.ToolCall{id: id, name: name, args: {:ok, args}}
        Elara.Message.assistant(nil, [call])
      end

    {:ok, script} = Agent.start_link(fn -> replies ++ [Elara.Message.assistant("fixed", [])] end)

    {:ok, session} =
      Elara.start_session(
        cwd: project,
        home: project,
        skill_paths: [],
        plugins: [@plugin],
        provider: {Elara.Provider.Scripted, script},
        persist: false
      )

    {:ok, pid} = Elara.session_pid(session)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(project)
    end)

    assert {:ok, "fixed"} =
             Elara.ask(session, "Read, test, fix, then repeat the same read and test")

    results =
      for %Elara.Message.ToolResult{call_id: id, outcome: outcome} <- Elara.transcript(session),
          into: %{},
          do: {id, outcome}

    assert {:ok, before} = results["read-before"]
    assert before =~ ":wrong"
    assert {:error, failed} = results["test-before"]
    assert failed =~ "Example.answer()"
    assert {:ok, after_edit} = results["read-after"]
    assert after_edit =~ ":correct"
    assert {:ok, passed} = results["test-after"]
    assert passed =~ "test:test/example_test.exs:3 ok"

    assert {:ok, %Elara.FlightRecorder.Report{status: :match}} =
             Elara.replay(Elara.recording(session))
  end

  defp invoke(session, script, name, args) do
    id = "call-#{System.unique_integer([:positive])}"
    call = %Elara.Message.ToolCall{id: id, name: name, args: {:ok, args}}
    {:ok, tool_turn} = Elara.Message.assistant(nil, [call])
    {:ok, final_turn} = Elara.Message.assistant("done", [])
    Agent.update(script, fn [] -> [{:ok, tool_turn}, {:ok, final_turn}] end)
    assert {:ok, "done"} = Elara.ask(session, name)

    result =
      Enum.find(
        Elara.transcript(session),
        &match?(%Elara.Message.ToolResult{call_id: ^id}, &1)
      )

    result.outcome
  end
end
