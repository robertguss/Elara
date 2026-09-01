defmodule Elara.Benchmark.PreflightV6Test do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.InternalConfirmatory

  @root Path.expand("../../..", __DIR__)
  @script Path.join(@root, "priv/benchmark/preflight_exp003_v6.exs")
  @output Path.join(@root, "docs/experiments/003-effect-receipt-v6-preflight.json")
  @candidate_ids for(class <- ~w(P W), n <- 1..8, do: class <> String.pad_leading("#{n}", 2, "0")) ++
                   for(n <- 1..4, do: "S" <> String.pad_leading("#{n}", 2, "0"))

  setup_all do
    Process.put(:elara_exp003_v6_preflight_no_run, true)
    Code.require_file(@script)
    Process.delete(:elara_exp003_v6_preflight_no_run)
    :ok
  end

  test "constructs all candidates and semantically validates all assignments before sampling" do
    report = read_report()

    assert report["schema"] == "elara.exp003.preflight.v6"
    assert report["linear_issue"] == "ROB-866"
    assert report["summary"]["candidate_count"] == 20
    assert report["summary"]["assignment_count"] == 40
    assert report["summary"]["assignment_roles"] == %{"primary" => 20, "secondary" => 20}
    assert report["summary"]["candidate_ids"] == Enum.sort(@candidate_ids)
    assert report["summary"]["all_candidate_bytes_constructed"]
    assert report["summary"]["all_assignments_semantically_validated"]
    refute report["summary"]["sampling_or_selection_performed"]

    assert Enum.sort(Enum.map(report["tasks"], & &1["id"])) == Enum.sort(@candidate_ids)
    assert length(Enum.uniq_by(report["assignments"], & &1["id"])) == 40

    for assignment <- report["assignments"] do
      assert assignment["fault"] in ~w(F1 F2 F3 F4)
      assert assignment["role"] in ~w(primary secondary)
      assert assignment["barrier_workspace_sha256"] =~ ~r/^[0-9a-f]{64}$/

      assert Map.keys(assignment["converged_workspace_sha256_by_condition"]) ==
               ~w(baseline receipts)

      assert Map.keys(assignment["causal_terminal_evidence_expected_to_survive"]) ==
               ~w(baseline receipts)
    end
  end

  test "P02 is one exact CRLF edit with unchanged surrounding bytes" do
    p02 = read_report()["tasks"] |> Enum.find(&(&1["id"] == "P02"))
    proof = p02["p02_crlf_exact_edit"]

    assert p02["operation_class"] == "patch"
    assert p02["fault_target_job_mutations"] == 1
    assert proof["unique_match_count"] == 1
    assert proof["crlf_only"]
    assert proof["preimage_sha256"] != proof["postimage_sha256"]
    assert proof["unrelated_prefix_sha256"] =~ ~r/^[0-9a-f]{64}$/
    assert proof["unrelated_suffix_sha256"] =~ ~r/^[0-9a-f]{64}$/
  end

  test "builds byte-identical canonical reports twice" do
    first = apply(Elara.Benchmark.Exp003V6Preflight, :build_report, [])
    second = apply(Elara.Benchmark.Exp003V6Preflight, :build_report, [])
    bytes = File.read!(@output)

    assert first == second
    assert InternalConfirmatory.canonical_json(first) == bytes
    assert JSON.decode!(bytes) == first
  end

  test "records zero beacon, selection, and held-out exposure" do
    exposure = read_report()["exposure"]

    refute exposure["future_beacon_committed"]
    refute exposure["future_beacon_fetched"]
    refute exposure["candidate_selection_performed"]
    refute exposure["held_out_task_literals_generated"]
    refute exposure["B_or_T_calculated"]
    assert exposure["target_fault_rows"] == 0
    assert exposure["target_timing_runs"] == 0
    assert exposure["external_fault_rows"] == 0
    assert exposure["dogfood_runs"] == 0
  end

  defp read_report, do: @output |> File.read!() |> JSON.decode!()
end
