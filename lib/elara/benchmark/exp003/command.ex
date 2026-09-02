defmodule Elara.Benchmark.Exp003.Command do
  @moduledoc false

  alias Elara.Benchmark.{ElaraAdapter, InternalConfirmatory}
  alias Elara.Benchmark.Exp003.Materializer

  @contracts %{
    {"elara.exp003.materialization-protocol.v8-development", "ER-3/FND-2-v8-development",
     "development"} => %{
      receipt_schema: "elara.exp003.materialization-receipt.v8-development",
      manifest_schema: "elara.exp003.corpus.v8-development",
      report_schema: "elara.exp003.internal-confirmatory-report.v8-development",
      checkpoint_schema: "elara.exp003.internal-confirmatory-checkpoint.v8-development",
      confirmatory: false
    },
    {"elara.exp003.materialization-protocol.v8", "ER-3/FND-2-v8", "confirmatory"} => %{
      receipt_schema: "elara.exp003.materialization-receipt.v8",
      manifest_schema: "elara.exp003.corpus.v8",
      report_schema: "elara.exp003.internal-confirmatory-report.v8",
      checkpoint_schema: "elara.exp003.internal-confirmatory-checkpoint.v8",
      confirmatory: true
    }
  }

  @spec qualify(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, term()}
  def qualify(
        repo_root,
        protocol_path,
        protocol_sha256,
        receipt_path,
        receipt_sha256,
        state_root,
        workspace_root,
        output_path
      ) do
    with {:ok, contract, manifest_path} <-
           contract(repo_root, protocol_path, protocol_sha256, receipt_path, receipt_sha256) do
      InternalConfirmatory.qualify_contract(
        contract,
        manifest_path,
        state_root,
        workspace_root,
        output_path
      )
    end
  end

  @spec execute(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, term()}
  def execute(
        repo_root,
        protocol_path,
        protocol_sha256,
        receipt_path,
        receipt_sha256,
        qualification_path,
        state_root,
        workspace_root,
        output_path
      ) do
    with {:ok, contract, manifest_path} <-
           contract(repo_root, protocol_path, protocol_sha256, receipt_path, receipt_sha256),
         :ok <- claim_confirmatory_execution(contract, receipt_path, receipt_sha256) do
      InternalConfirmatory.execute_contract(
        contract,
        manifest_path,
        qualification_path,
        state_root,
        workspace_root,
        output_path
      )
    end
  end

  @spec replay(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, term()}
  def replay(
        repo_root,
        protocol_path,
        protocol_sha256,
        receipt_path,
        receipt_sha256,
        report_path,
        output_path
      ) do
    with {:ok, contract, manifest_path} <-
           contract(repo_root, protocol_path, protocol_sha256, receipt_path, receipt_sha256) do
      InternalConfirmatory.replay_contract(contract, manifest_path, report_path, output_path)
    end
  end

  @spec contract(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map(), String.t()} | {:error, term()}
  def contract(repo_root, protocol_path, protocol_sha256, receipt_path, receipt_sha256) do
    repo_root = Path.expand(repo_root)
    protocol_path = Path.expand(protocol_path)
    receipt_path = Path.expand(receipt_path)

    with :ok <- check(repo_root == File.cwd!(), :command_must_run_from_repository_root),
         {:ok, protocol} <- verified_json(protocol_path, protocol_sha256, :protocol),
         {:ok, schema_contract} <- protocol_contract(protocol),
         :ok <- validate_protocol(protocol, schema_contract),
         :ok <- verify_source_identities(repo_root, protocol),
         {:ok, receipt} <- verified_json(receipt_path, receipt_sha256, :receipt),
         :ok <- validate_receipt(receipt, protocol_sha256, protocol, schema_contract),
         manifest_path = Path.join(Path.dirname(receipt_path), protocol["outputs"]["manifest"]),
         :ok <- verify_manifest(manifest_path, receipt, protocol, schema_contract),
         :ok <-
           Materializer.verify_bundle(
             repo_root,
             protocol_path,
             protocol_sha256,
             receipt_path,
             receipt_sha256
           ),
         {:ok, contract} <- build_contract(protocol, receipt, schema_contract) do
      {:ok, contract, manifest_path}
    end
  end

  @doc false
  @spec claim_confirmatory_execution(map(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def claim_confirmatory_execution(
        %{confirmatory: true} = contract,
        receipt_path,
        receipt_sha256
      )
      when is_binary(receipt_path) and is_binary(receipt_sha256) do
    with :ok <- check(valid_digest?(receipt_sha256), :invalid_claim_receipt_digest),
         claim_root <-
           Map.get(
             contract,
             :claim_root,
             Path.join([
               System.user_home!(),
               ".elara",
               "benchmark",
               "exp003",
               "execution-claims"
             ])
           ),
         :ok <- File.mkdir_p(claim_root) do
      write_execution_claim(
        Path.join(claim_root, receipt_sha256 <> ".json"),
        contract,
        receipt_sha256,
        Path.expand(receipt_path)
      )
    end
  end

  def claim_confirmatory_execution(%{confirmatory: false}, _receipt_path, _receipt_sha256),
    do: {:error, :confirmatory_execution_forbidden}

  def claim_confirmatory_execution(_contract, _receipt_path, _receipt_sha256),
    do: {:error, :invalid_confirmatory_execution_contract}

  defp write_execution_claim(claim_path, contract, receipt_sha256, receipt_path) do
    claim = %{
      "schema" => "elara.exp003.confirmatory-execution-claim.v1",
      "protocol" => contract.protocol,
      "manifest_sha256" => contract.manifest_sha256,
      "receipt_sha256" => receipt_sha256,
      "first_receipt_path" => receipt_path,
      "policy" => "one immutable execution; any interruption or failure forbids retry"
    }

    case File.open(claim_path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result =
          with :ok <- IO.binwrite(io, InternalConfirmatory.canonical_json(claim)),
               :ok <- :file.sync(io) do
            :ok
          end

        File.close(io)

        case result do
          :ok -> :ok
          {:error, reason} -> {:error, {:confirmatory_execution_claim_failed, reason}}
        end

      {:error, :eexist} ->
        {:error, :confirmatory_execution_already_claimed}

      {:error, reason} ->
        {:error, {:confirmatory_execution_claim_failed, reason}}
    end
  end

  defp build_contract(protocol, receipt, schema_contract) do
    source_paths = get_in(protocol, ["command_stack", "source_paths"])
    commands = get_in(protocol, ["command_stack", "commands"])
    targets = get_in(protocol, ["command_stack", "target_commits"])

    with :ok <- check(is_list(source_paths) and source_paths != [], :command_source_paths),
         :ok <-
           check(
             Enum.all?(source_paths, &Map.has_key?(protocol["source_identities"], &1)),
             :command_source_identity_missing
           ),
         :ok <-
           check(Enum.sort(Map.keys(commands || %{})) == ~w(execute qualify replay), :commands),
         :ok <- check(targets == ElaraAdapter.target_commits(), :target_commits) do
      {:ok,
       %{
         protocol: protocol["preregistration_version"],
         report_schema: schema_contract.report_schema,
         checkpoint_schema: schema_contract.checkpoint_schema,
         manifest_sha256: get_in(receipt, ["outputs", "manifest.json"]),
         manifest_schema: schema_contract.manifest_schema,
         manifest_version: protocol["preregistration_version"],
         source_paths: source_paths,
         commands: commands,
         exposure_version: "v8",
         confirmatory: schema_contract.confirmatory,
         execute_authorization: :contract,
         target_commits: targets
       }}
    end
  end

  defp validate_protocol(protocol, schema_contract) do
    with :ok <-
           check(
             get_in(protocol, ["exposure", "future_beacon_committed"]) ==
               schema_contract.confirmatory,
             :future_beacon_contract
           ),
         :ok <- check(is_map(protocol["source_identities"]), :source_identities),
         :ok <- check(is_map(protocol["command_stack"]), :command_stack),
         :ok <- check(protocol["outputs"]["manifest"] == "manifest.json", :manifest_path) do
      :ok
    end
  end

  defp validate_receipt(receipt, protocol_sha256, protocol, schema_contract) do
    with :ok <- check(receipt["schema"] == schema_contract.receipt_schema, :receipt_schema),
         :ok <-
           check(
             receipt["preregistration_version"] == protocol["preregistration_version"],
             :receipt_version
           ),
         :ok <-
           check(get_in(receipt, ["protocol", "sha256"]) == protocol_sha256, :receipt_protocol),
         :ok <- check(receipt["candidate_construction_count"] == 20, :construction_count),
         :ok <- check(receipt["eligible_candidate_count"] == 17, :eligible_count),
         :ok <- check(receipt["selected_task_count"] == 12, :task_count),
         :ok <- check(receipt["selected_row_count"] == 20, :row_count),
         :ok <-
           check(
             get_in(receipt, ["exposure", "v8_future_beacon_fetched"]) ==
               schema_contract.confirmatory,
             :future_beacon_exposure
           ),
         :ok <-
           check(
             get_in(receipt, ["exposure", "v8_held_out_selection_performed"]) ==
               schema_contract.confirmatory,
             :held_out_exposure
           ) do
      :ok
    end
  end

  defp verify_manifest(path, receipt, protocol, schema_contract) do
    expected = get_in(receipt, ["outputs", "manifest.json"])

    with :ok <- check(valid_digest?(expected), :manifest_digest),
         {:ok, bytes} <- File.read(path),
         :ok <- check(sha256(bytes) == expected, :manifest_receipt_mismatch),
         {:ok, manifest} when is_map(manifest) <- JSON.decode(bytes),
         :ok <- check(manifest["schema"] == schema_contract.manifest_schema, :manifest_schema),
         :ok <-
           check(
             manifest["preregistration_version"] == protocol["preregistration_version"],
             :manifest_version
           ) do
      :ok
    else
      {:error, reason} -> {:error, {:manifest_read_failed, reason}}
      _other -> {:error, :manifest_invalid}
    end
  end

  defp protocol_contract(protocol) do
    key = {protocol["schema"], protocol["preregistration_version"], protocol["mode"]}

    case Map.fetch(@contracts, key) do
      {:ok, contract} -> {:ok, contract}
      :error -> {:error, {:protocol_contract, key}}
    end
  end

  defp verify_source_identities(repo_root, protocol) do
    Enum.reduce_while(protocol["source_identities"], :ok, fn {path, expected}, :ok ->
      full_path = Path.expand(path, repo_root)

      result =
        with :ok <- check(Path.type(path) == :relative, {:source_path, path}),
             :ok <- check(inside?(full_path, repo_root), {:source_outside_repository, path}),
             :ok <- check(valid_digest?(expected), {:source_digest, path}),
             {:ok, bytes} <- File.read(full_path),
             :ok <- check(sha256(bytes) == expected, {:source_identity_mismatch, path}) do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp verified_json(path, expected, label) do
    with :ok <- check(valid_digest?(expected), {:expected_digest, label}),
         {:ok, bytes} <- File.read(path),
         :ok <- check(sha256(bytes) == expected, {:digest_mismatch, label}),
         {:ok, value} when is_map(value) <- JSON.decode(bytes) do
      {:ok, value}
    else
      {:error, reason} -> {:error, {label, reason}}
      _other -> {:error, {label, :invalid_json_object}}
    end
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")
  defp valid_digest?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
