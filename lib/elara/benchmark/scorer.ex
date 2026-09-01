defmodule Elara.Benchmark.Scorer do
  @moduledoc false

  alias Elara.Benchmark.{Evidence, Manifest, Runner}

  @bad_recovery_classes ~w(automatic_safe_indeterminate manual_recovery ambiguous_no_safe_action)

  @spec score(Manifest.t(), [map()], [map()], keyword()) :: map()
  def score(%Manifest{} = manifest, fault_records, no_fault_records, opts \\ [])
      when is_list(fault_records) and is_list(no_fault_records) do
    denominator =
      Keyword.get_lazy(opts, :denominator, fn ->
        manifest.data["fault_rows"]
        |> Enum.sort_by(& &1["order_index"])
        |> Enum.map(& &1["row_id"])
      end)

    with :ok <- validate_denominator(manifest, denominator),
         :ok <- validate_fault_evidence(manifest, fault_records),
         {:ok, consolidated} <- consolidate_faults(manifest, fault_records, denominator),
         :ok <- validate_no_fault_evidence(manifest, no_fault_records),
         :ok <- validate_no_fault_schedule(manifest, no_fault_records) do
      build_report(manifest, denominator, consolidated, fault_records, no_fault_records)
    else
      {:error, errors} when is_list(errors) -> invalid_report(errors)
      {:error, error} -> invalid_report([error])
    end
  end

  defp validate_denominator(manifest, denominator) do
    unknown = Enum.reject(denominator, &Map.has_key?(manifest.rows, &1))
    duplicates = denominator -- Enum.uniq(denominator)

    errors =
      []
      |> add_if(unknown != [], {:unknown_denominator_rows, unknown})
      |> add_if(duplicates != [], {:duplicate_denominator_rows, duplicates})
      |> add_if(denominator == [], :empty_denominator)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp validate_fault_evidence(manifest, records) do
    errors =
      records
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {record, index} ->
        case Evidence.validate_fault(manifest, record) do
          :ok -> immutable_fault_errors(manifest, record, index)
          {:error, reasons} -> [{:invalid_fault_evidence, index, reasons}]
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp consolidate_faults(_manifest, records, denominator) do
    denominator_set = MapSet.new(denominator)

    records = Enum.filter(records, &MapSet.member?(denominator_set, &1["row_id"]))
    grouped = Enum.group_by(records, &{&1["row_id"], &1["condition"], &1["run_index"]})

    expected_keys =
      for row_id <- denominator,
          condition <- ~w(baseline receipts),
          run_index <- 1..3,
          do: {row_id, condition, run_index}

    errors =
      Enum.flat_map(expected_keys, fn key ->
        case Map.get(grouped, key, []) do
          [] ->
            [{:missing_fault_run, key}]

          [record] ->
            expected_order = fault_order_index(elem(key, 1), elem(key, 2))

            if record["order_index"] == expected_order,
              do: [],
              else: [{:fault_order_mismatch, key, expected_order, record["order_index"]}]

          matches ->
            [{:duplicate_fault_run, key, length(matches)}]
        end
      end)

    extra_keys = Enum.sort(Map.keys(grouped) -- expected_keys)

    structural_errors =
      if extra_keys == [], do: errors, else: [{:unexpected_fault_runs, extra_keys} | errors]

    if structural_errors == [] do
      errors =
        denominator
        |> Enum.flat_map(fn row_id ->
          Enum.flat_map(~w(baseline receipts), fn condition ->
            repetitions =
              Enum.map(1..3, fn run_index ->
                [record] = grouped[{row_id, condition, run_index}]
                record
              end)

            repetition_errors(row_id, condition, repetitions)
          end)
        end)

      if errors == [] do
        consolidated =
          Map.new(
            for row_id <- denominator, condition <- ~w(baseline receipts) do
              repetitions =
                Enum.map(1..3, fn run_index ->
                  [record] = grouped[{row_id, condition, run_index}]
                  record
                end)

              {{row_id, condition},
               %{
                 "primary_recovery_class" => hd(repetitions)["primary_recovery_class"],
                 "repetitions" => repetitions
               }}
            end
          )

        {:ok, consolidated}
      else
        {:error, Enum.reverse(errors)}
      end
    else
      {:error, Enum.reverse(structural_errors)}
    end
  end

  defp repetition_errors(_row_id, _condition, []), do: []

  defp repetition_errors(row_id, condition, repetitions) do
    statuses = Enum.uniq(Enum.map(repetitions, & &1["record_status"]))
    classes = Enum.uniq(Enum.map(repetitions, & &1["primary_recovery_class"]))

    status_errors =
      Enum.flat_map(repetitions, fn record ->
        key = {row_id, condition, record["run_index"]}

        cond do
          record["record_status"] == "skipped" ->
            [{:skipped_fault_run, key}]

          record["record_status"] == "non_comparable" ->
            [{:non_comparable_fault_run, key}]

          record["record_status"] == "harness_failure" ->
            [{:harness_failure, key}]

          record["harness_errors"] != [] ->
            [{:harness_failure, key, record["harness_errors"]}]

          record["primary_recovery_class"] == "non_comparable" ->
            [{:non_comparable_fault_run, key}]

          record["primary_recovery_class"] == "harness_failure" ->
            [{:harness_failure, key}]

          true ->
            []
        end
      end)

    consistency_errors =
      []
      |> add_if(length(statuses) != 1, {:inconsistent_record_status, row_id, condition, statuses})
      |> add_if(length(classes) != 1, {:inconsistent_recovery_class, row_id, condition, classes})

    status_errors ++ consistency_errors
  end

  defp validate_no_fault_evidence(manifest, records) do
    errors =
      records
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {record, index} ->
        case Evidence.validate_no_fault(record) do
          :ok -> immutable_no_fault_errors(manifest, record, index)
          {:error, reasons} -> [{:invalid_no_fault_evidence, index, reasons}]
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp validate_no_fault_schedule(manifest, records) do
    grouped =
      Enum.group_by(records, &{&1["task_id"], &1["condition"], &1["phase"], &1["run_index"]})

    schedule = Runner.no_fault_schedule(manifest)

    expected_runs =
      Map.new(schedule, fn run ->
        key = {run["task_id"], run["condition"], run["phase"], run["run_index"]}
        {key, run}
      end)

    expected_keys =
      Enum.map(schedule, &{&1["task_id"], &1["condition"], &1["phase"], &1["run_index"]})

    errors =
      Enum.flat_map(expected_keys, fn key ->
        case Map.get(grouped, key, []) do
          [] ->
            [{:missing_no_fault_run, key}]

          [record] ->
            expected_order = expected_runs[key]["order_index"]

            []
            |> add_if(
              record["order_index"] != expected_order,
              {:no_fault_order_mismatch, key, expected_order, record["order_index"]}
            )
            |> add_if(
              record["phase"] == "measured" and record["elapsed_wall_us"] == 0,
              {:zero_no_fault_timing, key}
            )

          matches ->
            [{:duplicate_no_fault_run, key, length(matches)}]
        end
      end)

    extra_keys = Enum.sort(Map.keys(grouped) -- expected_keys)

    errors =
      if extra_keys == [], do: errors, else: [{:unexpected_no_fault_runs, extra_keys} | errors]

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp build_report(manifest, denominator, consolidated, fault_records, no_fault_records) do
    b = count_bad(consolidated, denominator, "baseline")
    t = count_bad(consolidated, denominator, "receipts")
    material = b >= 2 and b - t >= 2 and 2 * (b - t) >= b

    denominator_set = MapSet.new(denominator)

    scored_fault_records =
      Enum.filter(fault_records, &MapSet.member?(denominator_set, &1["row_id"]))

    safety_disqualifiers =
      scored_fault_records
      |> Enum.flat_map(fn record ->
        class_disqualifier =
          if record["primary_recovery_class"] == "safety_disqualifier",
            do: ["primary_recovery_class:safety_disqualifier"],
            else: []

        class_disqualifier ++ record["safety_disqualifiers"]
      end)
      |> Enum.uniq()

    knowledge = knowledge_result(manifest, scored_fault_records)
    terminal = terminal_result(manifest, scored_fault_records)
    no_fault = no_fault_correctness(no_fault_records)
    timing = timing_result(manifest, no_fault_records)

    hard_failure =
      safety_disqualifiers != [] or not knowledge["pass"] or not terminal["pass"] or
        not no_fault["pass"]

    status =
      cond do
        hard_failure -> "Fail"
        material and timing["pass"] -> "Pass"
        true -> "Mixed"
      end

    %{
      "schema" => "elara.exp003.score.v1",
      "status" => status,
      "valid" => true,
      "errors" => [],
      "denominator" => denominator,
      "B" => b,
      "T" => t,
      "B_minus_T" => b - t,
      "material_improvement" => material,
      "safety_disqualifiers" => safety_disqualifiers,
      "knowledge_and_safe_action" => knowledge,
      "causal_terminal_convergence" => terminal,
      "no_fault_correctness" => no_fault,
      "timing" => timing
    }
  end

  defp count_bad(consolidated, denominator, condition) do
    Enum.count(denominator, fn row_id ->
      consolidated[{row_id, condition}]["primary_recovery_class"] in @bad_recovery_classes
    end)
  end

  defp knowledge_result(manifest, records) do
    failures =
      Enum.flat_map(records, fn record ->
        row = manifest.rows[record["row_id"]]
        expected_action = row["expected_safe_action"][record["condition"]]
        bound = row["knowledge_and_safe_action_convergence_bound_ms"]

        cond do
          record["safe_next_action_expected"] != expected_action ->
            [{record["row_id"], record["condition"], :expected_action_drift}]

          record["safe_next_action_observed"] != expected_action ->
            [{record["row_id"], record["condition"], :wrong_safe_action}]

          is_nil(record["knowledge_convergence_ms"]) ->
            [{record["row_id"], record["condition"], :did_not_converge}]

          record["knowledge_convergence_ms"] > bound ->
            [{record["row_id"], record["condition"], :deadline_exceeded}]

          true ->
            []
        end
      end)

    %{"pass" => failures == [], "failures" => Enum.uniq(failures)}
  end

  defp terminal_result(manifest, records) do
    applicable =
      Enum.filter(records, fn record ->
        manifest.rows[record["row_id"]]["causal_terminal_evidence_expected_to_survive"]
      end)

    failures =
      Enum.flat_map(applicable, fn record ->
        row = manifest.rows[record["row_id"]]
        bound = row["terminal_convergence_bound_ms"]

        cond do
          record["causal_terminal_evidence_expected"] !=
              row["causal_terminal_evidence_expected_to_survive"] ->
            [{record["row_id"], record["condition"], :expectation_drift}]

          not record["causal_terminal_evidence_observed"] ->
            [{record["row_id"], record["condition"], :terminal_evidence_missing}]

          is_nil(record["terminal_convergence_ms"]) ->
            [{record["row_id"], record["condition"], :did_not_converge}]

          record["terminal_convergence_ms"] > bound ->
            [{record["row_id"], record["condition"], :deadline_exceeded}]

          true ->
            []
        end
      end)

    %{
      "pass" => failures == [],
      "applicable_repetitions" => length(applicable),
      "failures" => Enum.uniq(failures)
    }
  end

  defp no_fault_correctness(records) do
    failures =
      records
      |> Enum.reject(&(&1["workspace_correct"] and &1["outcome_correct"]))
      |> Enum.map(&{&1["task_id"], &1["condition"], &1["phase"], &1["run_index"]})

    %{"pass" => failures == [], "failures" => failures}
  end

  defp timing_result(manifest, records) do
    measured = Enum.filter(records, &(&1["phase"] == "measured"))

    ratios =
      Map.new(manifest.data["selection"]["selected_task_ids"], fn task_id ->
        baseline = measured_times(measured, task_id, "baseline") |> median()
        receipts = measured_times(measured, task_id, "receipts") |> median()
        {task_id, divide(receipts, baseline)}
      end)

    corpus_ratio = ratios |> Map.values() |> median_rationals()

    %{
      "pass" =>
        Enum.all?(ratios, fn {_task_id, ratio} -> less_than_or_equal?(ratio, {2, 1}) end) and
          less_than_or_equal?(corpus_ratio, {6, 5}),
      "per_task_ratio" => Map.new(ratios, fn {task, ratio} -> {task, rational_map(ratio)} end),
      "corpus_median_ratio" => rational_map(corpus_ratio),
      "corpus_threshold" => %{"numerator" => 6, "denominator" => 5},
      "per_task_threshold" => %{"numerator" => 2, "denominator" => 1}
    }
  end

  defp measured_times(records, task_id, condition) do
    records
    |> Enum.filter(&(&1["task_id"] == task_id and &1["condition"] == condition))
    |> Enum.map(& &1["elapsed_wall_us"])
  end

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)

    if rem(count, 2) == 1 do
      {Enum.at(sorted, div(count, 2)), 1}
    else
      {Enum.at(sorted, div(count, 2) - 1) + Enum.at(sorted, div(count, 2)), 2}
      |> reduce()
    end
  end

  defp median_rationals(values) do
    sorted = Enum.sort(values, &less_than_or_equal?/2)
    count = length(sorted)

    if rem(count, 2) == 1 do
      Enum.at(sorted, div(count, 2))
    else
      left = Enum.at(sorted, div(count, 2) - 1)
      right = Enum.at(sorted, div(count, 2))
      average(left, right)
    end
  end

  defp divide({_numerator, 0}, _denominator),
    do: raise(ArgumentError, "invalid zero timing median")

  defp divide(_numerator, {0, _denominator}),
    do: raise(ArgumentError, "zero baseline timing median")

  defp divide({left_numerator, left_denominator}, {right_numerator, right_denominator}) do
    reduce({left_numerator * right_denominator, left_denominator * right_numerator})
  end

  defp average({left_numerator, left_denominator}, {right_numerator, right_denominator}) do
    reduce(
      {left_numerator * right_denominator + right_numerator * left_denominator,
       2 * left_denominator * right_denominator}
    )
  end

  defp less_than_or_equal?(
         {left_numerator, left_denominator},
         {right_numerator, right_denominator}
       ) do
    left_numerator * right_denominator <= right_numerator * left_denominator
  end

  defp reduce({numerator, denominator}) do
    divisor = Integer.gcd(numerator, denominator)
    {div(numerator, divisor), div(denominator, divisor)}
  end

  defp rational_map({numerator, denominator}) do
    %{
      "numerator" => numerator,
      "denominator" => denominator,
      "decimal" => numerator / denominator
    }
  end

  defp invalid_report(errors) do
    %{
      "schema" => "elara.exp003.score.v1",
      "status" => "Invalid",
      "valid" => false,
      "errors" => errors
    }
  end

  defp add_if(errors, true, reason), do: [reason | errors]
  defp add_if(errors, false, _reason), do: errors

  defp immutable_fault_errors(manifest, record, index) do
    case manifest.rows[record["row_id"]] do
      nil ->
        [{:unknown_fault_row, index, record["row_id"]}]

      row ->
        task = manifest.tasks[row["task_id"]]
        condition = record["condition"]

        expected = %{
          "preregistration_version" => manifest.data["preregistration_version"],
          "seed_round" => manifest.data["beacon"]["round"],
          "seed_digest" => manifest.data["seed"]["sha256"],
          "corpus_manifest_digest" => manifest.sha256,
          "task_id" => task["id"],
          "operation_class" => row["operation_class"],
          "scope_id" => manifest.data["scope_id"],
          "exposure_split" => task["exposure_split"],
          "fixture_commit" => task["fixture"]["fixture_commit"],
          "initial_workspace_digest" => task["fixture"]["initial_workspace_sha256"],
          "fault_type" => row["fault_type"],
          "barrier_id" => row["barrier_id"],
          "killed_owner" => row["crash_target"],
          "delivered_messages" => row["delivered_messages"],
          "dropped_messages" => row["dropped_messages"],
          "surviving_storage" => row["surviving_storage"],
          "restart_order" => row["restart_order"],
          "observation_deadline_ms" => row["observation_deadline_ms"],
          "expected_workspace_digest" => task["fixture"]["expected_no_fault_workspace_sha256"],
          "causal_terminal_evidence_expected" =>
            row["causal_terminal_evidence_expected_to_survive"],
          "safe_next_action_expected" => row["expected_safe_action"][condition],
          "initial_reset_verified" => true
        }

        immutable_mismatches(record, expected, :fault_manifest_mismatch, index)
    end
  end

  defp immutable_no_fault_errors(manifest, record, index) do
    case manifest.tasks[record["task_id"]] do
      nil ->
        [{:unknown_no_fault_task, index, record["task_id"]}]

      task ->
        expected_outcome =
          task["plan"]["steps"] |> List.last() |> Map.fetch!("expected_no_fault_outcome")

        expected = %{
          "fixture_commit" => task["fixture"]["fixture_commit"],
          "initial_workspace_sha256" => task["fixture"]["initial_workspace_sha256"],
          "expected_workspace_sha256" => task["fixture"]["expected_no_fault_workspace_sha256"],
          "expected_outcome" => expected_outcome
        }

        immutable_mismatches(record, expected, :no_fault_manifest_mismatch, index)
    end
  end

  defp immutable_mismatches(record, expected, error, index) do
    Enum.flat_map(expected, fn {field, value} ->
      if record[field] == value,
        do: [],
        else: [{error, index, field, value, record[field]}]
    end)
  end

  defp fault_order_index("baseline", 1), do: 1
  defp fault_order_index("baseline", 2), do: 4
  defp fault_order_index("baseline", 3), do: 5
  defp fault_order_index("receipts", 1), do: 2
  defp fault_order_index("receipts", 2), do: 3
  defp fault_order_index("receipts", 3), do: 6
end
