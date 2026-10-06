defmodule Elara.Lab.Matrix do
  @moduledoc "Finite fault schedule planning; causal eligibility stays separate from outcome and cleanup."

  @families [
    {"session_recovery", "fault", ~w(provider_started provider_streaming tool_running)},
    {"handoff_recovery", "stage", ~w(prepared created transferred activated started)},
    {"child_recovery", "stage", ~w(parent_delegated child_provider child_marker)},
    {"job_recovery", "stage",
     ~w(session_running runner_running manager_running executor_running stub_running)},
    {"group_recovery", "stage", ~w(owner_running executor_running stub_running)},
    {"transport_recovery", "stage", ~w(client_running handler_running worker_running)},
    {"vm_recovery", "stage", ~w(provider_running mutation_running)}
  ]

  def cases do
    for {scenario, key, values} <- @families, value <- values do
      %{case_id: scenario <> ":" <> value, scenario: scenario, params: %{key => value}}
    end
  end

  def plan(repetitions, seed)
      when is_integer(repetitions) and repetitions > 0 and is_integer(seed) do
    for round <- 0..(repetitions - 1), cell <- cases() do
      Map.put(cell, :round, round)
    end
    |> Enum.with_index()
    |> Enum.map(fn {cell, index} -> Map.merge(cell, %{index: index, seed: seed + index}) end)
  end

  @input_checks ~w(input_identities known_history_inputs known_receipts unique_accepted_ids
    unique_input_payloads at_most_once_consumption linear_history unique_history_ids
    call_result_identity handoff_chain_ready)
  @checks %{
    "session_recovery" =>
      ~w(known_fault fault_witnessed target_down_witnessed unique_accepted_inputs
      backlog_witnessed_before_release one_shot_gate stable_labels exact_identities persisted_state_read
      settled_receipts active_input_cleared history_identity physical_marker_counts no_unexpected_labels
      backlog_completed responsive_probe timing_bounded indeterminate_without_receipt no_input_while_paused
      marker_hook_blocked_until_down),
    "handoff_recovery" =>
      @input_checks ++ ~w(fault_witnessed fault_checkpoint_persisted target_down_witnessed
      backlog_before_fault persisted_observation files_openable source_terminal continuation_and_backlog_completed
      physical_markers_once recovery_bounded backlog_bounded),
    "child_recovery" =>
      ~w(fault_witnessed target_down_witnessed backlog_before_fault files_openable
      input_identities all_inputs_terminal fault_input_not_successful child_once parent_link capacity_owned
      capacity_released markers_once uncertainty_preserved scoped_acknowledgment recovery_bounded backlog_bounded),
    "job_recovery" =>
      ~w(fault_witnessed target_down_witnessed identities all_inputs_terminal source_outcome
      completion_interpreted job_outcome slot_released launch_once native_stopped_before_cleanup stable_job_identity
      replay_retained recovery_bounded backlog_bounded),
    "group_recovery" =>
      ~w(fault_witnessed target_down_witnessed ordinary_child_owned launch_once
      native_stopped_before_cleanup epoch_interpreted settlement_interpreted owner_terminal executor_idle recovery_bounded),
    "transport_recovery" =>
      ~w(fault_witnessed target_down_witnessed identities all_inputs_completed
      source_mutation_indeterminate stable_intent direct_client_owned native_stopped_before_cleanup launch_once
      native_epoch_settled worker_serving recovery_bounded backlog_bounded),
    "vm_recovery" =>
      @input_checks ++
        ~w(fault_witnessed fresh_vm recovery_bound backlog_bound recovered_input_visible
      own_input_terminals no_request_replay single_physical_launch mutation_uncertain intent_preserved
      native_stopped_before_cleanup reopened_executor_idle cleanup_confirmed)
  }

  def check_names(cell) do
    extra =
      case {cell.scenario, cell.params["stage"]} do
        {"job_recovery", stage} when stage in ["executor_running", "stub_running"] ->
          ~w(epoch_changed held_before_ack acknowledgment_scoped uncertainty_preserved)

        {"group_recovery", "stub_running"} ->
          ~w(old_stub_stopped)

        _ ->
          []
      end

    Map.fetch!(@checks, cell.scenario) ++ extra
  end

  def judge(row, cell, commit) when is_map(row) do
    checks = row["checks"]

    valid_checks =
      is_map(checks) and map_size(checks) > 0 and
        Enum.all?(checks, fn {name, value} -> is_binary(name) and is_boolean(value) end)

    eligible =
      valid_checks and row["scenario"] == cell.scenario and row["seed"] == cell.seed and
        Enum.all?(check_names(cell), &Map.has_key?(checks, &1)) and
        row["params"] == cell.params and field(row, ["host", "commit"]) == commit and
        field(row, ["host", "dirty"]) == false and field(row, ["host", "schedulers"]) == 2 and
        field(row, ["matrix_peer", "max_restarts"]) == 3 and
        field(row, ["matrix_peer", "period"]) == 5 and
        field(row, ["matrix_peer", "artifacts_verified"]) == true and causal?(row, cell) and
        field(row, ["matrix_peer", "outer_launcher_verified"]) == true

    failed = if valid_checks, do: for({name, false} <- checks, do: name) |> Enum.sort(), else: []

    cleanup =
      field(row, ["cleanup", "confirmed"]) == true and
        field(row, ["matrix_peer", "outer_cleanup_confirmed"]) == true and
        not Map.has_key?(row, "retained_dir")

    %{
      eligible: eligible,
      passed: eligible and failed == [] and row["complete"] == true and cleanup,
      failed_checks: failed,
      cleanup_confirmed: cleanup,
      stop: not eligible or not cleanup
    }
  end

  def judge(_row, _cell, _commit),
    do: %{eligible: false, passed: false, failed_checks: [], cleanup_confirmed: false, stop: true}

  defp field(value, []), do: value
  defp field(value, [key | rest]) when is_map(value), do: field(Map.get(value, key), rest)
  defp field(_value, _keys), do: nil

  defp causal?(row, %{scenario: "vm_recovery"}) do
    row["checks"]["fault_witnessed"] == true and
      field(row, ["fault", "exit_status"]) == 137 and
      field(row, ["fault", "port_down"]) == true and
      field(row, ["fault", "vm_stopped"]) == true
  end

  defp causal?(row, _cell),
    do:
      row["checks"]["fault_witnessed"] == true and
        row["checks"]["target_down_witnessed"] == true
end
