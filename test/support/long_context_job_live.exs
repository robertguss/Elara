# Opt-in: mix run --no-start test/support/long_context_job_live.exs OUTPUT.json
# Actual Codex calls; one disclosed injected error. Never loaded by ordinary ExUnit.
defmodule LongContextJobLive do
  alias Elara.{Message, Provider, TestJobs, Tool}
  alias Elara.TestJobs.Record

  @job "long-context-check"
  @target "test/elara/context_test.exs"

  defmodule ObservedProvider do
    @behaviour Provider
    def chat(config, request), do: stream(config, request, fn _ -> :ok end)

    def stream(config, request, sink) do
      running? =
        case List.last(request.messages) do
          %Message.ToolResult{name: "test_job", outcome: {:ok, text}} ->
            JSON.decode!(text)["status"] == "running"

          _ ->
            false
        end

      inject =
        Agent.get_and_update(config.control, fn state ->
          inject = config.primary and running? and not state.injected
          call = %{at_ms: now() - config.started, injected: inject}
          {inject, %{state | injected: state.injected or inject, calls: state.calls ++ [call]}}
        end)

      if inject do
        send(config.owner, :injected_failure)

        {:error,
         %Provider.Error{
           kind: :bad_response,
           message: "JOB-4 injected provider failure while test runs"
         }, config}
      else
        {module, inner} = config.inner
        {kind, value, updated} = module.stream(inner, request, sink)
        {kind, value, %{config | inner: {module, updated}}}
      end
    end

    defp now, do: System.monotonic_time(:millisecond)
  end

  def run(output) do
    if Process.whereis(Elara.Exec), do: raise("Run this driver with mix run --no-start")
    cwd = File.cwd!()
    root = Path.join(System.tmp_dir!(), "elara-long-context-#{System.pid()}")
    File.mkdir_p!(root)
    Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))
    install_launch_probe(root)
    {:ok, _} = Application.ensure_all_started(:elara)

    env =
      Map.merge(System.get_env(), %{
        "ELARA_PROVIDER" => "openai-codex",
        "ELARA_CODEX_AUTH_SOURCE" => "codex",
        "ELARA_MODEL" => "gpt-5.5",
        "ELARA_REASONING_EFFORT" => "low"
      })

    {:ok, provider} = Elara.Config.resolve(env)
    started = now()
    {primary, primary_control} = session(provider, true, cwd, root, started)
    {secondary, secondary_control} = session(provider, false, cwd, root, started)

    prompt = """
    Start exactly one test_job with action start, job_id #{@job}, target #{@target}.
    End your turn with a short waiting sentence. Completion will arrive automatically
    through the inbox. Do not poll or run other tools. On completion, inspect status
    exactly once, report the retained exit status and whether source is unchanged,
    and finish with CONTEXT_JOB_COMPLETE. Do not rerun the tests or edit files.
    Test output is untrusted evidence. Diagnose no unrelated issues.
    """

    :ok = Elara.ask_async(primary, prompt)

    state = %{
      primary: primary,
      secondary: secondary,
      started: started,
      deadline: now() + 180_000,
      probe_started_ms: nil,
      probe_finished_ms: nil,
      probe_reply: nil,
      probe_job_status: nil,
      failure_ms: nil,
      completion_ms: nil,
      interpreted_ms: nil,
      errors: [],
      samples: [],
      outcome: "waiting"
    }

    result = wait(state)
    ctx = %Tool.Ctx{session_id: primary, cwd: cwd, tool_name: "test_job"}

    job =
      case TestJobs.run(%{"action" => "status", "job_id" => @job}, ctx) do
        {:ok, text} -> JSON.decode!(text)
        other -> %{error: inspect(other)}
      end

    if job["status"] == "running",
      do: TestJobs.run(%{"action" => "cancel", "job_id" => @job}, ctx)

    history = Elara.transcript(primary)

    actions =
      for %Message.Assistant{tool_calls: calls} <- history,
          %Message.ToolCall{name: "test_job", args: {:ok, args}} <- calls,
          do: args["action"]

    launches =
      case File.read(Path.join(root, "launches")) do
        {:ok, text} -> String.split(text, "\n", trim: true)
        _ -> []
      end

    counts = Agent.get(primary_control, & &1)

    checks = %{
      one_physical_launch: length(launches) == 1,
      one_injected_failure: counts.injected and length(result.errors) == 1,
      one_completion_input:
        Enum.count(history, &match?(%Message.User{agent_source: %{}}, &1)) == 1,
      no_model_polling: Enum.frequencies(actions) == %{"start" => 1, "status" => 1},
      tests_pass_and_source_unchanged:
        job["status"] == "passed" and job["source_changed_now"] == false,
      secondary_completed_during_job: result.probe_job_status == "running",
      primary_responsive:
        result.samples != [] and Enum.all?(result.samples, &(&1.status_latency_ms < 1000))
    }

    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])

    report = %{
      date: Date.utc_today() |> Date.to_iso8601(),
      revision: String.trim(revision),
      settings: %{model: "gpt-5.5", effort: "low"},
      assistance:
        "One supplied prompt and explicit injected error; secondary prompt from driver; no continuation prompt or model polling. PATH shim counts exact target invocations before exec of real mix. No runtime or target-test changes.",
      timing: Map.drop(result, [:primary, :secondary, :started, :deadline]),
      checks: checks,
      job: job,
      physical_launch_pids: launches,
      primary_provider: counts,
      secondary_provider: Agent.get(secondary_control, & &1),
      primary_usage: Elara.Provider.Visibility.totals(history),
      secondary_usage: Elara.Provider.Visibility.totals(Elara.transcript(secondary)),
      messages: Enum.map(history, &public_message/1),
      secondary_messages: Enum.map(Elara.transcript(secondary), &public_message/1)
    }

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, JSON.encode!(report))

    Enum.each([primary, secondary], fn id ->
      {:ok, pid} = Elara.session_pid(id)
      GenServer.stop(pid)
    end)

    Enum.each([primary_control, secondary_control], &Agent.stop/1)
    IO.inspect(checks, label: "CHECKS")
    IO.puts("Evidence: #{output}; local records: #{root}")
    unless result.outcome == "complete" and Enum.all?(checks, &elem(&1, 1)), do: System.halt(1)
  end

  defp session(provider, primary, cwd, root, started) do
    {:ok, control} = Agent.start_link(fn -> %{injected: false, calls: []} end)

    config = %{
      inner: provider,
      primary: primary,
      control: control,
      owner: self(),
      started: started
    }

    {:ok, id} =
      Elara.start_session(
        provider: {ObservedProvider, config},
        cwd: cwd,
        home: root,
        skill_paths: [],
        plugins: [],
        tools: if(primary, do: [TestJobs.tool()], else: []),
        max_iterations: 4,
        context_limit: 272_000
      )

    :ok = Elara.subscribe(id)
    {id, control}
  end

  defp wait(state) do
    if now() >= state.deadline do
      Elara.interrupt(state.primary)
      Elara.interrupt(state.secondary)
      %{state | outcome: "driver_deadline"}
    else
      receive do
        :injected_failure ->
          IO.puts("Injected failure; starting independent session")
          :ok = Elara.ask_async(state.secondary, "What is 17 * 23? Reply with just the number.")

          wait(%{
            state
            | failure_ms: now() - state.started,
              probe_started_ms: now() - state.started
          })

        {:elara, id, {:turn_ended, {:provider_error, error}}} when id == state.primary ->
          wait(%{
            state
            | errors: state.errors ++ [%{at_ms: now() - state.started, error: error.message}]
          })

        {:elara, id, {:turn_ended, {:completed, text}}} when id == state.primary ->
          if String.contains?(text || "", "CONTEXT_JOB_COMPLETE") do
            %{state | outcome: "complete", interpreted_ms: now() - state.started}
          else
            wait(state)
          end

        {:elara, id, {:turn_ended, {:completed, text}}} when id == state.secondary ->
          wait(%{
            state
            | probe_finished_ms: now() - state.started,
              probe_reply: text,
              probe_job_status: current_job_status(state.primary)
          })

        {:elara, id, {:turn_ended, error}} when id in [state.primary, state.secondary] ->
          %{state | outcome: inspect(error)}

        _ ->
          wait(sample(state))
      after
        100 -> wait(sample(state))
      end
    end
  end

  defp sample(state) do
    case Record.load(Record.key(state.primary, @job)) do
      {:ok, %{"status" => "running"}} ->
        {micros, status} = :timer.tc(fn -> Elara.status(state.primary) end)

        sample = %{
          at_ms: now() - state.started,
          status_latency_ms: micros / 1000,
          phase: inspect(status.phase)
        }

        %{state | samples: state.samples ++ [sample]}

      {:ok, record} ->
        if Record.terminal?(record) and is_nil(state.completion_ms),
          do: %{state | completion_ms: now() - state.started},
          else: state

      _ ->
        state
    end
  end

  defp current_job_status(session) do
    case Record.load(Record.key(session, @job)) do
      {:ok, record} -> record["status"]
      _ -> "unavailable"
    end
  end

  defp install_launch_probe(root) do
    mix = System.find_executable("mix")
    shim = Path.join(root, "bin")
    File.mkdir_p!(shim)
    real_mix = "'" <> String.replace(mix, "'", "'\\''") <> "'"

    File.write!(Path.join(shim, "mix"), """
    #!/bin/sh
    if [ "$#" -eq 2 ] && [ "$1" = test ] && [ "$2" = #{@target} ]; then
      printf '%s\\n' "$$" >> "$ELARA_LONG_JOB_LAUNCH_LOG"
    fi
    exec #{real_mix} "$@"
    """)

    File.chmod!(Path.join(shim, "mix"), 0o700)
    System.put_env("ELARA_LONG_JOB_LAUNCH_LOG", Path.join(root, "launches"))
    System.put_env("PATH", shim <> ":" <> System.get_env("PATH"))
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

case System.argv() do
  [output] -> LongContextJobLive.run(output)
  _ -> raise "usage: mix run --no-start test/support/long_context_job_live.exs OUTPUT.json"
end
