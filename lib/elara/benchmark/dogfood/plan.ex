defmodule Elara.Benchmark.Dogfood.Plan do
  @moduledoc false

  @versions %{
    "elara.exp003.dogfood-plan.v1" => "ER-3/FND-2-v1",
    "elara.exp003.dogfood-plan.v2" => "ER-3/FND-2-v2",
    "elara.exp003.dogfood-plan.v3" => "ER-3/FND-2-v3",
    "elara.exp003.dogfood-plan.v4" => "ER-3/FND-2-v4"
  }
  @task_ids Enum.map(1..12, &"D#{String.pad_leading(Integer.to_string(&1), 2, "0")}")
  @assignments ~w(
    no_fault_control
    controller_loss_before_dispatch
    executor_loss_before_mutation
    executor_loss_after_mutation
    completion_reply_lost_before_persistence
    timeout_interrupt
    concurrent_workspace_conflict
  )

  @enforce_keys [:path, :sha256, :repo_root, :data, :tasks]
  defstruct [:path, :sha256, :repo_root, :data, :tasks]

  @type t :: %__MODULE__{
          path: String.t(),
          sha256: String.t(),
          repo_root: String.t(),
          data: map(),
          tasks: %{String.t() => map()}
        }

  @spec load(String.t(), keyword()) :: {:ok, t()} | {:error, [term()]}
  def load(path, opts \\ []) when is_binary(path) do
    repo_root = opts |> Keyword.get(:repo_root, File.cwd!()) |> Path.expand()

    with {:ok, contents} <- read(path),
         digest = sha256(contents),
         :ok <- verify_digest(digest, Keyword.get(opts, :sha256)),
         {:ok, data} <- decode(contents),
         :ok <- validate(data, repo_root) do
      {:ok,
       %__MODULE__{
         path: Path.expand(path),
         sha256: digest,
         repo_root: repo_root,
         data: data,
         tasks: Map.new(data["tasks"], &{&1["id"], &1})
       }}
    else
      {:error, reasons} when is_list(reasons) -> {:error, reasons}
      {:error, reason} -> {:error, [reason]}
    end
  end

  @spec task(t(), String.t()) :: {:ok, map()} | {:error, :unknown_task}
  def task(%__MODULE__{tasks: tasks}, id) when is_binary(id) do
    case Map.fetch(tasks, id) do
      {:ok, task} -> {:ok, task}
      :error -> {:error, :unknown_task}
    end
  end

  @spec execution_tasks(t()) :: [map()]
  def execution_tasks(%__MODULE__{data: data, tasks: tasks}) do
    Enum.map(data["execution_order"], &Map.fetch!(tasks, &1))
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:plan_read_failed, reason}}
    end
  end

  defp decode(contents) do
    case JSON.decode(contents) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _other} -> {:error, :plan_not_an_object}
      {:error, reason} -> {:error, {:plan_json_invalid, reason}}
    end
  end

  defp verify_digest(_actual, nil), do: :ok
  defp verify_digest(actual, actual), do: :ok

  defp verify_digest(actual, expected) do
    {:error, {:plan_digest_mismatch, expected, actual}}
  end

  defp validate(data, repo_root) do
    tasks = data["tasks"]

    errors =
      []
      |> require(
        @versions[data["schema"]] == data["preregistration_version"],
        {:schema, data["schema"], data["preregistration_version"]}
      )
      |> require(is_list(tasks), :tasks_not_a_list)
      |> validate_tasks(tasks, data, repo_root)
      |> validate_contract(data)

    case Enum.reverse(errors) do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  rescue
    error -> {:error, [{:malformed_plan, Exception.message(error)}]}
  end

  defp validate_tasks(errors, tasks, data, repo_root) when is_list(tasks) do
    ids = Enum.map(tasks, & &1["id"])
    execution_order = data["execution_order"]
    seed = get_in(data, ["seed", "sha256"])

    errors =
      errors
      |> require(ids == @task_ids, {:task_frame_order, ids})
      |> require(Enum.uniq(ids) == ids, :duplicate_task_id)
      |> require(is_list(execution_order), :execution_order_not_a_list)
      |> require(Enum.sort(execution_order || []) == @task_ids, :invalid_execution_membership)
      |> require(
        execution_order == Enum.sort_by(tasks, & &1["order_key"]) |> Enum.map(& &1["id"]),
        :execution_order_mismatch
      )
      |> require(valid_hex?(seed, 64), :invalid_seed)

    Enum.reduce(tasks, errors, fn task, reasons ->
      validate_task(reasons, task, seed, repo_root)
    end)
  end

  defp validate_tasks(errors, _tasks, _data, _repo_root), do: errors

  defp validate_task(errors, task, seed_hex, repo_root) do
    id = task["id"]
    commit = task["commit"]
    parent = task["parent_commit"]
    acceptance = task["acceptance"]
    expected_order_key = order_key(seed_hex, id)

    errors =
      errors
      |> require(is_binary(task["prompt"]) and task["prompt"] != "", {:empty_prompt, id})
      |> require(task["assignment"] in @assignments, {:invalid_assignment, id})
      |> require(task["operation_mapping"] in ~w(write patch), {:invalid_operation_mapping, id})
      |> require(task["order_key"] == expected_order_key, {:order_key_mismatch, id})
      |> require(valid_hex?(commit, 40), {:invalid_commit, id})
      |> require(valid_hex?(parent, 40), {:invalid_parent_commit, id})
      |> require(valid_hex?(task["tree"], 40), {:invalid_tree, id})
      |> require(valid_hex?(task["patch_sha256"], 64), {:invalid_patch_digest, id})
      |> require(
        is_list(task["changed_files"]) and task["changed_files"] != [],
        {:changed_files, id}
      )
      |> require(valid_fault?(task), {:invalid_fault, id})
      |> require(valid_acceptance?(acceptance), {:invalid_acceptance, id})
      |> require(positive_integer?(task["active_deadline_ms"]), {:invalid_active_deadline, id})
      |> require(
        positive_integer?(task["knowledge_deadline_ms"]),
        {:invalid_knowledge_deadline, id}
      )

    case validate_git_pins(repo_root, task) do
      :ok -> errors
      {:error, reason} -> [reason | errors]
    end
  end

  defp validate_contract(errors, data) do
    tasks = data["tasks"] || []
    assignments = Enum.frequencies_by(tasks, & &1["assignment"])
    injected = Enum.reject(tasks, &(&1["assignment"] == "no_fault_control"))
    denominators = data["denominators"] || %{}
    thresholds = data["thresholds"] || %{}
    report = data["report_contract"] || %{}
    exposure = data["exposure"] || %{}

    errors
    |> require(assignments["no_fault_control"] == 2, :control_count_mismatch)
    |> require(length(injected) == 10, :injected_count_mismatch)
    |> require(
      injected |> Enum.map(& &1["assignment"]) |> Enum.uniq() |> length() >= 5,
      :insufficient_failure_types
    )
    |> require(
      denominators == %{"P" => 12, "I" => 10, "C" => 2},
      {:denominator_drift, denominators}
    )
    |> require(
      thresholds["minimum_classified_dispositions"] == 8 and
        thresholds["minimum_distinct_failure_types"] == 5 and
        thresholds["required_guidance"] == 10 and thresholds["maximum_abandonments"] == 0 and
        thresholds["unassisted_integer_inequality"] == "5 * U >= 4 * D",
      :threshold_drift
    )
    |> require(data["rounding"] == "one_decimal_half_away_from_zero", :rounding_drift)
    |> require(
      get_in(data, ["target", "commit"]) == "9ff416f2c22327c5ef38edcd52a9e89108fbc726",
      :target_commit_drift
    )
    |> require(
      get_in(data, ["provider", "requested_model"]) == "grok-4",
      :provider_model_drift
    )
    |> require(
      get_in(data, ["pilot", "provider"]) == "Elara.Provider.Scripted" and
        get_in(data, ["pilot", "real_task_runs"]) == 0,
      :pilot_not_inert
    )
    |> require(
      exposure == %{
        "dogfood_task_runs" => 0,
        "dogfood_fault_runs" => 0,
        "target_fault_results_observed" => 0
      },
      :fault_exposure_detected
    )
    |> require(
      report["safe_action_question_ids"] == ~w(
        last_durable_controller_fact
        last_durable_executor_fact
        external_mutation_evidence
        permitted_next_action
      ),
      :safe_action_questions_drift
    )
    |> require(
      is_list(report["required_task_fields"]) and
        Enum.all?(
          ~w(task_id disposition transcript_artifact receipt_event_artifact git_state acceptance_results model_call_count tool_call_count active_time_ms intervention_count safe_action_answers safety_disqualifiers harness_errors artifact_digests),
          &(&1 in report["required_task_fields"])
        ),
      :report_fields_incomplete
    )
  end

  defp validate_git_pins(repo_root, task) do
    commit = task["commit"]
    parent = task["parent_commit"]

    with {:ok, ^commit} <- git(repo_root, ["rev-parse", "#{commit}^{commit}"]),
         {:ok, ^parent} <- git(repo_root, ["rev-parse", "#{commit}^"]),
         {:ok, tree} <- git(repo_root, ["rev-parse", "#{commit}^{tree}"]),
         true <- tree == task["tree"],
         {:ok, patch} <- git_raw(repo_root, ["diff", "--binary", parent, commit]),
         true <- sha256(patch) == task["patch_sha256"],
         {:ok, changed_files} <- git(repo_root, ["diff", "--name-only", parent, commit]),
         true <- String.split(changed_files, "\n", trim: true) == task["changed_files"] do
      :ok
    else
      {:ok, actual} -> {:error, {:git_pin_mismatch, task["id"], actual}}
      false -> {:error, {:git_content_mismatch, task["id"]}}
      {:error, reason} -> {:error, {:git_validation_failed, task["id"], reason}}
    end
  end

  defp valid_acceptance?(commands) when is_list(commands) and commands != [] do
    Enum.all?(commands, fn command ->
      is_map(command) and is_binary(command["command"]) and command["command"] != "" and
        command["expected_exit"] == 0 and positive_integer?(command["timeout_ms"])
    end)
  end

  defp valid_acceptance?(_commands), do: false

  defp valid_fault?(%{"assignment" => "no_fault_control", "fault" => nil}), do: true

  defp valid_fault?(%{"assignment" => assignment, "fault" => fault}) when is_map(fault) do
    assignment != "no_fault_control" and is_binary(fault["type"]) and
      is_binary(fault["barrier_id"]) and is_binary(fault["owner"]) and
      is_binary(fault["permitted_action"]) and is_list(fault["delivered"]) and
      is_list(fault["dropped"]) and is_list(fault["restart_order"]) and
      fault["restart_order"] != []
  end

  defp valid_fault?(_task), do: false

  defp order_key(seed_hex, id) when is_binary(seed_hex) and is_binary(id) do
    case Base.decode16(seed_hex, case: :mixed) do
      {:ok, seed} -> sha256(seed <> <<0>> <> id)
      :error -> nil
    end
  end

  defp order_key(_seed_hex, _id), do: nil

  defp valid_hex?(value, length) when is_binary(value) do
    byte_size(value) == length and String.match?(value, ~r/\A[0-9a-f]+\z/)
  end

  defp valid_hex?(_value, _length), do: false
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp git(repo_root, args) do
    with {:ok, output} <- git_raw(repo_root, args) do
      {:ok, String.trim(output)}
    end
  end

  defp git_raw(repo_root, args) do
    case System.cmd("git", args, cd: repo_root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, {:git_exit, status}}
    end
  rescue
    error -> {:error, {:git_exception, Exception.message(error)}}
  end

  defp require(errors, true, _reason), do: errors
  defp require(errors, false, reason), do: [reason | errors]

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
