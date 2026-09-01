defmodule Elara.Benchmark.ExternalAdapterV2 do
  @moduledoc false

  alias Elara.Benchmark.{ExternalAdapter, Manifest}

  @source "lib/elara/benchmark/external_adapter_v2.ex"

  @spec comparator_commit() :: String.t()
  defdelegate comparator_commit(), to: ExternalAdapter

  @spec prepare(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate prepare(repo_root, state_root, lemon_root), to: ExternalAdapter

  @spec prove_no_fault(Manifest.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def prove_no_fault(
        %Manifest{data: %{"preregistration_version" => "ER-3/FND-2-v2"}} = manifest,
        config,
        workspace_root
      ) do
    with {:ok, report} <- ExternalAdapter.prove_no_fault(manifest, config, workspace_root) do
      {:ok,
       report
       |> Map.put("schema", "elara.exp003.external-adapter-equivalence.v2")
       |> Map.put("preregistration_version", "ER-3/FND-2-v2")
       |> Map.put("version_adapter", %{
         "source" => @source,
         "sha256" => file_sha256!(config.repo_root, @source),
         "base_adapter_source" => report["adapter"]["source"],
         "base_adapter_sha256" => report["adapter"]["sha256"]
       })}
    end
  end

  def prove_no_fault(%Manifest{}, _config, _workspace_root),
    do: {:error, :v2_manifest_required}

  defp file_sha256!(root, relative_path) do
    root
    |> Path.join(relative_path)
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
