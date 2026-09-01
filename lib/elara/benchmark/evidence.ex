defmodule Elara.Benchmark.Evidence do
  @moduledoc false

  alias Elara.Benchmark.Manifest

  @fault_schema "elara.exp003.fault-evidence.v1"
  @no_fault_schema "elara.exp003.no-fault-evidence.v1"

  @record_statuses ~w(completed skipped non_comparable harness_failure)
  @conditions ~w(baseline receipts)
  @classes ~w(
    automatic_terminal
    automatic_known_nonterminal
    automatic_safe_indeterminate
    manual_recovery
    ambiguous_no_safe_action
    safety_disqualifier
    harness_failure
    non_comparable
  )

  @fault_local_fields ~w(
    schema
    record_status
    causal_terminal_evidence_expected
    causal_terminal_evidence_observed
    terminal_convergence_ms
    knowledge_convergence_ms
  )

  @no_fault_fields ~w(
    schema
    task_id
    condition
    phase
    run_index
    order_index
    fixture_commit
    initial_workspace_sha256
    expected_workspace_sha256
    final_workspace_sha256
    observed_outcome
    expected_outcome
    workspace_correct
    outcome_correct
    elapsed_wall_us
    cpu_time_us
    storage_bytes
  )

  @spec fault_schema() :: String.t()
  def fault_schema, do: @fault_schema

  @spec no_fault_schema() :: String.t()
  def no_fault_schema, do: @no_fault_schema

  @spec validate_fault(Manifest.t(), map()) :: :ok | {:error, [term()]}
  def validate_fault(%Manifest{} = manifest, record) when is_map(record) do
    missing =
      missing_fields(record, Manifest.required_evidence_fields(manifest) ++ @fault_local_fields)

    errors =
      Enum.map(missing, &{:missing_field, &1}) ++
        validate_fault_values(record)

    if errors == [], do: :ok, else: {:error, errors}
  end

  @spec validate_no_fault(map()) :: :ok | {:error, [term()]}
  def validate_no_fault(record) when is_map(record) do
    missing = missing_fields(record, @no_fault_fields)

    errors =
      Enum.map(missing, &{:missing_field, &1}) ++
        validate_no_fault_values(record)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp validate_fault_values(record) do
    []
    |> valid(record["schema"] == @fault_schema, {:invalid_schema, record["schema"]})
    |> valid(
      record["record_status"] in @record_statuses,
      {:invalid_record_status, record["record_status"]}
    )
    |> valid(record["condition"] in @conditions, {:invalid_condition, record["condition"]})
    |> valid(
      record["primary_recovery_class"] in @classes,
      {:invalid_primary_recovery_class, record["primary_recovery_class"]}
    )
    |> valid(is_list(record["safety_disqualifiers"]), :invalid_safety_disqualifiers)
    |> valid(is_list(record["harness_errors"]), :invalid_harness_errors)
    |> valid(nonnegative_integer?(record["run_index"]), :invalid_run_index)
    |> valid(nonnegative_integer?(record["order_index"]), :invalid_order_index)
    |> valid(nonnegative_integer?(record["elapsed_ms"]), :invalid_elapsed_ms)
    |> valid(nonnegative_integer?(record["cpu_ms"]), :invalid_cpu_ms)
    |> valid(nonnegative_integer?(record["storage_bytes"]), :invalid_storage_bytes)
    |> valid(
      nonnegative_integer?(record["callback_attempt_count"]),
      :invalid_callback_attempt_count
    )
    |> valid(
      nonnegative_integer?(record["external_mutation_count"]),
      :invalid_external_mutation_count
    )
    |> valid(
      nonnegative_integer?(record["unplanned_intervention_count"]),
      :invalid_unplanned_intervention_count
    )
    |> valid(nonnegative_integer?(record["model_call_count"]), :invalid_model_call_count)
    |> valid(nonnegative_integer?(record["tool_call_count"]), :invalid_tool_call_count)
    |> valid(
      boolean?(record["causal_terminal_evidence_expected"]),
      :invalid_causal_terminal_expected
    )
    |> valid(
      boolean?(record["causal_terminal_evidence_observed"]),
      :invalid_causal_terminal_observed
    )
    |> valid(
      nullable_nonnegative_integer?(record["terminal_convergence_ms"]),
      :invalid_terminal_convergence_ms
    )
    |> valid(
      nullable_nonnegative_integer?(record["knowledge_convergence_ms"]),
      :invalid_knowledge_convergence_ms
    )
    |> Enum.reverse()
  end

  defp validate_no_fault_values(record) do
    []
    |> valid(record["schema"] == @no_fault_schema, {:invalid_schema, record["schema"]})
    |> valid(record["condition"] in @conditions, {:invalid_condition, record["condition"]})
    |> valid(record["phase"] in ~w(warmup measured), {:invalid_phase, record["phase"]})
    |> valid(nonnegative_integer?(record["run_index"]), :invalid_run_index)
    |> valid(nonnegative_integer?(record["order_index"]), :invalid_order_index)
    |> valid(boolean?(record["workspace_correct"]), :invalid_workspace_correct)
    |> valid(boolean?(record["outcome_correct"]), :invalid_outcome_correct)
    |> valid(nonnegative_integer?(record["elapsed_wall_us"]), :invalid_elapsed_wall_us)
    |> valid(nonnegative_integer?(record["cpu_time_us"]), :invalid_cpu_time_us)
    |> valid(nonnegative_integer?(record["storage_bytes"]), :invalid_storage_bytes)
    |> Enum.reverse()
  end

  defp missing_fields(record, required) do
    Enum.reject(required, &Map.has_key?(record, &1))
  end

  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0
  defp nullable_nonnegative_integer?(nil), do: true
  defp nullable_nonnegative_integer?(value), do: nonnegative_integer?(value)
  defp boolean?(value), do: value in [true, false]

  defp valid(errors, true, _reason), do: errors
  defp valid(errors, false, reason), do: [reason | errors]
end
