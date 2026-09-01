defmodule Elara.Benchmark.Compatibility do
  @moduledoc false

  @schema "elara.exp003.compatibility.v3"
  @version "ER-3/FND-2-v3"
  @faults ~w(F1 F2 F3 F4)

  @spec load(String.t()) :: {:ok, map()} | {:error, [term()]}
  def load(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, data} when is_map(data) <- JSON.decode(contents),
         :ok <- validate(data) do
      {:ok, data}
    else
      {:error, reasons} when is_list(reasons) -> {:error, reasons}
      {:error, reason} -> {:error, [reason]}
      _other -> {:error, [:compatibility_not_an_object]}
    end
  end

  @spec validate(map()) :: :ok | {:error, [term()]}
  def validate(data) when is_map(data) do
    candidates = data["candidates"]
    fault_contracts = data["fault_contracts"]

    errors =
      []
      |> require(data["schema"] == @schema, {:invalid_schema, data["schema"]})
      |> require(
        data["preregistration_version"] == @version,
        {:invalid_version, data["preregistration_version"]}
      )
      |> require(is_list(candidates), :candidates_not_a_list)
      |> require(valid_fault_contracts?(fault_contracts), :invalid_fault_contracts)
      |> validate_candidates(candidates, fault_contracts)

    case Enum.reverse(errors) do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  rescue
    error -> {:error, [{:malformed_compatibility_contract, Exception.message(error)}]}
  end

  def validate(_data), do: {:error, [:compatibility_not_an_object]}

  defp valid_fault_contracts?(contracts) when is_map(contracts) do
    Enum.sort(Map.keys(contracts)) == @faults and
      get_in(contracts, ["F1", "job_mutations_at_barrier"]) == 0 and
      get_in(contracts, ["F2", "job_mutations_at_barrier"]) == 0 and
      get_in(contracts, ["F1", "barrier_workspace"]) == "pre_effect_workspace" and
      get_in(contracts, ["F2", "barrier_workspace"]) == "pre_effect_workspace" and
      get_in(contracts, ["F3", "job_mutations_at_barrier"]) == 1 and
      get_in(contracts, ["F3", "barrier_workspace"]) == "fault_target_postcondition" and
      get_in(contracts, ["F4", "barrier_workspace"]) == "complete_task_workspace"
  end

  defp valid_fault_contracts?(_contracts), do: false

  defp validate_candidates(errors, candidates, contracts) when is_list(candidates) do
    ids = Enum.map(candidates, &map_value(&1, "id"))

    expected_ids =
      for(class <- ~w(W P), n <- 1..8, do: class <> String.pad_leading("#{n}", 2, "0")) ++
        for n <- 1..4, do: "S" <> String.pad_leading("#{n}", 2, "0")

    errors =
      errors
      |> require(length(candidates) == 20, :candidate_count_mismatch)
      |> require(Enum.sort(ids) == Enum.sort(expected_ids), :candidate_frame_mismatch)
      |> require(Enum.uniq(ids) == ids, :duplicate_candidate_id)

    Enum.reduce(candidates, errors, &validate_candidate(&2, &1, contracts))
  end

  defp validate_candidates(errors, _candidates, _contracts), do: errors

  defp validate_candidate(errors, candidate, contracts) when is_map(candidate) do
    id = candidate["id"]
    primary = candidate["primary_fault"]
    secondary = candidate["secondary_fault"]

    errors
    |> require(primary in @faults, {:invalid_primary_fault, id, primary})
    |> require(secondary in @faults, {:invalid_secondary_fault, id, secondary})
    |> require(primary != secondary, {:duplicate_fault_assignment, id, primary})
    |> require(
      candidate["fault_target_job_mutations"] in [0, 1],
      {:invalid_target_mutation_count, id}
    )
    |> require(
      is_integer(candidate["environmental_mutations_before_dispatch"]) and
        candidate["environmental_mutations_before_dispatch"] >= 0,
      {:invalid_environmental_mutation_count, id}
    )
    |> require(
      is_integer(candidate["step_count"]) and candidate["step_count"] >= 1,
      {:invalid_step_count, id}
    )
    |> validate_assignment(candidate, primary, contracts)
    |> validate_assignment(candidate, secondary, contracts)
  end

  defp validate_candidate(errors, candidate, _contracts),
    do: [{:invalid_candidate, map_value(candidate, "id")} | errors]

  defp validate_assignment(errors, candidate, fault, contracts) when fault in @faults do
    id = candidate["id"]
    contract = contracts[fault]

    errors
    |> require(
      valid_workspace_contract?(candidate, fault, contract),
      {:missing_workspace_contract, id, fault}
    )
    |> require(
      fault != "F3" or candidate["fault_target_job_mutations"] == 1,
      {:f3_requires_one_job_mutation, id}
    )
    |> require(
      fault != "F3" or not candidate["complete_task_requires_live_continuation"],
      {:f3_requires_live_continuation, id}
    )
  end

  defp validate_assignment(errors, _candidate, _fault, _contracts), do: errors

  defp valid_workspace_contract?(candidate, fault, contract) do
    default = contract["converged_workspace"]
    override = get_in(candidate, ["workspace_overrides", fault])

    valid_condition_map?(override || default)
  end

  defp valid_condition_map?(%{"baseline" => baseline, "receipts" => receipts}) do
    is_binary(baseline) and baseline != "" and is_binary(receipts) and receipts != ""
  end

  defp valid_condition_map?(_contract), do: false

  defp require(errors, true, _error), do: errors
  defp require(errors, false, error), do: [error | errors]

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)
  defp map_value(_map, _key), do: nil
end
