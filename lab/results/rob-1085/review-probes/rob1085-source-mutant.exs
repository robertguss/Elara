source = File.read!("lib/elara/lab/scenarios/session_recovery.ex")

mutations = %{
  "call_ids" => {"length(call_ids) == length(Enum.uniq(call_ids))", "true"},
  "segment" => {"length(segment) == 3 and marker_pair?", "marker_pair?"},
  "chain" => {"selected_chain_covers_store?(store) and", "true and"},
  "receipt" => {"receipts_match and exact_history?", "true and exact_history?"},
  "bound" =>
    {"defp bound(true, _value, _limit), do: \"fails\"",
     "defp bound(true, _value, _limit), do: \"undetermined\""},
  "late_success" =>
    {"completed_at >= deadline -> timeout_result(operation, settled)",
     "false -> timeout_result(operation, settled)"}
}

name = System.fetch_env!("ROB1085_MUTATION")
{from, to} = Map.fetch!(mutations, name)
if length(String.split(source, from)) != 2, do: raise("mutation must match exactly once")
Code.compiler_options(ignore_module_conflict: true)
Code.compile_string(String.replace(source, from, to), "independent-mutant-#{name}.ex")
Mix.Task.run("test", ["test/elara/lab_session_recovery_test.exs", "--seed", "0"])
