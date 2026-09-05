defmodule Elara.Coordinator.Engine do
  @moduledoc false

  alias Elara.Coordinator.{Result, Run}

  def run(owner, run_id, run_root, child_sup, config, pattern, specs, opts) do
    started_at = now_ms()
    opts = Keyword.put(opts, :run_deadline, started_at + config.time_budget_ms)

    with :ok <- validate_child_specs(pattern, specs, opts),
         :ok <- validate_unique_ids(pattern, specs, opts),
         {:ok, history} <- seed_history(config.parent, Keyword.get(opts, :history, :clone)),
         {:ok, phase} <-
           run_phase(owner, run_id, run_root, child_sup, config, specs, history, opts, 0) do
      finish_pattern(
        owner,
        run_id,
        run_root,
        child_sup,
        config,
        pattern,
        phase,
        history,
        opts,
        started_at
      )
    end
  end

  defp finish_pattern(
         _owner,
         _run_id,
         _run_root,
         _child_sup,
         _config,
         pattern,
         phase,
         _history,
         _opts,
         started_at
       )
       when pattern in [:parallel, :specialists] do
    {:ok, build_run(pattern, phase, nil, nil, started_at)}
  end

  defp finish_pattern(
         owner,
         run_id,
         run_root,
         child_sup,
         config,
         :candidates,
         phase,
         history,
         opts,
         started_at
       ) do
    with judge when is_map(judge) <- Keyword.get(opts, :judge),
         judge_prompt <- Map.fetch!(judge, :prompt) <> result_context(phase.results),
         judge <- Map.put(judge, :prompt, judge_prompt),
         {:ok, judged} <-
           run_phase(
             owner,
             run_id,
             run_root,
             child_sup,
             config,
             [judge],
             history,
             opts,
             phase.token_estimate
           ) do
      judge_result = List.first(judged.results)
      selected = select_candidate(judge_result, phase.results)
      combined = combine_phases(phase, judged)
      {:ok, build_run(:candidates, combined, selected, judge_result, started_at)}
    else
      nil -> {:error, :judge_required}
      error -> error
    end
  end

  defp finish_pattern(
         owner,
         run_id,
         run_root,
         child_sup,
         config,
         :map_reduce,
         phase,
         history,
         opts,
         started_at
       ) do
    with reducer when is_map(reducer) <- Keyword.get(opts, :reducer),
         reduce_prompt <- Map.fetch!(reducer, :prompt) <> result_context(phase.results),
         reducer <- Map.put(reducer, :prompt, reduce_prompt),
         {:ok, reduced} <-
           run_phase(
             owner,
             run_id,
             run_root,
             child_sup,
             config,
             [reducer],
             history,
             opts,
             phase.token_estimate
           ) do
      reducer_result = List.first(reduced.results)
      combined = combine_phases(phase, reduced)

      {:ok,
       build_run(
         :map_reduce,
         combined,
         reducer_result && reducer_result.answer,
         reducer_result,
         started_at
       )}
    else
      nil -> {:error, :reducer_required}
      error -> error
    end
  end

  defp run_phase(
         owner,
         run_id,
         run_root,
         child_sup,
         config,
         specs,
         history,
         opts,
         initial_tokens
       ) do
    deadline = Keyword.fetch!(opts, :run_deadline)
    select = Keyword.get(opts, :select)

    state = %{
      owner: owner,
      run_id: run_id,
      run_root: run_root,
      child_sup: child_sup,
      config: config,
      history: history,
      queued: Enum.map(specs, &normalize_spec/1),
      active: %{},
      results: [],
      failures: [],
      token_estimate: initial_tokens,
      deadline: deadline,
      select: select,
      selected: nil
    }

    state |> fill_slots() |> report_progress() |> await_phase()
  end

  defp fill_slots(state)
       when map_size(state.active) >= state.config.max_concurrency or state.queued == [],
       do: state

  defp fill_slots(%{queued: [spec | rest]} = state) do
    prompt_tokens = estimate_tokens(spec.prompt)

    if state.token_estimate + prompt_tokens > state.config.token_budget do
      result = %Result{id: spec.id, role: spec.role, status: :budget_exceeded}

      %{
        state
        | queued: rest,
          results: state.results ++ [result],
          failures: state.failures ++ [result]
      }
      |> fill_slots()
    else
      case start_child(state, spec) do
        {:ok, active} ->
          %{
            state
            | queued: rest,
              active: Map.put(state.active, active.task.ref, active),
              token_estimate: state.token_estimate + prompt_tokens
          }
          |> fill_slots()

        {:error, reason, worktree} ->
          result = %Result{
            id: spec.id,
            role: spec.role,
            status: :failed,
            error: inspect(reason),
            worktree: worktree
          }

          %{
            state
            | queued: rest,
              results: state.results ++ [result],
              failures: state.failures ++ [result]
          }
          |> fill_slots()
      end
    end
  end

  defp start_child(state, spec) do
    case child_cwd(state, spec) do
      {:ok, cwd, worktree} ->
        case start_child_session(state, spec, cwd) do
          {:ok, session, session_pid} ->
            case activate_child(state, spec, session, session_pid, worktree) do
              {:ok, active} ->
                {:ok, active}

              {:error, reason} ->
                stop_child_session(session_pid)
                cleanup_worktree(state.config.parent_config.cwd, state.run_root, worktree)
                {:error, reason, worktree}
            end

          {:error, reason} ->
            cleanup_worktree(state.config.parent_config.cwd, state.run_root, worktree)
            {:error, reason, worktree}
        end

      {:error, reason, worktree} ->
        cleanup_worktree(state.config.parent_config.cwd, state.run_root, worktree)
        {:error, reason, worktree}
    end
  end

  defp start_child_session(state, spec, cwd) do
    provider = state.config.provider_factory.(spec)
    child_opts = child_options(state, spec, cwd, provider)

    with {:ok, session} <- Elara.start_session_under(state.child_sup, child_opts),
         {:ok, session_pid} <- Elara.session_pid(session) do
      {:ok, session, session_pid}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp activate_child(state, spec, session, session_pid, worktree) do
    monitor = Process.monitor(session_pid)
    started_at = now_ms()

    task =
      Task.Supervisor.async_nolink(Elara.TaskSup, fn ->
        {Elara.ask(session, spec.prompt), now_ms() - started_at}
      end)

    child = %{
      id: spec.id,
      run_id: state.run_id,
      parent_session_id: state.config.parent_session_id,
      role: spec.role,
      pid: session_pid,
      task_pid: task.pid,
      session_id: session,
      worktree: worktree,
      worktree_root: if(worktree, do: state.run_root),
      status: :running
    }

    send(state.owner, {:coordinator_child_started, state.run_id, child})

    {:ok,
     %{
       spec: spec,
       task: task,
       session: session,
       session_pid: session_pid,
       monitor: monitor,
       worktree: worktree
     }}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp await_phase(%{active: active, queued: [], selected: nil} = state)
       when map_size(active) == 0 do
    report_progress(state)
    {:ok, state}
  end

  defp await_phase(%{selected: selected} = state) when not is_nil(selected) do
    state = state |> cancel_remaining(:not_selected) |> report_progress()
    {:ok, state}
  end

  defp await_phase(state) do
    timeout = max(state.deadline - now_ms(), 0)

    receive do
      {ref, {ask_result, duration}} when is_map_key(state.active, ref) ->
        Process.demonitor(ref, [:flush])
        {active, remaining} = Map.pop!(state.active, ref)
        Process.demonitor(active.monitor, [:flush])
        result = compact_result(active, ask_result, duration, state.config.max_result_bytes)

        send(
          state.owner,
          {:coordinator_child_finished, state.run_id, active.spec.id, result.status}
        )

        tokens = if result.answer, do: estimate_tokens(result.answer), else: 0
        results = state.results ++ [result]

        failures =
          if result.status == :completed, do: state.failures, else: state.failures ++ [result]

        selected = choose(state.select, results)

        %{
          state
          | active: remaining,
            results: results,
            failures: failures,
            token_estimate: state.token_estimate + tokens,
            selected: selected
        }
        |> fill_slots()
        |> report_progress()
        |> await_phase()

      {:DOWN, ref, :process, _pid, reason} when is_map_key(state.active, ref) ->
        {active, remaining} = Map.pop!(state.active, ref)
        result = failed_result(active, {:task_down, reason})
        send(state.owner, {:coordinator_child_finished, state.run_id, active.spec.id, :failed})

        %{
          state
          | active: remaining,
            results: state.results ++ [result],
            failures: state.failures ++ [result]
        }
        |> fill_slots()
        |> report_progress()
        |> await_phase()

      {:DOWN, monitor, :process, pid, reason} ->
        case find_by_monitor(state.active, monitor, pid) do
          nil ->
            await_phase(state)

          {ref, active} ->
            Process.exit(active.task.pid, :kill)
            Process.demonitor(active.task.ref, [:flush])
            result = failed_result(active, {:session_down, reason})

            send(
              state.owner,
              {:coordinator_child_finished, state.run_id, active.spec.id, :failed}
            )

            remaining = Map.delete(state.active, ref)

            %{
              state
              | active: remaining,
                results: state.results ++ [result],
                failures: state.failures ++ [result]
            }
            |> fill_slots()
            |> report_progress()
            |> await_phase()
        end
    after
      timeout ->
        state = state |> cancel_remaining(:time_budget_exceeded) |> report_progress()
        {:ok, state}
    end
  end

  defp cancel_remaining(state, reason) do
    active_results =
      Enum.map(state.active, fn {_ref, active} ->
        Process.exit(active.task.pid, :kill)
        Process.exit(active.session_pid, :kill)
        send(state.owner, {:coordinator_child_finished, state.run_id, active.spec.id, :cancelled})

        %Result{
          id: active.spec.id,
          role: active.spec.role,
          status: :cancelled,
          error: Atom.to_string(reason),
          session_id: active.session,
          worktree: active.worktree
        }
      end)

    queued_results =
      Enum.map(state.queued, fn spec ->
        %Result{id: spec.id, role: spec.role, status: :cancelled, error: Atom.to_string(reason)}
      end)

    %{
      state
      | active: %{},
        queued: [],
        results: state.results ++ active_results ++ queued_results,
        failures: state.failures ++ active_results ++ queued_results
    }
  end

  defp child_options(state, spec, cwd, provider) do
    base = state.config.parent_config

    custom =
      state.config.child_opts
      |> Keyword.merge(Map.get(spec, :session_opts, []))

    forced = [
      provider: provider,
      cwd: cwd,
      tools: base.tools,
      plugins: [],
      max_iterations: base.max_iterations,
      max_tool_output_bytes: base.max_tool_output_bytes,
      tool_timeout_ms: base.tool_timeout_ms,
      router: base.router,
      workspace_id: base.workspace_id,
      allowed_capabilities: base.allowed_capabilities,
      persist: false,
      seed_history: state.history,
      system: Map.get(spec, :system, base.system)
    ]

    base.skill_options |> Keyword.merge(custom) |> Keyword.merge(forced)
  end

  defp child_cwd(state, %{coding: true}) do
    root = state.run_root
    path = Path.join(root, random_id())

    with :ok <- File.mkdir_p(root),
         {:ok, _output, 0} <-
           run_command("git", ["worktree", "add", "--detach", path, "HEAD"],
             cd: state.config.parent_config.cwd,
             stderr_to_stdout: true
           ) do
      {:ok, path, path}
    else
      {:ok, output, status} ->
        {:error, {:worktree_failed, status, String.trim(output)}, path}

      {:error, reason} ->
        {:error, {:worktree_failed, reason}, path}
    end
  end

  defp child_cwd(state, _spec), do: {:ok, state.config.parent_config.cwd, nil}

  @doc false
  def run_root(run_id) do
    Path.join(System.tmp_dir!(), "elara-coordinator-#{safe_name(run_id)}")
  end

  @doc false
  def cleanup_worktree(_parent_cwd, _root, nil), do: :ok

  def cleanup_worktree(parent_cwd, root, path) do
    root = Path.expand(root)
    path = Path.expand(path)

    if Path.dirname(path) == root do
      run_command("git", ["worktree", "remove", "--force", path],
        cd: parent_cwd,
        stderr_to_stdout: true
      )

      remove_tree(path)

      run_command("git", ["worktree", "prune"],
        cd: parent_cwd,
        stderr_to_stdout: true
      )

      remove_directory(root)
      :ok
    else
      {:error, :worktree_outside_run_root}
    end
  end

  @doc false
  def cleanup_root(parent_cwd, root) do
    remove_tree(Path.expand(root))

    run_command("git", ["worktree", "prune"],
      cd: parent_cwd,
      stderr_to_stdout: true
    )

    :ok
  end

  defp run_command(command, arguments, options) do
    case System.cmd(command, arguments, options) do
      {output, status} -> {:ok, output, status}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp remove_tree(path) do
    File.rm_rf(path)
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp remove_directory(path) do
    File.rmdir(path)
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp stop_child_session(session_pid) do
    GenServer.stop(session_pid, :shutdown)
  catch
    :exit, _reason -> :ok
  end

  defp compact_result(active, {:ok, answer}, duration, max_bytes) do
    %Result{
      id: active.spec.id,
      role: active.spec.role,
      status: :completed,
      answer: truncate(answer, max_bytes),
      session_id: active.session,
      worktree: active.worktree,
      duration_ms: duration
    }
  end

  defp compact_result(active, {:error, reason}, duration, _max_bytes) do
    %Result{
      id: active.spec.id,
      role: active.spec.role,
      status: :failed,
      error: inspect(reason),
      session_id: active.session,
      worktree: active.worktree,
      duration_ms: duration
    }
  end

  defp failed_result(active, reason) do
    %Result{
      id: active.spec.id,
      role: active.spec.role,
      status: :failed,
      error: inspect(reason),
      session_id: active.session,
      worktree: active.worktree
    }
  end

  defp seed_history(parent, :clone), do: {:ok, Elara.transcript(parent)}
  defp seed_history(parent, {:fork, user_id}), do: Elara.history_before(parent, user_id)
  defp seed_history(_parent, _strategy), do: {:error, :invalid_history_strategy}

  defp normalize_spec(spec) do
    spec
    |> Map.put_new(:role, :general)
    |> Map.put_new(:coding, Map.get(spec, :role) == :coding)
  end

  defp validate_child_specs(pattern, specs, opts) do
    pattern
    |> additional_specs(opts)
    |> Kernel.++(specs)
    |> Enum.reduce_while(:ok, fn spec, :ok ->
      case validate_child_spec(spec) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_child_spec, reason}}}
      end
    end)
  end

  defp additional_specs(:candidates, opts), do: optional_spec(Keyword.get(opts, :judge))
  defp additional_specs(:map_reduce, opts), do: optional_spec(Keyword.get(opts, :reducer))
  defp additional_specs(_pattern, _opts), do: []

  defp optional_spec(nil), do: []
  defp optional_spec(spec), do: [spec]

  defp validate_child_spec(spec) when not is_map(spec), do: {:error, :map_required}

  defp validate_child_spec(spec) do
    cond do
      not (is_binary(Map.get(spec, :id)) and Map.get(spec, :id) != "") ->
        {:error, :id_required}

      not (is_binary(Map.get(spec, :prompt)) and Map.get(spec, :prompt) != "") ->
        {:error, :prompt_required}

      true ->
        :ok
    end
  end

  defp validate_unique_ids(pattern, specs, opts) do
    extra =
      case pattern do
        :candidates -> [Keyword.get(opts, :judge)]
        :map_reduce -> [Keyword.get(opts, :reducer)]
        _ -> []
      end

    ids =
      specs
      |> Kernel.++(Enum.reject(extra, &is_nil/1))
      |> Enum.map(&Map.get(&1, :id))

    if length(ids) == length(Enum.uniq(ids)), do: :ok, else: {:error, :duplicate_child_ids}
  end

  defp choose(nil, _results), do: nil
  defp choose(select, results) when is_function(select, 1), do: select.(results)

  defp find_by_monitor(active, monitor, pid) do
    Enum.find_value(active, fn {ref, child} ->
      if child.monitor == monitor and child.session_pid == pid, do: {ref, child}
    end)
  end

  defp result_context(results) do
    compact =
      Enum.map(results, &%{id: &1.id, role: &1.role, status: &1.status, answer: &1.answer})

    "\n\nStructured child results:\n" <> JSON.encode!(compact)
  end

  defp select_candidate(%Result{answer: answer}, candidates) when is_binary(answer) do
    answer = String.trim(answer)
    if Enum.any?(candidates, &(&1.id == answer)), do: answer
  end

  defp select_candidate(_judge, _candidates), do: nil

  defp combine_phases(first, second) do
    %{
      second
      | results: first.results ++ second.results,
        failures: first.failures ++ second.failures,
        token_estimate: second.token_estimate
    }
  end

  defp build_run(pattern, phase, selected, judge, started_at) do
    %Run{
      pattern: pattern,
      selected: selected || phase.selected,
      judge: judge,
      results: phase.results,
      failures: phase.failures,
      token_estimate: phase.token_estimate,
      elapsed_ms: now_ms() - started_at,
      worker_health: Elara.workers()
    }
  end

  defp estimate_tokens(text), do: div(byte_size(text) + 3, 4)

  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: binary_part(text, 0, max) <> "\n[truncated]"

  defp safe_name(value) do
    value |> to_string() |> String.replace(~r/[^a-zA-Z0-9_.-]+/, "-") |> String.trim("-")
  end

  defp random_id do
    12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp report_progress(state) do
    progress = %{
      token_estimate: state.token_estimate,
      active: map_size(state.active),
      queued: length(state.queued),
      completed: length(state.results)
    }

    send(state.owner, {:coordinator_progress, state.run_id, progress})
    state
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
