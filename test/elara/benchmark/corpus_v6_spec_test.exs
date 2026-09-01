defmodule Elara.Benchmark.CorpusV6SpecTest do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.{Compatibility, Fixture, Manifest, Runner}
  alias Elara.Benchmark.Dogfood.Plan

  @root Path.expand("../../..", __DIR__)
  @manifest_path Path.join(@root, "test/fixtures/benchmark/exp003-v6/manifest.json")
  @dogfood_path Path.join(@root, "test/fixtures/benchmark/exp003-v6/dogfood-plan.json")
  @external_path Path.join(
                   @root,
                   "test/fixtures/benchmark/exp003-v6/external-adapter-equivalence.json"
                 )
  @compatibility_path Path.join(
                        @root,
                        "docs/experiments/003-effect-receipt-v6-compatibility.json"
                      )
  @preflight_path Path.join(
                    @root,
                    "docs/experiments/003-effect-receipt-v6-preflight.json"
                  )
  @fixture_root Path.dirname(@manifest_path)
  @seed "10513722487da5bd0068d4d0466e179ba42d4310c174359ec8b87d558936509e"
  @selected ~w(S04 P08 W02 P06 S02 W05 W04 S01 P03 P07 W07 S03)
  @secondary ~w(S04 P08 W02 P06 S02 W05 W04 S01)
  @dogfood ~w(D04 D06 D11 D08 D02 D12 D03 D05 D07 D10 D09 D01)

  @artifact_sha256 %{
    "test/fixtures/benchmark/exp003-v6/manifest.json" =>
      "b415272e106db54087edbd54500c3544c94ca13b2d42950c0a63b82a38c0973c",
    "test/fixtures/benchmark/exp003-v6/dogfood-plan.json" =>
      "42b92b7f2e5d8fdb99db4a28a631ce239274e10875bedb13dc56e1f5dd50fe9f",
    "test/fixtures/benchmark/exp003-v6/external-adapter-equivalence.json" =>
      "f2ee5d0e52051d7675953bc09cf80674e3c420e6093c7497fe45513ad286561e",
    "test/fixtures/benchmark/exp003-v6/beacon/api.drand.sh.json" =>
      "55679fa09143f4aaa3ee8ff092662797acbe967c4c82e5d2bd344d05e71e973e",
    "test/fixtures/benchmark/exp003-v6/beacon/drand.cloudflare.com.json" =>
      "f36be1d4002e00c26863d5cea2100992c1bb4d2855d22c15c377964b595b9bd3",
    "test/fixtures/benchmark/exp003-v6/beacon/verification.json" =>
      "c177f1c140d9e75552817b2d0fb350cd5375e07c100d601d1cdc05a383114018",
    "test/fixtures/benchmark/exp003-v6/beacon/verify.cjs" =>
      "22036277f7890a5748fa1b53112f0584a2635b9d373ecafcba88c27c0e87aa6a",
    "test/fixtures/benchmark/exp003-v6/beacon/package.json" =>
      "97af654644489527ed0641e371b13055effe923d3a878f40191635018daec937",
    "docs/experiments/003-effect-receipt-v6-preflight.json" =>
      "8f69b8d15b2c7bb3ee782c87b778b0b32e536be1a548c207e7cd7664dd8b0216",
    "priv/benchmark/preflight_exp003_v6.exs" =>
      "48f36d9047138546e962ad636f18c8d936b0aa9cea8402ddff18ccdf6bb35121",
    "docs/experiments/003-effect-receipt-v6-compatibility.json" =>
      "ffb997e4d74e229ea615b5461ea7b833a4e1f3606fba9d2c6bd6872b1468b5eb",
    "priv/benchmark/materialize_exp003_v6.exs" =>
      "f919b1b7a82ddf55d705af26dd80cc43fb56c3be4f7b17c9a5c7b5ee7cf178b8"
  }

  @preserved_artifacts %{
    "test/fixtures/benchmark/exp003-v4/manifest.json" =>
      "14cc3a57763f0ab48f4b68a70317916d09ff4bee64ba18d150480dd1315820a2",
    "test/fixtures/benchmark/exp003-v4/dogfood-plan.json" =>
      "d08335edfc4fb2a322722c3ebf6ce5f7960208d4e28d99046c285ef67a8283ea",
    "test/fixtures/benchmark/exp003-v4/external-adapter-equivalence.json" =>
      "1983af558f124d802c14025f454a35aa11e19ca5adc13a0b25a21772f147f707",
    "test/fixtures/benchmark/exp003-v5/beacon/api.drand.sh.json" =>
      "24898a55a44ab5b9146cd6e745db0d0a688ebca8261695180bcc55015dd98a04",
    "test/fixtures/benchmark/exp003-v5/beacon/drand.cloudflare.com.json" =>
      "0ab8759a9caa6dabd507ae39d88bdc955ae935f63c21b8996a6436807ff0a60b",
    "test/fixtures/benchmark/exp003-v5/beacon/verification.json" =>
      "26656c573f96abceb9a3b55eb0e933313b352974e42757ec5c0e5bcb37d2c1d1"
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
    preflight = @preflight_path |> File.read!() |> JSON.decode!()

    %{
      manifest: manifest,
      dogfood: dogfood,
      compatibility: compatibility,
      external: external,
      preflight: preflight
    }
  end

  test "the verified future beacon derives the exact fresh v6 selection", %{manifest: manifest} do
    data = manifest.data
    beacon = data["beacon"]
    seed = Base.decode16!(@seed, case: :mixed)

    assert data["schema"] == "elara.exp003.corpus.v6"
    assert data["preregistration_version"] == "ER-3/FND-2-v6"
    assert beacon["round"] == 6_429_026
    assert beacon["nominal_time"] == "2026-09-01T22:30:00Z"

    assert beacon["randomness"] ==
             "da1187a4e2f7053c917fabcd2edf5e96109b22ab08db3318f19efe59757dfd55"

    material =
      "elara:exp-003:er3:fnd-2:v6\0" <>
        beacon["chain_hash"] <>
        ":#{beacon["round"]}:#{beacon["randomness"]}:#{data["seed"]["frozen_commit"]}"

    assert sha256(material) == @seed
    assert data["seed"]["sha256"] == @seed
    assert data["seed"]["frozen_commit"] == "ed9a2dbbdd2ba9ab743a9dc95d1f0ba08663891c"
    assert data["selection"]["selected_task_ids"] == @selected
    assert data["selection"]["secondary_row_task_ids"] == @secondary
    assert Enum.map(data["tasks"], & &1["id"]) == @selected
    assert length(data["fault_rows"]) == 20
    assert data["references"]["materialization"] == "ROB-868"

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
    assert api["round"] == 6_429_026
    assert verification["verified"]
    assert verification["client"] == "drand-client@1.4.2"
    assert Enum.map(verification["results"], &Map.drop(&1, ["url"])) == [api, api]
    assert sha256(Base.decode16!(api["signature"], case: :mixed)) == api["randomness"]

    for {filename, expected} <- manifest.data["beacon"]["artifact_sha256"] do
      assert file_sha256(Path.join(@fixture_root, "beacon/#{filename}")) == expected
    end
  end

  test "preflight precedes selection and every selected row satisfies its frozen contract",
       context do
    %{manifest: manifest, compatibility: compatibility, preflight: preflight} = context

    assert preflight["summary"]["candidate_count"] == 20
    assert preflight["summary"]["assignment_count"] == 40
    assert preflight["summary"]["all_candidate_bytes_constructed"]
    assert preflight["summary"]["all_assignments_semantically_validated"]
    refute preflight["summary"]["sampling_or_selection_performed"]

    assert manifest.data["compatibility"]["validated_before_seed_selection"]
    assert manifest.data["compatibility"]["preflight_sha256"] == file_sha256(@preflight_path)

    assert manifest.data["compatibility"]["preflight_source_sha256"] ==
             file_sha256(Path.join(@root, "priv/benchmark/preflight_exp003_v6.exs"))

    assert manifest.data["compatibility"]["sha256"] == file_sha256(@compatibility_path)
    profiles = Map.new(compatibility["candidates"], &{&1["id"], &1})

    for task <- manifest.data["tasks"] do
      profile = profiles[task["id"]]
      contract = task["workspace_contract"]

      assert task["primary_fault"] == profile["primary_fault"]
      assert task["secondary_fault"] == profile["secondary_fault"]
      assert task["fixture"]["schema"] == "elara.exp003.fixture.v6"
      assert task["plan"]["schema"] == "elara.exp003.plan.v6"

      assert contract["initial_reset_workspace_sha256"] ==
               task["fixture"]["initial_workspace_sha256"]

      assert contract["complete_task_workspace_sha256"] ==
               task["fixture"]["expected_no_fault_workspace_sha256"]
    end

    for row <- manifest.data["fault_rows"] do
      expected_causal =
        compatibility["fault_contracts"][row["fault_type"]][
          "causal_terminal_evidence_expected_to_survive"
        ]

      assert row["causal_terminal_evidence_expected_to_survive"] == expected_causal
      assert row["workspace_contract"]
      assert row["expected_converged_workspace_by_condition"]["baseline"]
      assert row["expected_converged_workspace_by_condition"]["receipts"]
      assert row["expected_safe_action"]["baseline"]
      assert row["expected_safe_action"]["receipts"]
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

  test "external and dogfood dispositions are v6-aligned and fault-unexposed", context do
    %{manifest: manifest, dogfood: dogfood, external: external} = context

    assert dogfood.data["schema"] == "elara.exp003.dogfood-plan.v6"
    assert dogfood.data["seed"]["sha256"] == @seed
    assert dogfood.data["seed"]["round"] == 6_429_026
    assert dogfood.data["execution_order"] == @dogfood
    assert dogfood.data["denominators"] == %{"P" => 12, "I" => 10, "C" => 2}
    assert dogfood.data["source"]["linear_issue"] == "ROB-868"
    assert dogfood.data["exposure"]["dogfood_task_runs"] == 0
    assert dogfood.data["exposure"]["dogfood_fault_runs"] == 0

    assert external["schema"] == "elara.exp003.external-adapter-equivalence.v6"
    assert external["preregistration_version"] == "ER-3/FND-2-v6"
    assert external["manifest_sha256"] == manifest.sha256
    assert external["summary"]["required_outcome"] == "Insufficient comparability"
    assert external["summary"]["no_fault_equivalent"] == 3
    assert external["summary"]["included_operation_classes"] == ~w(write patch shell)
    assert length(external["fault_comparability"]) == 20
    assert Enum.all?(external["fault_comparability"], &(&1["classification"] == "non_comparable"))
    assert external["comparability_floor"]["status"] == "below_floor"
    assert external["exposure"]["lemon_fault_rows_executed"] == 0
    assert external["exposure"]["target_fault_rows_executed"] == 0
    refute external["exposure"]["B_or_T_calculated"]

    assert manifest.data["exposure_statement"] == %{
             "B_or_T_calculated" => false,
             "dogfood_fault_runs" => 0,
             "dogfood_task_runs" => 0,
             "external_fault_rows_executed" => 0,
             "statement" =>
               "V6 materialization only; no internal, external, or dogfood fault output observed.",
             "target_fault_rows_executed" => 0
           }
  end

  test "all generated artifacts are exact, preserve prior evidence, and contain no stale v5 identity" do
    for {relative_path, expected} <- @artifact_sha256 do
      assert file_sha256(Path.join(@root, relative_path)) == expected
    end

    for {relative_path, expected} <- @preserved_artifacts do
      assert file_sha256(Path.join(@root, relative_path)) == expected
    end

    for path <- [@manifest_path, @dogfood_path, @external_path] do
      bytes = File.read!(path)
      refute bytes =~ "ER-3/FND-2-v5"
      refute bytes =~ "exp003-v5"
    end
  end

  defp temporary_root(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-exp003-v6-#{suffix}-#{System.unique_integer([:positive])}"
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
