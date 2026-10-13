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

  test "production command boundary scrubs inherited keys and permits named project variables" do
    script = ~S"""
    for name <- ~w(ELARA_API_KEY XAI_API_KEY EXA_API_KEY PRIVATE_OTHER_TOKEN PHX_PORT DATABASE_URL SECRET_KEY_BASE) do
      System.put_env(name, "fake-test-value")
    end
    for name <- ~w(SSH_AUTH_SOCK MISE_DATA_DIR ASDF_DATA_DIR HOMEBREW_PREFIX MIX_TEST_OPTION HEX_TEST_OPTION ERL_TEST_OPTION ELIXIR_TEST_OPTION HOMEBREW_GITHUB_API_TOKEN HEX_API_KEY MISE_SECRET) do
      System.put_env(name, "fake-test-value")
    end
    System.delete_env("LC_ALL")
    System.put_env("ELARA_COMMAND_ENV", " PHX_PORT, DATABASE_URL,SECRET_KEY_BASE,HEX_API_KEY,ELARA_API_KEY,XAI_API_KEY,EXA_API_KEY")
    {:ok, _} = Application.ensure_all_started(:elara)
    call = %Elara.Message.ToolCall{id: "environment", name: "bash",
      args: {:ok, %{"command" => "env | cut -d= -f1; set -e; mix --version; git --version; cargo --version"}}}
    {:ok, agent} = Agent.start_link(fn -> [
      {:ok, %Elara.Message.Assistant{tool_calls: [call]}},
      {:ok, %Elara.Message.Assistant{text: "checked"}}
    ] end)
    {:ok, session} = Elara.start_session(provider: {Elara.Provider.Scripted, agent},
      cwd: System.tmp_dir!(), persist: false, plugins: [], home: System.tmp_dir!(), skill_paths: [])
    {:ok, "checked"} = Elara.ask(session, "check environment and tools")
    result = Enum.find(Elara.transcript(session), &match?(%Elara.Message.ToolResult{}, &1))
    {:ok, output} = result.outcome
    IO.puts(output)
    {:error, {:not_started, message}} = Elara.Exec.run(["env"], env: %{"XAI_API_KEY" => "fake-test-value"})
    IO.puts(message)
    {:error, {:not_started, message}} = Elara.Exec.run(["env"], env: %{"UNNAMED_PROJECT_VARIABLE" => "fake-test-value"})
    IO.puts(message)
    {:ok, %Elara.Exec.Result{code: 0, output: "C"}} =
      Elara.Exec.run(["/bin/sh", "-c", "printf %s \"$LC_ALL\""], env: %{"LC_ALL" => "C"})
    Mix.Task.run("elara.env")
    """

    {output, 0} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "--no-start", "-e", script],
        cd: @root,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    for name <-
          ~w(ELARA_API_KEY XAI_API_KEY EXA_API_KEY PRIVATE_OTHER_TOKEN ELARA_COMMAND_ENV HOMEBREW_GITHUB_API_TOKEN MISE_SECRET) do
      refute name in String.split(output, "\n")
    end

    for name <-
          ~w(PHX_PORT DATABASE_URL SECRET_KEY_BASE SSH_AUTH_SOCK MISE_DATA_DIR ASDF_DATA_DIR HOMEBREW_PREFIX MIX_TEST_OPTION HEX_TEST_OPTION ERL_TEST_OPTION ELIXIR_TEST_OPTION HEX_API_KEY),
        do: assert(name in String.split(output, "\n"))

    assert output =~ "command environment overrides are not allowed: [\"XAI_API_KEY\"]"

    assert output =~
             "command environment overrides are not allowed: [\"UNNAMED_PROJECT_VARIABLE\"]"

    assert output =~ "Forwarded (names only):"
    assert output =~ "Withheld (names only):"
    assert output =~ "Mix "
    assert output =~ "git version"
    assert output =~ "cargo "
    refute output =~ "fake-test-value"
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

  test "the checkout's own project skills never reach test sessions" do
    checkout_skills = Path.join(@root, ".agents/skills")
    assert checkout_skills in Application.fetch_env!(:elara, :ignored_skill_dirs)

    for cwd <- [@root, Path.join(@root, "tmp/nested workspace")] do
      %{skills: skills} = Elara.Skills.discover(cwd)

      refute Enum.any?(skills, fn {_, skill} ->
               String.starts_with?(skill.path, checkout_skills)
             end)
    end
  end
end
