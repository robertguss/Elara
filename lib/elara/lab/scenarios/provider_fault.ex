defmodule Elara.Lab.Scenarios.ProviderFault do
  @moduledoc """
  JOB-3 and JOB-4 as a lab scenario: one scripted `bad_response` while a test job
  runs, in two cases. `before_completion` fails the turn that started the job;
  its completion still arrives and is interpreted with no continuation.
  `during_interpretation` fails the completion's own turn; the input keeps a
  failed receipt and one explicit continuation interprets the retained result.
  In both, a second session completes a turn while the job runs. Simulated
  provider only.
  """

  @behaviour Elara.Lab

  alias Elara.Lab.Jobs
  alias Elara.Message
  alias Elara.Provider
  alias Elara.Provider.Simulated

  @job "recovery-check"
  @stages [:before_completion, :during_interpretation]
  @fault %Provider.Error{kind: :bad_response, message: "lab injected empty assistant response"}
  @start "Start the recovery-check test job, then wait for completion."
  @continue "Interpret the retained recovery-check completion; do not rerun it."

  @impl true
  def run(%{provider: :real}), do: raise("provider_fault runs on the simulated provider only")

  def run(%{seed: seed, dir: dir}) do
    cases = Map.new(@stages, &{&1, run_case(&1, seed, Path.join(dir, Atom.to_string(&1)))})

    %{
      checks:
        for(
          {stage, result} <- cases,
          {name, ok} <- result.checks,
          into: %{},
          do: {:"#{stage}.#{name}", ok}
        ),
      completed_turns: cases |> Map.values() |> Enum.map(& &1.completed_turns) |> Enum.sum(),
      cleanup_confirmed: Enum.all?(Map.values(cases), & &1.cleanup_confirmed),
      interpreted_ms: Map.new(cases, fn {stage, result} -> {stage, result.interpreted_ms} end)
    }
  end

  defp run_case(stage, seed, cwd) do
    Jobs.fixture(cwd)

    base = [cwd: cwd, home: cwd, skill_paths: [], plugins: [], max_iterations: 4]
    primary_provider = Simulated.new(seed: seed, id: "#{stage}", profile: profile(rules(stage)))

    {:ok, primary} =
      Elara.start_session(base ++ [provider: primary_provider, tools: [Elara.TestJobs.tool()]])

    secondary_provider = Simulated.new(seed: seed, id: "#{stage}-secondary", profile: profile([]))
    {:ok, secondary} = Elara.start_session(base ++ [provider: secondary_provider, tools: []])

    try do
      result = exercise(stage, primary, secondary, cwd)
      Map.put(result, :cleanup_confirmed, cleanup(primary, secondary, cwd))
    rescue
      error ->
        cleanup(primary, secondary, cwd)
        reraise error, __STACKTRACE__
    end
  end

  defp exercise(stage, primary, secondary, cwd) do
    started = Jobs.now()
    :ok = Elara.subscribe(primary)
    :ok = Elara.ask_async(primary, @start)
    first = await_turn(primary)
    Jobs.await(fn -> Jobs.launched?(cwd) end)

    # The job is gated, so this turn provably overlaps it.
    secondary_reply = Elara.ask(secondary, "Reply while the job runs.")
    {:ok, at_reply} = Jobs.record(primary, @job)
    Jobs.release(cwd)

    {second, receipt, continuations} =
      case stage do
        :before_completion ->
          {await_turn(primary), nil, 0}

        :during_interpretation ->
          failed = await_turn(primary)
          # turn_ended is broadcast before the session settles the input's
          # receipt, which reads :consumed from dequeue until then.
          input = await_receipt(primary)
          :ok = Elara.ask_async(primary, @continue)
          {[failed, await_turn(primary)], input, 1}
      end

    turns = List.flatten([first, second])
    errors = Enum.count(turns, &match?({:provider_error, _}, &1))
    job = Jobs.command(primary, cwd, "status", @job)
    history = Elara.transcript(primary)

    checks = %{
      injected_once: errors == 1 and :deadline not in turns,
      failure_receipt: failure_receipt?(stage, receipt),
      one_command: Jobs.launches(cwd) == 1,
      one_completion: Jobs.inbox_inputs(history) == 1,
      one_start_one_status:
        Enum.frequencies(Jobs.actions(history)) == %{"start" => 1, "status" => 1},
      interpreted: match?({:completed, _}, List.last(turns)),
      current_pass: job["status"] == "passed" and job["source_changed_now"] == false,
      expected_continuation: continuations == if(stage == :before_completion, do: 0, else: 1),
      secondary_progressed_during_job:
        match?({:ok, _}, secondary_reply) and at_reply["status"] == "running"
    }

    %{
      checks: checks,
      completed_turns: Enum.count(turns, &match?({:completed, _}, &1)) + 1,
      interpreted_ms: Jobs.now() - started
    }
  end

  # The fault fires on one request shape: the start's running result, or the
  # completion input. Every other request follows the job protocol.
  defp rules(stage) do
    start =
      {:tool, "test_job", %{"action" => "start", "job_id" => @job, "target" => Jobs.target()}}

    status = {:tool, "test_job", %{"action" => "status", "job_id" => @job}}

    case stage do
      :before_completion ->
        [
          {&last_user?(&1, @start), start},
          {&running_result?/1, {:error, @fault}},
          {&completion?/1, status}
        ]

      :during_interpretation ->
        [
          {&last_user?(&1, @start), start},
          {&completion?/1, {:error, @fault}},
          {&last_user?(&1, @continue), status}
        ]
    end
  end

  defp last_user?(messages, text),
    do: match?(%Message.User{text: ^text, agent_source: nil}, List.last(messages))

  defp completion?(messages), do: match?(%Message.User{agent_source: %{}}, List.last(messages))

  defp running_result?(messages) do
    case List.last(messages) do
      %Message.ToolResult{name: "test_job", outcome: {:ok, text}} ->
        JSON.decode!(text)["status"] == "running"

      _ ->
        false
    end
  end

  defp profile(rules), do: [ttft_ms: 5, deltas_per_sec: 1000, answer_deltas: 3, rules: rules]

  defp await_receipt(session) do
    key = "test-job:" <> Elara.TestJobs.Record.key(session, @job)
    read = fn -> elem(Elara.input_status(session, key), 1) end

    try do
      Jobs.await(fn -> match?(%{state: :failed}, read.()) end, 2_000)
    rescue
      _ -> :ok
    end

    read.()
  end

  defp failure_receipt?(:before_completion, nil), do: true

  defp failure_receipt?(:during_interpretation, %{state: :failed, error: error}),
    do: error == inspect({:provider_error, @fault})

  defp failure_receipt?(_, _), do: false

  defp await_turn(session) do
    receive do
      {:elara, ^session, {:turn_ended, outcome}} -> outcome
    after
      30_000 -> :deadline
    end
  end

  defp cleanup(primary, secondary, cwd) do
    settled = Jobs.settle([{primary, cwd, @job}])
    Enum.each([primary, secondary], &Jobs.stop_session/1)
    settled
  end
end
