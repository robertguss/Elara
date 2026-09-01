defmodule Elara.Benchmark.Exp003V3Materializer do
  @moduledoc false

  alias Elara.Benchmark.{Compatibility, Fixture}

  @root "test/fixtures/benchmark/exp003-v3"
  @manifest_path Path.join(@root, "manifest.json")
  @dogfood_path Path.join(@root, "dogfood-plan.json")
  @external_path Path.join(@root, "external-adapter-equivalence.json")
  @compatibility_path "docs/experiments/003-effect-receipt-v3-compatibility.json"
  @v2_materializer "priv/benchmark/materialize_exp003_v2.exs"
  @v2_external "test/fixtures/benchmark/exp003-v2/external-adapter-equivalence.json"
  @old_randomness "102a5c96e0068d5a3bef46be242054307efb1dfd362c63c483c987f8d5319356"

  def run do
    {:ok, compatibility} = Compatibility.load(@compatibility_path)
    randomness = beacon_randomness!()

    @v2_materializer
    |> File.read!()
    |> transform_materializer(randomness)
    |> Code.eval_string([], file: @v2_materializer)

    Elara.Benchmark.Exp003V3MaterializerBase.run()

    manifest = @manifest_path |> read_json!() |> upgrade_manifest(compatibility)
    write_json!(@manifest_path, manifest)
    write_json!(@external_path, external_attestation(manifest))

    IO.puts("final_manifest_sha256=#{file_sha256!(@manifest_path)}")
    IO.puts("final_dogfood_plan_sha256=#{file_sha256!(@dogfood_path)}")
    IO.puts("external_attestation_sha256=#{file_sha256!(@external_path)}")
  end

  def compatible_source!(source) do
    {:ok, compatibility} = Compatibility.load(@compatibility_path)
    profiles = Map.new(compatibility["candidates"], &{&1["id"], &1})

    candidates =
      Enum.map(source["candidate_frame"], fn candidate ->
        profile = Map.fetch!(profiles, candidate["id"])
        true = profile["class"] == candidate["operation_class"]

        candidate
        |> Map.put("primary_fault", profile["primary_fault"])
        |> Map.put("secondary_fault", profile["secondary_fault"])
      end)

    true = Enum.sort(Map.keys(profiles)) == Enum.sort(Enum.map(candidates, & &1["id"]))
    Map.put(source, "candidate_frame", candidates)
  end

  defp transform_materializer(source, randomness) do
    source
    |> String.replace(
      "Elara.Benchmark.Exp003V2Materializer",
      "Elara.Benchmark.Exp003V3MaterializerBase"
    )
    |> String.replace("ER-3/FND-2-v2", "ER-3/FND-2-v3")
    |> String.replace("elara.exp003.corpus.v2", "elara.exp003.corpus.v3")
    |> String.replace("elara.exp003.fixture.v2", "elara.exp003.fixture.v3")
    |> String.replace("elara.exp003.plan.v2", "elara.exp003.plan.v3")
    |> String.replace("elara.exp003.dogfood-plan.v2", "elara.exp003.dogfood-plan.v3")
    |> String.replace("test/fixtures/benchmark/exp003-v2", @root)
    |> String.replace("materialize_exp003_v2.exs", "materialize_exp003_v3.exs")
    |> String.replace("@round 6_426_976", "@round 6_427_122")
    |> String.replace(@old_randomness, randomness)
    |> String.replace(
      "@frozen_commit \"ff15e210f8ba9d62e439f2fe03dc8eb4b02f77c2\"",
      "@frozen_commit \"b0c0fd4ac46d6d3e361aa923ffdc0b2e42a5ebb9\""
    )
    |> String.replace("elara:exp-003:er3:fnd-2:v2", "elara:exp-003:er3:fnd-2:v3")
    |> String.replace(
      "003-effect-receipt-confirmatory-preregistration-v2.md",
      "003-effect-receipt-confirmatory-preregistration-v3.md"
    )
    |> String.replace("ROB-843", "ROB-849")
    |> String.replace("2026-09-01T05:25:00Z", "2026-09-01T06:38:00Z")
    |> String.replace(
      "id in ~w(W02 P03 P05 P06) -> new_task(id, candidate, seed)",
      "id in ~w(W02 W04 W06 P03 P05 P06) -> new_task(id, candidate, seed)"
    )
    |> String.replace(
      "  defp new_task(\"P03\", candidate, seed) do",
      new_write_candidate_source() <> "\n\n  defp new_task(\"P03\", candidate, seed) do"
    )
    |> String.replace(
      "source = read_json!(@source_manifest)",
      "source = read_json!(@source_manifest) |> Elara.Benchmark.Exp003V3Materializer.compatible_source!()"
    )
    |> String.replace(
      "Elara.Benchmark.Exp003V3MaterializerBase.run()",
      ""
    )
  end

  defp new_write_candidate_source do
    ~S'''
      defp new_task("W04", candidate, seed) do
        t = tokens(seed, "W04")
        path = "lib/generated_#{t["path"]}/corpus_case.ex"
        before = module_value(t, "pre_#{t["value"]}")
        desired = module_value(t, "post_#{t["new_value"]}")
        conflict_value = "conflict_#{t["sentinel"]}"
        conflict = module_value(t, conflict_value)
        initial = project_files(t, conflict, conflict_value)

        step = write_step(path, before, desired, "regular", 0)
        step = Map.put(step, "expected_no_fault_outcome", "error_conflict")
        task(candidate, t, initial, initial, [step], [], ground_truth(0, 0))
      end

      defp new_task("W06", candidate, seed) do
        t = tokens(seed, "W06")
        path = "lib/generated_#{t["path"]}/corpus_case.ex"
        before = module_value(t, "pre_#{t["value"]}")
        test = "defmodule Corpus#{String.capitalize(t["module"])}Test do\n  use ExUnit.Case\n\n  test \"frozen outcome\" do\n    assert File.read!(\"#{path}\") == \"\"\n  end\nend\n"
        initial = base_files() ++ [file(path, before), file("test/corpus_case_test.exs", test)]
        expected = base_files() ++ [file(path, ""), file("test/corpus_case_test.exs", test)]
        step = write_step(path, before, "", "regular", 1)
        task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
      end
    '''
  end

  defp upgrade_manifest(manifest, compatibility) do
    tasks = Enum.map(manifest["tasks"], &upgrade_task/1)
    tasks_by_id = Map.new(tasks, &{&1["id"], &1})
    contracts = compatibility["fault_contracts"]

    rows =
      Enum.map(manifest["fault_rows"], fn row ->
        profile = Enum.find(compatibility["candidates"], &(&1["id"] == row["task_id"]))
        contract = contracts[row["fault_type"]]

        row
        |> Map.put("expected_workspace_observation", contract["barrier_workspace"])
        |> Map.put(
          "expected_converged_workspace_by_condition",
          get_in(profile, ["workspace_overrides", row["fault_type"]]) ||
            contract["converged_workspace"]
        )
        |> put_in(
          ["semantic_equivalence", "required_alignment"],
          required_alignment(row["fault_type"], tasks_by_id[row["task_id"]])
        )
        |> Map.put("workspace_contract", tasks_by_id[row["task_id"]]["workspace_contract"])
      end)

    manifest
    |> Map.put("tasks", tasks)
    |> Map.put("fault_rows", rows)
    |> Map.put("compatibility", %{
      "path" => @compatibility_path,
      "sha256" => file_sha256!(@compatibility_path),
      "candidate_count" => 20,
      "validated_assignment_count" => 40,
      "validated_before_seed_selection" => true
    })
    |> Map.put("exposure_statement", %{
      "target_fault_rows_executed" => 0,
      "external_fault_rows_executed" => 0,
      "dogfood_task_runs" => 0,
      "dogfood_fault_runs" => 0,
      "B_or_T_calculated" => false,
      "statement" =>
        "V3 materialization only; no internal, external, or dogfood fault output observed."
    })
  end

  defp upgrade_task(task) do
    initial = task["fixture"]["initial_files"]
    pre_effect = apply_environment(initial, task["plan"]["pre_operation_changes"])
    target = apply_target(pre_effect, task)
    complete = task["fixture"]["expected_no_fault_files"]

    task =
      if task["id"] == "P06" do
        put_in(task, ["plan", "continuation_policy"], %{
          "after_target_ok_live_controller" => "execute continuation exactly once",
          "after_target_ok_recovered_controller" =>
            "do not invent model-loop continuation; report partial task workspace",
          "after_target_error" => "halt without continuation",
          "after_target_indeterminate" => "halt without retry or continuation",
          "fault_injection" => "effect only; continuation is never faulted",
          "parallelism" => "forbidden"
        })
      else
        task
      end

    task
    |> Map.put("workspace_contract", %{
      "initial_reset_workspace_sha256" => Fixture.digest_files(initial),
      "pre_effect_workspace_sha256" => Fixture.digest_files(pre_effect),
      "fault_target_postcondition_sha256" => Fixture.digest_files(target),
      "complete_task_workspace_sha256" => Fixture.digest_files(complete),
      "environmental_mutations_before_dispatch" =>
        task["ground_truth"]["expected_no_fault_environmental_mutation_count"],
      "fault_target_job_mutations" =>
        task["ground_truth"]["expected_no_fault_job_external_mutation_count"]
    })
    |> then(fn upgraded ->
      digest = Fixture.fixture_digest(upgraded)

      upgraded
      |> put_in(["fixture", "fixture_sha256"], digest)
      |> put_in(["fixture", "fixture_commit"], "sha256:" <> digest)
    end)
  end

  defp apply_environment(files, changes) do
    Enum.reduce(changes, files, fn change, current ->
      upsert_file(current, change["path"], change["content"])
    end)
  end

  defp apply_target(files, task) do
    target_id = task["plan"]["fault_target_step"]
    step = Enum.find(task["plan"]["steps"], &(&1["id"] == target_id))

    if step["expected_job_external_mutation_count"] == 0 do
      files
    else
      case step["operation_kind"] do
        "write" ->
          upsert_file(files, step["arguments"]["path"], step["arguments"]["desired"]["content"])

        "patch" ->
          upsert_file(
            files,
            step["arguments"]["path"],
            step["frozen_declarations"]["postimage_content"]
          )

        "shell" ->
          task["fixture"]["expected_no_fault_files"]
      end
    end
  end

  defp upsert_file(files, path, content) do
    if Enum.any?(files, &(&1["path"] == path)) do
      Enum.map(files, fn
        %{"path" => ^path} = file -> Map.put(file, "content", content)
        file -> file
      end)
    else
      files ++ [%{"path" => path, "mode" => "0644", "content" => content}]
    end
  end

  defp required_alignment(fault, task) when fault in ~w(F1 F2) do
    "zero job-attributed mutations at cut; #{task["workspace_contract"]["environmental_mutations_before_dispatch"]} declared environmental mutations reported separately"
  end

  defp required_alignment("F3", _task),
    do: "exactly one fault-target job mutation; environmental activity cannot substitute"

  defp required_alignment("F4", task) do
    "terminal delivered after task-defined target mutation count #{task["workspace_contract"]["fault_target_job_mutations"]}"
  end

  defp external_attestation(manifest) do
    source = read_json!(@v2_external)
    v2_tasks = Map.new(source["tasks"], &{&1["template_id"], &1})

    by_fault_and_class =
      Map.new(source["fault_comparability"], fn row ->
        {{row["fault_type"], row["operation_class"]}, row}
      end)

    rows =
      Enum.map(manifest["fault_rows"], fn row ->
        template = Map.fetch!(by_fault_and_class, {row["fault_type"], row["operation_class"]})

        template
        |> Map.put("row_id", row["row_id"])
        |> Map.put("task_id", row["task_id"])
        |> Map.put("barrier_id", row["barrier_id"])
      end)

    tasks =
      Enum.map(manifest["adapter_equivalence_fixtures"], fn fixture ->
        template_id = fixture["template_id"]
        v2 = Map.fetch!(v2_tasks, template_id)
        {:ok, mapping} = Elara.Benchmark.ExternalAdapter.mapping(fixture)

        %{
          "fixture_id" => fixture["id"],
          "template_id" => template_id,
          "operation_class" => mapping["operation_kind"],
          "classification" => "equivalent_by_frozen_template_isomorphism",
          "expected_outcome" =>
            get_in(fixture, ["plan", "steps", Access.at(0), "expected_no_fault_outcome"]),
          "initial_workspace_sha256" => fixture["fixture"]["initial_workspace_sha256"],
          "expected_workspace_sha256" => fixture["fixture"]["expected_no_fault_workspace_sha256"],
          "fixture_commit" => fixture["fixture"]["fixture_commit"],
          "mapping" => mapping,
          "evidence" => %{
            "basis" =>
              "v3 changes generated literals and schema identity only; native Lemon tool mapping and no-fault control flow are unchanged",
            "v2_direct_observed_outcome" => v2["observed_outcome"],
            "v2_direct_classification" => v2["classification"],
            "v2_direct_fixture_commit" => v2["fixture_commit"],
            "v2_attestation_path" => @v2_external,
            "v2_attestation_sha256" => file_sha256!(@v2_external)
          }
        }
      end)

    source
    |> Map.put("schema", "elara.exp003.external-adapter-equivalence.v3")
    |> Map.put("preregistration_version", "ER-3/FND-2-v3")
    |> Map.put("manifest_sha256", file_sha256!(@manifest_path))
    |> Map.put("tasks", tasks)
    |> Map.put("fault_comparability", rows)
    |> Map.put("version_adapter", %{
      "source" => "lib/elara/benchmark/external_adapter.ex",
      "sha256" => file_sha256!("lib/elara/benchmark/external_adapter.ex"),
      "direct_execution_evidence_version" => "ER-3/FND-2-v2",
      "v3_evidence_method" => "generated-token-invariant fixture and mapping isomorphism"
    })
    |> Map.put("attestation_materializer", %{
      "source" => "priv/benchmark/materialize_exp003_v3.exs",
      "sha256" => file_sha256!("priv/benchmark/materialize_exp003_v3.exs"),
      "method" => "generated-token-invariant isomorphism to three direct v2 Lemon no-fault runs"
    })
    |> Map.put("exposure", %{
      "B_or_T_calculated" => false,
      "fault_execution" => "forbidden",
      "lemon_fault_rows_executed" => 0,
      "target_fault_rows_executed" => 0,
      "statement" =>
        "V3 reuses the pinned source capability finding; 20 rows remain non-comparable and no comparator or target fault row ran."
    })
    |> Map.put("summary", %{
      "fixture_count" => 3,
      "included_operation_classes" => ~w(write patch shell),
      "no_fault_equivalent" => 3,
      "equivalent_fault_rows" => 0,
      "fault_rows" => 20,
      "required_outcome" => "Insufficient comparability"
    })
  end

  defp beacon_randomness! do
    api = read_json!(Path.join(@root, "beacon/api.drand.sh.json"))
    cloudflare = read_json!(Path.join(@root, "beacon/drand.cloudflare.com.json"))
    true = api == cloudflare
    true = api["round"] == 6_427_122
    api["randomness"]
  end

  defp read_json!(path), do: path |> File.read!() |> JSON.decode!()
  defp write_json!(path, value), do: File.write!(path, Jason.encode!(value, pretty: true) <> "\n")

  defp file_sha256!(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end

Elara.Benchmark.Exp003V3Materializer.run()
