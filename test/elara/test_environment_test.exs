defmodule Elara.TestEnvironmentTest do
  use ExUnit.Case, async: true

  # The `mix test` alias sets this sentinel before the application starts, and
  # config/runtime.exs must remove it before the execution stub inherits the
  # environment. The test therefore fails on any machine if isolation regresses.
  @sentinel "ELARA_TEST_LAUNCH_SENTINEL"

  test "provider and Elara variables are cleared before the application starts" do
    assert @sentinel in Application.fetch_env!(:elara, :test_cleared_env)
    assert System.get_env(@sentinel) == nil

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

  test "state and skill roots are isolated before the application starts" do
    home = Application.fetch_env!(:elara, :skills_home)
    sessions = Application.fetch_env!(:elara, :sessions_root)

    refute String.starts_with?(Path.expand(home), System.user_home!())
    refute String.starts_with?(Path.expand(sessions), System.user_home!())
    assert Elara.Skills.discover(System.tmp_dir!()).options[:home] == Path.expand(home)
  end
end
