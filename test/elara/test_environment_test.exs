defmodule Elara.TestEnvironmentTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # Launch proof in a controlled subprocess: runtime config must clear these
  # variables before any application code runs, however the suite is started.
  test "test runtime config clears provider and Elara variables at launch" do
    script = ~S"""
    IO.puts("elara=" <> inspect(System.get_env("ELARA_LAUNCH_PROBE")))
    IO.puts("xai=" <> inspect(System.get_env("XAI_API_KEY")))
    IO.puts("root=" <> Application.fetch_env!(:elara, :sessions_root))
    """

    {output, 0} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "--no-start", "-e", script],
        cd: @root,
        env: [{"MIX_ENV", "test"}, {"ELARA_LAUNCH_PROBE", "1"}, {"XAI_API_KEY", "x"}],
        stderr_to_stdout: true
      )

    assert output =~ "elara=nil"
    assert output =~ "xai=nil"
    assert [_, root] = Regex.run(~r/root=(.+)/, output)
    refute String.starts_with?(root, System.user_home!())
  end

  @tag :requires_app
  test "commands run through the execution stub see no ELARA_* or XAI_API_KEY" do
    # Print only offending names so a large environment cannot hit the output cap.
    command = "env | grep -E '^(ELARA_[A-Za-z0-9_]*|XAI_API_KEY)=' | cut -d= -f1; true"

    assert {:ok, %Elara.Exec.Result{code: 0, output: output}} =
             Elara.Exec.run(["/bin/sh", "-c", command], cwd: System.tmp_dir!(), timeout_ms: 5_000)

    assert String.split(output, "\n", trim: true) == []
  end

  test "state and skill roots are isolated from the developer's home" do
    home = Application.fetch_env!(:elara, :skills_home)
    sessions = Application.fetch_env!(:elara, :sessions_root)

    refute String.starts_with?(Path.expand(home), System.user_home!())
    refute String.starts_with?(Path.expand(sessions), System.user_home!())
    assert Elara.Skills.discover(System.tmp_dir!()).options[:home] == Path.expand(home)
  end
end
