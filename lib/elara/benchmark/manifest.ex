defmodule Elara.Benchmark.Manifest do
  @moduledoc false

  alias Elara.Benchmark.Fixture

  @versions %{
    "elara.exp003.corpus.v1" => "ER-3/FND-2-v1",
    "elara.exp003.corpus.v2" => "ER-3/FND-2-v2",
    "elara.exp003.corpus.v3" => "ER-3/FND-2-v3"
  }

  @enforce_keys [:path, :sha256, :data, :tasks, :rows, :adapter_fixtures]
  defstruct [:path, :sha256, :data, :tasks, :rows, :adapter_fixtures]

  @type t :: %__MODULE__{
          path: String.t(),
          sha256: String.t(),
          data: map(),
          tasks: %{String.t() => map()},
          rows: %{String.t() => map()},
          adapter_fixtures: %{String.t() => map()}
        }

  @spec load(String.t(), keyword()) :: {:ok, t()} | {:error, [term()]}
  def load(path, opts \\ []) when is_binary(path) do
    with {:ok, contents} <- read(path),
         digest = sha256(contents),
         :ok <- verify_expected_digest(digest, Keyword.get(opts, :sha256)),
         {:ok, data} <- decode(contents),
         :ok <- validate(data, Path.dirname(path)) do
      {:ok,
       %__MODULE__{
         path: Path.expand(path),
         sha256: digest,
         data: data,
         tasks: Map.new(data["tasks"], &{&1["id"], &1}),
         rows: Map.new(data["fault_rows"], &{&1["row_id"], &1}),
         adapter_fixtures: Map.new(data["adapter_equivalence_fixtures"], &{&1["id"], &1})
       }}
    else
      {:error, reasons} when is_list(reasons) -> {:error, reasons}
      {:error, reason} -> {:error, [reason]}
    end
  end

  @spec task(t(), String.t()) :: {:ok, map()} | {:error, :unknown_task}
  def task(%__MODULE__{tasks: tasks}, id) do
    case Map.fetch(tasks, id) do
      {:ok, task} -> {:ok, task}
      :error -> {:error, :unknown_task}
    end
  end

  @spec adapter_fixture(t(), String.t()) :: {:ok, map()} | {:error, :unknown_adapter_fixture}
  def adapter_fixture(%__MODULE__{adapter_fixtures: fixtures}, id) do
    case Map.fetch(fixtures, id) do
      {:ok, fixture} -> {:ok, fixture}
      :error -> {:error, :unknown_adapter_fixture}
    end
  end

  @spec row(t(), String.t()) :: {:ok, map()} | {:error, :unknown_row}
  def row(%__MODULE__{rows: rows}, id) do
    case Map.fetch(rows, id) do
      {:ok, row} -> {:ok, row}
      :error -> {:error, :unknown_row}
    end
  end

  @spec required_evidence_fields(t()) :: [String.t()]
  def required_evidence_fields(%__MODULE__{data: data}), do: data["required_evidence_fields"]

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:manifest_read_failed, reason}}
    end
  end

  defp decode(contents) do
    case JSON.decode(contents) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _other} -> {:error, :manifest_not_an_object}
      {:error, reason} -> {:error, {:manifest_json_invalid, reason}}
    end
  end

  defp verify_expected_digest(_actual, nil), do: :ok
  defp verify_expected_digest(actual, actual), do: :ok

  defp verify_expected_digest(actual, expected) do
    {:error, {:manifest_digest_mismatch, expected, actual}}
  end

  defp validate(data, root) do
    errors =
      []
      |> require(
        @versions[data["schema"]] == data["preregistration_version"],
        {:schema, data["schema"], data["preregistration_version"]}
      )
      |> require(is_list(data["tasks"]), :tasks_not_a_list)
      |> require(is_list(data["fault_rows"]), :fault_rows_not_a_list)
      |> validate_collections(data)
      |> validate_artifacts(data, root)

    case Enum.reverse(errors) do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  rescue
    error -> {:error, [{:malformed_manifest, Exception.message(error)}]}
  end

  defp validate_collections(errors, %{"tasks" => tasks, "fault_rows" => rows} = data)
       when is_list(tasks) and is_list(rows) do
    task_ids = Enum.map(tasks, &map_value(&1, "id"))
    row_ids = Enum.map(rows, &map_value(&1, "row_id"))
    selected_ids = get_in(data, ["selection", "selected_task_ids"])

    errors
    |> require(length(tasks) == get_in(data, ["selection", "task_count"]), :task_count_mismatch)
    |> require(
      length(rows) == get_in(data, ["selection", "scored_row_count"]),
      :row_count_mismatch
    )
    |> require(Enum.uniq(task_ids) == task_ids, :duplicate_task_id)
    |> require(Enum.uniq(row_ids) == row_ids, :duplicate_row_id)
    |> require(task_ids == selected_ids, :selected_task_order_mismatch)
    |> require(
      Enum.map(rows, &map_value(&1, "order_index")) == Enum.to_list(1..length(rows)),
      :row_order_gap
    )
    |> require(
      Enum.all?(rows, &(map_value(&1, "task_id") in task_ids)),
      :row_references_unknown_task
    )
    |> require(valid_required_fields?(data["required_evidence_fields"]), :invalid_evidence_fields)
    |> validate_tasks(tasks)
    |> validate_adapter_fixtures(data["adapter_equivalence_fixtures"])
    |> validate_rows(rows)
  end

  defp validate_collections(errors, _data), do: errors

  defp validate_tasks(errors, tasks) do
    Enum.reduce(tasks, errors, fn task, reasons ->
      validate_task(reasons, task)
    end)
  end

  defp validate_task(
         errors,
         %{
           "id" => id,
           "fixture" => %{
             "initial_files" => initial_files,
             "expected_no_fault_files" => expected_files,
             "initial_workspace_sha256" => initial_digest,
             "expected_no_fault_workspace_sha256" => expected_digest,
             "fixture_sha256" => fixture_digest,
             "fixture_commit" => fixture_commit
           }
         } = task
       )
       when is_binary(id) and is_list(initial_files) and is_list(expected_files) do
    errors
    |> require(
      Fixture.digest_files(initial_files) == initial_digest,
      {:initial_fixture_digest_mismatch, id}
    )
    |> require(
      Fixture.digest_files(expected_files) == expected_digest,
      {:expected_fixture_digest_mismatch, id}
    )
    |> require(
      Fixture.fixture_digest(task) == fixture_digest,
      {:fixture_content_digest_mismatch, id}
    )
    |> require(
      fixture_commit == "sha256:" <> to_string(fixture_digest),
      {:fixture_commit_mismatch, id}
    )
  rescue
    _error -> [{:invalid_task_fixture, id} | errors]
  end

  defp validate_task(errors, task), do: [{:invalid_task_fixture, map_value(task, "id")} | errors]

  defp validate_adapter_fixtures(errors, fixtures) when is_list(fixtures) do
    ids = Enum.map(fixtures, &map_value(&1, "id"))
    template_ids = Enum.map(fixtures, &map_value(&1, "template_id"))

    errors =
      errors
      |> require(Enum.uniq(ids) == ids, :duplicate_adapter_fixture_id)
      |> require(Enum.uniq(template_ids) == template_ids, :duplicate_adapter_template_id)

    Enum.reduce(fixtures, errors, fn fixture, reasons ->
      task = %{
        "id" => map_value(fixture, "template_id"),
        "fixture" => map_value(fixture, "fixture"),
        "plan" => map_value(fixture, "plan")
      }

      reasons
      |> require(
        map_value(fixture, "scored") == false,
        {:scored_adapter_fixture, map_value(fixture, "id")}
      )
      |> validate_task(task)
    end)
  end

  defp validate_adapter_fixtures(errors, _fixtures),
    do: [:adapter_equivalence_fixtures_not_a_list | errors]

  defp validate_rows(errors, rows) do
    Enum.reduce(rows, errors, fn row, reasons ->
      row_id = map_value(row, "row_id")

      valid =
        is_map(row) and is_binary(row_id) and
          map_value(row, "fault_type") in ~w(F1 F2 F3 F4) and
          is_binary(map_value(row, "barrier_id")) and
          map_value(row, "crash_target") in ["controller", "selected_worker_or_tool_owner"] and
          condition_map?(map_value(row, "expected_primary_recovery_class")) and
          condition_map?(map_value(row, "expected_safe_action")) and
          is_integer(map_value(row, "observation_deadline_ms")) and
          is_integer(map_value(row, "knowledge_and_safe_action_convergence_bound_ms"))

      require(reasons, valid, {:invalid_fault_row, row_id})
    end)
  end

  defp validate_artifacts(errors, data, root) do
    artifacts = get_in(data, ["beacon", "artifact_sha256"])

    if is_map(artifacts) do
      Enum.reduce(artifacts, errors, fn {filename, expected}, reasons ->
        if is_binary(filename) and Path.basename(filename) == filename do
          path = Path.join([root, "beacon", filename])

          actual =
            case File.read(path) do
              {:ok, contents} -> sha256(contents)
              {:error, reason} -> {:error, reason}
            end

          require(reasons, actual == expected, {:beacon_artifact_mismatch, filename, actual})
        else
          [{:unsafe_beacon_artifact_path, filename} | reasons]
        end
      end)
    else
      [{:invalid_beacon_artifacts, artifacts} | errors]
    end
  end

  defp valid_required_fields?(fields) when is_list(fields) do
    Enum.uniq(fields) == fields and
      Enum.all?(
        ~w(row_id condition primary_recovery_class safety_disqualifiers harness_errors),
        &(&1 in fields)
      )
  end

  defp valid_required_fields?(_fields), do: false

  defp condition_map?(%{"baseline" => baseline, "receipts" => receipts}),
    do: is_binary(baseline) and is_binary(receipts)

  defp condition_map?(_value), do: false

  defp map_value(map, key) when is_map(map), do: map[key]
  defp map_value(_value, _key), do: nil

  defp require(errors, true, _reason), do: errors
  defp require(errors, false, reason), do: [reason | errors]

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
