defmodule Elara.Benchmark.MaterializationV8Test do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.{Dogfood.Plan, ElaraAdapter, Manifest}
  alias Elara.Benchmark.Exp003.{CandidateFactory, Command, Materializer}

  @root Path.expand("../../..", __DIR__)
  @protocol_path Path.join(
                   @root,
                   "test/fixtures/benchmark/exp003-v8-boundary/protocol.json"
                 )
  @beacon_path Path.join(
                 @root,
                 "test/fixtures/benchmark/exp003-v8-development/beacon.json"
               )
  @candidate_ids for(
                   class <- ~w(P W),
                   n <- 1..8,
                   do: class <> String.pad_leading(Integer.to_string(n), 2, "0")
                 ) ++
                   for(n <- 1..4, do: "S" <> String.pad_leading(Integer.to_string(n), 2, "0"))

  setup_all do
    root = temporary_root("outputs")
    File.mkdir!(root)
    output_a = Path.join(root, "materialization-a")
    output_b = Path.join(root, "materialization-b")

    protocol_sha256 = file_sha256(@protocol_path)
    beacon_sha256 = file_sha256(@beacon_path)

    assert {:ok, result_a} =
             Materializer.run(
               @root,
               @protocol_path,
               protocol_sha256,
               @beacon_path,
               beacon_sha256,
               output_a
             )

    assert {:ok, result_b} =
             Materializer.run(
               @root,
               @protocol_path,
               protocol_sha256,
               @beacon_path,
               beacon_sha256,
               output_b
             )

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      beacon_sha256: beacon_sha256,
      output_a: output_a,
      output_b: output_b,
      protocol_sha256: protocol_sha256,
      receipt: read_json(Path.join(output_a, "materialization-receipt.json")),
      result_a: result_a,
      result_b: result_b
    }
  end

  test "constructs and proves the complete 20-candidate frame before selecting 17", context do
    protocol = read_json(@protocol_path)
    source = read_json(Path.join(@root, get_in(protocol, ["inputs", "candidate_source", "path"])))

    compatibility =
      read_json(Path.join(@root, get_in(protocol, ["inputs", "compatibility", "path"])))

    seed = Base.decode16!(context.receipt["seed_sha256"], case: :mixed)
    source = CandidateFactory.compatible_source!(source, compatibility)

    tasks =
      CandidateFactory.construct_all(source, seed,
        fixture_schema: "elara.exp003.fixture.v8-development",
        plan_schema: "elara.exp003.plan.v8-development",
        fixture_ref: &"manifest.json#task-#{&1}",
        exposure_split: "development_materialization_fixture"
      )

    assert tasks |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.sort(@candidate_ids)
    assert length(tasks) == 20

    for task <- tasks do
      assert task["fixture"]["fixture_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      assert {:ok, mapping} = ElaraAdapter.mapping(task)
      assert length(mapping["tool_calls"]) == length(task["plan"]["steps"])
    end

    p02 = task!(tasks, "P02")
    p02_initial = file!(p02["fixture"]["initial_files"], p02["plan"]["steps"] |> hd() |> path!())
    assert p02_initial["content"] =~ "\r\n"

    w04 = task!(tasks, "W04")
    assert w04["fixture"]["initial_files"] == w04["fixture"]["expected_no_fault_files"]

    assert w04["plan"]["steps"] |> hd() |> Map.fetch!("expected_no_fault_outcome") ==
             "error_conflict"

    w06 = task!(tasks, "W06")
    w06_path = w06["plan"]["steps"] |> hd() |> path!()
    assert file!(w06["fixture"]["expected_no_fault_files"], w06_path)["content"] == ""

    proofs = context.receipt["candidate_construction_proofs"]
    assert Enum.map(proofs, & &1["id"]) == Enum.map(tasks, & &1["id"])
    assert Enum.all?(proofs, & &1["validated_before_selection"])
    assert context.receipt["eligible_candidate_count"] == 17
    assert context.receipt["selected_task_count"] == 12
    assert context.receipt["selected_row_count"] == 20
  end

  test "two materializations are byte-identical and load through public validators", context do
    assert Map.delete(context.result_a, "output_root") ==
             Map.delete(context.result_b, "output_root")

    for relative <- ~w(
          beacon/verified.json
          dogfood-plan.json
          external-adapter-equivalence.json
          manifest.json
          materialization-receipt.json
        ) do
      assert File.read!(Path.join(context.output_a, relative)) ==
               File.read!(Path.join(context.output_b, relative))
    end

    manifest_path = Path.join(context.output_a, "manifest.json")
    dogfood_path = Path.join(context.output_a, "dogfood-plan.json")

    assert {:ok, manifest} = Manifest.load(manifest_path)
    assert map_size(manifest.tasks) == 12
    assert map_size(manifest.rows) == 20

    assert {:ok, plan} = Plan.load(dogfood_path, repo_root: @root)
    assert length(Plan.execution_tasks(plan)) == 12
  end

  test "production materialization uses no executable source transformation" do
    factory = File.read!(Path.join(@root, "lib/elara/benchmark/exp003/candidate_factory.ex"))
    materializer = File.read!(Path.join(@root, "lib/elara/benchmark/exp003/materializer.ex"))

    for source <- [factory, materializer] do
      refute source =~ "Code.eval_string"
      refute source =~ "Code.string_to_quoted"
      refute source =~ "materialize_exp003_v6.exs"
      refute source =~ "transform_v6_source"
    end

    refute factory =~ "String.replace"
    refute factory =~ "retokenize"
    refute factory =~ "source[\"tasks\"]"
    refute factory =~ "source[\"adapter_equivalence_fixtures\"]"
    refute materializer =~ "String.replace"
    assert factory =~ ~s[defp new_task("P02"]
    assert factory =~ ~s[defp new_task("W04"]
    assert factory =~ ~s[defp new_task("W06"]
  end

  test "rejects a stale source path paired with another source's digest before output", context do
    {protocol_path, protocol_sha256, root} =
      tampered_protocol("stale-source", fn protocol ->
        identities = protocol["source_identities"]
        digest = Map.fetch!(identities, "priv/benchmark/preflight_exp003_v8.exs")

        identities =
          identities
          |> Map.delete("priv/benchmark/preflight_exp003_v8.exs")
          |> Map.put("priv/benchmark/preflight_exp003_v7.exs", digest)

        Map.put(protocol, "source_identities", identities)
      end)

    output = Path.join(root, "output")

    assert {:error, reason} = materialize(protocol_path, protocol_sha256, output, context)
    assert reason =~ "source_identity_frame"
    refute File.exists?(output)
  end

  test "rejects the right report hash paired with the wrong report path before output", context do
    {protocol_path, protocol_sha256, root} =
      tampered_protocol("wrong-report-path", fn protocol ->
        put_in(
          protocol,
          ["inputs", "command_path_report", "path"],
          "docs/experiments/003-effect-receipt-v6-preflight.json"
        )
      end)

    output = Path.join(root, "output")

    assert {:error, reason} = materialize(protocol_path, protocol_sha256, output, context)
    assert reason =~ "report_path"
    refute File.exists?(output)
  end

  test "rejects generated-source identity drift before output", context do
    {protocol_path, protocol_sha256, root} =
      tampered_protocol("source-drift", fn protocol ->
        put_in(
          protocol,
          ["source_identities", "lib/elara/benchmark/exp003/candidate_factory.ex"],
          String.duplicate("0", 64)
        )
      end)

    output = Path.join(root, "output")

    assert {:error, reason} = materialize(protocol_path, protocol_sha256, output, context)
    assert reason =~ "source_identity_mismatch"
    assert reason =~ "candidate_factory.ex"
    refute File.exists?(output)
  end

  test "command rebinding rejects a caller-replaced manifest and receipt", context do
    root = temporary_root("replaced-bundle")
    File.mkdir!(root)
    bundle = Path.join(root, "bundle")
    File.cp_r!(context.output_a, bundle)
    on_exit(fn -> File.rm_rf!(root) end)

    manifest_path = Path.join(bundle, "manifest.json")
    manifest = manifest_path |> read_json() |> Map.put("scope_id", "caller-replaced")
    File.write!(manifest_path, Materializer.canonical_json(manifest))

    receipt_path = Path.join(bundle, "materialization-receipt.json")

    receipt =
      receipt_path
      |> read_json()
      |> put_in(["outputs", "manifest.json"], file_sha256(manifest_path))

    File.write!(receipt_path, Materializer.canonical_json(receipt))

    assert {:error, reason} =
             Command.contract(
               @root,
               @protocol_path,
               context.protocol_sha256,
               receipt_path,
               file_sha256(receipt_path)
             )

    assert inspect(reason) =~ "bundle_identity_mismatch"
    assert inspect(reason) =~ "manifest.json"
  end

  test "confirmatory execution claim is receipt-bound and one-shot" do
    root = temporary_root("execution-claim")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    receipt_path = Path.join(root, "materialization-receipt.json")
    receipt_sha256 = String.duplicate("a", 64)

    contract = %{
      confirmatory: true,
      protocol: "ER-3/FND-2-v8",
      manifest_sha256: String.duplicate("b", 64),
      claim_root: root
    }

    assert :ok = Command.claim_confirmatory_execution(contract, receipt_path, receipt_sha256)

    assert {:error, :confirmatory_execution_already_claimed} =
             Command.claim_confirmatory_execution(
               contract,
               Path.join(root, "copied-bundle/materialization-receipt.json"),
               receipt_sha256
             )

    claim = read_json(Path.join(root, receipt_sha256 <> ".json"))
    assert claim["receipt_sha256"] == receipt_sha256
    assert claim["manifest_sha256"] == contract.manifest_sha256
    assert claim["first_receipt_path"] == receipt_path

    assert File.ls!(root) == [receipt_sha256 <> ".json"]

    assert {:error, :confirmatory_execution_forbidden} =
             Command.claim_confirmatory_execution(
               %{contract | confirmatory: false},
               Path.join(root, "other-receipt.json"),
               receipt_sha256
             )
  end

  test "rejects wrong protocol schema and cardinality before reading a missing beacon", context do
    for {label, mutate, expected} <- [
          {"schema", &Map.put(&1, "schema", "elara.exp003.materialization-protocol.v7"),
           "protocol_contract"},
          {"count", &put_in(&1, ["candidate_frame", "source_count"], 19), "source_count"}
        ] do
      {protocol_path, protocol_sha256, root} = tampered_protocol(label, mutate)
      output = Path.join(root, "output")
      missing_beacon = Path.join(root, "missing-beacon.json")

      assert {:error, reason} =
               Materializer.run(
                 @root,
                 protocol_path,
                 protocol_sha256,
                 missing_beacon,
                 context.beacon_sha256,
                 output
               )

      assert reason =~ expected
      refute reason =~ "missing-beacon"
      refute File.exists?(output)
    end
  end

  test "requires an absent output and temporary path under an existing parent", context do
    missing_parent = Path.join(temporary_root("absent-parent"), "output")

    assert {:error, reason} =
             materialize(@protocol_path, context.protocol_sha256, missing_parent, context)

    assert reason =~ "missing_output_parent"

    root = temporary_root("output-state")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    existing_output = Path.join(root, "existing")
    File.mkdir!(existing_output)

    assert {:error, reason} =
             materialize(@protocol_path, context.protocol_sha256, existing_output, context)

    assert reason =~ "existing_output"

    temporary_output = Path.join(root, "temporary")
    File.mkdir!(temporary_output <> ".tmp")

    assert {:error, reason} =
             materialize(@protocol_path, context.protocol_sha256, temporary_output, context)

    assert reason =~ "existing_temporary_output"
    refute File.exists?(temporary_output)
  end

  defp materialize(protocol_path, protocol_sha256, output, context) do
    Materializer.run(
      @root,
      protocol_path,
      protocol_sha256,
      @beacon_path,
      context.beacon_sha256,
      output
    )
  end

  defp tampered_protocol(label, mutate) do
    root = temporary_root(label)
    File.mkdir!(root)
    protocol_path = Path.join(root, "protocol.json")

    @protocol_path
    |> read_json()
    |> mutate.()
    |> Materializer.canonical_json()
    |> then(&File.write!(protocol_path, &1, [:exclusive]))

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    {protocol_path, file_sha256(protocol_path), root}
  end

  defp task!(tasks, id), do: Enum.find(tasks, &(&1["id"] == id))
  defp path!(step), do: get_in(step, ["arguments", "path"])
  defp file!(files, path), do: Enum.find(files, &(&1["path"] == path))
  defp read_json(path), do: path |> File.read!() |> JSON.decode!()

  defp temporary_root(label) do
    Path.join(
      System.tmp_dir!(),
      "elara-exp003-v8-#{label}-#{System.unique_integer([:positive])}"
    )
  end

  defp file_sha256(path), do: path |> File.read!() |> sha256()
  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
