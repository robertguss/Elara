defmodule Harness.ElixirProjectPluginTest do
  use ExUnit.Case, async: false

  alias Harness.Plugin.Loader
  alias Harness.Tool.Ctx

  @plugin Path.expand("../../.harness/plugins/elixir_project.exs", __DIR__)

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
             "elixir_last_run"
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
  end
end
