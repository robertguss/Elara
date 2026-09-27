defmodule Elara.Lab.Scenarios.SessionCrash do
  @moduledoc """
  JOB-5 as a lab scenario: an idle owner session is killed while its test job is
  provably running. The job completes while the owner is offline, a second
  session stays responsive meanwhile, and the explicitly reopened owner
  consumes exactly one completion. Simulated provider only.
  """

  @behaviour Elara.Lab

  alias Elara.Lab.{Faults, Jobs}
  alias Elara.Message
  alias Elara.Provider.Simulated

  @job "session-crash-check"

  @impl true
  def run(%{provider: :real}), do: raise("session_crash runs on the simulated provider only")

  def run(%{seed: seed, dir: dir}) do
    cwd = Path.join(dir, "workspace")
    Jobs.fixture(cwd)

    opts = [
      cwd: cwd,
      home: dir,
      skill_paths: [],
      plugins: [],
      tools: [Elara.TestJobs.tool()],
      max_iterations: 4,
      provider: Simulated.new(seed: seed, id: "primary", profile: profile(rules()))
    ]

    {:ok, primary} = Elara.start_session(opts)

    {:ok, secondary} =
      Elara.start_session(
        Keyword.merge(opts,
          tools: [],
          provider: Simulated.new(seed: seed, id: "secondary", profile: profile([]))
        )
      )

    try do
      report = exercise(primary, secondary, cwd, opts)
      Map.put(report, :cleanup_confirmed, cleanup(primary, secondary, cwd))
    rescue
      error ->
        cleanup(primary, secondary, cwd)
        reraise error, __STACKTRACE__
    end
  end

  defp exercise(primary, secondary, cwd, opts) do
    started = Jobs.now()
    {:ok, _waiting} = Elara.ask(primary, "Start the #{@job} test job, then wait for completion.")
    Jobs.await(fn -> Jobs.launched?(cwd) end)
    {:ok, before_kill} = Jobs.record(primary, @job)
    info = Enum.find(Elara.list_sessions(cwd), &(&1.id == primary))
    {:ok, old} = Elara.session_pid(primary)
    ref = Process.monitor(old)
    :ok = Faults.inject({:session, primary})

    killed =
      receive do
        {:DOWN, ^ref, :process, ^old, :killed} -> true
      after
        5000 -> false
      end

    killed_ms = Jobs.now() - started
    {:ok, after_kill} = Jobs.record(primary, @job)

    # The job is gated, so the secondary's turn provably overlaps it.
    :ok = Elara.subscribe(secondary)
    :ok = Elara.ask_async(secondary, "Reply while the other session is down.")
    probe = observe_secondary(primary, secondary, [], Jobs.now() + 30_000)
    Jobs.release(cwd)

    Jobs.await(fn ->
      match?({:ok, %{"status" => s}} when s != "running", Jobs.record(primary, @job))
    end)

    offline_at_terminal = Elara.session_pid(primary) == {:error, :session_not_found}
    {:ok, retained} = Jobs.record(primary, @job)

    {:ok, ^primary} = Elara.start_session(Keyword.put(opts, :resume, info.path))
    {:ok, reopened} = Elara.session_pid(primary)
    send(Elara.TestJobs, :deliver)
    Jobs.await(fn -> interpreted?(primary) end, 30_000)
    interpreted_ms = Jobs.now() - started
    job = Jobs.command(primary, cwd, "status", @job)
    history = Elara.transcript(primary)

    checks = %{
      job_running_across_kill:
        before_kill["status"] == "running" and after_kill["status"] == "running",
      one_physical_launch: Jobs.launches(cwd) == 1,
      owner_killed_and_explicitly_reopened: killed and old != reopened and offline_at_terminal,
      completed_while_offline:
        retained["status"] == "passed" and retained["delivery"] == "pending",
      one_completion_input:
        Jobs.inbox_inputs(history) == 1 and Jobs.input_state(primary, @job) == :consumed,
      no_model_polling: Enum.frequencies(Jobs.actions(history)) == %{"start" => 1, "status" => 1},
      tests_pass_and_source_unchanged:
        job["status"] == "passed" and job["source_changed_now"] == false,
      secondary_completed_during_job:
        match?({:completed, _}, probe.outcome) and probe.job_at_reply == "running",
      secondary_responsive: probe.samples != [] and Enum.all?(probe.samples, &(&1 < 1000))
    }

    %{
      checks: checks,
      completed_turns: 2 + if(match?({:completed, _}, probe.outcome), do: 1, else: 0),
      killed_ms: killed_ms,
      interpreted_ms: interpreted_ms,
      secondary_status_ms: Elara.Lab.percentiles(probe.samples)
    }
  end

  # The simulated primary starts the job on the host's prompt and inspects its
  # status once on completion; every other request is answered.
  defp rules do
    [
      {fn messages -> match?(%Message.User{agent_source: nil}, List.last(messages)) end,
       {:tool, "test_job", %{"action" => "start", "job_id" => @job, "target" => Jobs.target()}}},
      {fn messages -> match?(%Message.User{agent_source: %{}}, List.last(messages)) end,
       {:tool, "test_job", %{"action" => "status", "job_id" => @job}}}
    ]
  end

  defp profile(rules), do: [ttft_ms: 5, deltas_per_sec: 1000, answer_deltas: 3, rules: rules]

  defp observe_secondary(primary, secondary, samples, deadline) do
    {micros, _} = :timer.tc(fn -> Elara.status(secondary) end)
    samples = [micros / 1000 | samples]

    receive do
      {:elara, ^secondary, {:turn_ended, outcome}} ->
        {:ok, record} = Jobs.record(primary, @job)
        %{outcome: outcome, job_at_reply: record["status"], samples: Enum.reverse(samples)}
    after
      min(100, max(deadline - Jobs.now(), 0)) ->
        if Jobs.now() >= deadline,
          do: %{outcome: :deadline, job_at_reply: nil, samples: Enum.reverse(samples)},
          else: observe_secondary(primary, secondary, samples, deadline)
    end
  end

  defp interpreted?(session) do
    history = Elara.transcript(session)

    Jobs.input_state(session, @job) == :consumed and "status" in Jobs.actions(history) and
      match?(%Message.Assistant{tool_calls: []}, List.last(history))
  end

  defp cleanup(primary, secondary, cwd) do
    settled = Jobs.settle([{primary, cwd, @job}])
    Enum.each([primary, secondary], &Jobs.stop_session/1)
    settled
  end
end
