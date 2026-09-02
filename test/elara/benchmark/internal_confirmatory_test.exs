defmodule Elara.Benchmark.InternalConfirmatoryTest do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.{InternalConfirmatory, Manifest, Qualification, Runner}

  @manifest_path Path.expand("../../fixtures/benchmark/exp003-v6/manifest.json", __DIR__)
  @failed_checkpoint_path Path.expand(
                            "../../fixtures/benchmark/exp003-v4/internal-confirmatory-qualification-failed.checkpoint.json",
                            __DIR__
                          )
  @qualification_path Path.expand(
                        "../../fixtures/benchmark/exp003-v6/internal-confirmatory-qualification.json",
                        __DIR__
                      )
  @qualification_checkpoint_path Path.expand(
                                   "../../fixtures/benchmark/exp003-v6/internal-confirmatory-qualification.checkpoint.json",
                                   __DIR__
                                 )

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-internal-confirmatory-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      state: Path.join(root, "state"),
      workspace: Path.join(root, "workspace"),
      output: Path.join(root, "output.json")
    }
  end

  test "v6 qualification derives the complete development schedule" do
    assert {:ok, source} = Manifest.load(@manifest_path)
    assert {:ok, qualification} = Qualification.manifest(source)

    assert qualification.data["scope_id"] == "EXP-003-v6-internal-adapter-qualification"
    assert map_size(qualification.tasks) == 3
    assert map_size(qualification.rows) == 12
    assert length(Runner.fault_schedule(qualification)) == 72
    assert length(Runner.no_fault_schedule(qualification)) == 72

    assert Enum.all?(
             qualification.tasks,
             fn {_id, task} -> task["exposure_split"] == "development_adapter_fixture" end
           )
  end

  test "dirty state, workspace, and output paths fail before target preparation", context do
    File.mkdir_p!(context.state)

    assert {:error, {:dirty_path, :state_root, _path}} =
             InternalConfirmatory.qualify(
               @manifest_path,
               context.state,
               context.workspace,
               context.output
             )

    File.rm_rf!(context.state)
    File.mkdir_p!(context.workspace)

    assert {:error, {:dirty_path, :workspace_root, _path}} =
             InternalConfirmatory.qualify(
               @manifest_path,
               context.state,
               context.workspace,
               context.output
             )

    File.rm_rf!(context.workspace)
    File.mkdir_p!(Path.dirname(context.output))
    File.write!(context.output, "occupied")

    assert {:error, {:dirty_path, :output_path, _path}} =
             InternalConfirmatory.qualify(
               @manifest_path,
               context.state,
               context.workspace,
               context.output
             )
  end

  test "an unmatched started checkpoint is retained as an invalid interruption", context do
    checkpoint = %{
      "schema" => "elara.exp003.internal-confirmatory-checkpoint.v1",
      "protocol" => "ER-3/FND-2-v6",
      "mode" => "qualify",
      "source_manifest_sha256" => String.duplicate("a", 64),
      "execution_manifest_sha256" => String.duplicate("b", 64),
      "events" => [
        %{
          "sequence" => 1,
          "kind" => "fault",
          "status" => "started",
          "run" => %{
            "row_id" => "QUAL-W01-F1",
            "condition" => "baseline",
            "run_index" => 1,
            "order_index" => 1
          }
        }
      ]
    }

    File.mkdir_p!(context.state)

    File.write!(
      Path.join(context.state, "internal-confirmatory-checkpoint.json"),
      InternalConfirmatory.canonical_json(checkpoint)
    )

    assert {:error, {:interrupted_checkpoint, "fault", %{"row_id" => "QUAL-W01-F1"} = run}} =
             InternalConfirmatory.qualify(
               @manifest_path,
               context.state,
               context.workspace,
               context.output
             )

    assert run["condition"] == "baseline"
    refute File.exists?(context.output)
  end

  test "an altered v6 manifest is rejected before paths are created", context do
    altered_path = Path.join(context.root, "altered-manifest.json")
    manifest = @manifest_path |> File.read!() |> JSON.decode!() |> Map.put("tampered", true)
    File.mkdir_p!(context.root)
    File.write!(altered_path, JSON.encode!(manifest))

    assert {:error, [{:manifest_digest_mismatch, _expected, _actual}]} =
             InternalConfirmatory.qualify(
               altered_path,
               context.state,
               context.workspace,
               context.output
             )

    refute File.exists?(context.state)
    refute File.exists?(context.workspace)
    refute File.exists?(context.output)
  end

  test "all semantics-bearing command sources have frozen identities" do
    assert {:ok, identities} =
             InternalConfirmatory.source_identities(Path.expand("../../..", __DIR__))

    assert map_size(identities) == 12
    assert identities["priv/benchmark/run_internal_confirmatory.exs"]
    assert identities["lib/elara/benchmark/internal_confirmatory.ex"]
    assert identities["lib/elara/benchmark/elara_adapter.ex"]
    assert identities["lib/elara/benchmark/scorer.ex"]
    assert identities["priv/benchmark/elara_target_runner.exs"]
  end

  test "only an exact valid Pass score authorizes qualification or execution" do
    assert :ok =
             InternalConfirmatory.validate_authorizing_score(%{
               "valid" => true,
               "status" => "Pass",
               "errors" => []
             })

    assert {:error, {:non_passing_score, "Mixed"}} =
             InternalConfirmatory.validate_authorizing_score(%{
               "valid" => true,
               "status" => "Mixed",
               "errors" => []
             })

    assert {:error, {:non_passing_score, "Fail"}} =
             InternalConfirmatory.validate_authorizing_score(%{
               "valid" => true,
               "status" => "Fail",
               "errors" => []
             })

    assert {:error, {:invalid_score, [%{"code" => "malformed"}]}} =
             InternalConfirmatory.validate_authorizing_score(%{
               "valid" => false,
               "status" => "Invalid",
               "errors" => [%{"code" => "malformed"}]
             })
  end

  test "freezes a complete valid Pass V6 development qualification and checkpoint" do
    report_bytes = File.read!(@qualification_path)
    report = JSON.decode!(report_bytes)
    checkpoint_bytes = File.read!(@qualification_checkpoint_path)
    checkpoint = JSON.decode!(checkpoint_bytes)

    assert sha256(report_bytes) ==
             "8ef12be71c61bded368bca509d9b2d3ea6ef2e2aa44b24a698d641843576ed23"

    assert sha256(checkpoint_bytes) ==
             "4091b776e865bcd0c29dbcbb68d8eb33bf3b355d9d03f9fb6406d6b0db49ea34"

    assert InternalConfirmatory.canonical_json(report) == report_bytes
    assert InternalConfirmatory.canonical_json(checkpoint) == checkpoint_bytes
    assert report["protocol"] == "ER-3/FND-2-v6"
    assert report["score"]["valid"]
    assert report["score"]["status"] == "Pass"
    assert report["score"]["causal_terminal_convergence"]["applicable_repetitions"] == 9
    assert report["execution"]["fault_run_count"] == 72
    assert report["execution"]["no_fault_run_count"] == 72
    assert report["execution"]["checkpoint_event_count"] == 288
    assert report["execution"]["checkpoint_sha256"] == sha256(checkpoint_bytes)
    assert report["exposure"]["v6_confirmatory_fault_runs"] == 0
    assert report["exposure"]["v6_confirmatory_no_fault_timing_runs"] == 0
    refute report["exposure"]["confirmatory_B_or_T_calculated"]

    assert Enum.frequencies_by(checkpoint["events"], &{&1["kind"], &1["status"]}) == %{
             {"fault", "started"} => 72,
             {"fault", "completed"} => 72,
             {"no_fault", "started"} => 72,
             {"no_fault", "completed"} => 72
           }
  end

  test "replay fails closed on source hash drift and malformed score diagnostics", context do
    report = @qualification_path |> File.read!() |> JSON.decode!()
    scorer_path = "lib/elara/benchmark/scorer.ex"

    drifted =
      put_in(report, ["identities", scorer_path], String.duplicate("0", 64))

    drifted_path = Path.join(context.root, "drifted.json")
    File.mkdir_p!(context.root)
    File.write!(drifted_path, InternalConfirmatory.canonical_json(drifted))

    assert {:error, :report_source_identity_mismatch} =
             InternalConfirmatory.replay(@manifest_path, drifted_path, context.output)

    assert {:ok, current_identities} = InternalConfirmatory.source_identities(File.cwd!())

    malformed =
      report
      |> Map.put("identities", current_identities)
      |> put_in(["score", "errors"], [%{"malformed" => ["diagnostic"]}])

    malformed_path = Path.join(context.root, "malformed-diagnostic.json")
    File.write!(malformed_path, InternalConfirmatory.canonical_json(malformed))

    assert {:error, :score_replay_mismatch} =
             InternalConfirmatory.replay(@manifest_path, malformed_path, context.output)

    refute File.exists?(context.output)
  end

  test "retains the complete failed v4 development qualification checkpoint" do
    bytes = File.read!(@failed_checkpoint_path)
    checkpoint = JSON.decode!(bytes)

    assert sha256(bytes) == "e206f46325c420f5c664a0c185b223896e4a745ab598cc7091350769e5878a41"
    assert checkpoint["schema"] == "elara.exp003.internal-confirmatory-checkpoint.v1"
    assert length(checkpoint["events"]) == 288

    assert Enum.frequencies_by(checkpoint["events"], &{&1["kind"], &1["status"]}) == %{
             {"fault", "started"} => 72,
             {"fault", "completed"} => 72,
             {"no_fault", "started"} => 72,
             {"no_fault", "completed"} => 72
           }

    completed = Enum.filter(checkpoint["events"], &(&1["status"] == "completed"))

    assert Enum.all?(completed, fn event ->
             event["record_sha256"] ==
               event["record"] |> InternalConfirmatory.canonical_json() |> sha256()
           end)

    assert Enum.all?(
             completed,
             &(&1["record"]["exposure_split"] == "development_adapter_fixture" or
                 &1["kind"] == "no_fault")
           )
  end

  defp sha256(value),
    do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
