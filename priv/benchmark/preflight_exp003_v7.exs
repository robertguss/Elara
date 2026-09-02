Process.put(:elara_exp003_v6_preflight_no_run, true)
Code.require_file("priv/benchmark/preflight_exp003_v6.exs")
Process.delete(:elara_exp003_v6_preflight_no_run)

defmodule Elara.Benchmark.Exp003V7Preflight do
  @moduledoc false

  alias Elara.Benchmark.{ElaraAdapter, Fixture, InternalConfirmatory, Manifest, Runner}

  @root Path.expand("../..", __DIR__)
  @source_manifest "test/fixtures/benchmark/exp003/manifest.json"
  @compatibility_path "docs/experiments/003-effect-receipt-v5-compatibility.json"
  @output_path "docs/experiments/003-effect-receipt-v7-command-path-preflight.json"
  @preflight_domain "elara:exp-003:er3:v7:command-path-preflight:no-beacon\\0"
  @preflight_seed :crypto.hash(:sha256, @preflight_domain)
  @conditions ~w(baseline receipts)
  @expected_ineligible ~w(P03 P05 W04)
  @continuation_policy %{
    "after_target_error" => "halt without continuation",
    "after_target_indeterminate" => "halt without retry or continuation",
    "after_target_ok_live_controller" => "execute continuation exactly once",
    "after_target_ok_recovered_controller" =>
      "do not invent model-loop continuation; report partial task workspace",
    "fault_injection" => "effect only; continuation is never faulted",
    "parallelism" => "forbidden"
  }

  @preserved_artifacts %{
    "docs/experiments/003-effect-receipt-confirmatory-preregistration.md" =>
      "6e63641df815677d3a8498ea5d5e6f3b897144436ede2bae32f5de6bb0369bb9",
    "docs/experiments/003-effect-receipt-confirmatory-preregistration-v2.md" =>
      "3ef325a4cc8c5856dd61fb11b2bb5ddff5e3b304edd4f6ef8f902ea33f21c89f",
    "docs/experiments/003-effect-receipt-confirmatory-preregistration-v3.md" =>
      "a196b651bbe07d28c295528e148e2b9770180ffdfdd4b918f2c28528cf2d2070",
    "docs/experiments/003-effect-receipt-confirmatory-preregistration-v4.md" =>
      "f63c0baf227991126afcf83b2f22d61f42289568d7c6b393ad23dfa859d5d863",
    "docs/experiments/003-effect-receipt-confirmatory-preregistration-v5.md" =>
      "ddaff6f6b1007245df75aaed700ec131428e723c168a812ae8faada9e906c224",
    "docs/experiments/003-effect-receipt-confirmatory-preregistration-v6.md" =>
      "004acab9db1de74fd54dd35c480ceedfe0a72bf467a871aa577c7eb816b1810f",
    "docs/experiments/003-effect-receipt-v5-materialization-failure.md" =>
      "7dc27af1d7acdebd72a241af54961f99ed88d5ed7345b9efd25a99a1d8fe293a",
    "docs/experiments/003-effect-receipt-v6-preflight.json" =>
      "8f69b8d15b2c7bb3ee782c87b778b0b32e536be1a548c207e7cd7664dd8b0216",
    "docs/experiments/003-effect-receipt-v6-compatibility.json" =>
      "ffb997e4d74e229ea615b5461ea7b833a4e1f3606fba9d2c6bd6872b1468b5eb",
    "docs/experiments/003-effect-receipt-v6-execution-failure.md" =>
      "0c776c5b6d27f273042aec3d6eba29b351f132335e90427545eb3344dcac53ae",
    "priv/benchmark/preflight_exp003_v6.exs" =>
      "48f36d9047138546e962ad636f18c8d936b0aa9cea8402ddff18ccdf6bb35121",
    "priv/benchmark/materialize_exp003_v6.exs" =>
      "f919b1b7a82ddf55d705af26dd80cc43fb56c3be4f7b17c9a5c7b5ee7cf178b8",
    "test/fixtures/benchmark/exp003/manifest.json" =>
      "a40fa18d3ea00eee5c6b8963055cff49ca7f94388f42325c793e0460be98a5b7",
    "test/fixtures/benchmark/exp003-v2/manifest.json" =>
      "f5fde3aead3a4ff2aaf9d6aee880d7da2b9a60619523f084cedcaa0943a5d1d9",
    "test/fixtures/benchmark/exp003-v3/manifest.json" =>
      "4129ae964daf35469499dc9506ace9fa89db0c9f00a20826dfc6790edd5b5491",
    "test/fixtures/benchmark/exp003-v4/manifest.json" =>
      "14cc3a57763f0ab48f4b68a70317916d09ff4bee64ba18d150480dd1315820a2",
    "test/fixtures/benchmark/exp003-v4/internal-confirmatory-qualification-failed.checkpoint.json" =>
      "e206f46325c420f5c664a0c185b223896e4a745ab598cc7091350769e5878a41",
    "test/fixtures/benchmark/exp003-v5/beacon/api.drand.sh.json" =>
      "24898a55a44ab5b9146cd6e745db0d0a688ebca8261695180bcc55015dd98a04",
    "test/fixtures/benchmark/exp003-v5/beacon/drand.cloudflare.com.json" =>
      "0ab8759a9caa6dabd507ae39d88bdc955ae935f63c21b8996a6436807ff0a60b",
    "test/fixtures/benchmark/exp003-v5/beacon/verification.json" =>
      "26656c573f96abceb9a3b55eb0e933313b352974e42757ec5c0e5bcb37d2c1d1",
    "test/fixtures/benchmark/exp003-v6/manifest.json" =>
      "b415272e106db54087edbd54500c3544c94ca13b2d42950c0a63b82a38c0973c",
    "test/fixtures/benchmark/exp003-v6/dogfood-plan.json" =>
      "42b92b7f2e5d8fdb99db4a28a631ce239274e10875bedb13dc56e1f5dd50fe9f",
    "test/fixtures/benchmark/exp003-v6/external-adapter-equivalence.json" =>
      "f2ee5d0e52051d7675953bc09cf80674e3c420e6093c7497fe45513ad286561e",
    "test/fixtures/benchmark/exp003-v6/internal-confirmatory-qualification.json" =>
      "8ef12be71c61bded368bca509d9b2d3ea6ef2e2aa44b24a698d641843576ed23",
    "test/fixtures/benchmark/exp003-v6/internal-confirmatory-qualification.checkpoint.json" =>
      "4091b776e865bcd0c29dbcbb68d8eb33bf3b355d9d03f9fb6406d6b0db49ea34",
    "test/fixtures/benchmark/exp003-v6/internal-confirmatory-execution-failed.checkpoint.json" =>
      "9b8dce8dce1a53761e7f842a9648f22e1e75b65cd9c2b3ec5d7865112e72f4bb"
  }

  def run(state_root, workspace_root, output_path \\ @output_path) do
    state_root = Path.expand(state_root)
    workspace_root = Path.expand(workspace_root)
    output_path = Path.expand(output_path)
    assert_absent!(state_root, "state root")
    assert_absent!(workspace_root, "workspace root")
    assert_absent!(output_path, "output")
    verify_preserved_artifacts!()

    {tasks, profiles, source, compatibility} = construct_inputs!()
    rows = build_rows(tasks, profiles, source, compatibility)
    manifest = manifest(tasks, rows, source)
    {:ok, config} = ElaraAdapter.prepare(@root, state_root)

    stage_a = run_stage_a!(manifest, config, workspace_root)
    eligible = eligible_task_ids!(stage_a)
    stage_b = run_stage_b!(manifest, config, workspace_root, eligible, rows)

    report = build_report(tasks, profiles, stage_a, stage_b, eligible, config, source)

    bytes = InternalConfirmatory.canonical_json(report)
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, bytes)

    IO.puts("preflight_sha256=#{sha256(bytes)}")
    IO.puts("no_fault_runs=#{report["summary"]["no_fault_run_count"]}")
    IO.puts("eligible_candidates=#{report["summary"]["eligible_candidate_count"]}")
    IO.puts("fault_runs=#{report["summary"]["fault_run_count"]}")
    :ok
  end

  defp construct_inputs! do
    _v6_construction_report = Elara.Benchmark.Exp003V6Preflight.build_report()
    source = read_json!(@source_manifest)
    compatibility = read_json!(@compatibility_path)
    profiles = Map.new(compatibility["candidates"], &{&1["id"], &1})

    tasks =
      apply(Elara.Benchmark.Exp003V6CandidateFactory, :construct_all, [
        source,
        @preflight_seed
      ])
      |> Enum.map(&prepare_task!/1)
      |> Enum.sort_by(& &1["id"])

    ids = Enum.map(tasks, & &1["id"])
    true = length(tasks) == 20
    true = Enum.uniq(ids) == ids
    true = Enum.sort(Map.keys(profiles)) == ids

    {tasks, profiles, source, compatibility}
  end

  defp prepare_task!(task) do
    plan =
      task["plan"]
      |> Map.put("schema", "elara.exp003.plan.v7-development")
      |> maybe_add_continuation_policy(task["id"])

    task =
      task
      |> Map.put("exposure_split", "development_adapter_fixture")
      |> Map.put("plan", plan)
      |> update_in(["fixture"], fn fixture ->
        fixture
        |> Map.put("schema", "elara.exp003.fixture.v7-development")
        |> Map.put("fixture_ref", "generated:ROB-873/#{task["id"]}")
      end)

    fixture_digest = Fixture.fixture_digest(task)

    task
    |> put_in(["fixture", "fixture_sha256"], fixture_digest)
    |> put_in(["fixture", "fixture_commit"], "sha256:" <> fixture_digest)
    |> Map.put("workspace_contract", workspace_contract(task))
    |> validate_task!()
  end

  defp maybe_add_continuation_policy(plan, "P06"),
    do: Map.put(plan, "continuation_policy", @continuation_policy)

  defp maybe_add_continuation_policy(plan, _task_id), do: Map.delete(plan, "continuation_policy")

  defp validate_task!(task) do
    {:ok, mapping} = ElaraAdapter.mapping(task)
    step_count = length(task["plan"]["steps"])
    true = length(mapping["tool_calls"]) == step_count

    true =
      Enum.map(mapping["tool_calls"], & &1["step_index"]) == Enum.to_list(0..(step_count - 1))

    true =
      Enum.map(mapping["tool_calls"], & &1["step_id"]) ==
        Enum.map(task["plan"]["steps"], & &1["id"])

    call_ids = Enum.map(mapping["tool_calls"], & &1["tool_call_id"])
    true = Enum.uniq(call_ids) == call_ids
    true = Fixture.fixture_digest(task) == task["fixture"]["fixture_sha256"]

    true =
      task["fixture"]["fixture_commit"] == "sha256:" <> task["fixture"]["fixture_sha256"]

    task
  end

  defp build_rows(tasks, profiles, source, compatibility) do
    task_map = Map.new(tasks, &{&1["id"], &1})

    assignments =
      tasks
      |> Enum.flat_map(fn task ->
        profile = Map.fetch!(profiles, task["id"])

        [
          {task, profile["primary_fault"], "primary"},
          {task, profile["secondary_fault"], "secondary"}
        ]
      end)

    probes = [
      {Map.fetch!(task_map, "P06"), "F3", "continuation_probe"},
      {Map.fetch!(task_map, "P06"), "F4", "continuation_probe"}
    ]

    (assignments ++ probes)
    |> Enum.with_index(1)
    |> Enum.map(fn {{task, fault, role}, order_index} ->
      build_row(task, fault, role, order_index, profiles, source, compatibility)
    end)
  end

  defp build_row(task, fault, role, order_index, profiles, source, compatibility) do
    template =
      Enum.find(source["fault_rows"], fn row ->
        row["operation_class"] == task["operation_class"] and row["fault_type"] == fault
      end)

    contract = compatibility["fault_contracts"][fault]
    profile = profiles[task["id"]]

    convergence =
      get_in(profile, ["workspace_overrides", fault]) || contract["converged_workspace"]

    convergence =
      if task["id"] == "P06" and fault == "F4" do
        %{
          "baseline" => "fault_target_postcondition",
          "receipts" => "fault_target_postcondition"
        }
      else
        convergence
      end

    {:ok, mapping} = ElaraAdapter.mapping(task)
    row_id = "QUAL-V7-#{task["id"]}-#{fault}-#{role}"

    template
    |> Map.put("row_id", row_id)
    |> Map.put("order_index", order_index)
    |> Map.put("task_id", task["id"])
    |> Map.put("operation_class", task["operation_class"])
    |> Map.put("fault_type", fault)
    |> Map.put("fault_role", "development_qualification")
    |> Map.put("qualification_role", role)
    |> Map.put("source_row_id", template["row_id"])
    |> Map.put("exposure_split", "development_adapter_fixture")
    |> Map.put("fault_target_step", task["plan"]["fault_target_step"])
    |> Map.put("fault_target_tool_call_id", mapping["fault_target_tool_call_id"])
    |> Map.put("workspace_contract", task["workspace_contract"])
    |> Map.put("expected_converged_workspace_by_condition", convergence)
    |> Map.put(
      "expected_workspace_observation",
      if(task["id"] == "P06" and fault == "F4",
        do: "fault_target_postcondition",
        else: contract["barrier_workspace"]
      )
    )
    |> Map.put(
      "causal_terminal_evidence_expected_to_survive",
      contract["causal_terminal_evidence_expected_to_survive"]
    )
  end

  defp manifest(tasks, rows, source) do
    data = %{
      "schema" => "elara.exp003.command-path-preflight.v7-development",
      "preregistration_version" => "ER-3/FND-2-v7-development",
      "scope_id" => "EXP-003-v7-command-path-development",
      "required_evidence_fields" => source["required_evidence_fields"],
      "seed" => %{"sha256" => Base.encode16(@preflight_seed, case: :lower)},
      "beacon" => %{"round" => 0},
      "tasks" => tasks,
      "fault_rows" => rows
    }

    %Manifest{
      path: "generated:ROB-873",
      sha256: digest(data),
      data: data,
      tasks: Map.new(tasks, &{&1["id"], &1}),
      rows: Map.new(rows, &{&1["row_id"], &1}),
      adapter_fixtures: %{}
    }
  end

  defp run_stage_a!(manifest, config, workspace_root) do
    reference = make_ref()
    parent = self()
    config = %{config | evidence_sink: fn evidence -> send(parent, {reference, evidence}) end}

    runs =
      manifest.tasks
      |> Map.keys()
      |> Enum.sort()
      |> Enum.flat_map(fn task_id ->
        Enum.map(@conditions, &%{"task_id" => task_id, "condition" => &1})
      end)
      |> Enum.with_index(1)

    entries =
      ElaraAdapter.with_config(config, fn ->
        Enum.map(runs, fn {run, order_index} ->
          run =
            Map.merge(run, %{
              "phase" => "measured",
              "run_index" => 1,
              "order_index" => order_index
            })

          {:ok, record} =
            Runner.run_no_fault(manifest, run, adapter: ElaraAdapter, root: workspace_root)

          observation = receive_observation!(reference, run)
          assert_no_observation!(reference, run)
          stage_a_entry(manifest.tasks[run["task_id"]], record, observation)
        end)
      end)

    true = length(entries) == 40
    entries
  end

  defp stage_a_entry(task, record, observation) do
    {:ok, mapping} = ElaraAdapter.mapping(task)
    expected_ids = Enum.map(mapping["tool_calls"], & &1["tool_call_id"])
    expected_step_count = length(expected_ids)

    expected_outcome =
      task["plan"]["steps"] |> List.last() |> Map.fetch!("expected_no_fault_outcome")

    failures =
      []
      |> maybe_failure(record["workspace_correct"], "workspace_mismatch")
      |> maybe_failure(record["outcome_correct"], "outcome_mismatch")
      |> maybe_failure(observation["provider_plan_consumed"], "provider_plan_not_consumed")
      |> maybe_failure(
        observation["provider_call_count"] == expected_step_count + 1,
        "provider_call_count_mismatch"
      )
      |> maybe_failure(
        observation["provider_state"]["disposition"] == "completed",
        "provider_disposition_mismatch"
      )
      |> maybe_failure(
        observation["provider_state"]["remaining_turn_count"] == 0,
        "provider_state_not_empty"
      )
      |> maybe_failure(
        observation["provider_state"]["emitted_tool_call_ids"] == expected_ids,
        "emitted_tool_identity_mismatch"
      )
      |> maybe_failure(
        observation["tool_call_count"] == expected_step_count and
          observation["session_result_count"] == expected_step_count,
        "tool_or_result_cardinality_mismatch"
      )
      |> maybe_failure(
        no_fault_receipts_valid?(record["condition"], observation, expected_ids),
        "receipt_identity_or_cardinality_mismatch"
      )

    %{
      "task_id" => task["id"],
      "condition" => record["condition"],
      "eligible_condition" => failures == [],
      "failures" => Enum.reverse(failures),
      "expected" => %{
        "outcome" => expected_outcome,
        "workspace_sha256" => record["expected_workspace_sha256"],
        "provider_call_count" => expected_step_count + 1,
        "tool_call_ids" => expected_ids
      },
      "observed" => %{
        "outcome" => record["observed_outcome"],
        "workspace_sha256" => record["final_workspace_sha256"],
        "workspace_correct" => record["workspace_correct"],
        "outcome_correct" => record["outcome_correct"],
        "provider_plan_consumed" => observation["provider_plan_consumed"],
        "provider_call_count" => observation["provider_call_count"],
        "provider_state" => observation["provider_state"],
        "tool_call_count" => observation["tool_call_count"],
        "session_result_count" => observation["session_result_count"],
        "session_result" => observation["session_result"],
        "transcript_shape" => observation["transcript_shape"],
        "receipt_evidence" => no_fault_receipt_projection(observation["receipt_evidence"])
      }
    }
  end

  defp no_fault_receipts_valid?("baseline", observation, _expected_ids),
    do: observation["receipt_evidence"] == "not_applicable"

  defp no_fault_receipts_valid?("receipts", observation, expected_ids) do
    evidence = observation["receipt_evidence"]
    count = length(expected_ids)

    evidence["job_count"] == count and evidence["admission_count"] == count and
      evidence["callback_attempt_count"] == count and evidence["terminal_count"] == count and
      evidence["result_persisted"] and evidence["identity_consistent"] and
      Enum.sort(evidence["tool_call_ids"]) == Enum.sort(expected_ids)
  end

  defp no_fault_receipt_projection("not_applicable"), do: "not_applicable"

  defp no_fault_receipt_projection(evidence) do
    %{
      "job_count" => evidence["job_count"],
      "admission_count" => evidence["admission_count"],
      "callback_attempt_count" => evidence["callback_attempt_count"],
      "terminal_count" => evidence["terminal_count"],
      "result_persisted" => evidence["result_persisted"],
      "identity_consistent" => evidence["identity_consistent"],
      "job_id_format_valid" => evidence["job_id_format_valid"],
      "operation_digest_format_valid" => evidence["operation_digest_format_valid"],
      "tool_call_ids" => Enum.sort(evidence["tool_call_ids"]),
      "jobs" =>
        evidence["jobs"]
        |> Enum.map(
          &Map.take(
            &1,
            ~w(tool_call_id state result_kind admission_count callback_attempt_count terminal_count result_persisted identity_consistent)
          )
        )
        |> Enum.sort_by(& &1["tool_call_id"])
    }
  end

  defp eligible_task_ids!(entries) do
    grouped = Enum.group_by(entries, & &1["task_id"])

    eligible =
      grouped
      |> Enum.filter(fn {_task_id, conditions} ->
        length(conditions) == 2 and Enum.all?(conditions, & &1["eligible_condition"])
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    ineligible = Enum.sort(Map.keys(grouped) -- eligible)
    true = length(eligible) == 17
    true = ineligible == @expected_ineligible
    eligible
  end

  defp run_stage_b!(manifest, config, workspace_root, eligible, rows) do
    eligible_set = MapSet.new(eligible)

    selected_rows =
      Enum.filter(rows, fn row ->
        MapSet.member?(eligible_set, row["task_id"]) and
          (row["qualification_role"] in ~w(primary secondary) or row["task_id"] == "P06")
      end)

    true = Enum.count(selected_rows, &(&1["qualification_role"] in ~w(primary secondary))) == 34
    true = Enum.count(selected_rows, &(&1["qualification_role"] == "continuation_probe")) == 2

    runs =
      selected_rows
      |> Enum.flat_map(fn row ->
        Enum.map(@conditions, &%{"row_id" => row["row_id"], "condition" => &1})
      end)
      |> Enum.with_index(1)

    adapter_digest = file_sha256!("lib/elara/benchmark/elara_adapter.ex")
    reference = make_ref()
    parent = self()
    config = %{config | evidence_sink: fn evidence -> send(parent, {reference, evidence}) end}

    entries =
      ElaraAdapter.with_config(config, fn ->
        Enum.map(runs, fn {run, order_index} ->
          run = Map.merge(run, %{"run_index" => 1, "order_index" => order_index})

          opts = [
            adapter: ElaraAdapter,
            root: workspace_root,
            target_commit: ElaraAdapter.target_commits()[run["condition"]],
            adapter_digest: adapter_digest
          ]

          {:ok, record} = Runner.run_fault(manifest, run, opts)
          _observation = receive_observation!(reference, run)
          assert_no_observation!(reference, run)
          row = manifest.rows[run["row_id"]]
          validate_fault_record!(manifest.tasks[row["task_id"]], row, record)
          fault_projection(row, record)
        end)
      end)

    true = length(entries) == 72
    entries
  end

  defp validate_fault_record!(task, row, record) do
    expected_workspace = row["expected_converged_workspace_by_condition"][record["condition"]]
    expected_mutations = expected_external_mutations(task, row, record["condition"])
    receipts? = record["condition"] == "receipts"

    expected_task_jobs =
      if(receipts? and task["id"] == "P06" and row["fault_type"] == "F2",
        do: 2,
        else: if(receipts?, do: 1, else: 0)
      )

    true = record["initial_reset_verified"]
    true = record["harness_errors"] == []
    true = record["safety_disqualifiers"] == []

    true =
      record["primary_recovery_class"] ==
        row["expected_primary_recovery_class"][record["condition"]]

    true = record["safe_next_action_observed"] == row["expected_safe_action"][record["condition"]]
    true = record["workspace_observations"] == expected_workspace
    true = expected_workspace in record["workspace_digest_aliases"]
    false = record["workspace_digest_proves_causal_completion"]
    true = record["external_mutation_count"] == expected_mutations
    true = record["callback_attempt_count"] <= 1
    true = record["barrier_call_count"] == 1
    true = record["injection_count"] == 1
    true = get_in(record, ["barrier_facts", "fault_target_identity_matches"])

    true =
      record["knowledge_convergence_ms"] <= row["knowledge_and_safe_action_convergence_bound_ms"]

    if receipts? do
      true = record["controller_facts"]["target_match_count"] == 1
      true = record["executor_facts"]["target_match_count"] == 1
      true = record["controller_facts"]["job_count"] == expected_task_jobs
      true = record["executor_facts"]["task_job_count"] == expected_task_jobs
      true = record["executor_facts"]["admission_count"] == 1
      true = record["executor_facts"]["callback_attempt_count"] == 1
      true = record["executor_facts"]["terminal_count"] in [0, 1]
    else
      true = record["controller_facts"]["job_count"] == 0
      true = record["admission_count"] == 0
    end

    validate_p06_fault_transition!(task, row, record)
  end

  defp validate_p06_fault_transition!(%{"id" => id}, _row, _record) when id != "P06", do: :ok

  defp validate_p06_fault_transition!(_task, row, record) do
    condition = record["condition"]
    fault = row["fault_type"]
    state = record["provider_state"]

    expected =
      case {fault, condition} do
        {"F2", "receipts"} ->
          {3, "completed", ~w(exp003-p06 exp003-p06-continuation), [], [], 0}

        {fault, _condition} when fault in ~w(F1 F4) ->
          {1, "active", ~w(exp003-p06), [], ~w(exp003-p06-continuation), 2}

        {fault, _condition} when fault in ~w(F2 F3) ->
          {2, "skipped_non_ok", ~w(exp003-p06), ~w(exp003-p06-continuation), [], 0}
      end

    {calls, disposition, emitted, skipped, remaining_ids, remaining_turns} = expected
    true = state["call_count"] == calls
    true = state["disposition"] == disposition
    true = state["emitted_tool_call_ids"] == emitted
    true = state["skipped_tool_call_ids"] == skipped
    true = state["remaining_tool_call_ids"] == remaining_ids
    true = state["remaining_turn_count"] == remaining_turns

    if fault == "F2" and condition == "receipts" do
      true = record["task_tool_call_count"] == 2
      true = record["executor_facts"]["task_job_count"] == 2
      true = record["executor_facts"]["task_admission_count"] == 2
      true = record["executor_facts"]["task_callback_attempt_count"] == 2
      true = record["executor_facts"]["task_terminal_count"] == 2
      true = record["barrier_call_count"] == 1
      true = record["injection_count"] == 1
    else
      true = record["task_tool_call_count"] == 1
      if condition == "receipts", do: true = record["executor_facts"]["task_job_count"] == 1
    end

    :ok
  end

  defp expected_external_mutations(task, row, condition) do
    target = Enum.find(task["plan"]["steps"], &(&1["id"] == row["fault_target_step"]))
    count = target["expected_job_external_mutation_count"]
    if condition == "baseline" and row["fault_type"] in ~w(F1 F2), do: 0, else: count
  end

  defp fault_projection(row, record) do
    executor = record["executor_facts"]
    controller = record["controller_facts"]

    %{
      "row_id" => row["row_id"],
      "task_id" => row["task_id"],
      "fault_type" => row["fault_type"],
      "qualification_role" => row["qualification_role"],
      "condition" => record["condition"],
      "expected_primary_recovery_class" =>
        row["expected_primary_recovery_class"][record["condition"]],
      "primary_recovery_class" => record["primary_recovery_class"],
      "expected_safe_action" => row["expected_safe_action"][record["condition"]],
      "safe_next_action_observed" => record["safe_next_action_observed"],
      "workspace_observation" => record["workspace_observations"],
      "workspace_digest_aliases" => record["workspace_digest_aliases"],
      "workspace_digest_proves_causal_completion" => false,
      "callback_attempt_count" => record["callback_attempt_count"],
      "external_mutation_count" => record["external_mutation_count"],
      "target_session_result_count" => record["session_result_count"],
      "task_session_result_count" => record["task_session_result_count"],
      "target_tool_call_count" => record["tool_call_count"],
      "task_tool_call_count" => record["task_tool_call_count"],
      "causal_terminal_evidence_expected" => record["causal_terminal_evidence_expected"],
      "causal_terminal_evidence_observed" => record["causal_terminal_evidence_observed"],
      "session_classification" => record["session_classification"],
      "provider_state" => record["provider_state"],
      "barrier" => %{
        "source" => record["barrier_facts"]["source"],
        "point" => record["barrier_source_point"],
        "tool_call_id" => record["barrier_facts"]["tool_call_id"],
        "expected_tool_call_id" => record["barrier_facts"]["expected_fault_target_tool_call_id"],
        "identity_matches" => record["barrier_facts"]["fault_target_identity_matches"],
        "barrier_count" => record["barrier_call_count"],
        "injection_count" => record["injection_count"]
      },
      "controller" => %{
        "status" => controller["status"],
        "job_count" => controller["job_count"],
        "target_match_count" => controller["target_match_count"] || 0,
        "tool_call_id" => controller["tool_call_id"],
        "result_persisted" => controller["result_persisted"],
        "task_tool_call_ids" => Enum.sort(controller["task_tool_call_ids"] || [])
      },
      "executor" => %{
        "status" => executor["status"],
        "target_match_count" => executor["target_match_count"] || 0,
        "admission_count" => executor["admission_count"],
        "callback_attempt_count" => executor["callback_attempt_count"],
        "terminal_count" => executor["terminal_count"],
        "result_kind" => executor["result_kind"],
        "task_job_count" => executor["task_job_count"] || 0,
        "task_admission_count" => executor["task_admission_count"] || 0,
        "task_callback_attempt_count" => executor["task_callback_attempt_count"] || 0,
        "task_terminal_count" => executor["task_terminal_count"] || 0,
        "task_tool_call_ids" => Enum.sort(executor["task_tool_call_ids"] || [])
      },
      "hooks_observed" => record["hooks_observed"],
      "convergence_bound_ms" => row["knowledge_and_safe_action_convergence_bound_ms"],
      "convergence_within_bound" =>
        record["knowledge_convergence_ms"] <=
          row["knowledge_and_safe_action_convergence_bound_ms"],
      "harness_errors" => record["harness_errors"],
      "safety_disqualifiers" => record["safety_disqualifiers"]
    }
  end

  defp build_report(tasks, profiles, stage_a, stage_b, eligible, config, source) do
    ineligible = Enum.sort(Map.keys(profiles) -- eligible)
    assignment_runs = Enum.filter(stage_b, &(&1["qualification_role"] in ~w(primary secondary)))
    probe_runs = Enum.filter(stage_b, &(&1["qualification_role"] == "continuation_probe"))
    mapping_proofs = Enum.map(tasks, &mapping_proof!/1)
    stage_a_records = compact_stage_a(stage_a)
    assignment_records = compact_stage_b(assignment_runs)
    probe_records = compact_stage_b(probe_runs)

    %{
      "schema" => "elara.exp003.command-path-preflight.v7",
      "linear_issue" => "ROB-873",
      "purpose" => "development-only exact-command-path proof before any V7 beacon commitment",
      "command" =>
        "mix run priv/benchmark/preflight_exp003_v7.exs -- <absent-state-root> <absent-workspace-root> <absent-output.json>",
      "development_entropy" => %{
        "beacon_derived" => false,
        "domain" => @preflight_domain,
        "sha256" => Base.encode16(@preflight_seed, case: :lower)
      },
      "inputs" => %{
        "candidate_source" => @source_manifest,
        "candidate_source_sha256" => file_sha256!(@source_manifest),
        "compatibility" => @compatibility_path,
        "compatibility_sha256" => file_sha256!(@compatibility_path),
        "adapter_source" => "lib/elara/benchmark/elara_adapter.ex",
        "adapter_sha256" => file_sha256!("lib/elara/benchmark/elara_adapter.ex"),
        "target_runner_source" => "priv/benchmark/elara_target_runner.exs",
        "target_runner_sha256" => file_sha256!("priv/benchmark/elara_target_runner.exs"),
        "neutral_runner_source" => "lib/elara/benchmark/runner.ex",
        "neutral_runner_sha256" => file_sha256!("lib/elara/benchmark/runner.ex"),
        "preflight_source" => "priv/benchmark/preflight_exp003_v7.exs",
        "preflight_source_sha256" => file_sha256!("priv/benchmark/preflight_exp003_v7.exs"),
        "source_required_evidence_field_count" => length(source["required_evidence_fields"])
      },
      "targets" =>
        Map.new(config.targets, fn {condition, target} ->
          {condition, %{"commit" => target.commit}}
        end),
      "summary" => %{
        "candidate_count" => length(tasks),
        "mapping_proof_count" => length(mapping_proofs),
        "no_fault_run_count" => length(stage_a),
        "eligible_candidate_count" => length(eligible),
        "eligible_candidate_ids" => eligible,
        "ineligible_candidate_count" => length(ineligible),
        "ineligible_candidate_ids" => ineligible,
        "assignment_count" => div(length(assignment_runs), 2),
        "assignment_fault_run_count" => length(assignment_runs),
        "continuation_probe_count" => div(length(probe_runs), 2),
        "continuation_probe_run_count" => length(probe_runs),
        "fault_run_count" => length(stage_b),
        "total_command_path_run_count" => length(stage_a) + length(stage_b),
        "all_eligible_fault_runs_valid" =>
          Enum.all?(stage_b, &(&1["harness_errors"] == [] and &1["safety_disqualifiers"] == [])),
        "byte_determinism_required" => true
      },
      "mapping_proofs" => mapping_proofs,
      "stage_a_no_fault_eligibility" => %{
        "rule" =>
          "Both pinned conditions must match frozen outcome/workspace and complete provider, identity, and cardinality contracts; no adapter-owned semantic shim.",
        "records" => stage_a_records,
        "semantic_matrix_sha256" => digest(stage_a),
        "exact_ineligible_set_reproduced" => ineligible == @expected_ineligible
      },
      "stage_b_fault_command_path" => %{
        "assignment_records" => assignment_records,
        "p06_continuation_probe_records" => probe_records,
        "semantic_matrix_sha256" => digest(stage_b)
      },
      "p06_transition_proof" => p06_transition_proof(stage_a, stage_b),
      "s04_alias_proof" => s04_alias_proof(stage_b),
      "future_sampling_frame_constraints" => %{
        "estimand" => "conditional on the frozen 17-candidate E=1 command-path frame",
        "forbidden_inference" =>
          "No inference to the original 20 candidates or excluded idempotent/conflict semantics.",
        "sampling" =>
          "ROB-874 must freeze a new deterministic beacon/stratified rule over exactly these 17 IDs, with quotas and inclusion probabilities; never skip-and-redraw from the old frame.",
        "post_freeze_failure" =>
          "Any later candidate failure invalidates the execution; it never shrinks the denominator or substitutes a candidate.",
        "invalidation" =>
          "Inclusion or replacement based on beacon order, fault, timing, comparator, dogfood, or B/T evidence invalidates the approach."
      },
      "preserved_artifact_sha256" => @preserved_artifacts,
      "exposure" => %{
        "v7_future_beacon_committed" => false,
        "v7_future_beacon_fetched" => false,
        "v7_beacon_candidate_selection_performed" => false,
        "v7_held_out_task_literals_generated" => false,
        "v7_held_out_target_fault_rows" => 0,
        "v7_target_timing_runs" => 0,
        "v7_comparator_runs" => 0,
        "v7_dogfood_runs" => 0,
        "v7_B_or_T_calculated" => false,
        "development_no_fault_runs" => length(stage_a),
        "development_fault_runs" => length(stage_b)
      },
      "limitations" => [
        "This is development command-path qualification, not confirmatory evidence.",
        "P03, P05, and W04 are excluded by the fixed two-condition no-fault rule because unchanged pinned builtins cannot express their frozen idempotent/conflict semantics.",
        "Workspace digest aliases prove current postconditions, never causal job completion.",
        "Baseline fault barriers remain nearest-existing instrumented seams and N/A/non-equivalent to receipt-native durable seams.",
        "V6 remains an immutable invalid execution and was not retried, resumed, repaired, or rescored."
      ]
    }
  end

  defp compact_stage_a(entries) do
    entries
    |> Enum.group_by(& &1["task_id"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {task_id, conditions} ->
      by_condition = Map.new(conditions, &{&1["condition"], &1})
      eligible = Enum.all?(conditions, & &1["eligible_condition"])

      record = %{
        "task_id" => task_id,
        "eligible" => eligible,
        "condition_semantic_sha256" => Map.new(@conditions, &{&1, digest(by_condition[&1])})
      }

      if eligible do
        record
      else
        Map.put(
          record,
          "failure_evidence",
          Map.new(@conditions, fn condition ->
            entry = by_condition[condition]

            {condition,
             %{
               "failures" => entry["failures"],
               "expected_outcome" => entry["expected"]["outcome"],
               "expected_workspace_sha256" => entry["expected"]["workspace_sha256"],
               "observed" =>
                 Map.take(
                   entry["observed"],
                   ~w(outcome workspace_sha256 workspace_correct outcome_correct provider_plan_consumed provider_call_count tool_call_count session_result_count session_result)
                 )
             }}
          end)
        )
      end
    end)
  end

  defp compact_stage_b(entries) do
    entries
    |> Enum.group_by(& &1["row_id"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {row_id, conditions} ->
      first = hd(conditions)

      %{
        "row_id" => row_id,
        "task_id" => first["task_id"],
        "fault_type" => first["fault_type"],
        "qualification_role" => first["qualification_role"],
        "conditions" =>
          Map.new(conditions, fn entry ->
            {entry["condition"],
             %{
               "valid" =>
                 entry["harness_errors"] == [] and entry["safety_disqualifiers"] == [] and
                   entry["convergence_within_bound"],
               "semantic_projection_sha256" => digest(entry)
             }}
          end)
      }
    end)
  end

  defp mapping_proof!(task) do
    {:ok, mapping} = ElaraAdapter.mapping(task)
    calls = task["plan"]["scripted_provider"] |> Enum.filter(&(&1["kind"] == "tool_call"))

    steps =
      mapping["tool_calls"]
      |> Enum.zip(calls)
      |> Enum.map(fn {mapped, source} ->
        %{
          "step_index" => mapped["step_index"],
          "step_id" => mapped["step_id"],
          "tool_call_id" => mapped["tool_call_id"],
          "arguments_ref" => source["arguments_ref"],
          "arguments_sha256" => digest(mapped["tool_arguments"])
        }
      end)

    proof = %{
      "task_id" => task["id"],
      "step_count" => length(steps),
      "unique_tool_call_ids" =>
        steps |> Enum.map(& &1["tool_call_id"]) |> Enum.uniq() |> length() == length(steps),
      "step_indices_bijective" =>
        Enum.map(steps, & &1["step_index"]) == Enum.to_list(0..(length(steps) - 1)),
      "arguments_refs_bijective" =>
        Enum.map(steps, & &1["arguments_ref"]) ==
          Enum.map(0..(length(steps) - 1), &"plan.steps[#{&1}].arguments"),
      "fault_target_step" => mapping["fault_target_step"],
      "fault_target_tool_call_id" => mapping["fault_target_tool_call_id"],
      "mapping_semantic_sha256" => digest(%{"mapping" => mapping, "source_calls" => calls})
    }

    if task["id"] == "P06" do
      Map.merge(proof, %{
        "steps" => steps,
        "final_assistant_text" => mapping["final_assistant_text"],
        "non_ok_halt_assistant_text" => mapping["non_ok_halt_assistant_text"],
        "continuation_policy" => mapping["continuation_policy"]
      })
    else
      proof
    end
  end

  defp p06_transition_proof(stage_a, stage_b) do
    no_fault = Enum.filter(stage_a, &(&1["task_id"] == "P06"))
    faults = Enum.filter(stage_b, &(&1["task_id"] == "P06"))

    %{
      "no_fault" =>
        Enum.map(no_fault, fn entry ->
          %{
            "condition" => entry["condition"],
            "provider_state" => entry["observed"]["provider_state"],
            "receipt_evidence" => entry["observed"]["receipt_evidence"]
          }
        end),
      "faults" =>
        Enum.map(faults, fn entry ->
          %{
            "fault_type" => entry["fault_type"],
            "condition" => entry["condition"],
            "provider_state" => entry["provider_state"],
            "target_tool_call_count" => entry["target_tool_call_count"],
            "task_tool_call_count" => entry["task_tool_call_count"],
            "target_session_result_count" => entry["target_session_result_count"],
            "task_session_result_count" => entry["task_session_result_count"],
            "controller_job_count" => entry["controller"]["job_count"],
            "executor_task_job_count" => entry["executor"]["task_job_count"],
            "barrier_count" => entry["barrier"]["barrier_count"],
            "injection_count" => entry["barrier"]["injection_count"],
            "barrier_identity_matches" => entry["barrier"]["identity_matches"],
            "hook_observation_count" => length(entry["hooks_observed"]),
            "workspace_observation" => entry["workspace_observation"],
            "session_classification" => entry["session_classification"]
          }
        end),
      "halt_assistant_text" => "Task halted after non-ok target result.",
      "fault_target_tool_call_id" => "exp003-p06",
      "continuation_tool_call_id" => "exp003-p06-continuation"
    }
  end

  defp s04_alias_proof(stage_b) do
    entry =
      Enum.find(stage_b, fn entry ->
        entry["task_id"] == "S04" and entry["fault_type"] == "F2" and
          entry["condition"] == "receipts"
      end)

    Map.take(
      entry,
      ~w(row_id condition workspace_observation workspace_digest_aliases workspace_digest_proves_causal_completion callback_attempt_count external_mutation_count primary_recovery_class controller executor barrier)
    )
  end

  defp workspace_contract(task) do
    initial = task["fixture"]["initial_files"]
    pre_effect = apply_environment(initial, task["plan"]["pre_operation_changes"])
    target_step = target_step!(task)

    target =
      if target_step["expected_job_external_mutation_count"] == 0 do
        pre_effect
      else
        apply_successful_step(pre_effect, target_step, task)
      end

    %{
      "environmental_mutations_before_dispatch" => length(task["plan"]["pre_operation_changes"]),
      "fault_target_job_mutations" => target_step["expected_job_external_mutation_count"],
      "initial_reset_workspace_sha256" => Fixture.digest_files(initial),
      "pre_effect_workspace_sha256" => Fixture.digest_files(pre_effect),
      "fault_target_postcondition_sha256" => Fixture.digest_files(target),
      "complete_task_workspace_sha256" =>
        Fixture.digest_files(task["fixture"]["expected_no_fault_files"])
    }
  end

  defp apply_successful_step(files, %{"operation_kind" => "write"} = step, _task) do
    args = step["arguments"]
    upsert_file(files, args["path"], args["desired"]["content"])
  end

  defp apply_successful_step(files, %{"operation_kind" => "patch"} = step, _task) do
    args = step["arguments"]
    before = file_content!(files, args["path"])
    after_content = String.replace(before, args["old_text"], args["new_text"], global: false)
    upsert_file(files, args["path"], after_content)
  end

  defp apply_successful_step(_files, %{"operation_kind" => "shell"}, task),
    do: task["fixture"]["expected_no_fault_files"]

  defp apply_environment(files, changes) do
    Enum.reduce(changes, files, fn change, current ->
      upsert_file(current, change["path"], change["content"])
    end)
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

  defp file_content!(files, path),
    do: Enum.find_value(files, &(&1["path"] == path && &1["content"]))

  defp target_step!(task) do
    target = task["plan"]["fault_target_step"]
    Enum.find(task["plan"]["steps"], &(&1["id"] == target))
  end

  defp receive_observation!(reference, run) do
    receive do
      {^reference, observation} -> observation
    after
      1_000 -> raise "adapter observation missing for #{inspect(run)}"
    end
  end

  defp assert_no_observation!(reference, run) do
    receive do
      {^reference, observation} ->
        raise "duplicate adapter observation for #{inspect(run)}: #{inspect(observation)}"
    after
      0 -> :ok
    end
  end

  defp maybe_failure(failures, true, _failure), do: failures
  defp maybe_failure(failures, false, failure), do: [failure | failures]

  defp verify_preserved_artifacts! do
    Enum.each(@preserved_artifacts, fn {path, expected} ->
      actual = file_sha256!(path)
      if actual != expected, do: raise("preserved artifact changed: #{path}: #{actual}")
    end)
  end

  defp assert_absent!(path, label) do
    if File.exists?(path), do: raise("#{label} must be absent: #{path}")
  end

  defp read_json!(path), do: path |> root_path() |> File.read!() |> JSON.decode!()
  defp file_sha256!(path), do: path |> root_path() |> File.read!() |> sha256()
  defp root_path(path), do: Path.join(@root, path)
  defp digest(value), do: value |> InternalConfirmatory.canonical_json() |> sha256()
  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end

unless Process.get(:elara_exp003_v7_preflight_no_run) do
  args =
    case System.argv() do
      ["--" | rest] -> rest
      rest -> rest
    end

  case args do
    [state_root, workspace_root, output_path] ->
      Elara.Benchmark.Exp003V7Preflight.run(state_root, workspace_root, output_path)

    [state_root, workspace_root] ->
      Elara.Benchmark.Exp003V7Preflight.run(state_root, workspace_root)

    _args ->
      raise "usage: mix run priv/benchmark/preflight_exp003_v7.exs -- <absent-state-root> <absent-workspace-root> [absent-output.json]"
  end
end
