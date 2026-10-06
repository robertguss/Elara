defmodule Elara.Lab.MatrixTest do
  use ExUnit.Case, async: false
  alias Elara.Lab.{Matrix, MatrixRunner}

  test "the registered finite grid is round-major with 1200 distinct row identities and seeds" do
    rows = Matrix.plan(50, 1_085_000)
    assert length(Matrix.cases()) == 24
    assert length(rows) == 1_200
    assert Enum.map(rows, & &1.index) == Enum.to_list(0..1_199)
    assert Enum.map(rows, & &1.seed) == Enum.to_list(1_085_000..1_086_199)
    assert Enum.map(Enum.take(rows, 24), & &1.case_id) == Enum.map(Matrix.cases(), & &1.case_id)

    assert Enum.map(Enum.slice(rows, 24, 24), & &1.case_id) ==
             Enum.map(Matrix.cases(), & &1.case_id)

    assert Enum.all?(Enum.frequencies_by(rows, & &1.case_id), fn {_, n} -> n == 50 end)
  end

  test "a causally witnessed failed outcome remains eligible and is reported as a check failure" do
    [cell | _] = Matrix.plan(1, 42)
    row = fixture(cell)
    verdict = Matrix.judge(row, cell, "reviewed-sha")
    assert verdict.eligible
    assert verdict.passed
    assert verdict.cleanup_confirmed
    assert verdict.failed_checks == []

    failed = row |> Map.put("complete", false) |> put_in(["checks", "settled_receipts"], false)
    verdict = Matrix.judge(failed, cell, "reviewed-sha")
    assert verdict.eligible
    refute verdict.passed
    refute verdict.stop
    assert verdict.failed_checks == ["settled_receipts"]
  end

  test "wrong identity, source, configuration and missing causal or malformed evidence are ineligible" do
    [cell | _] = Matrix.plan(1, 42)
    row = fixture(cell)

    for invalid <- [
          Map.put(row, "seed", 43),
          Map.put(row, "scenario", "smoke"),
          Map.put(row, "params", %{}),
          Map.put(row, "host", false),
          Map.put(row, "matrix_peer", "invalid"),
          Map.put(row, "checks", nil),
          Map.update!(row, "checks", &Map.delete(&1, "settled_receipts")),
          put_in(row, ["host", "commit"], "other-sha"),
          put_in(row, ["host", "dirty"], true),
          put_in(row, ["host", "schedulers"], 14),
          put_in(row, ["matrix_peer", "max_restarts"], 100),
          put_in(row, ["matrix_peer", "artifacts_verified"], false),
          put_in(row, ["matrix_peer", "outer_launcher_verified"], false),
          put_in(row, ["checks", "fault_witnessed"], false),
          put_in(row, ["checks", "target_down_witnessed"], false),
          put_in(row, ["checks", "settled_receipts"], "true")
        ] do
      refute Matrix.judge(invalid, cell, "reviewed-sha").eligible, inspect(invalid)
    end
  end

  test "whole-VM eligibility requires real OS exit and Port/VM stop witnesses" do
    cell = Matrix.plan(1, 42) |> Enum.find(&(&1.scenario == "vm_recovery"))

    row =
      fixture(cell)
      |> Map.put("fault", %{"exit_status" => 137, "port_down" => true, "vm_stopped" => true})

    assert Matrix.judge(row, cell, "reviewed-sha").eligible

    for invalid <- [
          Map.put(row, "fault", nil),
          put_in(row, ["fault", "exit_status"], 0),
          put_in(row, ["fault", "port_down"], false),
          put_in(row, ["fault", "vm_stopped"], false)
        ] do
      refute Matrix.judge(invalid, cell, "reviewed-sha").eligible
    end

    for invalid <- [nil, false, "not a row", []],
        do: assert(Matrix.judge(invalid, cell, "reviewed-sha").stop)
  end

  test "unconfirmed cleanup and observed retention stop reuse even with otherwise valid evidence" do
    [cell | _] = Matrix.plan(1, 42)
    row = fixture(cell)

    for unsettled <- [
          put_in(row, ["cleanup", "confirmed"], false),
          put_in(row, ["matrix_peer", "outer_cleanup_confirmed"], false),
          Map.put(row, "retained_dir", "/owned/retained-root")
        ] do
      verdict = Matrix.judge(unsettled, cell, "reviewed-sha")
      assert verdict.eligible
      refute verdict.cleanup_confirmed
      refute verdict.passed
      assert verdict.stop
    end
  end

  test "the summary counts eligible failures and excludes ineligible clocks from spreads" do
    [cell | _] = Matrix.plan(1, 42)

    passing = %{
      cell: cell,
      report: %{"recovery_ms" => 10, "backlog_ms" => 20},
      verdict: %{
        eligible: true,
        passed: true,
        cleanup_confirmed: true,
        stop: false,
        failed_checks: []
      }
    }

    failing = %{
      passing
      | report: %{"recovery_ms" => 30},
        verdict: %{passing.verdict | passed: false, failed_checks: ["settled_receipts"]}
    }

    invalid = %{
      passing
      | report: %{"recovery_ms" => 999},
        verdict: %{
          passing.verdict
          | eligible: false,
            passed: false,
            cleanup_confirmed: false,
            stop: true
        }
    }

    summary = MatrixRunner.summarize([passing, failing, invalid], 4)
    assert summary.recorded == 3
    assert summary.eligible == 2
    assert summary.passed == 1
    assert summary.outcome_failures == 1
    assert summary.ineligible == 1
    assert summary.unconfirmed_cleanup == 1
    refute summary.completed

    assert summary.cases[cell.case_id].recovery_ms == %{
             count: 2,
             p50: 10,
             p95: 30,
             p99: 30,
             max: 30
           }

    assert summary.cases[cell.case_id].backlog_ms.count == 1
    assert summary.cases[cell.case_id].failed_checks == %{"settled_receipts" => 1}
  end

  defp fixture(cell) do
    %{
      "scenario" => cell.scenario,
      "seed" => cell.seed,
      "params" => cell.params,
      "host" => %{"commit" => "reviewed-sha", "dirty" => false, "schedulers" => 2},
      "matrix_peer" => %{
        "max_restarts" => 3,
        "period" => 5,
        "artifacts_verified" => true,
        "outer_launcher_verified" => true,
        "outer_cleanup_confirmed" => true
      },
      "checks" => Map.new(Matrix.check_names(cell), &{&1, true}),
      "complete" => true,
      "cleanup" => %{"confirmed" => true}
    }
  end
end
