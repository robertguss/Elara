source = File.read!("lib/elara/lab/scenarios/session_recovery.ex")
mutation = System.fetch_env!("ROB1085_MUTATION")

{old, new} =
  case mutation do
    "identity" ->
      {"accepted_ids == witness.accepted_order and", "true and"}

    "history" ->
      {"history_identity: StoreView.exact_history?(witness.history, accepted_fixture(witness)),",
       "history_identity: true,"}

    "terminal" ->
      {"\"text\" => text,\n         \"interrupted\" => false", "\"text\" => text"}

    "markers" ->
      {"physical_marker_counts: witness.marker_bytes == expected_labels(witness.fault),",
       "physical_marker_counts: true,"}

    "typed" ->
      start = "  defp typed_uncertainty?(%{fault: :tool_running} = witness) do"
      stop = "  defp typed_uncertainty?(witness),"
      [_, tail] = String.split(source, start, parts: 2)
      [body, _] = String.split(tail, stop, parts: 2)

      {start <> body,
       start <> "\n    witness.inputs[\"A\"].receipt.error =~ \"indeterminate\"\n  end\n\n"}

    "barrier" ->
      {"%{arrival_from: {from, target}, backlog_ids: [_, _]} = state",
       "%{arrival_from: {from, target}} = state"}

    "oneshot" ->
      {"not selected or state.arrival_from != nil or state.injections > 0 ->", "not selected ->"}

    "down" ->
      {"def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}",
       "def handle_info({:DOWN, _ref, :process, pid, reason}, state), do: {:noreply, %{state | down: %{target: pid, reason: reason, at: Jobs.now()}}}"}

    "early" ->
      {"hook_returned_before_down: state.hook_returned_before_down or is_nil(state.down)",
       "hook_returned_before_down: is_nil(state.down)"}

    "deadline" ->
      {"timeout = max(deadline - Jobs.now(), 0)", "timeout = max(deadline - Jobs.now(), 0) + 500"}

    "cleanup" ->
      {"complete = prerequisites and cleanup.confirmed", "complete = prerequisites"}
  end

if not String.contains?(source, old), do: raise("mutation anchor missing")
Code.compiler_options(ignore_module_conflict: true)

Code.compile_string(
  String.replace(source, old, new, global: false),
  "isolated-runtime-mutation-#{mutation}.ex"
)

IO.puts("MUTATION_LOADED=#{mutation}")
