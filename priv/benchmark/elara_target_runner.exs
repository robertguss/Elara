defmodule Elara.Benchmark.TargetRunner do
  @moduledoc false

  alias Elara.Effect.{ControllerJournal, TestExecutor}
  alias Elara.Message
  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}
  alias Elara.Session.Store

  defmodule InstrumentedRouter do
    @moduledoc false
    use GenServer

    def start_link(coordinator), do: GenServer.start_link(__MODULE__, coordinator)

    @impl true
    def init(coordinator), do: {:ok, coordinator}

    @impl true
    def handle_call({:checkout, _request, _excluded}, _from, coordinator) do
      worker = %Elara.Executor.Router.Worker{
        id: "qualification-local",
        executor: {Elara.Benchmark.TargetRunner.InstrumentedExecutor, coordinator},
        capabilities: :all,
        workspaces: :all,
        placement: :local,
        healthy?: true,
        load: 0
      }

      {:reply, {:ok, worker}, coordinator}
    end

    def handle_call(:workers, _from, coordinator), do: {:reply, [], coordinator}

    @impl true
    def handle_cast({:complete, _id, _healthy?, _pid}, coordinator),
      do: {:noreply, coordinator}
  end

  defmodule InstrumentedExecutor do
    @moduledoc false

    def execute(coordinator, request, tool) do
      send(
        coordinator,
        {:baseline_barrier, :before_callback, self(), barrier_facts(request, :before_callback)}
      )

      receive do
        {:continue_baseline, :before_callback} -> :ok
      end

      result = Elara.Executor.Local.execute(%{cwd: request_cwd(coordinator)}, request, tool)

      send(
        coordinator,
        {:baseline_barrier, :after_callback, self(), barrier_facts(request, :after_callback)}
      )

      receive do
        {:continue_baseline, :after_callback} -> result
      end
    end

    defp request_cwd(coordinator) do
      send(coordinator, {:request_cwd, self()})

      receive do
        {:request_cwd, cwd} -> cwd
      end
    end

    defp barrier_facts(request, point) do
      %{
        "source" => "baseline_instrumented_router",
        "adapter_point" => Atom.to_string(point),
        "local_executor_invocation_count" => if(point == :before_callback, do: 0, else: 1),
        "local_executor_return_count" => if(point == :before_callback, do: 0, else: 1),
        "job_id" => Map.get(request, :job_id),
        "operation_digest" => Map.get(request, :operation_digest),
        "tool_call_id" => request.tool_call_id
      }
    end
  end

  defmodule PlanProvider do
    @moduledoc false
    @behaviour Elara.Provider

    alias Elara.Message.ToolResult
    alias Elara.Provider.Request

    @impl true
    def chat(agent, %Request{messages: messages}) when is_pid(agent) do
      {assistant, _state} =
        Agent.get_and_update(agent, fn state ->
          {assistant, updated} = next_turn(state, messages)
          {{assistant, updated}, updated}
        end)

      {:ok, assistant, agent}
    end

    defp next_turn(%{turns: [%{kind: :tool_call} = turn | rest]} = state, messages) do
      case last_tool_outcome(messages) do
        nil ->
          emit_tool(state, turn, rest)

        {:ok, _payload} ->
          emit_tool(state, turn, rest)

        {_kind, _payload} ->
          {state.halt_turn,
           %{
             state
             | turns: [],
               call_count: state.call_count + 1,
               disposition: :skipped_non_ok,
               skipped_tool_call_ids:
                 Enum.map(state.turns, fn
                   %{kind: :tool_call, tool_call_id: id} -> id
                   _turn -> nil
                 end)
                 |> Enum.reject(&is_nil/1)
           }}
      end
    end

    defp next_turn(%{turns: [%{kind: :assistant_text, assistant: assistant}]} = state, _messages) do
      {assistant, %{state | turns: [], call_count: state.call_count + 1, disposition: :completed}}
    end

    defp next_turn(%{turns: []}, _messages), do: raise("provider plan exhausted")

    defp emit_tool(state, turn, rest) do
      {turn.assistant,
       %{
         state
         | turns: rest,
           call_count: state.call_count + 1,
           emitted_tool_call_ids: state.emitted_tool_call_ids ++ [turn.tool_call_id]
       }}
    end

    defp last_tool_outcome(messages) do
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %ToolResult{outcome: outcome} -> outcome
        _message -> nil
      end)
    end
  end

  @spec run(map()) :: map()
  def run(request) do
    remove_adapter_mix_environment()

    case request["mode"] do
      "fault_qualification" -> run_fault(request)
      _other -> run_no_fault(request)
    end
  end

  defp run_no_fault(request) do
    {:ok, hooks} = Agent.start_link(fn -> [] end)
    hook = fn point -> Agent.update(hooks, &[Atom.to_string(point) | &1]) end
    {:ok, provider} = start_provider(request)
    {executor, executor_config} = start_executor(request, hook)

    {:ok, session} =
      Elara.start_session(session_options(request, provider, executor, hook, false))

    ask_result = Elara.ask(session, request["prompt"])
    transcript = Elara.transcript(session)
    status = Elara.status(session)
    provider_state = provider_state(provider)
    {:ok, session_pid} = Elara.session_pid(session)
    GenServer.stop(session_pid)

    receipt_evidence = receipt_evidence(request, executor, executor_config)
    hooks_observed = hooks |> Agent.get(&Enum.reverse/1)
    stop_executor(executor)

    tool_results = Enum.filter(transcript, &is_struct(&1, ToolResult))
    tool_result = List.last(tool_results)

    %{
      "status" => "ok",
      "schema" => "elara.exp003.internal-adapter-observation.v1",
      "task_id" => request["task_id"],
      "condition" => request["condition"],
      "target_commit" => request["target_commit"],
      "runtime" => runtime(),
      "observed_outcome" => normalize_outcome(tool_result.outcome),
      "tool_result_kind" => tool_result.outcome |> elem(0) |> Atom.to_string(),
      "provider_plan_consumed" =>
        provider_state["remaining_turn_count"] == 0 and
          provider_state["disposition"] == "completed",
      "provider_call_count" => provider_state["call_count"],
      "provider_state" => provider_state,
      "tool_call_count" => length(tool_results),
      "session_result_count" => length(tool_results),
      "session_result" => normalize_ask_result(ask_result),
      "session_idle" =>
        status.phase == :idle and status.current_effect == nil and status.task_count == 0,
      "transcript_shape" => Enum.map(transcript, &message_shape/1),
      "hooks_observed" => hooks_observed,
      "receipt_evidence" => receipt_evidence
    }
  end

  defp run_fault(request) do
    Application.put_env(:elara, :sessions_root, request["session_root"])
    {:ok, hooks} = Agent.start_link(fn -> [] end)
    {:ok, barrier} = Agent.start_link(fn -> :armed end)
    {:ok, provider} = start_provider(request)
    coordinator = self()
    selected_point = native_point(request["row"]["fault_type"])

    hook = fn point ->
      Agent.update(hooks, &[Atom.to_string(point) | &1])

      armed? =
        point == selected_point and
          Agent.get_and_update(barrier, fn
            :armed -> {true, :disarmed}
            :disarmed -> {false, :disarmed}
          end)

      if armed? do
        send(
          coordinator,
          {:native_barrier, point, self(), native_facts(request, point, provider)}
        )

        receive do
          {:continue_native, ^point} -> :ok
        end
      else
        :ok
      end
    end

    {router, executor, executor_config} = start_fault_owners(request, hook)

    {:ok, session} =
      Elara.start_session(session_options(request, provider, executor, hook, true, router))

    ask_pid = start_ask(session, request["prompt"])
    started = System.monotonic_time(:millisecond)
    {source_point, owner_pid, facts} = await_selected_barrier(request)
    write_barrier_event(request, facts)
    command = await_injection_command(request)
    assert_injection!(command, request["row"])
    session_pid = session_pid!(session)
    inject(request["row"]["crash_target"], session_pid, owner_pid)

    {final_session, final_executor, ask_result, recovery_actions} =
      recover(request, provider, router, executor, executor_config, session, ask_pid, hook)

    convergence_ms = max(System.monotonic_time(:millisecond) - started, 0)
    transcript = safe_transcript(final_session)
    status = safe_status(final_session)
    provider_state = provider_state(provider)
    receipt_evidence = fault_receipt_evidence(request, final_executor, executor_config)
    controller_facts = controller_facts(request)
    hooks_observed = hooks |> Agent.get(&Enum.reverse/1)
    stop_session(final_session)
    stop_executor(final_executor)
    stop_router(router)

    tool_results = Enum.filter(transcript, &is_struct(&1, ToolResult))

    target_results =
      Enum.filter(tool_results, &(&1.call_id == request["row"]["fault_target_tool_call_id"]))

    causal_terminal = causal_terminal?(receipt_evidence)

    %{
      "status" => "ok",
      "schema" => "elara.exp003.internal-fault-observation.v1",
      "task_id" => request["task_id"],
      "condition" => request["condition"],
      "target_commit" => request["target_commit"],
      "runtime" => runtime(),
      "barrier_source_point" => Atom.to_string(source_point),
      "barrier_facts" => facts,
      "barrier_call_count" => 1,
      "injection_count" => 1,
      "injection_acknowledged" => true,
      "killed_owner" => request["row"]["crash_target"],
      "recovery_actions" => recovery_actions,
      "controller_facts" => controller_facts,
      "executor_facts" => receipt_evidence,
      "causal_terminal_evidence_observed" => causal_terminal,
      "session_classification" => session_classification(target_results, ask_result),
      "knowledge_convergence_ms" => convergence_ms,
      "terminal_convergence_ms" => if(causal_terminal, do: convergence_ms, else: nil),
      "admission_count" => evidence_count(receipt_evidence, "admission_count"),
      "callback_attempt_count" => evidence_count(receipt_evidence, "callback_attempt_count"),
      "session_result_count" => length(target_results),
      "task_session_result_count" => length(tool_results),
      "model_call_count" => provider_state["call_count"],
      "tool_call_count" => length(target_results),
      "task_tool_call_count" => length(tool_results),
      "provider_plan_remaining" => provider_state["remaining_turn_count"],
      "provider_state" => provider_state,
      "hooks_observed" => hooks_observed,
      "final_status" => status_evidence(status),
      "transcript_shape" => Enum.map(transcript, &message_shape/1),
      "ask_result" => normalize_ask_result(ask_result),
      "harness_errors" => [],
      "unplanned_intervention_count" => 0
    }
  end

  defp start_fault_owners(%{"condition" => "baseline"}, _hook) do
    {:ok, router} = InstrumentedRouter.start_link(self())
    {router, nil, nil}
  end

  defp start_fault_owners(%{"condition" => "receipts"} = request, hook) do
    {executor, config} = start_executor(request, hook)
    {nil, executor, config}
  end

  defp session_options(request, provider, executor, hook, persist?, router \\ nil) do
    options = [
      provider: {Elara.Benchmark.TargetRunner.PlanProvider, provider},
      cwd: request["workspace_root"],
      persist: persist?,
      plugins: [],
      tool_timeout_ms: request["tool_timeout_ms"],
      allowed_capabilities: :all
    ]

    options = if router, do: Keyword.put(options, :router, router), else: options
    receipt_options(options, request, executor, hook)
  end

  defp start_provider(request) do
    mapping = request["mapping"]

    tool_turns =
      Enum.map(mapping["tool_calls"], fn mapped ->
        call = %ToolCall{
          id: mapped["tool_call_id"],
          name: mapped["tool_name"],
          args: {:ok, mapped["tool_arguments"]}
        }

        {:ok, assistant} = Message.assistant(nil, [call])

        %{
          kind: :tool_call,
          tool_call_id: mapped["tool_call_id"],
          assistant: assistant
        }
      end)

    {:ok, final_turn} = Message.assistant(mapping["final_assistant_text"], [])
    {:ok, halt_turn} = Message.assistant(mapping["non_ok_halt_assistant_text"], [])

    Agent.start_link(fn ->
      %{
        turns: tool_turns ++ [%{kind: :assistant_text, assistant: final_turn}],
        halt_turn: halt_turn,
        call_count: 0,
        disposition: :active,
        emitted_tool_call_ids: [],
        skipped_tool_call_ids: []
      }
    end)
  end

  defp await_selected_barrier(%{"condition" => "receipts"} = request) do
    expected = native_point(request["row"]["fault_type"])

    receive do
      {:native_barrier, ^expected, owner_pid, facts} -> {expected, owner_pid, facts}
    after
      request["row"]["observation_deadline_ms"] -> raise "native fault barrier not reached"
    end
  end

  defp await_selected_barrier(%{"condition" => "baseline"} = request) do
    expected =
      if request["row"]["fault_type"] in ~w(F1 F2), do: :before_callback, else: :after_callback

    await_baseline_barrier(request, expected)
  end

  defp await_baseline_barrier(request, expected) do
    receive do
      {:request_cwd, pid} ->
        send(pid, {:request_cwd, request["workspace_root"]})
        await_baseline_barrier(request, expected)

      {:baseline_barrier, ^expected, owner_pid, facts} ->
        expected_tool_call_id = request["row"]["fault_target_tool_call_id"]

        facts =
          facts
          |> Map.put("semantic_seam", "N/A/non-equivalent")
          |> Map.put("expected_fault_target_tool_call_id", expected_tool_call_id)
          |> Map.put(
            "fault_target_identity_matches",
            facts["tool_call_id"] == expected_tool_call_id
          )

        {expected, owner_pid, facts}

      {:baseline_barrier, other, owner_pid, _facts} ->
        send(owner_pid, {:continue_baseline, other})
        await_baseline_barrier(request, expected)
    after
      request["row"]["observation_deadline_ms"] -> raise "baseline fault barrier not reached"
    end
  end

  defp write_barrier_event(request, facts) do
    event = %{
      "schema" => "elara.exp003.fault-barrier.v1",
      "barrier_id" => request["row"]["barrier_id"],
      "facts" => facts
    }

    write_atomic!(request["barrier_event_path"], JSON.encode!(event))
  end

  defp await_injection_command(request) do
    deadline =
      System.monotonic_time(:millisecond) + request["row"]["observation_deadline_ms"]

    await_json_file(request["injection_command_path"], deadline)
  end

  defp await_json_file(path, deadline) do
    case File.read(path) do
      {:ok, encoded} ->
        JSON.decode!(encoded)

      {:error, :enoent} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await_json_file(path, deadline)
        else
          raise "fault injection command timed out"
        end

      {:error, reason} ->
        raise "fault injection command read failed: #{inspect(reason)}"
    end
  end

  defp assert_injection!(%{"action" => "inject", "owner" => owner}, %{"crash_target" => owner}),
    do: :ok

  defp inject("controller", session_pid, owner_pid) do
    kill_and_wait(session_pid)
    _blocked_observer_owned_by_target = owner_pid
    :ok
  end

  defp inject("selected_worker_or_tool_owner", _session_pid, owner_pid),
    do: kill_and_wait(owner_pid)

  defp recover(
         %{"condition" => "receipts", "row" => %{"crash_target" => "controller"}} = request,
         provider,
         router,
         executor,
         _executor_config,
         _session,
         ask_pid,
         _hook
       ) do
    await_ask_exit(ask_pid)
    store_path = newest_store_path(request["workspace_root"])
    no_fault = fn _point -> :ok end

    options =
      request
      |> session_options(provider, executor, no_fault, true, router)
      |> Keyword.put(:resume, store_path)

    {:ok, recovered} = Elara.start_session(options)

    reconciliation =
      case request["row"]["fault_type"] do
        "F1" -> "native_same_identity_reconciliation"
        "F4" -> "native_terminal_reconciliation"
      end

    {recovered, executor, {:exit, :controller_loss},
     ["kill_controller", "reopen_persisted_session", reconciliation]}
  end

  defp recover(
         %{"condition" => "receipts"} = request,
         _provider,
         _router,
         _executor,
         _executor_config,
         session,
         ask_pid,
         _hook
       ) do
    reopened = reopen_executor(request)
    :ok = Elara.replace_effect_executor(session, reopened)

    {session, reopened, await_ask(ask_pid, request["row"]["observation_deadline_ms"]),
     ["kill_original_executor_process", "reopen_same_logical_executor", "replace_effect_executor"]}
  end

  defp recover(
         %{"condition" => "baseline", "row" => %{"crash_target" => "controller"}} = request,
         provider,
         router,
         _executor,
         _executor_config,
         _session,
         ask_pid,
         _hook
       ) do
    await_ask_exit(ask_pid)
    store_path = newest_store_path(request["workspace_root"])

    options =
      request
      |> session_options(provider, nil, fn _point -> :ok end, true, router)
      |> Keyword.put(:resume, store_path)

    {:ok, recovered} = Elara.start_session(options)

    {recovered, nil, {:exit, :controller_loss},
     ["kill_controller", "reopen_persisted_session", "native_transcript_repair"]}
  end

  defp recover(
         %{"condition" => "baseline"} = request,
         _provider,
         _router,
         nil,
         nil,
         session,
         ask_pid,
         _hook
       ) do
    {session, nil, await_ask(ask_pid, request["row"]["observation_deadline_ms"]),
     ["kill_selected_tool_owner", "observe_native_session_failure"]}
  end

  defp reopen_executor(request) do
    {:ok, executor} =
      TestExecutor.start_link(
        id: "exp003-receipt-equivalence",
        path: request["executor_ledger_path"],
        fault_hook: fn _point -> :ok end
      )

    Process.unlink(executor)
    executor
  end

  defp start_ask(session, prompt) do
    parent = self()

    spawn(fn ->
      result =
        try do
          Elara.ask(session, prompt)
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {:ask_result, self(), result})
    end)
  end

  defp await_ask(pid, timeout) do
    receive do
      {:ask_result, ^pid, result} -> result
    after
      timeout -> raise "ask did not converge"
    end
  end

  defp await_ask_exit(pid) do
    receive do
      {:ask_result, ^pid, result} -> result
    after
      1_000 -> {:exit, :not_observed}
    end
  end

  defp newest_store_path(cwd) do
    {:ok, info} = Store.newest(cwd)
    info.path
  end

  defp native_point("F1"), do: :after_intent_commit_before_dispatch
  defp native_point("F2"), do: :after_accept_reply_before_callback
  defp native_point("F3"), do: :after_external_mutation_before_completion_commit
  defp native_point("F4"), do: :after_completion_reply_before_session_result_persist

  defp native_facts(request, point, provider) do
    provider_state = Agent.get(provider, & &1)
    actual_tool_call_id = List.last(provider_state.emitted_tool_call_ids)
    expected_tool_call_id = request["row"]["fault_target_tool_call_id"]

    %{
      "source" => "native_receipt_hook",
      "point" => Atom.to_string(point),
      "controller_journal_path" => request["controller_journal_path"],
      "executor_ledger_path" => request["executor_ledger_path"],
      "tool_call_id" => actual_tool_call_id,
      "expected_fault_target_tool_call_id" => expected_tool_call_id,
      "fault_target_identity_matches" => actual_tool_call_id == expected_tool_call_id
    }
  end

  defp fault_receipt_evidence(%{"condition" => "baseline"}, nil, nil),
    do: %{
      "status" => "not_applicable",
      "admission_count" => "not_applicable",
      "callback_attempt_count" => "not_applicable",
      "terminal_count" => "not_applicable"
    }

  defp fault_receipt_evidence(%{"condition" => "receipts"} = request, executor, executor_config) do
    jobs = controller_jobs(request)
    target = unique_target_job!(request, jobs)
    task_records = Enum.map(jobs, &TestExecutor.query(executor, &1.job_id))

    target
    |> then(&TestExecutor.query(executor, &1.job_id))
    |> record_evidence(executor_config)
    |> Map.merge(%{
      "target_match_count" => 1,
      "task_job_count" => length(jobs),
      "task_admission_count" => sum_record_count(task_records, :admission_count),
      "task_callback_attempt_count" => sum_record_count(task_records, :callback_attempt_count),
      "task_terminal_count" => sum_record_count(task_records, :terminal_count),
      "task_tool_call_ids" => Enum.map(jobs, & &1.tool_call_id)
    })
  end

  defp record_evidence({state, record}, executor_config) do
    %{
      "status" => Atom.to_string(state),
      "job_id" => record.job_id,
      "operation_digest" => record.operation_digest,
      "admission_count" => record.admission_count,
      "callback_attempt_count" => record.callback_attempt_count,
      "terminal_count" => record.terminal_count,
      "result_kind" =>
        if(record.result, do: record.result |> elem(0) |> Atom.to_string(), else: nil),
      "executor_configuration" => stringify(executor_config)
    }
  end

  defp controller_facts(%{"condition" => "baseline"}),
    do: %{"status" => "not_applicable", "job_count" => 0, "result_persisted" => false}

  defp controller_facts(%{"condition" => "receipts"} = request) do
    journal = start_journal(request["controller_journal_path"])
    {:ok, jobs} = ControllerJournal.all(journal)
    target = unique_target_job!(request, jobs)
    {:ok, observation} = ControllerJournal.observation(journal, target.job_id)

    facts = %{
      "status" => "available",
      "job_count" => length(jobs),
      "target_match_count" => 1,
      "job_id" => target.job_id,
      "operation_digest" => target.operation_digest,
      "tool_call_id" => target.tool_call_id,
      "result_persisted" => observation != nil and observation.result_persisted?,
      "task_tool_call_ids" => Enum.map(jobs, & &1.tool_call_id)
    }

    :ok = ControllerJournal.close(journal)
    facts
  end

  defp controller_jobs(request) do
    journal = start_journal(request["controller_journal_path"])
    {:ok, jobs} = ControllerJournal.all(journal)
    :ok = ControllerJournal.close(journal)
    jobs
  end

  defp unique_target_job!(request, jobs) do
    tool_call_id = request["row"]["fault_target_tool_call_id"]

    case Enum.filter(jobs, &(&1.tool_call_id == tool_call_id)) do
      [job] -> job
      matches -> raise "fault target durable job match count #{length(matches)}"
    end
  end

  defp sum_record_count(records, field) do
    Enum.sum(
      Enum.map(records, fn
        {_state, record} -> Map.fetch!(record, field)
        other -> raise "invalid task receipt record: #{inspect(other)}"
      end)
    )
  end

  defp causal_terminal?(%{"status" => state, "terminal_count" => 1})
       when state in ["completed", "failed"], do: true

  defp causal_terminal?(_evidence), do: false

  defp evidence_count(evidence, key) do
    case Map.get(evidence, key) do
      count when is_integer(count) -> count
      _not_applicable -> 0
    end
  end

  defp session_classification([%ToolResult{outcome: outcome}], _ask_result),
    do: classify_tool_result(outcome)

  defp session_classification([], {:exit, :controller_loss}), do: "interrupted_on_reopen"
  defp session_classification(_results, ask_result), do: normalize_ask_result(ask_result)

  defp provider_state(provider) do
    Agent.get(provider, fn state ->
      %{
        "call_count" => state.call_count,
        "disposition" => Atom.to_string(state.disposition),
        "remaining_turn_count" => length(state.turns),
        "remaining_tool_call_ids" =>
          Enum.flat_map(state.turns, fn
            %{kind: :tool_call, tool_call_id: id} -> [id]
            _turn -> []
          end),
        "emitted_tool_call_ids" => state.emitted_tool_call_ids,
        "skipped_tool_call_ids" => state.skipped_tool_call_ids
      }
    end)
  end

  defp classify_tool_result({:error, message}) do
    cond do
      String.contains?(message, "interrupted") -> "interrupted_without_causal_terminal"
      String.contains?(message, ["crashed", "killed"]) -> "failed_without_causal_terminal"
      true -> "error"
    end
  end

  defp classify_tool_result(outcome), do: normalize_outcome(outcome)

  defp safe_transcript(nil), do: []
  defp safe_transcript(session), do: Elara.transcript(session)
  defp safe_status(nil), do: %{}
  defp safe_status(session), do: Elara.status(session)

  defp status_evidence(status) when is_map(status) do
    %{
      "phase" => status |> Map.get(:phase) |> stringify(),
      "current_effect" => status |> Map.get(:current_effect) |> stringify(),
      "task_count" => Map.get(status, :task_count, 0),
      "mailbox_length" => Map.get(status, :mailbox_length, 0)
    }
  end

  defp session_pid!(session) do
    {:ok, pid} = Elara.session_pid(session)
    pid
  end

  defp kill_and_wait(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      1_000 -> raise "fault owner did not terminate"
    end
  end

  defp stop_session(nil), do: :ok

  defp stop_session(session) do
    case Elara.session_pid(session) do
      {:ok, pid} -> GenServer.stop(pid)
      {:error, :session_not_found} -> :ok
    end
  end

  defp stop_router(nil), do: :ok

  defp stop_router(router) do
    if Process.alive?(router), do: GenServer.stop(router)
  end

  defp write_atomic!(path, contents) do
    temporary = path <> ".tmp"
    File.write!(temporary, contents)
    File.rename!(temporary, path)
  end

  defp start_executor(%{"condition" => "baseline"}, _hook), do: {nil, nil}

  defp start_executor(%{"condition" => "receipts"} = request, hook) do
    id = "exp003-receipt-equivalence"

    {:ok, executor} =
      TestExecutor.start_link(
        id: id,
        path: request["executor_ledger_path"],
        fault_hook: hook
      )

    Process.unlink(executor)
    {executor, TestExecutor.configuration(executor)}
  end

  defp receipt_options(options, %{"condition" => "baseline"}, nil, _hook), do: options

  defp receipt_options(options, %{"condition" => "receipts"} = request, executor, hook) do
    options ++
      [
        effect_executor: executor,
        effect_journal_path: request["controller_journal_path"],
        effect_fault_hook: hook
      ]
  end

  defp receipt_evidence(%{"condition" => "baseline"}, nil, nil), do: "not_applicable"

  defp receipt_evidence(%{"condition" => "receipts"} = request, executor, executor_config) do
    journal = start_journal(request["controller_journal_path"])
    {:ok, jobs} = ControllerJournal.all(journal)

    evidence =
      Enum.map(jobs, fn job ->
        record = terminal_record!(TestExecutor.query(executor, job.job_id))
        {:ok, observation} = ControllerJournal.observation(journal, job.job_id)

        %{
          "job_id" => record.job_id,
          "tool_call_id" => job.tool_call_id,
          "operation_digest" => record.operation_digest,
          "state" => Atom.to_string(record.state),
          "result_kind" => record.result |> elem(0) |> Atom.to_string(),
          "admission_count" => record.admission_count,
          "callback_attempt_count" => record.callback_attempt_count,
          "terminal_count" => record.terminal_count,
          "result_persisted" => observation.result_persisted?,
          "identity_consistent" =>
            job.job_id == record.job_id and job.operation_digest == record.operation_digest and
              observation.job_id == record.job_id and
              observation.operation_digest == record.operation_digest
        }
      end)

    journal_config = ControllerJournal.configuration(journal)
    :ok = ControllerJournal.close(journal)

    %{
      "state" => "terminal",
      "job_count" => length(evidence),
      "admission_count" => Enum.sum(Enum.map(evidence, & &1["admission_count"])),
      "callback_attempt_count" => Enum.sum(Enum.map(evidence, & &1["callback_attempt_count"])),
      "terminal_count" => Enum.sum(Enum.map(evidence, & &1["terminal_count"])),
      "result_persisted" => Enum.all?(evidence, & &1["result_persisted"]),
      "identity_consistent" => Enum.all?(evidence, & &1["identity_consistent"]),
      "job_id_format_valid" =>
        Enum.all?(evidence, &String.starts_with?(&1["job_id"], "er1j_v1_")),
      "operation_digest_format_valid" =>
        Enum.all?(evidence, &(byte_size(&1["operation_digest"]) == 64)),
      "tool_call_ids" => Enum.map(evidence, & &1["tool_call_id"]),
      "jobs" => evidence,
      "executor_configuration" => stringify(executor_config),
      "controller_configuration" => stringify(journal_config)
    }
  end

  defp terminal_record!({state, record}) when state in [:completed, :failed], do: record
  defp terminal_record!(other), do: raise("nonterminal no-fault receipt: #{inspect(other)}")

  defp start_journal(path) do
    {:ok, journal} = ControllerJournal.start_link(path: path)
    Process.unlink(journal)
    journal
  end

  defp stop_executor(nil), do: :ok
  defp stop_executor(executor), do: TestExecutor.close(executor)

  defp normalize_outcome({:ok, _payload}), do: "ok"

  defp normalize_outcome({:error, "exit " <> rest}) do
    case Integer.parse(rest) do
      {status, _remainder} -> "error_exit_#{status}"
      :error -> "error"
    end
  end

  defp normalize_outcome({:error, message}) do
    if String.contains?(message, ["old_text not found", "need exactly one"]),
      do: "error_conflict",
      else: "error"
  end

  defp normalize_outcome({:indeterminate, _message}), do: "indeterminate"

  defp normalize_ask_result({:ok, text}), do: text
  defp normalize_ask_result({:error, reason}), do: "error:" <> inspect(reason)
  defp normalize_ask_result({:exit, reason}), do: "exit:" <> inspect(reason)

  defp message_shape(%User{}), do: "user"
  defp message_shape(%Assistant{tool_calls: [_ | _]}), do: "assistant_tool_call"
  defp message_shape(%ToolResult{}), do: "tool_result"
  defp message_shape(%Assistant{}), do: "assistant_text"

  defp runtime do
    %{
      "elixir" => System.version(),
      "otp_release" => List.to_string(:erlang.system_info(:otp_release)),
      "erts" => List.to_string(:erlang.system_info(:version)),
      "system_architecture" => List.to_string(:erlang.system_info(:system_architecture))
    }
  end

  defp remove_adapter_mix_environment do
    Enum.each(~w(MIX_BUILD_PATH MIX_DEPS_PATH MIX_ENV), &System.delete_env/1)
  end

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)
  end

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end

[request_path, output_path] =
  case System.argv() do
    ["--", request_path, output_path] -> [request_path, output_path]
    [request_path, output_path] -> [request_path, output_path]
  end

result =
  try do
    request_path |> File.read!() |> JSON.decode!() |> Elara.Benchmark.TargetRunner.run()
  rescue
    error ->
      %{
        "status" => "error",
        "kind" => "exception",
        "message" => Exception.message(error),
        "exception" => inspect(error.__struct__)
      }
  catch
    kind, reason ->
      %{"status" => "error", "kind" => to_string(kind), "message" => inspect(reason)}
  end

File.write!(output_path, JSON.encode!(result))
if result["status"] == "error", do: System.halt(1)
