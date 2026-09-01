defmodule Elara.Benchmark.DogfoodReportTest do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.Dogfood.{Plan, Redactor, Report}

  @path "test/fixtures/benchmark/exp003/dogfood-plan.json"

  setup do
    {:ok, plan} = Plan.load(@path)
    {:ok, plan: plan}
  end

  test "redaction detects seeded credential forms without returning their values" do
    api_value = "xai-fixturecredential12345"
    bearer_value = "Bearer fixtureauthorization98765"

    raw = %{
      "nested" => [%{"api_key" => api_value}],
      "ELARA_API_KEY" => api_value,
      "transcript" => "header #{bearer_value} tail",
      "credential_capability" => "xai_authenticated_chat"
    }

    paths = Redactor.secret_paths(raw)
    inspected_paths = inspect(paths)
    refute inspected_paths =~ api_value
    refute inspected_paths =~ bearer_value
    assert ["nested", 0, "api_key"] in paths
    assert ["ELARA_API_KEY"] in paths
    assert ["transcript"] in paths

    encoded = raw |> Redactor.redact() |> JSON.encode!()
    refute encoded =~ api_value
    refute encoded =~ bearer_value
    assert encoded =~ "[REDACTED]"
    assert encoded =~ "xai_authenticated_chat"
  end

  test "execution reports require every artifact field and four safe-action answers", %{
    plan: plan
  } do
    report = execution_report(plan)
    assert :ok = Report.validate(plan, report)

    [first, injected | rest] = report["task_results"]
    assert first["safe_action_answers"] == %{}

    incomplete =
      update_in(injected["safe_action_answers"], &Map.delete(&1, "permitted_next_action"))

    invalid = %{report | "task_results" => [first, incomplete | rest]}

    assert {:error, errors} = Report.validate(plan, invalid)
    assert {:incomplete_safe_action_answers, injected["task_id"]} in errors
  end

  test "a prior safety disqualifier produces valid terminal non-execution", %{plan: plan} do
    report = Report.safety_blocked(plan, ["duplicate external mutation"], "ROB-838")

    assert :ok = Report.validate(plan, report)
    assert report["status"] == "not_executed"
    assert report["task_results"] == []
    assert report["exposure"] == %{"dogfood_task_runs" => 0, "dogfood_fault_runs" => 0}
  end

  test "unredacted report values are rejected by path only", %{plan: plan} do
    report = execution_report(plan)
    secret = "ghp_fixturecredential123456789"
    invalid = put_in(report, ["task_results", Access.at(0), "transcript_artifact"], secret)

    assert {:error, errors} = Report.validate(plan, invalid)
    rendered = inspect(errors)
    assert rendered =~ "unredacted_secret_paths"
    refute rendered =~ secret
  end

  defp execution_report(plan) do
    task_results =
      Enum.map(Plan.execution_tasks(plan), fn task ->
        injected? = task["assignment"] != "no_fault_control"

        %{
          "task_id" => task["id"],
          "disposition" => "completed",
          "transcript_artifact" => "sha256:" <> String.duplicate("1", 64),
          "receipt_event_artifact" => "sha256:" <> String.duplicate("2", 64),
          "git_state" => %{
            "initial_head" => task["parent_commit"],
            "initial_status_sha256" => String.duplicate("4", 64),
            "final_head" => task["parent_commit"],
            "final_status_sha256" => String.duplicate("5", 64),
            "diff_sha256" => task["patch_sha256"]
          },
          "acceptance_results" =>
            task["acceptance"]
            |> Enum.with_index(1)
            |> Enum.map(fn {_command, index} ->
              %{
                "command_index" => index,
                "exit" => 0,
                "elapsed_ms" => 10,
                "output_sha256" => String.duplicate("6", 64)
              }
            end),
          "model_call_count" => 2,
          "tool_call_count" => 1,
          "active_time_ms" => 100,
          "intervention_count" => 0,
          "knowledge_convergence_ms" => if(injected?, do: 100, else: nil),
          "fault_evidence" =>
            if(injected?,
              do: %{
                "assignment" => task["assignment"],
                "barrier_id" => task["fault"]["barrier_id"],
                "owner" => task["fault"]["owner"],
                "injected" => true
              },
              else: nil
            ),
          "safe_action_answers" => if(injected?, do: safe_answers(), else: %{}),
          "safety_disqualifiers" => [],
          "harness_errors" => [],
          "artifact_digests" => [String.duplicate("3", 64)]
        }
      end)

    %{
      "schema" => "elara.exp003.dogfood-report.v1",
      "mode" => "execution",
      "status" => "completed",
      "plan_sha256" => plan.sha256,
      "target_commit" => plan.data["target"]["commit"],
      "task_results" => task_results,
      "safety_disqualifiers" => [],
      "harness_errors" => []
    }
  end

  defp safe_answers do
    %{
      "last_durable_controller_fact" => "intent committed",
      "last_durable_executor_fact" => "accepted",
      "external_mutation_evidence" => "postcondition observed; causality unknown",
      "permitted_next_action" => "query the same executor; do not retry"
    }
  end
end
