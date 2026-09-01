alias Elara.Benchmark.InternalConfirmatory

args =
  case System.argv() do
    ["--" | rest] -> rest
    rest -> rest
  end

result =
  case args do
    ["qualify", manifest, state, workspace, output] ->
      InternalConfirmatory.qualify(manifest, state, workspace, output)

    ["execute", manifest, qualification, state, workspace, output] ->
      InternalConfirmatory.execute(manifest, qualification, state, workspace, output)

    ["replay", manifest, execution, output] ->
      InternalConfirmatory.replay(manifest, execution, output)

    _other ->
      {:error,
       "usage: mix run priv/benchmark/run_internal_confirmatory.exs -- " <>
         "qualify <v4-manifest> <state-root> <workspace-root> <output.json> | " <>
         "execute <v4-manifest> <qualification.json> <state-root> <workspace-root> " <>
         "<output.json> | replay <v4-manifest> <execution.json> <score-output.json>"}
  end

case result do
  {:ok, report} ->
    score = Map.get(report, "score", report)
    IO.puts("internal confirmatory command complete; score=#{score["status"]}")

  {:error, reason} ->
    raise "internal confirmatory command failed: #{inspect(reason, limit: :infinity)}"
end
