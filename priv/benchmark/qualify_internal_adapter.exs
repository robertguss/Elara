alias Elara.Benchmark.{ElaraAdapter, Manifest}

[manifest_path, state_root, workspace_root, output_path] =
  case System.argv() do
    ["--", manifest, state, workspace, output] ->
      [manifest, state, workspace, output]

    [manifest, state, workspace, output] ->
      [manifest, state, workspace, output]

    _other ->
      raise "usage: mix run priv/benchmark/qualify_internal_adapter.exs -- " <>
              "<v3-manifest> <state-root> <workspace-root> <output.json>"
  end

repo_root = File.cwd!()
{:ok, manifest} = Manifest.load(Path.expand(manifest_path))
{:ok, config} = ElaraAdapter.prepare(repo_root, Path.expand(state_root))

{:ok, report} =
  ElaraAdapter.qualify_faults(manifest, config, Path.expand(workspace_root))

output_path = Path.expand(output_path)
File.mkdir_p!(Path.dirname(output_path))
File.write!(output_path, JSON.encode!(report))

IO.puts(
  "qualified #{report["fault_qualification"]["run_count"]} fault runs; " <>
    "confirmatory exposure=#{report["exposure"]["v3_confirmatory_fault_runs"]}"
)
