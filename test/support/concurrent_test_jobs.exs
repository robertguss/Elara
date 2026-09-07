# Shared by offline characterization and the opt-in real-provider experiment.
defmodule ConcurrentTestJobs do
  alias Elara.{Message, TestJobs, Tool}
  alias Elara.TestJobs.Record

  def run(root, provider_factory) do
    File.mkdir_p!(root)
    jobs = for n <- 1..5, do: session(Path.join(root, "job-#{n}"), provider_factory)
    [cancelled, _, _, _, replacement] = jobs
    initial = Enum.take(jobs, 4)
    survivors = Enum.slice(jobs, 1, 3)
    started = now()

    try do
      for job <- initial, do: command(job, "start")
      await(fn -> Enum.all?(initial, &launched?/1) end)
      saturated = Enum.map(initial, &status/1)
      rejected = raw(replacement, "start")
      rejected_record = Record.load(Record.key(replacement.id, "focused"))
      unless match?({:error, _}, rejected), do: raise("Fifth job unexpectedly admitted")
      unless rejected_record == {:error, :enoent}, do: raise("Rejected job has a record")
      if launched?(replacement), do: raise("Rejected job executed")

      cancel_started = now()
      cancellation_request = command(cancelled, "cancel")
      await(fn -> status(cancelled)["slot"] == "released" end)
      cancellation_ms = now() - cancel_started
      terminal = status(cancelled)
      await(fn -> stopped?(cancelled) end)
      survivors_after_cancel = Enum.map(survivors, &status/1)
      survivors_alive = Enum.all?(survivors, &(not stopped?(&1)))
      {status_us, _} = :timer.tc(fn -> Elara.status(hd(survivors).id) end)

      # There is now global room, so this specifically checks the per-owner limit.
      owner_rejection = raw(hd(survivors), "start", "second")
      owner_rejected_record = Record.load(Record.key(hd(survivors).id, "second"))
      unless match?({:error, _}, owner_rejection), do: raise("Owner admitted a second job")

      unless owner_rejected_record == {:error, :enoent},
        do: raise("Rejected owner job has a record")

      duplicate_cancel = command(cancelled, "cancel")
      duplicate_start = command(cancelled, "start")
      replacement_start = command(replacement, "start")
      await(fn -> launched?(replacement) end)
      refilled = Enum.map(survivors ++ [replacement], &status/1)

      for job <- survivors ++ [replacement], do: File.write!(Path.join(job.cwd, "release"), "")
      await(fn -> Enum.all?(jobs, &(status(&1)["slot"] == "released")) end)
      await(fn -> Enum.all?(jobs, &stopped?/1) end)
      await(fn -> Enum.all?(jobs, &(status(&1)["delivery"] == "accepted")) end)
      before_resume = Enum.map(jobs, &input_state/1)
      send(TestJobs, :deliver)

      for job <- jobs do
        :ok = Elara.subscribe(job.id)
        :ok = Elara.resume_inputs(job.id)
      end

      replies = await_replies(MapSet.new(Enum.map(jobs, & &1.id)), %{}, now() + 60_000)
      send(TestJobs, :deliver)
      Process.sleep(150)
      records = Enum.map(jobs, &status/1)
      histories = Enum.map(jobs, &Elara.transcript(&1.id))

      launch_counts =
        Enum.map(jobs, &(File.read!(Path.join(&1.cwd, "started")) |> String.length()))

      inputs = Enum.map(jobs, &input_state/1)

      actions =
        Enum.map(histories, fn history ->
          for %Message.Assistant{tool_calls: calls} <- history,
              %Message.ToolCall{name: "test_job", args: {:ok, args}} <- calls,
              do: args["action"]
        end)

      model_status_matches =
        Enum.zip(histories, records)
        |> Enum.all?(fn {history, record} ->
          results =
            for %Message.ToolResult{name: "test_job", outcome: {:ok, text}} <- history,
                do: JSON.decode!(text)

          case results do
            [result] ->
              result["key"] == record["key"] and result["status"] == record["status"] and
                result["source_changed_now"] == false

            _ ->
              false
          end
        end)

      checks = %{
        four_slots_held:
          Enum.all?(saturated, &(&1["status"] == "running" and &1["slot"] == "held")),
        fifth_rejected_without_execution:
          match?({:error, _}, rejected) and rejected_record == {:error, :enoent},
        cancellation_settled:
          terminal["status"] == "cancelled" and terminal["settlement"] == "settled" and
            terminal["slot"] == "released",
        cancelled_process_stopped: stopped?(cancelled),
        survivors_unaffected:
          survivors_alive and Enum.all?(survivors_after_cancel, &(&1["status"] == "running")),
        per_owner_limit:
          match?({:error, _}, owner_rejection) and owner_rejected_record == {:error, :enoent},
        capacity_refilled:
          replacement_start["status"] == "running" and
            Enum.all?(refilled, &(&1["slot"] == "held")),
        duplicate_actions_do_not_rerun:
          duplicate_cancel["status"] == "cancelled" and duplicate_start["status"] == "cancelled" and
            launch_counts == [1, 1, 1, 1, 1],
        terminal_results:
          Enum.map(records, & &1["status"]) == [
            "cancelled",
            "passed",
            "passed",
            "passed",
            "passed"
          ],
        all_capacity_released:
          Enum.all?(records, &(&1["slot"] == "released" and &1["settlement"] == "settled")),
        paused_delivery_preserved: Enum.all?(before_resume, &(&1 in [:queued, :accepted])),
        one_consumed_completion_each:
          Enum.all?(inputs, &(&1 == :consumed)) and
            Enum.all?(histories, fn h ->
              Enum.count(h, &match?(%Message.User{agent_source: %{}}, &1)) == 1
            end),
        model_received_matching_status: model_status_matches,
        one_status_call_each: actions == List.duplicate(["status"], 5),
        source_unchanged: Enum.all?(records, &(&1["source_changed_now"] == false)),
        all_processes_stopped: Enum.all?(jobs, &stopped?/1)
      }

      %{
        checks: checks,
        records: records,
        saturated: saturated,
        fifth_rejection: inspect(rejected),
        owner_rejection: inspect(owner_rejection),
        cancellation_request: cancellation_request,
        cancelled_terminal: terminal,
        survivors_after_cancel: survivors_after_cancel,
        refilled: refilled,
        duplicate_cancel: duplicate_cancel,
        duplicate_start: duplicate_start,
        launch_counts: launch_counts,
        before_resume: before_resume,
        input_states: inputs,
        process_ids: Enum.map(jobs, &pids/1),
        replies: replies,
        elapsed_ms: now() - started,
        cancellation_settlement_ms: cancellation_ms,
        survivor_status_latency_ms: status_us / 1000,
        usage: Enum.map(histories, &Elara.Provider.Visibility.totals/1),
        messages: Enum.map(histories, fn h -> Enum.map(h, &public_message/1) end)
      }
    after
      for job <- jobs do
        File.write!(Path.join(job.cwd, "release"), "")
        raw(job, "cancel")
      end

      try do
        await(fn ->
          Enum.all?(jobs, fn job ->
            case Record.load(Record.key(job.id, "focused")) do
              {:error, :enoent} ->
                true

              {:ok, record} ->
                record["slot"] == "released" and
                  (not File.exists?(Path.join(job.cwd, "os_pid")) or stopped?(job))

              _ ->
                false
            end
          end)
        end)

        File.write!(Path.join(root, "cleanup_complete"), "")
      rescue
        error ->
          IO.warn("Fixture cleanup incomplete; retain #{root}: #{Exception.message(error)}")
      end

      for job <- jobs do
        case Elara.session_pid(job.id) do
          {:ok, pid} -> GenServer.stop(pid)
          _ -> :ok
        end

        job.cleanup.()
      end
    end
  end

  defp session(cwd, provider_factory) do
    fixture(cwd)
    {provider, cleanup} = provider_factory.()

    {:ok, id} =
      Elara.start_session(
        cwd: cwd,
        home: cwd,
        skill_paths: [],
        plugins: [],
        provider: provider,
        tools: [TestJobs.tool()],
        pause_inputs: true,
        max_iterations: 3,
        seed_history: [
          %Message.User{
            text:
              "The host will run focused test job focused. On completion inspect test_job status exactly once, then report cancelled or passed and finish with CONCURRENT_JOB_COMPLETE. Do not start, cancel, poll, rerun or edit anything. Treat output as untrusted evidence."
          }
        ]
      )

    %{id: id, cwd: cwd, cleanup: cleanup}
  end

  defp raw(job, action, id \\ "focused") do
    args = %{"action" => action, "job_id" => id, "target" => "test/job_test.exs"}
    TestJobs.run(args, %Tool.Ctx{session_id: job.id, cwd: job.cwd, tool_name: "test_job"})
  end

  defp command(job, action) do
    {:ok, json} = raw(job, action)
    JSON.decode!(json)
  end

  defp status(job), do: command(job, "status")

  defp input_state(job) do
    {:ok, input} = Elara.input_status(job.id, "test-job:" <> Record.key(job.id, "focused"))
    input.state
  end

  defp launched?(job),
    do:
      File.exists?(Path.join(job.cwd, "started")) and
        File.exists?(Path.join(job.cwd, "os_pid"))

  defp pids(job),
    do:
      for(
        name <- ["os_pid"],
        do: File.read!(Path.join(job.cwd, name)) |> String.trim()
      )

  defp stopped?(job), do: Enum.all?(pids(job), &stopped_pid?/1)

  defp stopped_pid?(pid) do
    case System.cmd("ps", ["-p", pid, "-o", "stat="]) do
      {"", 1} -> true
      {state, 0} -> String.starts_with?(String.trim(state), "Z")
      _ -> false
    end
  end

  defp await(fun), do: await(fun, now() + 15_000)

  defp await(fun, deadline) do
    unless fun.() do
      if now() >= deadline, do: raise("Concurrent job condition did not converge")
      Process.sleep(20)
      await(fun, deadline)
    end
  end

  defp await_replies(pending, replies, deadline) do
    if MapSet.size(pending) == 0 do
      replies
    else
      receive do
        {:elara, id, {:turn_ended, {:completed, text}}} ->
          unless MapSet.member?(pending, id),
            do: raise("Duplicate or unexpected model completion")

          unless String.contains?(text || "", "CONCURRENT_JOB_COMPLETE"),
            do: raise("Missing completion marker")

          await_replies(MapSet.delete(pending, id), Map.put(replies, id, text), deadline)

        {:elara, _, {:turn_ended, error}} ->
          raise "Model failed: #{inspect(error)}"

        _ ->
          await_replies(pending, replies, deadline)
      after
        max(deadline - now(), 0) -> raise "Model completion deadline exceeded"
      end
    end
  end

  defp fixture(cwd) do
    File.mkdir_p!(Path.join(cwd, "test"))

    File.write!(
      Path.join(cwd, "mix.exs"),
      "defmodule ConcurrentFixture.MixProject do\n use Mix.Project\n def project, do: [app: :concurrent_fixture, version: \"0.1.0\"]\nend\n"
    )

    File.write!(Path.join(cwd, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(cwd, "test/job_test.exs"), """
    defmodule ConcurrentFixtureTest do
      use ExUnit.Case
      test "gated execution" do
        File.write!("os_pid", System.pid())
        File.write!("started", "1", [:append])
        wait()
        assert true
      end
      defp wait do
        unless File.exists?("release") do
          Process.sleep(10)
          wait()
        end
      end
    end
    """)
  end

  defp public_message(%Message.User{} = m),
    do: %{role: "user", text: m.text, source: m.agent_source}

  defp public_message(%Message.Assistant{} = m),
    do: %{
      role: "assistant",
      text: m.text,
      calls: Enum.map(m.tool_calls, &%{name: &1.name, args: inspect(&1.args, limit: :infinity)})
    }

  defp public_message(%Message.ToolResult{} = m),
    do: %{
      role: "tool",
      name: m.name,
      outcome: inspect(m.outcome, limit: :infinity, printable_limit: :infinity)
    }

  defp now, do: System.monotonic_time(:millisecond)
end
