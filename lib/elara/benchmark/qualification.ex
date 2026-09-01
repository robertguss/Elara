defmodule Elara.Benchmark.Qualification do
  @moduledoc false

  alias Elara.Benchmark.Manifest

  @schema "elara.exp003.internal-adapter-qualification.v1"
  @version "ER-3/INTERNAL-ADAPTER-QUAL-v1"
  @sources %{
    "elara.exp003.corpus.v3" => "ER-3/FND-2-v3",
    "elara.exp003.corpus.v4" => "ER-3/FND-2-v4"
  }
  @fixture_by_class %{"write" => "W01", "patch" => "P01", "shell" => "S02"}

  @spec manifest(Manifest.t()) :: {:ok, Manifest.t()} | {:error, term()}
  def manifest(%Manifest{} = source) do
    with :ok <- validate_source(source),
         {:ok, tasks} <- qualification_tasks(source),
         rows <- qualification_rows(source, tasks),
         :ok <- validate_matrix(tasks, rows) do
      data = %{
        "schema" => @schema,
        "preregistration_version" => @version,
        "scope_id" => qualification_scope(source),
        "source_manifest_sha256" => source.sha256,
        "selection" => %{
          "task_count" => length(tasks),
          "scored_row_count" => length(rows),
          "selected_task_ids" => Enum.map(tasks, & &1["id"])
        },
        "tasks" => tasks,
        "fault_rows" => rows,
        "required_evidence_fields" => source.data["required_evidence_fields"],
        "adapter_equivalence_fixtures" => [],
        "seed" => source.data["seed"],
        "beacon" => source.data["beacon"]
      }

      {:ok,
       %Manifest{
         path: source.path <> "#internal-adapter-qualification",
         sha256: digest(data),
         data: data,
         tasks: Map.new(tasks, &{&1["id"], &1}),
         rows: Map.new(rows, &{&1["row_id"], &1}),
         adapter_fixtures: %{}
       }}
    end
  end

  @spec schema() :: String.t()
  def schema, do: @schema

  defp validate_source(%Manifest{data: data}) do
    if @sources[data["schema"]] == data["preregistration_version"],
      do: :ok,
      else: {:error, :not_frozen_qualification_source}
  end

  defp qualification_scope(%Manifest{data: %{"schema" => "elara.exp003.corpus.v3"}}),
    do: "EXP-003-v3-internal-adapter-qualification"

  defp qualification_scope(%Manifest{data: %{"schema" => "elara.exp003.corpus.v4"}}),
    do: "EXP-003-v4-internal-adapter-qualification"

  defp qualification_tasks(source) do
    source.data["adapter_equivalence_fixtures"]
    |> Enum.reduce_while({:ok, []}, fn fixture, {:ok, tasks} ->
      if fixture["exposure_split"] == "development_adapter_fixture" and
           fixture["scored"] == false do
        task = %{
          "id" => fixture["template_id"],
          "operation_class" => fixture["operation_class"],
          "exposure_split" => fixture["exposure_split"],
          "request" => "Execute the single frozen development adapter operation.",
          "fixture" => fixture["fixture"],
          "plan" => fixture["plan"]
        }

        {:cont, {:ok, [task | tasks]}}
      else
        {:halt, {:error, {:invalid_development_fixture, fixture["id"]}}}
      end
    end)
    |> then(fn
      {:ok, tasks} -> {:ok, Enum.sort_by(tasks, & &1["operation_class"])}
      error -> error
    end)
  end

  defp qualification_rows(source, tasks) do
    task_by_class = Map.new(tasks, &{&1["operation_class"], &1})

    source.data["fault_rows"]
    |> Enum.uniq_by(&{&1["operation_class"], &1["fault_type"]})
    |> Enum.sort_by(&{&1["operation_class"], &1["fault_type"]})
    |> Enum.with_index(1)
    |> Enum.map(fn {source_row, order_index} ->
      class = source_row["operation_class"]
      task = Map.fetch!(task_by_class, class)
      task_id = Map.fetch!(@fixture_by_class, class)

      source_row
      |> Map.put("row_id", "QUAL-#{task_id}-#{source_row["fault_type"]}")
      |> Map.put("task_id", task["id"])
      |> Map.put("fault_target_tool_call_id", tool_call_id(task))
      |> Map.put("order_index", order_index)
      |> Map.put("fault_role", "development_qualification")
      |> Map.put("source_row_id", source_row["row_id"])
      |> Map.put("exposure_split", "development_adapter_fixture")
      |> Map.put("workspace_contract", workspace_contract(task))
    end)
  end

  defp validate_matrix(tasks, rows) do
    expected =
      MapSet.new([
        {"patch", "F1"},
        {"patch", "F2"},
        {"patch", "F3"},
        {"patch", "F4"},
        {"shell", "F1"},
        {"shell", "F2"},
        {"shell", "F3"},
        {"shell", "F4"},
        {"write", "F1"},
        {"write", "F2"},
        {"write", "F3"},
        {"write", "F4"}
      ])

    actual = MapSet.new(rows, &{&1["operation_class"], &1["fault_type"]})

    cond do
      length(tasks) != 3 ->
        {:error, :development_task_count_mismatch}

      actual != expected ->
        {:error, {:qualification_matrix_mismatch, actual}}

      Enum.any?(tasks, &(&1["exposure_split"] != "development_adapter_fixture")) ->
        {:error, :confirmatory_task_in_qualification}

      true ->
        :ok
    end
  end

  defp workspace_contract(task) do
    fixture = task["fixture"]

    %{
      "environmental_mutations_before_dispatch" => 0,
      "fault_target_job_mutations" => 1,
      "initial_reset_workspace_sha256" => fixture["initial_workspace_sha256"],
      "pre_effect_workspace_sha256" => fixture["initial_workspace_sha256"],
      "fault_target_postcondition_sha256" => fixture["expected_no_fault_workspace_sha256"],
      "complete_task_workspace_sha256" => fixture["expected_no_fault_workspace_sha256"]
    }
  end

  defp tool_call_id(task) do
    task["plan"]["scripted_provider"] |> hd() |> Map.fetch!("tool_call_id")
  end

  defp digest(data) do
    data
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, item} ->
      JSON.encode!(key) <> ":" <> canonical_json(item)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(value) when is_list(value) do
    value |> Enum.map_join(",", &canonical_json/1) |> then(&("[" <> &1 <> "]"))
  end

  defp canonical_json(value), do: JSON.encode!(value)
end
