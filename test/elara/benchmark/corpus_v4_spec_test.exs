defmodule Elara.Benchmark.CorpusV4SpecTest do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.{Compatibility, Fixture, Manifest, Runner}
  alias Elara.Benchmark.Dogfood.Plan

  @manifest_path Path.expand("../../fixtures/benchmark/exp003-v4/manifest.json", __DIR__)
  @dogfood_path Path.expand("../../fixtures/benchmark/exp003-v4/dogfood-plan.json", __DIR__)
  @external_path Path.expand(
                   "../../fixtures/benchmark/exp003-v4/external-adapter-equivalence.json",
                   __DIR__
                 )
  @compatibility_path Path.expand(
                        "../../../docs/experiments/003-effect-receipt-v4-compatibility.json",
                        __DIR__
                      )
  @fixture_root Path.dirname(@manifest_path)
  @seed "b0e2163cd22735e68d32bab00bd640662cccbf429d1c29502b83d0f9f2cef110"
  @selected ~w(W08 P08 P03 W03 W07 P07 S03 S02 W05 P06 S01 S04)
  @secondary ~w(W08 P08 P03 W03 W07 P07 S03 S02)
  @dogfood ~w(D08 D10 D04 D06 D07 D11 D02 D05 D01 D03 D12 D09)

  @preserved_artifacts %{
    "test/fixtures/benchmark/exp003-v2/manifest.json" =>
      "f5fde3aead3a4ff2aaf9d6aee880d7da2b9a60619523f084cedcaa0943a5d1d9",
    "test/fixtures/benchmark/exp003-v2/dogfood-plan.json" =>
      "ea598e3430702236ed2b9b7da4b4cf9d94376f866e3f28d25a8bd789fd7b6576",
    "test/fixtures/benchmark/exp003-v2/external-adapter-equivalence.json" =>
      "557bc146767ea23e50d43eb505cca114a340225cfddf3c28dc0e4e87758dfd32",
    "test/fixtures/benchmark/exp003-v3/manifest.json" =>
      "4129ae964daf35469499dc9506ace9fa89db0c9f00a20826dfc6790edd5b5491",
    "test/fixtures/benchmark/exp003-v3/dogfood-plan.json" =>
      "04221a8d72d8c4e14ff70c8ec9af88095e3017d1a2b7386f5c03fca3ea4923b8",
    "test/fixtures/benchmark/exp003-v3/external-adapter-equivalence.json" =>
      "928c541658f8096a1b0f74f7101b37a6a82af386c3557fb59978485c17cf8c2e"
  }

  defmodule NeutralAdapter do
    @behaviour Elara.Benchmark.Adapter

    @impl true
    def execute(task, cwd, %{kind: :no_fault}) do
      outcome =
        Enum.reduce_while(task["plan"]["steps"], "ok", fn step, _outcome ->
          case execute_step(step, cwd) do
            "ok" -> {:cont, "ok"}
            other -> {:halt, other}
          end
        end)

      {:ok, %{"outcome" => outcome}}
    end

    defp execute_step(%{"operation_kind" => "write"} = step, cwd) do
      args = step["arguments"]
      target = Path.join(cwd, args["path"])

      cond do
        File.regular?(target) and sha256(File.read!(target)) == args["desired"]["sha256"] ->
          "ok"

        expected_write_state?(target, args["expected"]) ->
          File.mkdir_p!(Path.dirname(target))
          File.write!(target, args["desired"]["content"])
          "ok"

        true ->
          "error_conflict"
      end
    end

    defp execute_step(%{"operation_kind" => "patch"} = step, cwd) do
      args = step["arguments"]
      target = Path.join(cwd, args["path"])
      content = File.read!(target)

      cond do
        sha256(content) == args["postimage_sha256"] ->
          "ok"

        sha256(content) == args["preimage_sha256"] and
            length(:binary.matches(content, args["old_text"])) == 1 ->
          File.write!(
            target,
            String.replace(content, args["old_text"], args["new_text"], global: false)
          )

          "ok"

        true ->
          "error_conflict"
      end
    end

    defp execute_step(%{"operation_kind" => "shell"} = step, cwd) do
      args = step["arguments"]

      {_output, status} =
        System.shell(args["command"],
          cd: Path.join(cwd, args["relative_cwd"]),
          env: Map.to_list(args["environment"]),
          stderr_to_stdout: true
        )

      if status == 0, do: "ok", else: "error_exit_#{status}"
    end

    defp expected_write_state?(target, %{"state" => "absent"}), do: not File.exists?(target)

    defp expected_write_state?(target, %{"state" => "regular", "sha256" => digest}),
      do: File.regular?(target) and sha256(File.read!(target)) == digest

    defp sha256(value),
      do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  setup_all do
    {:ok, manifest} = Manifest.load(@manifest_path)
    {:ok, dogfood} = Plan.load(@dogfood_path)
    {:ok, compatibility} = Compatibility.load(@compatibility_path)
    external = @external_path |> File.read!() |> JSON.decode!()

    %{manifest: manifest, dogfood: dogfood, compatibility: compatibility, external: external}
  end

  test "the verified future beacon derives the exact fresh v4 selection", %{manifest: manifest} do
    data = manifest.data
    beacon = data["beacon"]
    seed = Base.decode16!(@seed, case: :mixed)

    assert data["schema"] == "elara.exp003.corpus.v4"
    assert data["preregistration_version"] == "ER-3/FND-2-v4"
    assert beacon["round"] == 6_428_786
    assert beacon["nominal_time"] == "2026-09-01T20:30:00Z"

    assert beacon["randomness"] ==
             "33b42acf65bf167b02cf360627e5444dc6236321b70888567468acd50bcd3ddf"

    material =
      "elara:exp-003:er3:fnd-2:v4\0" <>
        beacon["chain_hash"] <>
        ":#{beacon["round"]}:#{beacon["randomness"]}:#{data["seed"]["frozen_commit"]}"

    assert sha256(material) == @seed
    assert data["seed"]["sha256"] == @seed
    assert data["selection"]["selected_task_ids"] == @selected
    assert data["selection"]["secondary_row_task_ids"] == @secondary
    assert Enum.map(data["tasks"], & &1["id"]) == @selected
    assert length(data["fault_rows"]) == 20

    assert data["references"]["preregistration"] ==
             "docs/experiments/003-effect-receipt-confirmatory-preregistration-v4.md"

    assert data["references"]["materialization"] == "ROB-855"

    for candidate <- data["candidate_frame"] do
      assert candidate["order_key"] == sha256(seed <> <<0>> <> candidate["id"])
    end
  end

  test "both relays and the official client preserve the committed beacon", %{manifest: manifest} do
    [api_path, cloudflare_path] = manifest.data["beacon"]["relay_response_paths"]
    api = read_fixture(api_path)
    cloudflare = read_fixture(cloudflare_path)
    verification = read_fixture(manifest.data["beacon"]["verification_path"])

    assert api == cloudflare
    assert verification["verified"]
    assert verification["client"] == "drand-client@1.4.2"
    assert Enum.map(verification["results"], &Map.drop(&1, ["url"])) == [api, api]
    assert sha256(Base.decode16!(api["signature"], case: :mixed)) == api["randomness"]

    for {filename, expected} <- manifest.data["beacon"]["artifact_sha256"] do
      assert file_sha256(Path.join(@fixture_root, "beacon/#{filename}")) == expected
    end
  end

  test "every selected row satisfies the pre-seed compatibility and workspace contract", %{
    manifest: manifest,
    compatibility: compatibility
  } do
    assert manifest.data["compatibility"]["candidate_count"] == 20
    assert manifest.data["compatibility"]["validated_assignment_count"] == 40
    assert manifest.data["compatibility"]["validated_before_seed_selection"]
    assert manifest.data["compatibility"]["sha256"] == file_sha256(@compatibility_path)

    profiles = Map.new(compatibility["candidates"], &{&1["id"], &1})

    for task <- manifest.data["tasks"] do
      profile = profiles[task["id"]]
      contract = task["workspace_contract"]

      assert task["primary_fault"] == profile["primary_fault"]
      assert task["secondary_fault"] == profile["secondary_fault"]
      assert task["fixture"]["schema"] == "elara.exp003.fixture.v4"
      assert task["plan"]["schema"] == "elara.exp003.plan.v4"

      assert contract["initial_reset_workspace_sha256"] ==
               task["fixture"]["initial_workspace_sha256"]

      assert contract["complete_task_workspace_sha256"] ==
               task["fixture"]["expected_no_fault_workspace_sha256"]
    end

    for row <- manifest.data["fault_rows"] do
      assert row["workspace_contract"]

      assert row["expected_workspace_observation"] in ~w(pre_effect_workspace fault_target_postcondition complete_task_workspace)

      assert row["expected_converged_workspace_by_condition"]["baseline"]
      assert row["expected_converged_workspace_by_condition"]["receipts"]
    end
  end

  test "every selected task reaches its no-fault ground truth", %{manifest: manifest} do
    root = temporary_root("no-fault")

    records =
      @selected
      |> Enum.with_index(1)
      |> Enum.map(fn {task_id, index} ->
        run = %{
          "task_id" => task_id,
          "condition" => "receipts",
          "phase" => "measured",
          "run_index" => 1,
          "order_index" => index
        }

        assert {:ok, record} =
                 Runner.run_no_fault(manifest, run, adapter: NeutralAdapter, root: root)

        record
      end)

    assert length(records) == 12
    assert Enum.all?(records, & &1["workspace_correct"])
    assert Enum.all?(records, & &1["outcome_correct"])
  end

  @tag timeout: 120_000
  test "every expected workspace is an offline passing Mix project", %{manifest: manifest} do
    root = temporary_root("expected")

    for task <- manifest.data["tasks"] do
      cwd = Path.join(root, String.downcase(task["id"]))
      assert {:ok, _digest} = Fixture.reset(task, cwd, :expected_no_fault)

      {output, status} =
        System.cmd("mix", ["test"],
          cd: cwd,
          env: [{"HEX_OFFLINE", "1"}, {"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert status == 0, "#{task["id"]} expected fixture failed offline:\n#{output}"
      assert output =~ "Result: 1 passed"
    end
  end

  test "external and dogfood dispositions are v4-aligned and fault-unexposed", context do
    %{manifest: manifest, dogfood: dogfood, external: external} = context

    assert dogfood.data["schema"] == "elara.exp003.dogfood-plan.v4"
    assert dogfood.data["seed"]["sha256"] == @seed
    assert dogfood.data["seed"]["round"] == 6_428_786
    assert dogfood.data["execution_order"] == @dogfood
    assert dogfood.data["denominators"] == %{"P" => 12, "I" => 10, "C" => 2}

    assert dogfood.data["source"]["frozen_artifact"] ==
             "docs/experiments/003-effect-receipt-confirmatory-preregistration-v4.md"

    assert dogfood.data["source"]["linear_issue"] == "ROB-855"
    assert dogfood.data["exposure"]["dogfood_task_runs"] == 0
    assert dogfood.data["exposure"]["dogfood_fault_runs"] == 0

    assert external["schema"] == "elara.exp003.external-adapter-equivalence.v4"
    assert external["preregistration_version"] == "ER-3/FND-2-v4"
    assert external["manifest_sha256"] == manifest.sha256
    assert external["summary"]["no_fault_equivalent"] == 3
    assert external["summary"]["included_operation_classes"] == ~w(write patch shell)
    assert length(external["fault_comparability"]) == 20
    assert Enum.all?(external["fault_comparability"], &(&1["classification"] == "non_comparable"))

    assert external["version_adapter"]["v4_evidence_method"] ==
             "generated-token-invariant fixture and mapping isomorphism"

    assert Enum.all?(external["tasks"], fn task ->
             task["classification"] == "equivalent_by_frozen_template_isomorphism" and
               task["evidence"]["v2_direct_classification"] == "equivalent" and
               task["evidence"]["basis"] =~ "v4 changes"
           end)

    assert external["exposure"]["lemon_fault_rows_executed"] == 0
    assert external["exposure"]["target_fault_rows_executed"] == 0
    refute external["exposure"]["B_or_T_calculated"]
  end

  test "v2 and v3 confirmatory artifacts remain byte-identical" do
    for {relative_path, expected} <- @preserved_artifacts do
      path = Path.expand("../../../#{relative_path}", __DIR__)
      assert file_sha256(path) == expected
    end
  end

  defp temporary_root(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-exp003-v4-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp read_fixture(path),
    do: path |> then(&Path.join(@fixture_root, &1)) |> File.read!() |> JSON.decode!()

  defp file_sha256(path), do: path |> File.read!() |> sha256()
  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
