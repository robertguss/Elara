defmodule Elara.LabScenariosTest do
  # Not async: scenarios share the TestJobs slots and swap the sessions root.
  use ExUnit.Case, async: false

  # Two runs of one seed; each must pass and clean up before the next starts.
  defp run!(scenario, seed \\ 1) do
    [first, second] = for _ <- 1..2, do: passing_run!(scenario, seed)
    assert is_binary(first.choices_digest) and first.choices_digest == second.choices_digest
    second
  end

  defp passing_run!(scenario, seed) do
    {:ok, [result]} = Elara.Lab.run(scenario, seed: seed)
    refute Map.has_key?(result, :retained_dir), "cleanup unconfirmed: #{result[:retained_dir]}"
    assert Elara.Lab.failed_checks(result) == [], inspect(result.checks, pretty: true)
    result
  end

  @tag timeout: 90_000
  test "concurrent_jobs: cancellation frees one of four slots without disturbing the others" do
    result = run!("concurrent_jobs")
    assert result.completed_turns == 5
    assert result.statuses == ["cancelled", "passed", "passed", "passed", "passed"]
  end

  @tag timeout: 90_000
  test "session_crash: a job survives its killed idle owner and is delivered once on reopen" do
    result = run!("session_crash")
    assert result.completed_turns == 3
  end

  @tag timeout: 90_000
  test "provider_fault: a scripted failure before or during interpretation loses no completion" do
    result = run!("provider_fault")

    for stage <- ["before_completion", "during_interpretation"],
        check <- [
          "scripted_fault_in_expected_turn",
          "failure_receipt",
          "primary_responsive_during_job"
        ],
        do: assert(Map.has_key?(result.checks, :"#{stage}.#{check}"))

    assert result.checks.fault_rule_fired_once_each
  end
end
