defmodule Elara.TestEnvironmentTest do
  use ExUnit.Case, async: true

  # The execution stub starts with the application, before test_helper.exs runs.
  # A command must not see provider or Elara settings from the developer's shell.
  test "commands run through the execution stub see no ELARA_* or XAI_API_KEY" do
    assert {:ok, %Elara.Exec.Result{code: 0, output: output}} =
             Elara.Exec.run(["/usr/bin/env"], cwd: System.tmp_dir!(), timeout_ms: 5_000)

    leaked =
      output
      |> String.split("\n")
      |> Enum.filter(
        &(String.starts_with?(&1, "ELARA_") or String.starts_with?(&1, "XAI_API_KEY="))
      )
      |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd()))

    assert leaked == []
  end

  test "user skill discovery uses the isolated test home" do
    home = Application.fetch_env!(:elara, :skills_home)

    assert home != System.user_home!()
    assert Elara.Skills.discover(System.tmp_dir!()).options[:home] == Path.expand(home)
  end
end
