alias Elara.Benchmark.Exp003.Command

args =
  case System.argv() do
    ["--" | rest] -> rest
    rest -> rest
  end

result =
  case args do
    [
      "qualify",
      protocol,
      protocol_sha256,
      receipt,
      receipt_sha256,
      state,
      workspace,
      output
    ] ->
      Command.qualify(
        File.cwd!(),
        protocol,
        protocol_sha256,
        receipt,
        receipt_sha256,
        state,
        workspace,
        output
      )

    [
      "execute",
      protocol,
      protocol_sha256,
      receipt,
      receipt_sha256,
      qualification,
      state,
      workspace,
      output
    ] ->
      Command.execute(
        File.cwd!(),
        protocol,
        protocol_sha256,
        receipt,
        receipt_sha256,
        qualification,
        state,
        workspace,
        output
      )

    ["replay", protocol, protocol_sha256, receipt, receipt_sha256, report, output] ->
      Command.replay(
        File.cwd!(),
        protocol,
        protocol_sha256,
        receipt,
        receipt_sha256,
        report,
        output
      )

    _other ->
      {:error,
       "usage: mix run priv/benchmark/run_exp003_v8.exs -- " <>
         "qualify <protocol> <protocol-sha256> <receipt> <receipt-sha256> " <>
         "<state-root> <workspace-root> <output.json> | " <>
         "execute <protocol> <protocol-sha256> <receipt> <receipt-sha256> " <>
         "<qualification.json> <state-root> <workspace-root> <output.json> | " <>
         "replay <protocol> <protocol-sha256> <receipt> <receipt-sha256> " <>
         "<report.json> <score-output.json>"}
  end

case result do
  {:ok, report} ->
    score = Map.get(report, "score", report)
    IO.puts("EXP-003 V8 command complete; score=#{score["status"]}")

  {:error, reason} ->
    raise "EXP-003 V8 command failed: #{inspect(reason, limit: :infinity)}"
end
