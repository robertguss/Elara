defmodule Elara.Benchmark.Dogfood.Report do
  @moduledoc false

  alias Elara.Benchmark.Dogfood.{Plan, Redactor}

  @schema "elara.exp003.dogfood-report.v1"
  @dispositions ~w(completed failed conflict not_started indeterminate)

  @spec validate(Plan.t(), map()) :: :ok | {:error, [term()]}
  def validate(%Plan{} = plan, report) when is_map(report) do
    secret_paths = Redactor.secret_paths(report)

    errors =
      []
      |> require(report["schema"] == @schema, {:schema, report["schema"]})
      |> require(report["plan_sha256"] == plan.sha256, :plan_digest_mismatch)
      |> require(
        report["target_commit"] == plan.data["target"]["commit"],
        :target_commit_mismatch
      )
      |> require(secret_paths == [], {:unredacted_secret_paths, secret_paths})
      |> require(is_list(report["safety_disqualifiers"]), :invalid_safety_disqualifiers)
      |> require(is_list(report["harness_errors"]), :invalid_harness_errors)
      |> validate_mode(plan, report)

    case Enum.reverse(errors) do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  rescue
    error -> {:error, [{:malformed_report, Exception.message(error)}]}
  end

  @spec safety_blocked(Plan.t(), [String.t()], String.t()) :: map()
  def safety_blocked(%Plan{} = plan, disqualifiers, source)
      when is_list(disqualifiers) and disqualifiers != [] and is_binary(source) do
    %{
      "schema" => @schema,
      "mode" => "safety_blocked",
      "status" => "not_executed",
      "plan_sha256" => plan.sha256,
      "target_commit" => plan.data["target"]["commit"],
      "blocked_by" => source,
      "task_results" => [],
      "safety_disqualifiers" => disqualifiers,
      "harness_errors" => [],
      "exposure" => %{"dogfood_task_runs" => 0, "dogfood_fault_runs" => 0}
    }
  end

  defp validate_mode(errors, plan, %{"mode" => "inert_pilot"} = report) do
    pilot = report["pilot"] || %{}

    errors
    |> require(report["status"] == "passed", :pilot_not_passed)
    |> require(report["task_results"] == [], :pilot_contains_task_results)
    |> require(pilot["real_task_runs"] == 0, :pilot_ran_real_task)
    |> require(pilot["fault_runs"] == 0, :pilot_ran_fault)
    |> require(
      Enum.all?(
        ~w(disposable_clone detached_parent_verified push_blocked shared_source_read_only shared_source_unchanged cleanup_complete),
        &(pilot[&1] == true)
      ),
      :pilot_isolation_incomplete
    )
    |> require(pilot["git_object_sharing"] == false, :pilot_shared_git_objects)
    |> require(pilot["remotes_present"] == false, :pilot_remote_present)
    |> require(
      pilot["credential_values_in_environment"] == false,
      :pilot_credential_value_exposed
    )
    |> require(nonnegative_integer?(pilot["cleanup_ms"]), :invalid_cleanup_time)
    |> require(valid_digest?(pilot["process_output_sha256"]), :invalid_pilot_output_digest)
    |> require(plan.data["pilot"]["real_task_runs"] == 0, :plan_pilot_drift)
  end

  defp validate_mode(errors, _plan, %{"mode" => "safety_blocked"} = report) do
    errors
    |> require(report["status"] == "not_executed", :blocked_report_status)
    |> require(
      is_binary(report["blocked_by"]) and report["blocked_by"] != "",
      :missing_block_source
    )
    |> require(report["task_results"] == [], :blocked_report_contains_results)
    |> require(report["safety_disqualifiers"] != [], :blocked_report_without_disqualifier)
    |> require(get_in(report, ["exposure", "dogfood_task_runs"]) == 0, :blocked_task_exposure)
    |> require(get_in(report, ["exposure", "dogfood_fault_runs"]) == 0, :blocked_fault_exposure)
  end

  defp validate_mode(errors, plan, %{"mode" => "execution"} = report) do
    results = report["task_results"]
    expected_ids = Enum.map(Plan.execution_tasks(plan), & &1["id"])

    errors =
      errors
      |> require(report["status"] in ~w(completed failed), :invalid_execution_status)
      |> require(is_list(results), :task_results_not_a_list)
      |> require(
        is_list(results) and Enum.map(results, & &1["task_id"]) == expected_ids,
        :task_result_order_mismatch
      )

    if is_list(results) do
      Enum.reduce(results, errors, fn result, reasons ->
        validate_task_result(reasons, plan, result)
      end)
    else
      errors
    end
  end

  defp validate_mode(errors, _plan, report), do: [{:invalid_mode, report["mode"]} | errors]

  defp validate_task_result(errors, plan, result) do
    id = result["task_id"]
    task = plan.tasks[id] || %{}
    required = plan.data["report_contract"]["required_task_fields"]
    missing = Enum.reject(required, &Map.has_key?(result, &1))
    injected? = task["assignment"] != "no_fault_control"

    errors
    |> require(missing == [], {:missing_task_fields, id, missing})
    |> require(result["disposition"] in @dispositions, {:invalid_disposition, id})
    |> require(nonnegative_integer?(result["model_call_count"]), {:invalid_model_calls, id})
    |> require(nonnegative_integer?(result["tool_call_count"]), {:invalid_tool_calls, id})
    |> require(nonnegative_integer?(result["active_time_ms"]), {:invalid_active_time, id})
    |> require(
      nonnegative_integer?(result["active_time_ms"]) and
        result["active_time_ms"] <= task["active_deadline_ms"],
      {:active_deadline_exceeded, id}
    )
    |> require(
      nonnegative_integer?(result["intervention_count"]),
      {:invalid_intervention_count, id}
    )
    |> require(valid_artifact?(result["transcript_artifact"]), {:invalid_transcript_artifact, id})
    |> require(
      valid_artifact?(result["receipt_event_artifact"]),
      {:invalid_receipt_event_artifact, id}
    )
    |> require(valid_git_state?(result["git_state"]), {:invalid_git_state, id})
    |> require(
      valid_acceptance_results?(task, result["acceptance_results"]),
      {:invalid_acceptance_results, id}
    )
    |> require(is_list(result["safety_disqualifiers"]), {:invalid_task_disqualifiers, id})
    |> require(is_list(result["harness_errors"]), {:invalid_task_harness_errors, id})
    |> require(
      is_list(result["artifact_digests"]) and result["artifact_digests"] != [] and
        Enum.all?(result["artifact_digests"], &valid_digest?/1),
      {:invalid_artifact_digests, id}
    )
    |> require(
      valid_fault_evidence?(task, result["fault_evidence"]),
      {:invalid_fault_evidence, id}
    )
    |> require(
      not injected? or valid_safe_action_answers?(plan, result["safe_action_answers"]),
      {:incomplete_safe_action_answers, id}
    )
    |> require(
      not injected? or
        (nonnegative_integer?(result["knowledge_convergence_ms"]) and
           result["knowledge_convergence_ms"] <= task["knowledge_deadline_ms"]),
      {:knowledge_deadline_not_met, id}
    )
  end

  defp valid_artifact?("sha256:" <> digest), do: valid_digest?(digest)
  defp valid_artifact?(_value), do: false

  defp valid_git_state?(state) when is_map(state) do
    Enum.all?(
      ~w(initial_head initial_status_sha256 final_head final_status_sha256 diff_sha256),
      &is_binary(state[&1])
    ) and
      Enum.all?(
        ~w(initial_status_sha256 final_status_sha256 diff_sha256),
        &valid_digest?(state[&1])
      )
  end

  defp valid_git_state?(_state), do: false

  defp valid_acceptance_results?(task, results) when is_list(results) do
    length(results) == length(task["acceptance"]) and
      results
      |> Enum.with_index(1)
      |> Enum.all?(fn {result, index} ->
        result["command_index"] == index and is_integer(result["exit"]) and
          nonnegative_integer?(result["elapsed_ms"]) and valid_digest?(result["output_sha256"])
      end)
  end

  defp valid_acceptance_results?(_task, _results), do: false

  defp valid_fault_evidence?(%{"assignment" => "no_fault_control"}, nil), do: true

  defp valid_fault_evidence?(task, evidence) when is_map(evidence) do
    evidence["assignment"] == task["assignment"] and
      evidence["barrier_id"] == task["fault"]["barrier_id"] and
      evidence["owner"] == task["fault"]["owner"] and evidence["injected"] == true
  end

  defp valid_fault_evidence?(_task, _evidence), do: false

  defp valid_safe_action_answers?(plan, answers) when is_map(answers) do
    questions = plan.data["report_contract"]["safe_action_question_ids"]

    Map.keys(answers) |> Enum.sort() == Enum.sort(questions) and
      Enum.all?(questions, &(is_binary(answers[&1]) and answers[&1] != ""))
  end

  defp valid_safe_action_answers?(_plan, _answers), do: false
  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0

  defp valid_digest?(value) when is_binary(value) do
    byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]+\z/)
  end

  defp valid_digest?(_value), do: false
  defp require(errors, true, _reason), do: errors
  defp require(errors, false, reason), do: [reason | errors]
end
