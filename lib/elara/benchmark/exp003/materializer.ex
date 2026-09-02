defmodule Elara.Benchmark.Exp003.Materializer do
  @moduledoc false

  alias Elara.Benchmark.{ExternalAdapter, Fixture, InternalConfirmatory}
  alias Elara.Benchmark.Exp003.CandidateFactory

  @contracts %{
    {"elara.exp003.materialization-protocol.v8-development", "ER-3/FND-2-v8-development",
     "development"} => %{
      beacon_schema: "elara.exp003.verified-beacon.v8-development",
      manifest_schema: "elara.exp003.corpus.v8-development",
      fixture_schema: "elara.exp003.fixture.v8-development",
      plan_schema: "elara.exp003.plan.v8-development",
      dogfood_schema: "elara.exp003.dogfood-plan.v8-development",
      external_schema: "elara.exp003.external-adapter-equivalence.v8-development",
      receipt_schema: "elara.exp003.materialization-receipt.v8-development",
      exposure_split: "development_materialization_fixture",
      confirmatory: false
    },
    {"elara.exp003.materialization-protocol.v8", "ER-3/FND-2-v8", "confirmatory"} => %{
      beacon_schema: "elara.exp003.verified-beacon.v8",
      manifest_schema: "elara.exp003.corpus.v8",
      fixture_schema: "elara.exp003.fixture.v8",
      plan_schema: "elara.exp003.plan.v8",
      dogfood_schema: "elara.exp003.dogfood-plan.v8",
      external_schema: "elara.exp003.external-adapter-equivalence.v8",
      receipt_schema: "elara.exp003.materialization-receipt.v8",
      exposure_split: "held_out_relative_to_target_implementation",
      confirmatory: true
    }
  }
  @eligible_ids ~w(P01 P02 P04 P06 P07 P08 S01 S02 S03 S04 W01 W02 W03 W05 W06 W07 W08)
  @excluded_ids ~w(P03 P05 W04)
  @shell_ids ~w(S01 S02 S03 S04)
  @input_keys ~w(candidate_source command_path_report compatibility dogfood_source external_source)
  @required_source_paths ~w(
    lib/elara/benchmark/elara_adapter.ex
    lib/elara/benchmark/evidence.ex
    lib/elara/benchmark/exp003/candidate_factory.ex
    lib/elara/benchmark/exp003/command.ex
    lib/elara/benchmark/exp003/materializer.ex
    lib/elara/benchmark/external_adapter.ex
    lib/elara/benchmark/fixture.ex
    lib/elara/benchmark/internal_confirmatory.ex
    lib/elara/benchmark/manifest.ex
    lib/elara/benchmark/qualification.ex
    lib/elara/benchmark/runner.ex
    lib/elara/benchmark/scorer.ex
    mix.lock
    priv/benchmark/elara_target_runner.exs
    priv/benchmark/materialize_exp003_v8.exs
    priv/benchmark/preflight_exp003_v8.exs
    priv/benchmark/run_exp003_v8.exs
  )
  @output_paths %{
    "manifest" => "manifest.json",
    "dogfood" => "dogfood-plan.json",
    "external" => "external-adapter-equivalence.json",
    "beacon" => "beacon/verified.json",
    "receipt" => "materialization-receipt.json"
  }

  @spec run(String.t(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def run(repo_root, protocol_path, protocol_sha256, beacon_path, beacon_sha256, output_root) do
    repo_root = Path.expand(repo_root)
    protocol_path = Path.expand(protocol_path)
    beacon_path = Path.expand(beacon_path)
    output_root = Path.expand(output_root)

    try do
      assert_output_state!(output_root)
      {protocol, protocol_bytes} = verified_json!(protocol_path, protocol_sha256, :protocol)
      contract = contract!(protocol)
      validate_protocol!(repo_root, protocol, contract)
      inputs = load_inputs!(repo_root, protocol)
      verify_source_identities!(repo_root, protocol)

      source =
        CandidateFactory.compatible_source!(inputs["candidate_source"], inputs["compatibility"])

      CandidateFactory.validate_blueprints!(source, inputs["compatibility"])

      {beacon, beacon_bytes} = verified_json!(beacon_path, beacon_sha256, :beacon)
      validate_beacon!(protocol, beacon, contract)

      materialization =
        build_materialization(
          protocol,
          inputs,
          beacon,
          beacon_sha256,
          protocol_sha256,
          contract
        )

      write_outputs!(
        output_root,
        materialization,
        beacon_bytes,
        protocol_path,
        protocol_bytes,
        beacon_path,
        beacon_sha256,
        contract
      )
    rescue
      error in [ArgumentError, File.Error, MatchError] ->
        {:error, Exception.message(error)}
    end
  end

  @spec verify_bundle(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def verify_bundle(repo_root, protocol_path, protocol_sha256, receipt_path, receipt_sha256) do
    repo_root = Path.expand(repo_root)
    protocol_path = Path.expand(protocol_path)
    receipt_path = Path.expand(receipt_path)
    bundle_root = Path.dirname(receipt_path)

    verification_root =
      bundle_root <>
        ".verify-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    try do
      {receipt, receipt_bytes} = verified_json!(receipt_path, receipt_sha256, :receipt)
      require!(canonical_json(receipt) == receipt_bytes, :noncanonical_receipt)

      require!(
        Path.basename(receipt_path) == @output_paths["receipt"],
        {:receipt_path, receipt_path}
      )

      beacon_path = Path.join(bundle_root, @output_paths["beacon"])
      beacon_sha256 = get_in(receipt, ["outputs", @output_paths["beacon"]])
      require!(valid_digest?(beacon_sha256), :receipt_beacon_digest)

      case run(
             repo_root,
             protocol_path,
             protocol_sha256,
             beacon_path,
             beacon_sha256,
             verification_root
           ) do
        {:ok, _result} ->
          Enum.each(Map.values(@output_paths), fn relative ->
            expected = File.read!(Path.join(verification_root, relative))
            actual = File.read!(Path.join(bundle_root, relative))
            require!(actual == expected, {:bundle_identity_mismatch, relative})
          end)

          :ok

        {:error, reason} ->
          {:error, {:bundle_rematerialization_failed, reason}}
      end
    rescue
      error in [ArgumentError, File.Error, MatchError] ->
        {:error, Exception.message(error)}
    after
      File.rm_rf(verification_root)
    end
  end

  @spec canonical_json(term()) :: binary()
  def canonical_json(value), do: InternalConfirmatory.canonical_json(value)

  defp build_materialization(
         protocol,
         inputs,
         beacon,
         beacon_sha256,
         protocol_sha256,
         contract
       ) do
    source =
      CandidateFactory.compatible_source!(inputs["candidate_source"], inputs["compatibility"])

    seed = seed(protocol, beacon)

    all_tasks =
      CandidateFactory.construct_all(source, seed,
        fixture_schema: contract.fixture_schema,
        plan_schema: contract.plan_schema,
        fixture_ref: &"manifest.json#task-#{&1}",
        exposure_split: contract.exposure_split
      )
      |> Enum.map(&put_workspace_contract/1)

    profiles = Map.new(inputs["compatibility"]["candidates"], &{&1["id"], &1})
    construction_proofs = validate_all_candidates!(all_tasks, profiles)
    eligible_tasks = Enum.filter(all_tasks, &(&1["id"] in @eligible_ids))
    eligible_ids = eligible_tasks |> Enum.map(& &1["id"]) |> Enum.sort()
    require!(eligible_ids == @eligible_ids, {:eligible_frame, eligible_ids})

    candidates =
      source["candidate_frame"]
      |> Enum.filter(&(&1["id"] in @eligible_ids))

    selected_ids = selected_ids(candidates)
    selected_tasks = Map.new(eligible_tasks, &{&1["id"], &1})
    tasks = Enum.map(selected_ids, &Map.fetch!(selected_tasks, &1))
    secondary_ids = Enum.take(selected_ids, 8)
    rows = rows(source, inputs["compatibility"], tasks, selected_ids, secondary_ids)
    adapters = adapter_fixtures(all_tasks)
    selection = selection(candidates, selected_ids, secondary_ids)

    manifest =
      source
      |> Map.put("schema", contract.manifest_schema)
      |> Map.put("preregistration_version", protocol["preregistration_version"])
      |> Map.put("scope_id", scope_id(contract))
      |> Map.put("beacon", manifest_beacon(protocol, beacon, beacon_sha256))
      |> Map.put("seed", seed_record(protocol, beacon, seed, contract))
      |> Map.put("candidate_frame", candidates)
      |> Map.put("selection", selection)
      |> Map.put("tasks", tasks)
      |> Map.put("fault_rows", rows)
      |> Map.put("adapter_equivalence_fixtures", adapters)
      |> Map.put("compatibility", %{
        "path" => input_path(protocol, "compatibility"),
        "sha256" => input_sha256(protocol, "compatibility"),
        "source_mapping_count" => 20,
        "candidate_count" => 17,
        "validated_assignment_count" => 34,
        "validated_before_selection" => true
      })
      |> Map.put("materializer", %{
        "protocol_sha256" => protocol_sha256,
        "source_identities" => protocol["source_identities"],
        "candidate_source" => protocol["inputs"]["candidate_source"]
      })
      |> Map.put("references", %{
        "roadmap" =>
          "docs/roadmap.md#er3-v8-1--build-and-freeze-an-explicit-pre-beacon-materializer",
        "predecessor_protocol" => "docs/experiments/003-effect-receipt-v7-protocol.json",
        "predecessor_failure" =>
          "docs/experiments/003-effect-receipt-v7-materialization-failure.md"
      })
      |> Map.put(
        "exposure_statement",
        materialization_exposure(contract, "materialization only; no target or comparator run")
      )
      |> Map.put("amendment_policy", %{
        "version" => protocol["preregistration_version"],
        "development_only" => not contract.confirmatory,
        "future_beacon_committed" => contract.confirmatory,
        "post_beacon_change_requires_new_protocol_and_genuinely_future_beacon" => true,
        "missing_or_inconsistent_rows_invalidate_instead_of_shrinking_denominator" => true
      })

    dogfood = dogfood(inputs["dogfood_source"], protocol, beacon, seed, contract)

    external =
      external_attestation(
        inputs["external_source"],
        manifest,
        rows,
        adapters,
        protocol,
        contract
      )

    %{
      manifest: manifest,
      dogfood: dogfood,
      external: external,
      construction_proofs: construction_proofs,
      selected_ids: selected_ids,
      secondary_ids: secondary_ids,
      seed: Base.encode16(seed, case: :lower)
    }
  end

  defp contract!(protocol) do
    key = {protocol["schema"], protocol["preregistration_version"], protocol["mode"]}

    case Map.fetch(@contracts, key) do
      {:ok, contract} ->
        contract

      :error ->
        raise ArgumentError, "materialization rejected: #{inspect({:protocol_contract, key})}"
    end
  end

  defp validate_protocol!(repo_root, protocol, contract) do
    require!(
      get_in(protocol, ["exposure", "future_beacon_committed"]) == contract.confirmatory,
      :future_beacon
    )

    require!(get_in(protocol, ["exposure", "held_out_selection_performed"]) == false, :held_out)
    require!(Enum.sort(Map.keys(protocol["inputs"] || %{})) == @input_keys, :input_frame)
    require!(protocol["outputs"] == @output_paths, :output_paths)

    require!(
      get_in(protocol, ["candidate_frame", "eligible_ids"]) == @eligible_ids,
      :eligible_ids
    )

    require!(
      get_in(protocol, ["candidate_frame", "excluded_ids"]) == @excluded_ids,
      :excluded_ids
    )

    require!(get_in(protocol, ["candidate_frame", "source_count"]) == 20, :source_count)
    require!(get_in(protocol, ["candidate_frame", "eligible_count"]) == 17, :eligible_count)
    require!(get_in(protocol, ["selection", "task_count"]) == 12, :task_count)
    require!(get_in(protocol, ["selection", "row_count"]) == 20, :row_count)

    require!(
      Enum.sort(Map.keys(protocol["source_identities"] || %{})) == @required_source_paths,
      :source_identity_frame
    )

    Enum.each(protocol["inputs"], fn {name, input} ->
      validate_identity!(repo_root, input, {:input, name})
      require!(is_binary(input["schema"]), {:input_schema, name})
    end)

    Enum.each(protocol["source_identities"], fn {path, digest} ->
      validate_relative_path!(repo_root, path, {:source_identity, path})
      require!(valid_digest?(digest), {:source_digest, path})
    end)

    command_report = protocol["inputs"]["command_path_report"]

    require!(
      String.ends_with?(command_report["path"], "-v7-command-path-preflight.json"),
      :report_path
    )

    :ok
  end

  defp load_inputs!(repo_root, protocol) do
    Map.new(protocol["inputs"], fn {name, input} ->
      path = Path.join(repo_root, input["path"])
      {data, _bytes} = verified_json!(path, input["sha256"], {:input, name})
      require!(data["schema"] == input["schema"], {:input_schema_mismatch, name})
      {name, data}
    end)
    |> tap(&validate_inputs!/1)
  end

  defp validate_inputs!(inputs) do
    source = inputs["candidate_source"]
    compatibility = inputs["compatibility"]
    report = inputs["command_path_report"]
    external = inputs["external_source"]

    require!(length(source["candidate_frame"] || []) == 20, :candidate_source_count)
    require!(length(compatibility["candidates"] || []) == 20, :compatibility_count)

    require!(
      get_in(report, ["summary", "eligible_candidate_ids"]) == @eligible_ids,
      :report_frame
    )

    require!(get_in(report, ["summary", "eligible_candidate_count"]) == 17, :report_count)
    require!(get_in(report, ["summary", "total_command_path_run_count"]) == 112, :report_runs)
    require!(get_in(report, ["summary", "all_eligible_fault_runs_valid"]) == true, :report_status)

    require!(
      get_in(external, ["summary", "required_outcome"]) == "Insufficient comparability",
      :external_outcome
    )

    :ok
  end

  defp verify_source_identities!(repo_root, protocol) do
    Enum.each(protocol["source_identities"], fn {path, expected} ->
      actual = repo_root |> Path.join(path) |> File.read!() |> sha256()
      require!(actual == expected, {:source_identity_mismatch, path, expected, actual})
    end)
  end

  defp validate_beacon!(protocol, beacon, contract) do
    expected = protocol["beacon"]
    require!(beacon["schema"] == contract.beacon_schema, {:beacon_schema, beacon["schema"]})
    require!(beacon["mode"] == protocol["mode"], :beacon_mode)
    require!(beacon["confirmatory"] == contract.confirmatory, :confirmatory_beacon)
    require!(beacon["verified"] == true, :beacon_not_verified)
    require!(beacon["verification_method"] == expected["verification_method"], :beacon_method)
    require!(beacon["network"] == expected["network"], :beacon_network)
    require!(beacon["chain_hash"] == expected["chain_hash"], :beacon_chain)
    require!(beacon["round"] == expected["round"], :beacon_round)
    require!(beacon["client"] == expected["client"], :beacon_client)
    require!(valid_digest?(beacon["randomness"]), :beacon_randomness)
    :ok
  end

  defp validate_all_candidates!(tasks, profiles) do
    Enum.map(tasks, fn task ->
      profile = Map.fetch!(profiles, task["id"])
      require!(task["operation_class"] == profile["class"], {:class, task["id"]})
      require!(task["primary_fault"] == profile["primary_fault"], {:primary, task["id"]})
      require!(task["secondary_fault"] == profile["secondary_fault"], {:secondary, task["id"]})
      require!(length(task["plan"]["steps"]) == profile["step_count"], {:steps, task["id"]})

      require!(
        Fixture.fixture_digest(task) == task["fixture"]["fixture_sha256"],
        {:fixture, task["id"]}
      )

      {:ok, mapping} = Elara.Benchmark.ElaraAdapter.mapping(task)
      require!(length(mapping["tool_calls"]) == profile["step_count"], {:mapping, task["id"]})

      %{
        "id" => task["id"],
        "operation_class" => task["operation_class"],
        "fixture_sha256" => task["fixture"]["fixture_sha256"],
        "mapping_sha256" => canonical_json(mapping) |> sha256(),
        "workspace_contract" => task["workspace_contract"],
        "primary_fault" => task["primary_fault"],
        "secondary_fault" => task["secondary_fault"],
        "validated_before_selection" => true
      }
    end)
  end

  defp selected_ids(candidates) do
    typed =
      for operation <- ~w(write patch), fault <- ~w(F1 F2 F3 F4) do
        candidates
        |> Enum.filter(&(&1["operation_class"] == operation and &1["primary_fault"] == fault))
        |> Enum.min_by(& &1["order_key"])
        |> Map.fetch!("id")
      end

    selected =
      (typed ++ @shell_ids)
      |> Enum.sort_by(&candidate!(candidates, &1)["order_key"])

    require!(length(selected) == 12 and Enum.uniq(selected) == selected, :selection_cardinality)
    selected
  end

  defp selection(candidates, selected, secondary) do
    choices =
      for operation <- ~w(write patch), into: %{} do
        by_fault =
          for fault <- ~w(F1 F2 F3 F4), into: %{} do
            id =
              selected
              |> Enum.map(&candidate!(candidates, &1))
              |> Enum.find(&(&1["operation_class"] == operation and &1["primary_fault"] == fault))
              |> Map.fetch!("id")

            {fault, id}
          end

        {operation, by_fault}
      end

    %{
      "algorithm" =>
        "Conditional E=1 frame: lowest SHA-256 order key per primary F1-F4 for write and patch; include S01-S04; sort all 12 by key; add secondary rows for eight lowest-key selected tasks",
      "selected_task_ids" => selected,
      "secondary_row_task_ids" => secondary,
      "candidate_order_keys" => Map.new(candidates, &{&1["id"], &1["order_key"]}),
      "stratum_choices" => Map.put(choices, "shell", @shell_ids),
      "task_count" => 12,
      "scored_row_count" => 20
    }
  end

  defp rows(source, compatibility, tasks, selected, secondary) do
    tasks_by_id = Map.new(tasks, &{&1["id"], &1})
    profiles = Map.new(compatibility["candidates"], &{&1["id"], &1})

    specs =
      Enum.map(selected, &{&1, tasks_by_id[&1]["primary_fault"], "primary"}) ++
        Enum.map(secondary, &{&1, tasks_by_id[&1]["secondary_fault"], "secondary"})

    specs
    |> Enum.with_index(1)
    |> Enum.map(fn {{task_id, fault, role}, index} ->
      task = tasks_by_id[task_id]
      profile = profiles[task_id]
      contract = compatibility["fault_contracts"][fault]

      template =
        Enum.find(source["fault_rows"], fn row ->
          row["fault_type"] == fault and row["operation_class"] == task["operation_class"]
        end) || raise(ArgumentError, "missing row template for #{task_id}/#{fault}")

      target = task["plan"]["fault_target_step"]
      step = Enum.find(task["plan"]["steps"], &(&1["id"] == target))

      call =
        Enum.find(
          task["plan"]["scripted_provider"],
          &(&1["arguments_ref"] == step_ref(task, step))
        )

      convergence =
        get_in(profile, ["workspace_overrides", fault]) || contract["converged_workspace"]

      template
      |> Map.put("row_id", "#{task_id}-#{fault}")
      |> Map.put("order_index", index)
      |> Map.put("task_id", task_id)
      |> Map.put("operation_class", task["operation_class"])
      |> Map.put("fault_role", role)
      |> Map.put(
        "observation_deadline_ms",
        if(task["operation_class"] == "shell", do: 5_000, else: 2_000)
      )
      |> Map.put("fault_target_step", target)
      |> Map.put("fault_target_tool_call_id", call["tool_call_id"])
      |> Map.put(
        "evidence_scope",
        "fault-target durable job only; task totals reported separately"
      )
      |> Map.put("workspace_contract", task["workspace_contract"])
      |> Map.put("expected_converged_workspace_by_condition", convergence)
      |> Map.put(
        "expected_workspace_observation",
        if(task_id == "P06" and fault == "F4",
          do: "fault_target_postcondition",
          else: contract["barrier_workspace"]
        )
      )
      |> Map.put(
        "causal_terminal_evidence_expected_to_survive",
        contract["causal_terminal_evidence_expected_to_survive"]
      )
    end)
  end

  defp adapter_fixtures(tasks) do
    tasks_by_id = Map.new(tasks, &{&1["id"], &1})

    Enum.map(~w(W01 P01 S02), fn id ->
      task = tasks_by_id[id]

      fixture =
        task["fixture"]
        |> Map.put("fixture_ref", "manifest.json#adapter-#{id}")
        |> Map.drop(~w(fixture_sha256 fixture_commit))

      fake = %{"id" => id, "fixture" => fixture, "plan" => task["plan"]}
      digest = Fixture.fixture_digest(fake)

      %{
        "id" => "adapter-#{String.downcase(id)}",
        "template_id" => id,
        "operation_class" => task["operation_class"],
        "exposure_split" => "development_adapter_fixture",
        "scored" => false,
        "fixture" =>
          fixture
          |> Map.put("fixture_sha256", digest)
          |> Map.put("fixture_commit", "sha256:" <> digest),
        "plan" => task["plan"]
      }
    end)
  end

  defp external_attestation(source, manifest, rows, adapters, protocol, contract) do
    by_fault_and_class =
      Map.new(source["fault_comparability"], fn row ->
        {{row["fault_type"], row["operation_class"]}, row}
      end)

    external_rows =
      Enum.map(rows, fn row ->
        template = Map.fetch!(by_fault_and_class, {row["fault_type"], row["operation_class"]})

        template
        |> Map.put("row_id", row["row_id"])
        |> Map.put("task_id", row["task_id"])
        |> Map.put("barrier_id", row["barrier_id"])
      end)

    tasks =
      Enum.map(adapters, fn fixture ->
        {:ok, mapping} = ExternalAdapter.mapping(fixture)

        %{
          "fixture_id" => fixture["id"],
          "template_id" => fixture["template_id"],
          "operation_class" => mapping["operation_kind"],
          "classification" => "equivalent_by_frozen_template_isomorphism",
          "expected_outcome" =>
            get_in(fixture, ["plan", "steps", Access.at(0), "expected_no_fault_outcome"]),
          "initial_workspace_sha256" => fixture["fixture"]["initial_workspace_sha256"],
          "expected_workspace_sha256" => fixture["fixture"]["expected_no_fault_workspace_sha256"],
          "fixture_commit" => fixture["fixture"]["fixture_commit"],
          "mapping" => mapping
        }
      end)

    source
    |> Map.put("schema", contract.external_schema)
    |> Map.put("preregistration_version", protocol["preregistration_version"])
    |> Map.put("manifest_sha256", canonical_json(manifest) |> sha256())
    |> Map.put("tasks", tasks)
    |> Map.put("fault_comparability", external_rows)
    |> Map.put("attestation_materializer", %{
      "source" => "lib/elara/benchmark/exp003/materializer.ex",
      "sha256" => protocol["source_identities"]["lib/elara/benchmark/exp003/materializer.ex"],
      "method" => "explicit token isomorphism; comparator fault execution remains forbidden"
    })
    |> Map.put("exposure", %{
      "B_or_T_calculated" => false,
      "fault_execution" => "forbidden",
      "lemon_fault_rows_executed" => 0,
      "target_fault_rows_executed" => 0,
      "statement" => "V8 materialization only; no comparator or target fault row ran."
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

  defp dogfood(source, protocol, beacon, seed, contract) do
    tasks =
      Enum.map(
        source["tasks"],
        &Map.put(&1, "order_key", CandidateFactory.order_key(seed, &1["id"]))
      )

    order = tasks |> Enum.sort_by(& &1["order_key"]) |> Enum.map(& &1["id"])

    source
    |> Map.put("schema", contract.dogfood_schema)
    |> Map.put("preregistration_version", protocol["preregistration_version"])
    |> Map.put("seed", %{
      "sha256" => Base.encode16(seed, case: :lower),
      "round" => beacon["round"],
      "order_key_formula" => "SHA-256(hex_decode(seed.sha256) || NUL || task_id)"
    })
    |> Map.put("execution_order", order)
    |> Map.put("tasks", tasks)
    |> put_in(["source", "frozen_artifact"], protocol["path"])
    |> put_in(["source", "roadmap_item"], "ER3-V8-1")
    |> Map.put("exposure", %{
      "dogfood_task_runs" => 0,
      "dogfood_fault_runs" => 0,
      "target_fault_results_observed" => 0
    })
  end

  defp put_workspace_contract(task) do
    initial = task["fixture"]["initial_files"]
    pre_effect = apply_environment(initial, task["plan"]["pre_operation_changes"])
    target = apply_target(pre_effect, task)
    complete = task["fixture"]["expected_no_fault_files"]

    Map.put(task, "workspace_contract", %{
      "initial_reset_workspace_sha256" => Fixture.digest_files(initial),
      "pre_effect_workspace_sha256" => Fixture.digest_files(pre_effect),
      "fault_target_postcondition_sha256" => Fixture.digest_files(target),
      "complete_task_workspace_sha256" => Fixture.digest_files(complete),
      "environmental_mutations_before_dispatch" =>
        task["ground_truth"]["expected_no_fault_environmental_mutation_count"],
      "fault_target_job_mutations" =>
        task["ground_truth"]["expected_no_fault_job_external_mutation_count"]
    })
  end

  defp apply_environment(files, changes) do
    Enum.reduce(changes, files, fn change, current ->
      upsert_file(current, change["path"], change["content"])
    end)
  end

  defp apply_target(files, task) do
    step = Enum.find(task["plan"]["steps"], &(&1["id"] == task["plan"]["fault_target_step"]))

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

  defp seed(protocol, beacon) do
    domain = get_in(protocol, ["seed", "domain_separator"])
    commitment = get_in(protocol, ["seed", "commitment"])

    :crypto.hash(
      :sha256,
      domain <>
        beacon["chain_hash"] <>
        ":#{beacon["round"]}:" <> beacon["randomness"] <> ":" <> commitment
    )
  end

  defp seed_record(protocol, beacon, seed, contract) do
    %{
      "derivation" =>
        "SHA-256(domain_separator || chain_hash || ':' || decimal_round || ':' || randomness_hex || ':' || commitment)",
      "domain_separator" => get_in(protocol, ["seed", "domain_separator"]),
      "commitment" => get_in(protocol, ["seed", "commitment"]),
      "round" => beacon["round"],
      "sha256" => Base.encode16(seed, case: :lower),
      "confirmatory" => contract.confirmatory
    }
  end

  defp manifest_beacon(protocol, beacon, beacon_sha256) do
    beacon
    |> Map.put("artifact_sha256", %{"verified.json" => beacon_sha256})
    |> Map.put("round_formula", get_in(protocol, ["beacon", "round_formula"]))
  end

  defp write_outputs!(
         output_root,
         materialization,
         beacon_bytes,
         protocol_path,
         protocol_bytes,
         _beacon_path,
         beacon_sha256,
         contract
       ) do
    manifest_bytes = canonical_json(materialization.manifest)
    dogfood_bytes = canonical_json(materialization.dogfood)
    external_bytes = canonical_json(materialization.external)

    output_sha256 = %{
      "manifest.json" => sha256(manifest_bytes),
      "dogfood-plan.json" => sha256(dogfood_bytes),
      "external-adapter-equivalence.json" => sha256(external_bytes),
      "beacon/verified.json" => sha256(beacon_bytes)
    }

    receipt = %{
      "schema" => contract.receipt_schema,
      "preregistration_version" =>
        if(contract.confirmatory, do: "ER-3/FND-2-v8", else: "ER-3/FND-2-v8-development"),
      "protocol" => %{
        "path" => Path.relative_to_cwd(protocol_path),
        "sha256" => sha256(protocol_bytes)
      },
      "beacon" => %{
        "path" => @output_paths["beacon"],
        "sha256" => beacon_sha256,
        "confirmatory" => contract.confirmatory
      },
      "seed_sha256" => materialization.seed,
      "candidate_construction_count" => length(materialization.construction_proofs),
      "eligible_candidate_count" => length(@eligible_ids),
      "eligible_candidate_ids" => @eligible_ids,
      "candidate_construction_proofs" => materialization.construction_proofs,
      "selected_task_ids" => materialization.selected_ids,
      "secondary_row_task_ids" => materialization.secondary_ids,
      "selected_task_count" => 12,
      "selected_row_count" => 20,
      "outputs" => output_sha256,
      "exposure" =>
        materialization_exposure(
          contract,
          if(contract.confirmatory,
            do: "frozen V8 beacon, selection, and literals only",
            else: "fixed non-confirmatory development entropy only"
          )
        )
    }

    output_bytes =
      Map.merge(output_sha256, %{
        "manifest.json" => manifest_bytes,
        "dogfood-plan.json" => dogfood_bytes,
        "external-adapter-equivalence.json" => external_bytes,
        "beacon/verified.json" => beacon_bytes,
        "materialization-receipt.json" => canonical_json(receipt)
      })

    temp_root = output_root <> ".tmp"
    File.mkdir!(temp_root)

    try do
      Enum.each(output_bytes, fn
        {path, bytes} when is_binary(bytes) ->
          destination = Path.join(temp_root, path)
          File.mkdir_p!(Path.dirname(destination))
          File.write!(destination, bytes, [:exclusive])

        {_path, _digest} ->
          :ok
      end)

      File.rename!(temp_root, output_root)

      {:ok,
       %{
         "output_root" => output_root,
         "manifest_sha256" => output_sha256["manifest.json"],
         "dogfood_sha256" => output_sha256["dogfood-plan.json"],
         "external_sha256" => output_sha256["external-adapter-equivalence.json"],
         "receipt_sha256" => sha256(output_bytes["materialization-receipt.json"]),
         "selected_task_ids" => materialization.selected_ids
       }}
    rescue
      error ->
        File.rm_rf(temp_root)
        reraise error, __STACKTRACE__
    end
  end

  defp assert_output_state!(output_root) do
    parent = Path.dirname(output_root)
    require!(File.dir?(parent), {:missing_output_parent, parent})
    require!(!File.exists?(output_root), {:existing_output, output_root})

    require!(
      !File.exists?(output_root <> ".tmp"),
      {:existing_temporary_output, output_root <> ".tmp"}
    )
  end

  defp verified_json!(path, expected_sha256, label) do
    require!(valid_digest?(expected_sha256), {:invalid_expected_digest, label})
    bytes = File.read!(path)
    actual = sha256(bytes)
    require!(actual == expected_sha256, {:digest_mismatch, label, expected_sha256, actual})

    case JSON.decode(bytes) do
      {:ok, value} when is_map(value) -> {value, bytes}
      _other -> raise ArgumentError, "invalid JSON object: #{inspect(label)}"
    end
  end

  defp validate_identity!(repo_root, identity, label) do
    path = identity["path"]
    validate_relative_path!(repo_root, path, label)
    require!(valid_digest?(identity["sha256"]), {:identity_digest, label})
  end

  defp validate_relative_path!(repo_root, path, label) do
    require!(is_binary(path) and path != "", {:identity_path, label})
    require!(Path.type(path) == :relative, {:absolute_identity_path, label})
    expanded = Path.expand(path, repo_root)
    require!(inside?(expanded, repo_root), {:identity_outside_repository, label})
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp materialization_exposure(contract, statement) do
    %{
      "v8_future_beacon_committed" => contract.confirmatory,
      "v8_future_beacon_fetched" => contract.confirmatory,
      "v8_held_out_selection_performed" => contract.confirmatory,
      "v8_held_out_literals_generated" => contract.confirmatory,
      "v8_target_fault_runs" => 0,
      "v8_target_timing_runs" => 0,
      "v8_external_fault_runs" => 0,
      "v8_dogfood_runs" => 0,
      "v8_B_or_T_calculated" => false,
      "statement" => statement
    }
  end

  defp scope_id(%{confirmatory: true}), do: "EXP-003-v8-confirmatory"
  defp scope_id(%{confirmatory: false}), do: "EXP-003-v8-development-materialization"

  defp input_path(protocol, key), do: get_in(protocol, ["inputs", key, "path"])
  defp input_sha256(protocol, key), do: get_in(protocol, ["inputs", key, "sha256"])

  defp step_ref(task, step) do
    index = Enum.find_index(task["plan"]["steps"], &(&1["id"] == step["id"]))
    "plan.steps[#{index}].arguments"
  end

  defp candidate!(candidates, id), do: Enum.find(candidates, &(&1["id"] == id))
  defp valid_digest?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp require!(true, _reason), do: :ok

  defp require!(false, reason),
    do: raise(ArgumentError, "materialization rejected: #{inspect(reason)}")
end
