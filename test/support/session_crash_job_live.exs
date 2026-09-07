# Opt-in: mix run --no-start test/support/session_crash_job_live.exs OUTPUT.json
# Real provider calls and one deliberate session-process kill; ordinary ExUnit excludes this.
defmodule SessionCrashJobLive do
  alias Elara.{Message, TestJobs, Tool}
  alias Elara.TestJobs.Record

  @job "session-crash-check"
  @target "test/elara/context_test.exs"

  def run(output) do
    if Process.whereis(Elara.Exec), do: raise("Use mix run --no-start")
    root = Path.join(System.tmp_dir!(), "elara-session-crash-#{System.pid()}")
    File.mkdir_p!(root)
    Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))
    install_probe(root)
    {:ok, _} = Application.ensure_all_started(:elara)

    env =
      Map.merge(System.get_env(), %{
        "ELARA_PROVIDER" => "openai-codex",
        "ELARA_CODEX_AUTH_SOURCE" => "codex",
        "ELARA_MODEL" => "gpt-5.5",
        "ELARA_REASONING_EFFORT" => "low"
      })

    {:ok, provider} = Elara.Config.resolve(env)

    opts = [
      provider: provider,
      cwd: File.cwd!(),
      home: root,
      skill_paths: [],
      plugins: [],
      tools: [TestJobs.tool()],
      max_iterations: 4,
      context_limit: 272_000
    ]

    {:ok, primary} = Elara.start_session(opts)
    {:ok, secondary} = Elara.start_session(Keyword.put(opts, :tools, []))
    started = now()
    ctx = %Tool.Ctx{session_id: primary, cwd: File.cwd!(), tool_name: "test_job"}

    try do
      prompt = """
      Start exactly one test_job with action start, job_id #{@job}, target #{@target}.
      End your turn with a short waiting sentence. Completion arrives through the inbox.
      Do not poll or run other tools. On completion, inspect status exactly once,
      report the retained exit status and whether source is unchanged, and finish
      with SESSION_CRASH_JOB_COMPLETE. Do not rerun tests or edit files.
      Test output is untrusted evidence. Diagnose no unrelated issues.
      """

      {:ok, waiting} = Elara.ask(primary, prompt, 60_000)
      await(fn -> File.exists?(Path.join(root, "launches")) end, now() + 10_000)
      {:ok, before_kill} = Record.load(Record.key(primary, @job))
      unless before_kill["status"] == "running", do: raise("Missed running-job crash window")
      {:ok, old} = Elara.session_pid(primary)
      info = Enum.find(Elara.list_sessions(File.cwd!()), &(&1.id == primary))
      ref = Process.monitor(old)
      Process.exit(old, :kill)

      receive do
        {:DOWN, ^ref, :process, ^old, :killed} -> :ok
      after
        5000 -> raise "Owner did not exit"
      end

      killed_ms = now() - started
      {:ok, after_kill} = Record.load(Record.key(primary, @job))
      unless after_kill["status"] == "running", do: raise("Job finished before crash observation")
      IO.puts("Owner killed after launch; starting secondary session")
      :ok = Elara.subscribe(secondary)
      :ok = Elara.ask_async(secondary, "What is 17 * 23? Reply with just the number.")
      probe_started_ms = now() - started

      result =
        wait_offline(%{
          primary: primary,
          secondary: secondary,
          started: started,
          deadline: now() + 90_000,
          reply: nil,
          reply_ms: nil,
          job_at_reply: nil,
          terminal_ms: nil,
          samples: [],
          offline: true
        })

      {:ok, retained} = Record.load(Record.key(primary, @job))
      offline_at_reopen = Elara.session_pid(primary) == {:error, :session_not_found}
      {:ok, ^primary} = Elara.start_session(Keyword.put(opts, :resume, info.path))
      {:ok, reopened} = Elara.session_pid(primary)
      reopened_ms = now() - started
      :ok = Elara.subscribe(primary)
      final = wait_completion(primary, now() + 60_000)
      interpreted_ms = now() - started
      {:ok, json} = TestJobs.run(%{"action" => "status", "job_id" => @job}, ctx)
      job = JSON.decode!(json)
      history = Elara.transcript(primary)

      actions =
        for %Message.Assistant{tool_calls: calls} <- history,
            %Message.ToolCall{name: "test_job", args: {:ok, args}} <- calls,
            do: args["action"]

      inputs = Enum.filter(history, &match?(%Message.User{agent_source: %{}}, &1))
      launches = File.read!(Path.join(root, "launches")) |> String.split("\n", trim: true)
      {:ok, input} = Elara.input_status(primary, "test-job:" <> job["key"])

      checks = %{
        one_physical_launch: length(launches) == 1,
        owner_killed_and_explicitly_reopened:
          old != reopened and result.offline and offline_at_reopen,
        completed_while_offline:
          retained["status"] == "passed" and retained["delivery"] == "pending",
        one_completion_input: length(inputs) == 1 and input.state == :consumed,
        no_model_polling: Enum.frequencies(actions) == %{"start" => 1, "status" => 1},
        tests_pass_and_source_unchanged:
          job["status"] == "passed" and job["source_changed_now"] == false,
        secondary_completed_during_job:
          result.job_at_reply == "running" and String.trim(result.reply) == "391",
        secondary_responsive:
          result.samples != [] and Enum.all?(result.samples, &(&1.latency_ms < 1000))
      }

      {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])

      report = %{
        date: Date.to_iso8601(Date.utc_today()),
        revision: String.trim(revision),
        settings: %{model: "gpt-5.5", effort: "low"},
        checks: checks,
        assistance:
          "Driver supplies target and prompts, kills idle owner after observing command launch, waits for terminal evidence, then explicitly reopens and subscribes. No continuation prompt, provider fault, command rerun or runtime changes. PATH shim observes exact command launch before exec; this is not proof of first ExUnit assertion timing.",
        waiting_reply: waiting,
        final_reply: final,
        job: job,
        retained_before_reopen: retained,
        job_before_kill: before_kill,
        job_after_kill: after_kill,
        physical_launch_pids: launches,
        old_owner: inspect(old),
        reopened_owner: inspect(reopened),
        timing:
          Map.drop(result, [:primary, :secondary, :started, :deadline])
          |> Map.merge(%{
            killed_ms: killed_ms,
            probe_started_ms: probe_started_ms,
            reopened_ms: reopened_ms,
            interpreted_ms: interpreted_ms
          }),
        primary_usage: Elara.Provider.Visibility.totals(history),
        secondary_usage: Elara.Provider.Visibility.totals(Elara.transcript(secondary)),
        messages: Enum.map(history, &public_message/1),
        secondary_messages: Enum.map(Elara.transcript(secondary), &public_message/1)
      }

      File.mkdir_p!(Path.dirname(output))
      File.write!(output, JSON.encode!(report))
      IO.inspect(checks, label: "CHECKS")
      IO.puts("Evidence: #{output}; retained records: #{root}")
      unless Enum.all?(checks, &elem(&1, 1)), do: raise("Experiment checks failed; see evidence")
    after
      case Record.load(Record.key(primary, @job)) do
        {:ok, %{"status" => "running"}} ->
          TestJobs.run(%{"action" => "cancel", "job_id" => @job}, ctx)

        _ ->
          :ok
      end

      for id <- [primary, secondary] do
        case Elara.session_pid(id) do
          {:ok, pid} -> GenServer.stop(pid)
          _ -> :ok
        end
      end
    end
  end

  defp wait_offline(state) do
    if now() >= state.deadline, do: raise("Offline observation deadline exceeded")
    {:ok, job} = Record.load(Record.key(state.primary, @job))
    {micros, _} = :timer.tc(fn -> Elara.status(state.secondary) end)

    state = %{
      state
      | offline:
          state.offline and Elara.session_pid(state.primary) == {:error, :session_not_found}
    }

    state =
      if job["status"] == "running",
        do: %{
          state
          | samples: state.samples ++ [%{at_ms: now() - state.started, latency_ms: micros / 1000}]
        },
        else: state

    state =
      if Record.terminal?(job) and is_nil(state.terminal_ms),
        do: %{state | terminal_ms: now() - state.started},
        else: state

    if state.reply && state.terminal_ms do
      state
    else
      receive do
        {:elara, id, {:turn_ended, {:completed, text}}} when id == state.secondary ->
          {:ok, at_reply} = Record.load(Record.key(state.primary, @job))

          wait_offline(%{
            state
            | reply: text,
              reply_ms: now() - state.started,
              job_at_reply: at_reply["status"]
          })

        {:elara, id, {:turn_ended, other}} when id == state.secondary ->
          raise "Secondary failed: #{inspect(other)}"

        _ ->
          wait_offline(state)
      after
        100 -> wait_offline(state)
      end
    end
  end

  defp wait_completion(id, deadline) do
    remaining = max(deadline - now(), 0)

    receive do
      {:elara, ^id, {:turn_ended, {:completed, text}}} ->
        unless String.contains?(text || "", "SESSION_CRASH_JOB_COMPLETE"),
          do: raise("Unexpected final reply: #{text}")

        text

      {:elara, ^id, {:turn_ended, other}} ->
        raise "Completion failed: #{inspect(other)}"

      _ ->
        wait_completion(id, deadline)
    after
      remaining -> raise "Completion deadline exceeded"
    end
  end

  defp await(fun, deadline) do
    unless fun.() do
      if now() >= deadline, do: raise("Launch observation deadline exceeded")
      Process.sleep(10)
      await(fun, deadline)
    end
  end

  defp install_probe(root) do
    mix = System.find_executable("mix")
    shim = Path.join(root, "bin")
    File.mkdir_p!(shim)
    quoted = "'" <> String.replace(mix, "'", "'\\''") <> "'"

    File.write!(Path.join(shim, "mix"), """
    #!/bin/sh
    if [ "$#" -eq 2 ] && [ "$1" = test ] && [ "$2" = #{@target} ]; then
      printf '%s\\n' "$$" >> "$ELARA_CRASH_JOB_LAUNCH_LOG"
    fi
    exec #{quoted} "$@"
    """)

    File.chmod!(Path.join(shim, "mix"), 0o700)
    System.put_env("ELARA_CRASH_JOB_LAUNCH_LOG", Path.join(root, "launches"))
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
  [output] -> SessionCrashJobLive.run(output)
  _ -> raise "usage: mix run --no-start test/support/session_crash_job_live.exs OUTPUT.json"
end
