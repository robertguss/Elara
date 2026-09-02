alias Elara.Benchmark.Exp003.Materializer

args =
  case System.argv() do
    ["--" | rest] -> rest
    rest -> rest
  end

case args do
  [protocol_path, protocol_sha256, beacon_path, beacon_sha256, output_root] ->
    case Materializer.run(
           File.cwd!(),
           protocol_path,
           protocol_sha256,
           beacon_path,
           beacon_sha256,
           output_root
         ) do
      {:ok, result} ->
        IO.puts("manifest_sha256=#{result["manifest_sha256"]}")
        IO.puts("dogfood_sha256=#{result["dogfood_sha256"]}")
        IO.puts("external_sha256=#{result["external_sha256"]}")
        IO.puts("receipt_sha256=#{result["receipt_sha256"]}")
        IO.puts("tasks=#{Enum.join(result["selected_task_ids"], ",")}")

      {:error, reason} ->
        raise "EXP-003 V8 materialization failed: #{reason}"
    end

  _other ->
    raise "usage: mix run priv/benchmark/materialize_exp003_v8.exs -- " <>
            "<protocol.json> <protocol-sha256> <verified-beacon.json> " <>
            "<beacon-sha256> <absent-output-root>"
end
