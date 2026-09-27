defmodule Elara.Lab.Scenarios.ConcurrentJobs do
  @moduledoc """
  JOB-10 as a lab scenario: five sessions compete for the four test-job slots.
  The fifth is rejected without a record, cancelling one job frees a slot the
  fifth then takes, and each paused session receives one completion and makes
  one status call. Simulated provider only.

  Its process check covers each fixture's recorded test pid, not whole process
  groups; LAB-5 owns the stronger orphan check.
  """

  @behaviour Elara.Lab

  alias Elara.Lab.Jobs
  alias Elara.Message
  alias Elara.Provider.Simulated

  @job "focused"

  @impl true
  def run(%{provider: :real}), do: raise("concurrent_jobs runs on the simulated provider only")

  def run(%{seed: seed, dir: dir}) do
    jobs = for n <- 1..5, do: session(Path.join(dir, "job-#{n}"), seed, n)

    try do
      report = exercise(jobs)
      Map.put(report, :cleanup_confirmed, cleanup(jobs))
    rescue
      error ->
        cleanup(jobs)
        reraise error, __STACKTRACE__
    end
  end

  defp exercise(jobs) do
    [cancelled, _, _, _, replacement] = jobs
    initial = Enum.take(jobs, 4)
    survivors = Enum.slice(jobs, 1, 3)
    started = Jobs.now()

    for job <- initial, do: command(job, "start")
    Jobs.await(fn -> Enum.all?(initial, &Jobs.launched?(&1.cwd)) end)
    saturated = Enum.map(initial, &status/1)
    rejected = Jobs.call(replacement.id, replacement.cwd, "start", @job)
    rejected_record = Jobs.record(replacement.id, @job)
    replacement_ran_while_rejected = Jobs.launched?(replacement.cwd)

    cancel_started = Jobs.now()
    command(cancelled, "cancel")
    Jobs.await(fn -> status(cancelled)["slot"] == "released" end)
    cancellation_ms = Jobs.now() - cancel_started
    terminal = status(cancelled)
    Jobs.await(fn -> Jobs.stopped?(cancelled.cwd) end)
    survivors_after_cancel = Enum.map(survivors, &status/1)
    survivors_alive = Enum.all?(survivors, &(not Jobs.stopped?(&1.cwd)))
    {status_us, _} = :timer.tc(fn -> Elara.status(hd(survivors).id) end)

    # There is now global room, so this specifically checks the per-owner limit.
    owner = hd(survivors)
    owner_rejection = Jobs.call(owner.id, owner.cwd, "start", "second")
    owner_rejected_record = Jobs.record(owner.id, "second")

    duplicate_cancel = command(cancelled, "cancel")
    duplicate_start = command(cancelled, "start")
    replacement_start = command(replacement, "start")
    Jobs.await(fn -> Jobs.launched?(replacement.cwd) end)
    refilled = Enum.map(survivors ++ [replacement], &status/1)

    for job <- survivors ++ [replacement], do: Jobs.release(job.cwd)
    Jobs.await(fn -> Enum.all?(jobs, &(status(&1)["slot"] == "released")) end)
    Jobs.await(fn -> Enum.all?(jobs, &Jobs.stopped?(&1.cwd)) end)
    Jobs.await(fn -> Enum.all?(jobs, &(status(&1)["delivery"] == "accepted")) end)
    before_resume = Enum.map(jobs, &Jobs.input_state(&1.id, @job))
    send(Elara.TestJobs, :deliver)

    for job <- jobs do
      :ok = Elara.subscribe(job.id)
      :ok = Elara.resume_inputs(job.id)
    end

    replies = await_replies(MapSet.new(jobs, & &1.id), %{}, Jobs.now() + 60_000)
    # A second delivery pass must not deliver any completion again.
    send(Elara.TestJobs, :deliver)
    Process.sleep(150)
    records = Enum.map(jobs, &status/1)
    histories = Enum.map(jobs, &Elara.transcript(&1.id))
    inputs = Enum.map(jobs, &Jobs.input_state(&1.id, @job))

    checks = %{
      four_slots_held:
        Enum.all?(saturated, &(&1["status"] == "running" and &1["slot"] == "held")),
      fifth_rejected_without_execution:
        match?({:error, _}, rejected) and rejected_record == {:error, :enoent} and
          not replacement_ran_while_rejected,
      cancellation_settled:
        terminal["status"] == "cancelled" and terminal["settlement"] == "settled" and
          terminal["slot"] == "released",
      cancelled_process_stopped: Jobs.stopped?(cancelled.cwd),
      survivors_unaffected:
        survivors_alive and Enum.all?(survivors_after_cancel, &(&1["status"] == "running")),
      per_owner_limit:
        match?({:error, _}, owner_rejection) and owner_rejected_record == {:error, :enoent},
      capacity_refilled:
        replacement_start["status"] == "running" and Enum.all?(refilled, &(&1["slot"] == "held")),
      duplicate_actions_do_not_rerun:
        duplicate_cancel["status"] == "cancelled" and duplicate_start["status"] == "cancelled" and
          Enum.map(jobs, &Jobs.launches(&1.cwd)) == [1, 1, 1, 1, 1],
      terminal_results:
        Enum.map(records, & &1["status"]) == ["cancelled", "passed", "passed", "passed", "passed"],
      all_capacity_released:
        Enum.all?(records, &(&1["slot"] == "released" and &1["settlement"] == "settled")),
      paused_delivery_preserved: Enum.all?(before_resume, &(&1 in [:queued, :accepted])),
      one_consumed_completion_each:
        Enum.all?(inputs, &(&1 == :consumed)) and
          Enum.all?(histories, &(Jobs.inbox_inputs(&1) == 1)),
      model_received_matching_status: Enum.all?(Enum.zip(histories, records), &status_matches?/1),
      one_status_call_each: Enum.map(histories, &Jobs.actions/1) == List.duplicate(["status"], 5),
      every_session_completed:
        map_size(replies) == 5 and Enum.all?(replies, &match?({_, {:ok, _}}, &1)),
      source_unchanged: Enum.all?(records, &(&1["source_changed_now"] == false)),
      all_processes_stopped: Enum.all?(jobs, &Jobs.stopped?(&1.cwd))
    }

    %{
      checks: checks,
      completed_turns: Enum.count(replies, &match?({_, {:ok, _}}, &1)),
      statuses: Enum.map(records, & &1["status"]),
      cancellation_settlement_ms: cancellation_ms,
      survivor_status_latency_ms: status_us / 1000,
      model_elapsed_ms: Jobs.now() - started
    }
  end

  defp session(cwd, seed, n) do
    Jobs.fixture(cwd)

    profile = [
      ttft_ms: 5,
      deltas_per_sec: 1000,
      answer_deltas: 3,
      tool_rounds: 1,
      tool_plan: [{"test_job", %{"action" => "status", "job_id" => @job}}]
    ]

    {:ok, id} =
      Elara.start_session(
        cwd: cwd,
        home: cwd,
        skill_paths: [],
        plugins: [],
        provider: Simulated.new(seed: seed, id: "job-#{n}", profile: profile),
        tools: [Elara.TestJobs.tool()],
        pause_inputs: true,
        max_iterations: 3,
        seed_history: [
          %Message.User{
            text: "The host runs test job #{@job}. On completion inspect its status once."
          }
        ]
      )

    %{id: id, cwd: cwd}
  end

  defp command(job, action), do: Jobs.command(job.id, job.cwd, action, @job)
  defp status(job), do: command(job, "status")

  defp status_matches?({history, record}) do
    results =
      for %Message.ToolResult{name: "test_job", outcome: {:ok, text}} <- history,
          do: JSON.decode!(text)

    match?([_], results) and
      Enum.all?(results, fn result ->
        result["key"] == record["key"] and result["status"] == record["status"] and
          result["source_changed_now"] == false
      end)
  end

  defp await_replies(pending, replies, deadline) do
    if MapSet.size(pending) == 0 do
      replies
    else
      receive do
        {:elara, id, {:turn_ended, outcome}} ->
          outcome =
            if match?({:completed, _}, outcome), do: {:ok, elem(outcome, 1)}, else: outcome

          # A second completion for one session also lands here and is recorded.
          replies = Map.update(replies, id, outcome, fn _ -> :duplicate end)
          await_replies(MapSet.delete(pending, id), replies, deadline)

        _ ->
          await_replies(pending, replies, deadline)
      after
        max(deadline - Jobs.now(), 0) -> raise "model completion deadline exceeded"
      end
    end
  end

  defp cleanup(jobs) do
    settled = Jobs.settle(Enum.map(jobs, &{&1.id, &1.cwd, @job}))
    Enum.each(jobs, &Jobs.stop_session(&1.id))
    settled
  end
end
