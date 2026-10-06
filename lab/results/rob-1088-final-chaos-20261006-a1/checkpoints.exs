alias Elara.Lab.{Artifacts, Matrix, MatrixRunner, VM}
repo = Path.expand(".")
dir = Path.expand("lab/results/rob-1088-final-chaos-20261006-a1")
path = Path.join(dir, "registration.json")
root = Path.join(dir, "rows")
receipt = for {stage, index} <- Enum.with_index(~w(client_running handler_running worker_running), 24), do: %{index: index, round: 0, seed: 1_088_700 + index, case_id: "receipt_transport:" <> stage, scenario: "transport_recovery", params: %{"stage" => stage, "receipt_backend" => "true"}}
general = for {stage, index} <- Enum.with_index(~w(session_running runner_running manager_running executor_running stub_running), 27), do: %{index: index, round: 0, seed: 1_088_700 + index, case_id: "general_job:" <> stage, scenario: "job_recovery", params: %{"stage" => stage, "api" => "job"}}
cells = Matrix.plan(1, 1_088_700) ++ receipt ++ general
true = length(cells) == 32 and Enum.map(cells, & &1.seed) == Enum.to_list(1_088_700..1_088_731)
required_checks = Enum.sum(Enum.map(cells, &(length(Matrix.check_names(&1)))))

case System.argv() do
  ["register"] ->
    false = File.exists?(root)
    artifacts = Artifacts.snapshot(repo)
    true = artifacts.source.dirty == false
    host = Path.join(dir, "host-conditions.json") |> File.read!() |> JSON.decode!()
    manifest = %{schema: 1, purpose: "LAB8 finite frozen-source regression; separate from original LAB5 measurement", repo: repo, root: root, commit: artifacts.source.commit, timeout_ms: 60_000, cells: cells, required_checks: required_checks, artifacts: artifacts, host_conditions: host}
    File.write!(path, JSON.encode!(manifest) <> "\n", [:exclusive, :sync])
    IO.puts(JSON.encode!(%{commit: manifest.commit, cells: length(cells), required_checks: required_checks, modules: length(artifacts.modules)}))
  ["run"] ->
    bytes = File.read!(path)
    manifest = JSON.decode!(bytes)
    true = manifest["schema"] == 1 and manifest["timeout_ms"] == 60_000
    true = manifest["cells"] == JSON.decode!(JSON.encode!(cells))
    true = manifest["required_checks"] == required_checks
    true = Artifacts.verify(manifest["artifacts"]).verified
    File.mkdir!(root)
    frozen = Path.join(root, "registration.json")
    File.write!(frozen, bytes, [:exclusive, :sync])
    results = Enum.reduce_while(cells, [], fn cell, results ->
      row_root = Path.join(root, String.pad_leading(to_string(cell.index), 4, "0"))
      row = MatrixRunner.execute(cell, frozen, row_root, repo: manifest["repo"], commit: manifest["commit"], timeout: 60_000)
      IO.puts(JSON.encode!(%{index: cell.index, case_id: cell.case_id, verdict: row.verdict}))
      next = [row | results]
      if row.verdict.stop or not row.verdict.passed, do: {:halt, next}, else: {:cont, next}
    end) |> Enum.reverse()
    summary = MatrixRunner.summarize(results, 32)
    VM.write(root, "summary", summary)
    IO.puts(JSON.encode!(summary))
    System.halt(if summary.completed and summary.passed == 32, do: 0, else: 1)
end
