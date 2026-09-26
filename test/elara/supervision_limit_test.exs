defmodule Elara.SupervisionLimitTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # The test config raises :max_restarts because crash-recovery tests kill
  # supervised singletons on purpose. This checks the production default in a
  # separate VM: the fourth crash within five seconds stops the application.
  test "the production restart limit escalates a fourth rapid crash" do
    script = ~S"""
    :ok = Application.stop(:elara)
    Application.delete_env(:elara, :max_restarts)
    {:ok, _} = Application.ensure_all_started(:elara)

    crash = fn ->
      old = Process.whereis(Elara.TestJobs)
      Process.exit(old, :kill)

      wait = fn wait, tries ->
        current = Process.whereis(Elara.TestJobs)

        cond do
          is_pid(current) and current != old -> :restarted
          tries == 0 -> :stopped
          true -> Process.sleep(10) && wait.(wait, tries - 1)
        end
      end

      wait.(wait, 100)
    end

    results = for _ <- 1..4, do: crash.()
    IO.puts("results=" <> inspect(results))
    IO.puts("running=" <> inspect(is_pid(Process.whereis(Elara.Supervisor))))
    """

    {output, 0} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", script],
        cd: @root,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert output =~ "results=[:restarted, :restarted, :restarted, :stopped]"
    assert output =~ "running=false"
  end
end
