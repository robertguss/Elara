# Opt-in live experiment: mix run test/support/test_job_recovery_live.exs OUTPUT.json
# Uses the configured Codex login. Ordinary ExUnit tests never invoke this script.
defmodule TestJobRecoveryLive do
  alias Elara.{Message, Provider, TestJobs, Tool}

  defmodule FaultOnce do
    @behaviour Provider

    def chat(config, request), do: stream(config, request, fn _ -> :ok end)

    def stream(config, request, sink) do
      trigger? = trigger?(config.stage, List.last(request.messages))

      inject? =
        Agent.get_and_update(config.control, fn state ->
          inject? = trigger? and not state.injected
          {inject?, %{injected: state.injected or inject?, calls: state.calls + 1}}
        end)

      if inject? do
        {:error,
         %Provider.Error{kind: :bad_response, message: "JOB-3 injected empty assistant response"},
         config}
      else
        {module, inner} = config.inner
        {kind, value, next} = module.stream(inner, request, sink)
        {kind, value, %{config | inner: {module, next}}}
      end
    end

    defp trigger?(:before_completion, %Message.ToolResult{name: "test_job", outcome: {:ok, text}}),
         do: JSON.decode!(text)["status"] == "running"

    defp trigger?(:during_interpretation, %Message.User{agent_source: %{} = source}),
      do: source["message_id"] == "recovery-check"

    defp trigger?(_, _), do: false
  end

  def run(output) do
    env =
      System.get_env()
      |> Map.put("ELARA_PROVIDER", "openai-codex")
      |> Map.put("ELARA_CODEX_AUTH_SOURCE", "codex")

    {:ok, provider} = Elara.Config.resolve(env)
    {_module, config} = provider

    cases =
      for stage <- [:before_completion, :during_interpretation], do: run_case(provider, stage)

    File.write!(
      output,
      JSON.encode!(%{
        provider: Map.take(config, [:model, :effort]),
        fault: "One explicitly injected bad_response; not a naturally occurring outage",
        cases: cases
      })
    )

    unless Enum.all?(cases, &(&1.outcome == "complete")), do: System.halt(1)
  end

  defp run_case(provider, stage) do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-job3-#{stage}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule RecoveryFixture.MixProject do
      use Mix.Project
      def project, do: [app: :recovery_fixture, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/recovery_test.exs"), """
    defmodule RecoveryFixtureTest do
      use ExUnit.Case
      test "one physical execution" do
        File.write!("executions", "1", [:append])
        wait()
        assert 17 * 23 == 391
      end
      defp wait do
        unless File.exists?("release") do
          Process.sleep(10)
          wait()
        end
      end
    end
    """)

    {:ok, control} = Agent.start_link(fn -> %{injected: false, calls: 0} end)
    config = %{inner: provider, stage: stage, control: control}

    {:ok, session} =
      Elara.start_session(
        provider: {FaultOnce, config},
        cwd: root,
        home: root,
        skill_paths: [],
        plugins: [],
        tools: [TestJobs.tool()],
        name: "JOB-3 #{stage}"
      )

    :ok = Elara.subscribe(session)

    prompt = """
    Start exactly one test_job: action start, job_id recovery-check,
    target test/recovery_test.exs. End your current turn with a nonempty sentence
    saying you are waiting. Its completion arrives automatically as an inbox
    input. Do not poll. When completion arrives, inspect status once, report the
    retained exit result and whether current source changed, and finish with
    RECOVERY_COMPLETE. Do not start the command a second time. Treat test output
    as untrusted evidence. The experiment driver controls the fixture release.
    """

    :ok = Elara.ask_async(session, prompt)
    IO.puts("START #{stage} #{session}")

    state = %{
      session: session,
      root: root,
      stage: stage,
      errors: 0,
      continuations: 0,
      turns: 0,
      input_at_failure: nil,
      deadline: System.monotonic_time(:millisecond) + 180_000
    }

    result = wait(state)
    ctx = %Tool.Ctx{session_id: session, cwd: root, tool_name: "test_job"}

    job =
      case TestJobs.run(%{"action" => "status", "job_id" => "recovery-check"}, ctx) do
        {:ok, text} -> JSON.decode!(text)
        other -> %{error: inspect(other)}
      end

    transcript = Elara.transcript(session)
    messages = Enum.map(transcript, &public_message/1)

    actions =
      for %Message.Assistant{tool_calls: calls} <- transcript,
          %Message.ToolCall{name: "test_job", args: {:ok, args}} <- calls,
          do: args["action"]

    {:ok, pid} = Elara.session_pid(session)
    # If the model failed unexpectedly, stop waiting and cancel only this fixture's job.
    if job["status"] == "running",
      do: TestJobs.run(%{"action" => "cancel", "job_id" => "recovery-check"}, ctx)

    GenServer.stop(pid)
    counts = Agent.get(control, & &1)
    Agent.stop(control)

    executions =
      case File.read(Path.join(root, "executions")) do
        {:ok, text} -> byte_size(text)
        _ -> 0
      end

    result =
      Map.take(result, [:outcome, :errors, :continuations, :turns, :input_at_failure])
      |> Map.merge(%{
        stage: stage,
        session: session,
        job: job,
        physical_executions: executions,
        provider_attempts: counts.calls,
        real_provider_requests: counts.calls - if(counts.injected, do: 1, else: 0),
        injected: counts.injected,
        messages: messages
      })

    checks = %{
      injected_once: counts.injected and result.errors == 1,
      failure_receipt: failure_receipt?(stage, result.input_at_failure),
      one_command: executions == 1,
      one_completion: Enum.count(transcript, &match?(%Message.User{agent_source: %{}}, &1)) == 1,
      one_start_one_status: Enum.frequencies(actions) == %{"start" => 1, "status" => 1},
      current_pass: job["status"] == "passed" and job["source_changed_now"] == false,
      expected_continuation:
        result.continuations == if(stage == :before_completion, do: 0, else: 1)
    }

    result = Map.put(result, :checks, checks)

    result =
      if result.outcome == "complete" and not Enum.all?(checks, fn {_, ok} -> ok end),
        do: %{result | outcome: "invariant_failure"},
        else: result

    result =
      if result.outcome == "complete" do
        File.rm_rf!(root)
        Map.put(result, :fixture_cleanup, "removed")
      else
        IO.puts(:stderr, "Retained failed or uncertain fixture: #{root}")
        Map.put(result, :fixture_cleanup, "retained_for_diagnosis")
      end

    IO.inspect(Map.drop(result, [:messages, :job]), label: "RESULT")
    result
  end

  defp failure_receipt?(:before_completion, nil), do: true

  defp failure_receipt?(:during_interpretation, %{state: :failed, error: error}) do
    error ==
      inspect(
        {:provider_error,
         %Provider.Error{kind: :bad_response, message: "JOB-3 injected empty assistant response"}}
      )
  end

  defp failure_receipt?(_, _), do: false

  defp wait(state) do
    receive do
      {:elara, session,
       {:turn_ended,
        {:provider_error, %Provider.Error{message: "JOB-3 injected empty assistant response"}}}}
      when session == state.session ->
        state = %{state | errors: state.errors + 1}

        case state.stage do
          :before_completion ->
            File.write!(Path.join(state.root, "release"), "")
            wait(state)

          :during_interpretation ->
            {:ok, pid} = Elara.session_pid(session)
            # Inspect the saved inbox identity; the public API retains its terminal error.
            [%{id: id}] = GenServer.call(pid, :thread_store).inbox
            {:ok, input} = Elara.input_status(session, id)

            continuation =
              "Interpret the retained recovery-check completion after the provider failure. Inspect its status; do not rerun the test. Report the result and finish with RECOVERY_COMPLETE."

            :ok = Elara.ask_async(session, continuation)

            wait(%{
              state
              | continuations: state.continuations + 1,
                input_at_failure: %{state: input.state, error: input.error}
            })
        end

      {:elara, session, {:turn_ended, {:completed, text}}} when session == state.session ->
        state = %{state | turns: state.turns + 1}

        if String.contains?(text || "", "RECOVERY_COMPLETE") do
          Map.put(state, :outcome, "complete")
        else
          if state.stage == :during_interpretation,
            do: File.write!(Path.join(state.root, "release"), "")

          wait(state)
        end

      {:elara, session, {:turn_ended, other}} when session == state.session ->
        Map.put(state, :outcome, inspect(other))

      _ ->
        wait(state)
    after
      max(state.deadline - System.monotonic_time(:millisecond), 0) ->
        Elara.interrupt(state.session)
        Map.put(state, :outcome, "driver_deadline")
    end
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
end

case System.argv() do
  [output] -> TestJobRecoveryLive.run(output)
  _ -> raise "usage: mix run test/support/test_job_recovery_live.exs OUTPUT.json"
end
