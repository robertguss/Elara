defmodule Elara.Session do
  @moduledoc """
  Mechanical shell around Core. Bookkeeping only: tasks, timers, subscribers.
  """

  use GenServer

  alias Elara.Effect.{ControllerJournal, DeclarativeWrite, Job, Sidecar}
  alias Elara.FlightRecorder
  alias Elara.Message
  alias Elara.Message.{Assistant, ToolResult}
  alias Elara.Plugin.Server, as: PluginServer
  alias Elara.Protocol
  alias Elara.Provider
  alias Elara.Executor.{Request, Router}
  alias Elara.Session.{Core, Store}
  alias Elara.Tool
  alias Elara.Tool.{Ctx, PluginRef}

  @effect_recovery_timeout_ms 1_000

  defmodule Shell do
    @moduledoc false
    @type t :: %__MODULE__{
            core: Core.State.t(),
            store: Store.t(),
            provider: {module(), term()},
            cwd: String.t(),
            tool_timeout_ms: pos_integer(),
            effect_journal: pid() | nil,
            effect_journal_path: String.t(),
            effect_executor: GenServer.server() | nil,
            effect_executor_explicit?: boolean(),
            base_tools: %{String.t() => Tool.t()},
            plugins: [%{pid: pid(), path: String.t()}],
            subscribers: %{pid() => reference()},
            pending_reply: GenServer.from() | nil,
            tasks: %{
              reference() => {:provider | :tool, Core.ref(), pid(), {pid(), reference()} | nil}
            },
            pending_effects: %{Core.ref() => Job.t()},
            timers: %{Core.ref() => reference()}
          }

    defstruct [
      :core,
      :store,
      :provider,
      :cwd,
      :tool_timeout_ms,
      :id,
      :incarnation,
      :router,
      :workspace_id,
      :allowed_capabilities,
      :recorder,
      :effect_journal_path,
      :effect_executor,
      :effect_executor_explicit?,
      :effect_fault_hook,
      base_tools: %{},
      plugins: [],
      subscribers: %{},
      attachments: %{},
      controller: nil,
      next_event_seq: 1,
      event_log: :queue.new(),
      event_log_size: 0,
      event_log_limit: 1_000,
      effect_journal: nil,
      pending_reply: nil,
      tasks: %{},
      pending_effects: %{},
      timers: %{}
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init(opts) do
    core_config = Keyword.fetch!(opts, :core_config)
    provider = Keyword.fetch!(opts, :provider)
    cwd = Keyword.fetch!(opts, :cwd)
    store = Keyword.fetch!(opts, :store)
    tool_timeout_ms = Keyword.get(opts, :tool_timeout_ms, 30_000)
    plugin_paths = Keyword.get(opts, :plugin_paths, [])
    router = Keyword.fetch!(opts, :router)
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    allowed_capabilities = Keyword.fetch!(opts, :allowed_capabilities)
    effect_journal_path = Keyword.fetch!(opts, :effect_journal_path)
    effect_executor = Keyword.get(opts, :effect_executor)
    effect_executor_explicit? = Keyword.fetch!(opts, :effect_executor_explicit?)
    effect_fault_hook = Keyword.fetch!(opts, :effect_fault_hook)

    recovery = %{
      cwd: cwd,
      router: router,
      executor: effect_executor,
      executor_explicit?: effect_executor_explicit?,
      journal_path: effect_journal_path,
      workspace_id: workspace_id,
      allowed_capabilities: allowed_capabilities,
      fault_hook: effect_fault_hook
    }

    case prepare_session(store, core_config, recovery) do
      {:ok, store, core, effect_journal} ->
        with {:ok, _} <- Registry.register(Elara.Sessions, store.id, nil),
             {:ok, plugins, tools} <- start_plugins(plugin_paths, cwd, core.config.tools) do
          incarnation = new_incarnation()

          shell = %Shell{
            core: Core.replace_tools(core, tools),
            store: store,
            id: store.id,
            incarnation: incarnation,
            router: router,
            workspace_id: workspace_id,
            allowed_capabilities: allowed_capabilities,
            effect_journal_path: effect_journal_path,
            effect_executor: effect_executor,
            effect_executor_explicit?: effect_executor_explicit?,
            effect_fault_hook: effect_fault_hook,
            effect_journal: effect_journal,
            provider: provider,
            cwd: cwd,
            tool_timeout_ms: tool_timeout_ms,
            base_tools: core.config.tools,
            plugins: plugins
          }

          recorder = FlightRecorder.new(shell.core, shell.id, incarnation, store.path)
          {:ok, %{shell | recorder: recorder}}
        else
          {:error, reason} ->
            close_effect_journal(effect_journal)
            Store.release(store)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, shell) do
    close_effect_journal(shell.effect_journal)
    FlightRecorder.close(shell.recorder)
    Store.release(shell.store)
    :ok
  end

  @impl true
  def handle_call({:ask, prompt}, from, shell) do
    if Core.idle?(shell.core) do
      {:noreply, feed({:ask, prompt}, %{shell | pending_reply: from})}
    else
      {:reply, {:error, :busy}, shell}
    end
  end

  def handle_call(:session_id, _from, shell), do: {:reply, shell.id, shell}

  def handle_call(:status, _from, shell) do
    {:message_queue_len, mailbox_length} = Process.info(self(), :message_queue_len)

    status = %{
      id: shell.id,
      incarnation: shell.incarnation,
      phase: shell.core.phase,
      current_effect: current_effect(shell.core.phase),
      mailbox_length: mailbox_length,
      task_count: map_size(shell.tasks),
      subscriber_count: map_size(shell.subscribers) + map_size(shell.attachments),
      event_head: shell.next_event_seq - 1,
      event_retained: shell.event_log_size,
      recording_path: FlightRecorder.path(shell.recorder),
      recorded_transitions: shell.recorder.sequence,
      worker_health: Router.workers(shell.router)
    }

    {:reply, status, shell}
  end

  def handle_call({:ask_async, prompt}, _from, shell) do
    if Core.idle?(shell.core) do
      {:reply, :ok, feed({:ask, prompt}, shell)}
    else
      {:reply, {:error, :busy}, shell}
    end
  end

  def handle_call(:transcript, _from, shell) do
    {:reply, shell.core.history, shell}
  end

  def handle_call(:materialized_view, _from, shell) do
    {:reply, materialized_view(shell), shell}
  end

  def handle_call(:snapshot, _from, shell) do
    {:reply, snapshot(shell), shell}
  end

  def handle_call(:recording, _from, shell) do
    {:reply, FlightRecorder.snapshot(shell.recorder), shell}
  end

  def handle_call({:why, selector}, _from, shell) do
    {:reply, FlightRecorder.why(shell.recorder, selector), shell}
  end

  def handle_call(:cwd, _from, shell) do
    {:reply, shell.cwd, shell}
  end

  def handle_call({:replace_effect_executor, executor}, _from, shell) do
    shell = %{shell | effect_executor: executor, effect_executor_explicit?: true}
    {:reply, :ok, resume_pending_effects(shell)}
  end

  def handle_call(:child_config, _from, shell) do
    config = %{
      provider: shell.provider,
      cwd: shell.cwd,
      tools: Map.values(shell.base_tools),
      system: shell.core.config.system,
      max_iterations: shell.core.config.max_iterations,
      max_tool_output_bytes: shell.core.config.max_tool_output_bytes,
      tool_timeout_ms: shell.tool_timeout_ms,
      router: shell.router,
      workspace_id: shell.workspace_id,
      allowed_capabilities: shell.allowed_capabilities
    }

    {:reply, config, shell}
  end

  def handle_call(:plugins, _from, shell) do
    {:reply, Enum.map(shell.plugins, &PluginServer.info(&1.pid)), shell}
  end

  def handle_call(:reload_plugins, _from, shell) do
    if Core.idle?(shell.core) do
      case reload_plugins(shell) do
        {:ok, shell, infos} -> {:reply, {:ok, infos}, shell}
        {:error, shell, reason} -> {:reply, {:error, reason}, shell}
      end
    else
      {:reply, {:error, :busy}, shell}
    end
  end

  def handle_call(:user_entries, _from, shell) do
    entries =
      shell.store
      |> Store.user_entries()
      |> Enum.map(&%{id: &1.id, text: &1.message.text})

    {:reply, entries, shell}
  end

  def handle_call({:history_before, id}, _from, shell) do
    {:reply, Store.history_before_user(shell.store, id), shell}
  end

  def handle_call({:tree, id}, _from, shell) do
    idle_store_change(shell, fn store -> Store.move_before_user(store, id) end)
  end

  def handle_call(:clone, _from, shell) do
    idle_store_change(shell, fn store ->
      with {:ok, target} <- Store.clone(store) do
        {:ok, target, nil}
      end
    end)
  end

  def handle_call({:fork, id}, _from, shell) do
    idle_store_change(shell, fn store -> Store.fork_before_user(store, id) end)
  end

  def handle_call({:name, name}, _from, shell) do
    if Core.idle?(shell.core) do
      case Store.rename(shell.store, name) do
        {:ok, store} -> {:reply, :ok, %{shell | store: store}}
        {:error, reason} -> {:reply, {:error, reason}, shell}
      end
    else
      {:reply, {:error, :busy}, shell}
    end
  end

  def handle_call({:hydrate, store}, _from, shell) do
    if Core.idle?(shell.core) do
      case hydrate(store, shell.core.config) do
        {:ok, store, core} ->
          if store.path != shell.store.path do
            Store.release(shell.store)
          end

          core = Core.rebase_history(shell.core, core.history)
          recorder = FlightRecorder.segment(shell.recorder, core, :history_rebased)
          {:reply, {:ok, core.history}, %{shell | store: store, core: core, recorder: recorder}}

        {:error, reason} ->
          {:reply, {:error, reason}, shell}
      end
    else
      {:reply, {:error, :busy}, shell}
    end
  end

  def handle_call(:subscribe, {pid, _}, shell) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{shell | subscribers: Map.put(shell.subscribers, pid, ref)}}
  end

  def handle_call({:attach, mode, cursor, incarnation}, {pid, _}, shell)
      when mode in [:control, :observe] and is_integer(cursor) and cursor >= 0 do
    with :ok <- validate_incarnation(incarnation, shell),
         :ok <- validate_cursor(cursor, shell),
         :ok <- grant_control(mode, pid, shell) do
      ref = Process.monitor(pid)
      replay = Enum.filter(:queue.to_list(shell.event_log), fn {seq, _} -> seq > cursor end)
      attachment = %{monitor: ref, mode: mode, protocol: 1}

      shell = %{
        shell
        | attachments: Map.put(shell.attachments, pid, attachment),
          controller: if(mode == :control, do: pid, else: shell.controller)
      }

      reply = %{
        id: shell.id,
        incarnation: shell.incarnation,
        head: shell.next_event_seq - 1,
        replay: replay
      }

      {:reply, {:ok, reply}, shell}
    else
      {:error, reason} -> {:reply, {:error, reason}, shell}
    end
  end

  def handle_call({:attach_v2, mode, _cursor, _incarnation}, {pid, _}, shell)
      when mode in [:control, :observe] do
    case grant_control(mode, pid, shell) do
      :ok ->
        ref = Process.monitor(pid)
        attachment = %{monitor: ref, mode: mode, protocol: 2}

        shell = %{
          shell
          | attachments: Map.put(shell.attachments, pid, attachment),
            controller: if(mode == :control, do: pid, else: shell.controller)
        }

        {:reply, {:ok, snapshot(shell)}, shell}

      {:error, reason} ->
        {:reply, {:error, reason}, shell}
    end
  end

  def handle_call({:attached_command, command}, {pid, _}, shell) do
    if shell.controller == pid do
      handle_attached_command(command, shell)
    else
      {:reply, {:error, :not_controller}, shell}
    end
  end

  @impl true
  def handle_cast(:interrupt, shell) do
    shell = %{abort_running_tasks(shell) | pending_effects: %{}}
    {:noreply, feed(:interrupt, shell)}
  end

  @impl true
  def handle_info({task_ref, result}, shell) when is_map_key(shell.tasks, task_ref) do
    Process.demonitor(task_ref, [:flush])
    {kind, core_ref, _pid, plugin_lease} = Map.fetch!(shell.tasks, task_ref)
    shell = untrack_task(shell, task_ref, core_ref)

    shell =
      case {kind, result} do
        {:provider, {:ok, assistant, new_cfg}} ->
          shell = %{shell | provider: {elem(shell.provider, 0), new_cfg}}
          feed({:provider_result, core_ref, {:ok, assistant}}, shell)

        {:provider, {:error, error, new_cfg}} ->
          shell = %{shell | provider: {elem(shell.provider, 0), new_cfg}}
          feed({:provider_result, core_ref, {:error, error}}, shell)

        {:tool, %Sidecar.Result{status: :terminal} = result} ->
          shell = %{shell | pending_effects: Map.delete(shell.pending_effects, core_ref)}
          shell = feed({:tool_result, core_ref, result.outcome}, shell)
          persist_effect_result(shell, result)

        {:tool, %Sidecar.Result{status: :awaiting_executor, job: job}} ->
          shell = %{shell | pending_effects: Map.put(shell.pending_effects, core_ref, job)}
          resume_pending_effect(shell, core_ref, job)

        {:tool, %DeclarativeWrite.Result{status: :terminal} = result} ->
          shell = %{shell | pending_effects: Map.delete(shell.pending_effects, core_ref)}
          shell = feed({:tool_result, core_ref, result.outcome}, shell)
          persist_effect_result(shell, result)

        {:tool, %DeclarativeWrite.Result{status: :awaiting_executor, job: job}} ->
          shell = %{shell | pending_effects: Map.put(shell.pending_effects, core_ref, job)}
          resume_pending_effect(shell, core_ref, job)

        {:tool, result} ->
          outcome = settle_tool_result(plugin_lease, result)
          feed({:tool_result, core_ref, outcome}, shell)
      end

    {:noreply, shell}
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, shell)
      when is_map_key(shell.tasks, task_ref) do
    {kind, core_ref, _pid, plugin_lease} = Map.fetch!(shell.tasks, task_ref)
    shell = untrack_task(shell, task_ref, core_ref)
    abort_plugin_invocation(plugin_lease)

    shell =
      case kind do
        :tool ->
          feed({:tool_crashed, core_ref, Exception.format_exit(reason)}, shell)

        :provider ->
          err = %Provider.Error{
            kind: :crash,
            message: "provider task crashed: #{inspect(reason)}"
          }

          feed({:provider_result, core_ref, {:error, err}}, shell)
      end

    {:noreply, shell}
  end

  def handle_info({:DOWN, mon_ref, :process, pid, _reason}, shell) do
    subscribers =
      case Map.get(shell.subscribers, pid) do
        ^mon_ref -> Map.delete(shell.subscribers, pid)
        _ -> shell.subscribers
      end

    {attachment, attachments} =
      case Map.get(shell.attachments, pid) do
        %{monitor: ^mon_ref} = attachment -> {attachment, Map.delete(shell.attachments, pid)}
        _ -> {nil, shell.attachments}
      end

    controller =
      case attachment do
        %{monitor: ^mon_ref, mode: :control} -> nil
        _ -> shell.controller
      end

    {:noreply,
     %{shell | subscribers: subscribers, attachments: attachments, controller: controller}}
  end

  def handle_info({:tool_deadline, core_ref}, shell) do
    case find_task_by_core_ref(shell, core_ref, :tool) do
      nil ->
        {:noreply, shell}

      {task_ref, pid, plugin_lease} ->
        Process.demonitor(task_ref, [:flush])
        Process.exit(pid, :kill)
        shell = untrack_task(shell, task_ref, core_ref)
        abort_plugin_invocation(plugin_lease)
        {:noreply, feed({:tool_timeout, core_ref}, shell)}
    end
  end

  def handle_info(
        {port, {:exit_status, status}},
        %Shell{store: %Store{lock_handle: port}} = shell
      ) do
    {:stop, {:session_lock_lost, status}, shell}
  end

  def handle_info(_msg, shell), do: {:noreply, shell}

  defp prepare_session(store, config, %{executor: nil}) do
    case hydrate(store, config) do
      {:ok, store, core} -> {:ok, store, core, nil}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_session(store, config, recovery) do
    case Store.claim(store) do
      {:ok, store} -> prepare_claimed_session(store, config, recovery)
      {:error, _reason} = error -> error
    end
  end

  defp prepare_claimed_session(store, config, recovery) do
    case ControllerJournal.start_link(path: recovery.journal_path) do
      {:ok, journal} ->
        case recover_store(store, config.tools, journal, recovery) do
          {:ok, store} ->
            case persist_repairs(store, Core.new(config, Store.history(store))) do
              {:ok, store, core} ->
                {:ok, store, core, journal}

              {:error, reason} ->
                close_effect_journal(journal)
                Store.release(store)
                {:error, reason}
            end

          {:error, reason} ->
            close_effect_journal(journal)
            Store.release(store)
            {:error, reason}
        end

      {:error, reason} ->
        Store.release(store)
        {:error, reason}
    end
  end

  defp recover_store(store, tools, journal, recovery) do
    with {:ok, jobs} <- ControllerJournal.all(journal) do
      jobs_by_call = jobs_by_tool_call(jobs)

      store
      |> Store.history()
      |> unresolved_tool_calls()
      |> Enum.reduce_while({:ok, store}, fn call, {:ok, store} ->
        case Map.get(jobs_by_call, call.id) do
          nil ->
            case persist_not_started(store, call, tools) do
              {:ok, store} -> {:cont, {:ok, store}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          job ->
            case recover_tool_call(store, call, job, tools, journal, recovery) do
              {:ok, store} -> {:cont, {:ok, store}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
      end)
    end
  end

  defp persist_not_started(store, call, tools) do
    case {call.args, Map.get(tools, call.name)} do
      {{:ok, _args}, %Tool{plugin: nil, mutating: true}} ->
        Store.append(
          store,
          Message.tool_result(
            call,
            {:error,
             "effect not_started: no durable controller intent; " <>
               "action=do_not_reconcile_or_auto_retry"}
          )
        )

      _other ->
        {:ok, store}
    end
  end

  defp jobs_by_tool_call(jobs) do
    Enum.reduce(jobs, %{}, fn job, jobs_by_call ->
      case Map.get(job, :tool_call_id) do
        tool_call_id when is_binary(tool_call_id) and tool_call_id != "" ->
          Map.update(jobs_by_call, tool_call_id, job, fn existing ->
            if job.effect_id.sequence > existing.effect_id.sequence, do: job, else: existing
          end)

        _tool_call_id ->
          jobs_by_call
      end
    end)
  end

  defp unresolved_tool_calls(history) do
    {trailing_results, rest} =
      history
      |> Enum.reverse()
      |> Enum.split_while(&is_struct(&1, ToolResult))

    case rest do
      [%Assistant{tool_calls: calls} | _] when calls != [] ->
        completed = trailing_results |> Enum.map(& &1.call_id) |> MapSet.new()
        Enum.reject(calls, &MapSet.member?(completed, &1.id))

      _history ->
        []
    end
  end

  defp recover_tool_call(store, call, job, tools, journal, recovery) do
    cond do
      declarative_write_job?(job) ->
        recover_declarative_write(store, call, job, tools, journal, recovery)

      recovery.executor_explicit? ->
        recover_generic_tool_call(store, call, job, tools, journal, recovery)

      true ->
        {:error, {:unrecoverable_effect, job.job_id}}
    end
  end

  defp recover_declarative_write(store, call, job, tools, journal, recovery) do
    with {:ok, args} <- call.args,
         %Tool{} = tool <- Map.get(tools, call.name),
         true <- Tool.builtin_write?(tool),
         true <- recoverable_declarative_write?(job, call, args, recovery) do
      result =
        DeclarativeWrite.reconcile(
          recovery.executor,
          journal,
          job,
          recovery.cwd,
          timeout: @effect_recovery_timeout_ms,
          sidecar_hook: recovery.fault_hook,
          operation_hook: recovery.fault_hook,
          effect_observer: recovery.fault_hook,
          result_format: :write_tool
        )

      persist_recovered_tool_result(store, call, journal, result)
    else
      _reason -> {:error, {:unrecoverable_effect, job.job_id}}
    end
  end

  defp recover_generic_tool_call(store, call, job, tools, journal, recovery) do
    with {:ok, args} <- call.args,
         %Tool{plugin: nil, mutating: true} = tool <- Map.get(tools, call.name),
         true <- recoverable_job?(job, call, args, tool, recovery) do
      request = request_from_job(store.id, job, tool)
      operation = fn -> Router.execute(recovery.router, request, tool, recovery.cwd) end

      result =
        Sidecar.reconcile(
          recovery.executor,
          journal,
          job,
          operation,
          @effect_recovery_timeout_ms,
          recovery.fault_hook
        )

      persist_recovered_tool_result(store, call, journal, result)
    else
      _reason -> {:error, {:unrecoverable_effect, job.job_id}}
    end
  end

  defp persist_recovered_tool_result(store, call, journal, %{status: :terminal} = result) do
    with {:ok, store} <- Store.append(store, Message.tool_result(call, result.outcome)),
         :ok <- mark_effect_result_persisted(journal, result) do
      {:ok, store}
    end
  end

  defp persist_recovered_tool_result(_store, _call, _journal, %{
         status: :awaiting_executor,
         job: job
       }) do
    {:error, {:effect_executor_unavailable, job.job_id}}
  end

  defp recoverable_declarative_write?(job, call, args, recovery) do
    authority_scope = %{
      allowed_capabilities: canonical_capabilities(recovery.allowed_capabilities),
      placement: :local
    }

    job.operation_kind == :declarative_write and
      job.tool_call_id == call.id and
      job.tool_name == "declarative_write" and
      job.tool_version == "1" and
      job.arguments["path"] == args["path"] and
      job.arguments["desired"]["content"] == args["content"] and
      job.workspace_id == recovery.workspace_id and
      job.required_capabilities == ["filesystem:write"] and
      job.authority_scope == authority_scope and
      DeclarativeWrite.validate(job, recovery.cwd) == :ok
  end

  defp declarative_write_job?(%Job{operation_kind: :declarative_write}), do: true
  defp declarative_write_job?(%Job{}), do: false

  defp recoverable_job?(job, call, args, tool, recovery) do
    authority_scope = %{
      allowed_capabilities: canonical_capabilities(recovery.allowed_capabilities),
      placement: tool.placement
    }

    job.operation_kind == :run_tool and
      job.tool_call_id == call.id and
      job.tool_name == call.name and
      job.tool_version == tool.version and
      job.arguments == args and
      job.workspace_id == recovery.workspace_id and
      job.required_capabilities == canonical_capabilities(tool.capabilities) and
      job.authority_scope == authority_scope
  end

  defp canonical_capabilities(:all), do: :all

  defp canonical_capabilities(capabilities) when is_list(capabilities) do
    capabilities |> Enum.uniq() |> Enum.sort()
  end

  defp request_from_job(session_id, job, tool) do
    %Request{
      job_id: job.job_id,
      operation_digest: job.operation_digest,
      tool_call_id: job.tool_call_id,
      session_id: session_id,
      tool_name: job.tool_name,
      tool_version: job.tool_version,
      arguments: job.arguments,
      workspace_id: job.workspace_id,
      deadline_ms: System.system_time(:millisecond) + @effect_recovery_timeout_ms,
      max_output_bytes: 16_384,
      cancellation_id: new_cancellation_id(),
      required_capabilities: job.required_capabilities,
      placement: tool.placement,
      mutating: true
    }
  end

  defp resume_pending_effects(shell) do
    Enum.reduce(shell.pending_effects, shell, fn {core_ref, job}, shell ->
      resume_pending_effect(shell, core_ref, job)
    end)
  end

  defp resume_pending_effect(shell, core_ref, job) do
    with true <- effect_executor_available?(shell.effect_executor),
         {:ok, operation} <- pending_effect_operation(shell, job) do
      task = Task.Supervisor.async_nolink(Elara.TaskSup, operation)

      shell
      |> Map.update!(:pending_effects, &Map.delete(&1, core_ref))
      |> track_tool_task(task, core_ref, nil)
    else
      _unavailable_or_invalid -> fail_closed_pending_effect(shell, core_ref, job)
    end
  end

  defp fail_closed_pending_effect(shell, core_ref, job) do
    if declarative_write_job?(job) and not shell.effect_executor_explicit? do
      result =
        DeclarativeWrite.reconcile_unavailable(
          shell.effect_journal,
          job,
          shell.cwd
        )

      shell = %{shell | pending_effects: Map.delete(shell.pending_effects, core_ref)}
      shell = feed({:tool_result, core_ref, result.outcome}, shell)
      persist_effect_result(shell, result)
    else
      shell
    end
  end

  defp pending_effect_operation(shell, job) do
    cond do
      declarative_write_job?(job) ->
        {:ok,
         fn ->
           DeclarativeWrite.reconcile(
             shell.effect_executor,
             shell.effect_journal,
             job,
             shell.cwd,
             timeout: @effect_recovery_timeout_ms,
             sidecar_hook: shell.effect_fault_hook,
             operation_hook: shell.effect_fault_hook,
             effect_observer: shell.effect_fault_hook,
             result_format: :write_tool
           )
         end}

      shell.effect_executor_explicit? ->
        generic_pending_effect_operation(shell, job)

      true ->
        :error
    end
  end

  defp generic_pending_effect_operation(shell, job) do
    case Map.get(shell.core.config.tools, job.tool_name) do
      %Tool{plugin: nil, mutating: true} = tool ->
        request = request_from_job(shell.id, job, tool)
        operation = fn -> Router.execute(shell.router, request, tool, shell.cwd) end

        {:ok,
         fn ->
           Sidecar.reconcile(
             shell.effect_executor,
             shell.effect_journal,
             job,
             operation,
             @effect_recovery_timeout_ms,
             shell.effect_fault_hook
           )
         end}

      _invalid_tool ->
        :error
    end
  end

  defp effect_executor_available?(nil), do: false

  defp effect_executor_available?(executor) do
    is_pid(GenServer.whereis(executor))
  end

  defp hydrate(store, config) do
    with {:ok, store} <- Store.claim(store) do
      persist_repairs(store, Core.new(config, Store.history(store)))
    end
  end

  defp idle_store_change(shell, change) do
    if Core.idle?(shell.core) do
      case change.(shell.store) do
        {:ok, store, prompt} ->
          case Store.claim(store) do
            {:ok, store} ->
              if store.path != shell.store.path, do: Store.release(shell.store)
              core = Core.rebase_history(shell.core, Store.history(store))
              recorder = FlightRecorder.segment(shell.recorder, core, :history_rebased)

              {:reply, {:ok, prompt, core.history},
               %{shell | store: store, core: core, recorder: recorder}}

            {:error, reason} ->
              {:reply, {:error, reason}, shell}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, shell}
      end
    else
      {:reply, {:error, :busy}, shell}
    end
  end

  defp persist_repairs(store, core) do
    extras = Enum.drop(core.history, length(Store.history(store)))

    extras
    |> Enum.reduce_while({:ok, store}, fn message, {:ok, store} ->
      case Store.append(store, message) do
        {:ok, store} -> {:cont, {:ok, store}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, store} ->
        {:ok, store, core}

      {:error, reason} ->
        Store.release(store)
        {:error, reason}
    end
  end

  defp persist_effect_result(shell, %Sidecar.Result{} = result) do
    case mark_effect_result_persisted(shell.effect_journal, result) do
      :ok -> shell
      {:error, reason} -> raise "effect result persistence failed: #{inspect(reason)}"
    end
  end

  defp persist_effect_result(shell, %DeclarativeWrite.Result{} = result) do
    case mark_effect_result_persisted(shell.effect_journal, result) do
      :ok -> shell
      {:error, reason} -> raise "effect result persistence failed: #{inspect(reason)}"
    end
  end

  defp mark_effect_result_persisted(_journal, %Sidecar.Result{executor_record: nil}), do: :ok

  defp mark_effect_result_persisted(journal, %Sidecar.Result{job: job}) do
    case ControllerJournal.mark_result_persisted(journal, job.job_id) do
      {:ok, _observation} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp mark_effect_result_persisted(_journal, %DeclarativeWrite.Result{executor_record: nil}),
    do: :ok

  defp mark_effect_result_persisted(journal, %DeclarativeWrite.Result{job: job}) do
    case ControllerJournal.mark_result_persisted(journal, job.job_id) do
      {:ok, _observation} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp feed(fact, shell) do
    {recorder, begin} = FlightRecorder.begin_transition(shell.recorder, shell.core, fact)
    message_offset = length(shell.core.history)
    {core, effects} = Core.step(shell.core, fact)
    {recorder, transition} = FlightRecorder.complete_transition(recorder, begin, core, effects)
    shell = %{shell | core: core, recorder: recorder}
    patch_context = {message_offset, Enum.drop(core.history, message_offset)}

    effects
    |> Enum.with_index()
    |> Enum.reduce(shell, fn {effect, index}, shell ->
      effect_id = Map.merge(transition.id, %{effect_index: index})
      run_effect(effect, effect_id, shell, patch_context)
    end)
  end

  defp run_effect(
         {:emit, {:message_appended, message} = event},
         effect_id,
         shell,
         patch_context
       ) do
    case Store.append(shell.store, message) do
      {:ok, store} ->
        emit(event, effect_id, %{shell | store: store}, patch_context)

      {:error, reason} ->
        raise "session persistence failed: #{inspect(reason)}"
    end
  end

  defp run_effect({:emit, event}, effect_id, shell, patch_context) do
    emit(event, effect_id, shell, patch_context)
  end

  defp run_effect({:call_provider, core_ref, request}, _effect_id, shell, _patch_context) do
    {mod, cfg} = shell.provider
    task = Task.Supervisor.async_nolink(Elara.TaskSup, mod, :chat, [cfg, request])
    track_task(shell, task, :provider, core_ref)
  end

  defp run_effect(
         {:run_tool, core_ref, call, %Tool{plugin: %PluginRef{} = plugin} = tool},
         effect_id,
         shell,
         _patch_context
       ) do
    {:ok, args} = call.args

    case PluginServer.checkout(plugin.server, plugin.generation) do
      {:ok, lease, module, plugin_state} ->
        ctx = %Ctx{cwd: shell.cwd}
        request = tool_request(shell, call, tool, args)
        {shell, request, _job} = commit_tool_intent(shell, effect_id, request, tool)
        config = %{module: module, plugin_state: plugin_state, ctx: ctx}

        task =
          Task.Supervisor.async_nolink(
            Elara.TaskSup,
            Elara.Executor.PluginLocal,
            :execute,
            [config, request, tool]
          )

        track_tool_task(shell, task, core_ref, {plugin.server, lease})

      {:error, :busy} ->
        feed({:tool_result, core_ref, {:error, "plugin is busy"}}, shell)

      {:error, :stale_generation} ->
        feed({:tool_result, core_ref, {:error, "plugin generation is stale"}}, shell)
    end
  end

  defp run_effect({:run_tool, core_ref, call, tool}, effect_id, shell, _patch_context) do
    {:ok, args} = call.args

    if capabilities_allowed?(tool.capabilities, shell.allowed_capabilities) do
      if Tool.builtin_write?(tool) do
        run_declarative_write(shell, effect_id, core_ref, call, args)
      else
        run_routed_tool(shell, effect_id, core_ref, call, tool, args)
      end
    else
      feed(
        {:tool_result, core_ref, {:error, "permission denied: required capability not granted"}},
        shell
      )
    end
  end

  defp run_declarative_write(shell, effect_id, core_ref, call, args) do
    case DeclarativeWrite.prepare_arguments(args, shell.cwd) do
      {:ok, arguments} ->
        {shell, job} = commit_declarative_write_intent(shell, effect_id, call, arguments)

        task =
          Task.Supervisor.async_nolink(Elara.TaskSup, fn ->
            DeclarativeWrite.execute(
              shell.effect_executor,
              shell.effect_journal,
              job,
              shell.cwd,
              timeout: shell.tool_timeout_ms,
              sidecar_hook: shell.effect_fault_hook,
              operation_hook: shell.effect_fault_hook,
              effect_observer: shell.effect_fault_hook,
              result_format: :write_tool
            )
          end)

        track_tool_task(shell, task, core_ref, nil)

      {:error, message} ->
        feed({:tool_result, core_ref, {:error, message}}, shell)
    end
  end

  defp run_routed_tool(shell, effect_id, core_ref, call, tool, args) do
    request = tool_request(shell, call, tool, args)
    {shell, request, job} = commit_tool_intent(shell, effect_id, request, tool)

    task =
      if job && shell.effect_executor && shell.effect_executor_explicit? do
        operation = fn -> Router.execute(shell.router, request, tool, shell.cwd) end

        Task.Supervisor.async_nolink(Elara.TaskSup, fn ->
          Sidecar.execute(
            shell.effect_executor,
            shell.effect_journal,
            job,
            operation,
            @effect_recovery_timeout_ms,
            shell.effect_fault_hook
          )
        end)
      else
        Task.Supervisor.async_nolink(
          Elara.TaskSup,
          Router,
          :execute,
          [shell.router, request, tool, shell.cwd]
        )
      end

    track_tool_task(shell, task, core_ref, nil)
  end

  defp emit(event, effect_id, shell, patch_context) do
    seq = shell.next_event_seq
    event_log = :queue.in({seq, event}, shell.event_log)
    event_log_size = shell.event_log_size + 1
    {event_log, event_log_size} = trim_event_log(event_log, event_log_size, shell.event_log_limit)

    shell = %{
      shell
      | next_event_seq: seq + 1,
        event_log: event_log,
        event_log_size: event_log_size,
        recorder: FlightRecorder.link_event(shell.recorder, seq, effect_id)
    }

    Enum.each(shell.subscribers, fn {pid, _} ->
      send(pid, {:elara, shell.id, event})
    end)

    patch_ops = Protocol.patch_ops(event, shell.core, patch_context)

    Enum.each(shell.attachments, fn
      {pid, %{protocol: 2}} ->
        send(pid, {:elara_patch, shell.id, shell.incarnation, seq, patch_ops})

      {pid, _attachment} ->
        send(pid, {:elara_event, shell.id, shell.incarnation, seq, event})
    end)

    case {event, shell.pending_reply} do
      {{:turn_ended, {:completed, text}}, from} when from != nil ->
        GenServer.reply(from, {:ok, text})
        %{shell | pending_reply: nil}

      {{:turn_ended, outcome}, from} when from != nil ->
        GenServer.reply(from, {:error, outcome})
        %{shell | pending_reply: nil}

      _ ->
        shell
    end
  end

  defp track_task(shell, %Task{ref: ref, pid: pid}, kind, core_ref, plugin_lease \\ nil) do
    %{shell | tasks: Map.put(shell.tasks, ref, {kind, core_ref, pid, plugin_lease})}
  end

  defp track_tool_task(shell, task, core_ref, plugin_lease) do
    timer = Process.send_after(self(), {:tool_deadline, core_ref}, shell.tool_timeout_ms)

    shell
    |> track_task(task, :tool, core_ref, plugin_lease)
    |> Map.update!(:timers, &Map.put(&1, core_ref, timer))
  end

  defp untrack_task(shell, task_ref, core_ref) do
    shell = %{shell | tasks: Map.delete(shell.tasks, task_ref)}

    case Map.pop(shell.timers, core_ref) do
      {nil, timers} ->
        %{shell | timers: timers}

      {timer, timers} ->
        Process.cancel_timer(timer)
        # Flush a timer message that may already be in the mailbox.
        receive do
          {:tool_deadline, ^core_ref} -> :ok
        after
          0 -> :ok
        end

        %{shell | timers: timers}
    end
  end

  defp find_task_by_core_ref(shell, core_ref, kind) do
    Enum.find_value(shell.tasks, fn
      {task_ref, {^kind, ^core_ref, pid, plugin_lease}} -> {task_ref, pid, plugin_lease}
      _ -> nil
    end)
  end

  defp abort_running_tasks(shell) do
    Enum.reduce(Map.keys(shell.tasks), shell, fn task_ref, shell ->
      {kind, core_ref, pid, plugin_lease} = Map.fetch!(shell.tasks, task_ref)
      _ = kind

      # Plugin checkouts stay with the in-flight invocation so reload remains
      # :busy until that call ends. Builtin/provider tasks are killed now.
      if plugin_lease do
        shell
      else
        Process.demonitor(task_ref, [:flush])
        Process.exit(pid, :kill)

        receive do
          {^task_ref, _result} -> :ok
        after
          0 -> :ok
        end

        untrack_task(shell, task_ref, core_ref)
      end
    end)
  end

  defp settle_tool_result(nil, outcome), do: outcome

  defp settle_tool_result({server, lease}, {:commit, outcome, plugin_state}) do
    case PluginServer.commit_invocation(server, lease, plugin_state) do
      :ok -> outcome
      {:error, :stale_lease} -> {:error, "plugin invocation expired"}
    end
  end

  defp settle_tool_result({server, lease}, {:abort, outcome}) do
    :ok = PluginServer.abort_invocation(server, lease)
    outcome
  end

  defp settle_tool_result(plugin_lease, _result) do
    abort_plugin_invocation(plugin_lease)
    {:error, "plugin returned an invalid invocation result"}
  end

  defp abort_plugin_invocation(nil), do: :ok

  defp abort_plugin_invocation({server, lease}) do
    PluginServer.abort_invocation(server, lease)
  end

  defp start_plugins(paths, cwd, base_tools) when is_list(paths) do
    paths
    |> Enum.reduce_while({:ok, [], MapSet.new(), []}, fn
      path, {:ok, plugins, ids, tools} when is_binary(path) ->
        expanded = Path.expand(path, cwd)
        opts = [owner: self(), cwd: cwd, path: expanded]

        case DynamicSupervisor.start_child(Elara.PluginSup, {PluginServer, opts}) do
          {:ok, pid} ->
            info = PluginServer.info(pid)

            if MapSet.member?(ids, info.id) do
              {:halt, {:error, {:plugin_load_failed, expanded, {:duplicate_plugin_id, info.id}}}}
            else
              plugin = %{pid: pid, path: expanded}

              {:cont,
               {:ok, [plugin | plugins], MapSet.put(ids, info.id),
                PluginServer.tools(pid) ++ tools}}
            end

          {:error, reason} ->
            {:halt, {:error, {:plugin_load_failed, expanded, reason}}}
        end

      _path, _acc ->
        {:halt, {:error, {:plugin_load_failed, "<plugins>", :invalid_plugin_path}}}
    end)
    |> case do
      {:ok, plugins, _ids, plugin_tools} ->
        case tool_table(Map.values(base_tools) ++ plugin_tools) do
          {:ok, tools} -> {:ok, Enum.reverse(plugins), tools}
          {:error, reason} -> {:error, {:plugin_load_failed, "<registry>", reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_plugins(_paths, _cwd, _base_tools) do
    {:error, {:plugin_load_failed, "<plugins>", :invalid_plugins}}
  end

  defp reload_plugins(shell) do
    case prepare_plugins(shell.plugins) do
      {:ok, prepared} ->
        case prepared_tool_table(shell.base_tools, prepared) do
          {:ok, tools} ->
            Enum.each(prepared, fn %{plugin: plugin} ->
              :ok = PluginServer.commit_reload(plugin.pid)
            end)

            core = Core.replace_tools(shell.core, tools)
            recorder = FlightRecorder.segment(shell.recorder, core, :plugins_reloaded)
            infos = Enum.map(shell.plugins, &PluginServer.info(&1.pid))
            {:ok, %{shell | core: core, recorder: recorder}, infos}

          {:error, path, reason} ->
            abort_prepared(prepared)
            {:error, shell, {:plugin_reload_failed, path, reason}}
        end

      {:error, prepared, path, reason} ->
        abort_prepared(prepared)
        {:error, shell, {:plugin_reload_failed, path, reason}}
    end
  end

  defp prepare_plugins(plugins) do
    Enum.reduce_while(plugins, {:ok, []}, fn plugin, {:ok, prepared} ->
      case PluginServer.prepare_reload(plugin.pid) do
        {:ok, tools} ->
          {:cont, {:ok, [%{plugin: plugin, tools: tools} | prepared]}}

        {:error, reason} ->
          {:halt, {:error, Enum.reverse(prepared), plugin.path, reason}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      error -> error
    end
  end

  defp prepared_tool_table(base_tools, prepared) do
    Enum.reduce_while(prepared, {:ok, base_tools}, fn entry, {:ok, tools} ->
      case tool_table(Map.values(tools) ++ entry.tools) do
        {:ok, tools} -> {:cont, {:ok, tools}}
        {:error, reason} -> {:halt, {:error, entry.plugin.path, reason}}
      end
    end)
  end

  defp abort_prepared(prepared) do
    Enum.each(prepared, fn %{plugin: plugin} ->
      :ok = PluginServer.abort_reload(plugin.pid)
    end)
  end

  defp tool_table(tools) do
    try do
      {:ok, Tool.table(tools)}
    rescue
      error in ArgumentError -> {:error, Exception.message(error)}
    end
  end

  defp handle_attached_command({:ask, prompt}, shell) when is_binary(prompt) do
    if Core.idle?(shell.core) do
      {:reply, :ok, feed({:ask, prompt}, shell)}
    else
      {:reply, {:error, :busy}, shell}
    end
  end

  defp handle_attached_command(:interrupt, shell) do
    {:reply, :ok, feed(:interrupt, abort_running_tasks(shell))}
  end

  defp handle_attached_command(_command, shell), do: {:reply, {:error, :invalid_command}, shell}

  defp validate_incarnation(nil, _shell), do: :ok
  defp validate_incarnation(incarnation, %{incarnation: incarnation}), do: :ok
  defp validate_incarnation(_incarnation, _shell), do: {:error, :stale_incarnation}

  defp validate_cursor(cursor, shell) when cursor > shell.next_event_seq - 1,
    do: {:error, :invalid_cursor}

  defp validate_cursor(0, _shell), do: :ok

  defp validate_cursor(cursor, shell) do
    case :queue.peek(shell.event_log) do
      {:value, {first, _}} when cursor < first - 1 -> {:error, :cursor_expired}
      _ -> :ok
    end
  end

  defp snapshot(shell) do
    %{
      id: shell.id,
      incarnation: shell.incarnation,
      head: shell.next_event_seq - 1,
      snapshot: materialized_view(shell)
    }
  end

  defp materialized_view(shell) do
    Protocol.snapshot(shell.id, shell.incarnation, shell.core)
  end

  defp grant_control(:observe, _pid, _shell), do: :ok

  defp grant_control(:control, pid, %{controller: controller}) when controller in [nil, pid],
    do: :ok

  defp grant_control(:control, _pid, _shell), do: {:error, :control_taken}

  defp trim_event_log(queue, size, limit) when size > limit do
    {{:value, _}, queue} = :queue.out(queue)
    trim_event_log(queue, size - 1, limit)
  end

  defp trim_event_log(queue, size, _limit), do: {queue, size}

  defp current_effect(:idle), do: nil
  defp current_effect({:calling_provider, ref, _}), do: %{kind: :provider, ref: ref}

  defp current_effect({:running_tool, ref, call, _rest, _}),
    do: %{kind: :tool, ref: ref, name: call.name}

  defp new_incarnation do
    12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp new_cancellation_id do
    12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp tool_request(shell, call, tool, args) do
    %Request{
      tool_call_id: call.id,
      session_id: shell.id,
      tool_name: call.name,
      tool_version: tool.version,
      arguments: args,
      workspace_id: shell.workspace_id,
      deadline_ms: System.system_time(:millisecond) + shell.tool_timeout_ms,
      max_output_bytes: shell.core.config.max_tool_output_bytes,
      cancellation_id: new_cancellation_id(),
      required_capabilities: tool.capabilities,
      placement: tool.placement,
      mutating: tool.mutating
    }
  end

  defp commit_declarative_write_intent(shell, effect_id, call, arguments) do
    shell = ensure_effect_journal(shell)

    job =
      Job.new(effect_id,
        operation_kind: :declarative_write,
        tool_call_id: call.id,
        tool_name: "declarative_write",
        tool_version: "1",
        arguments: arguments,
        workspace_id: shell.workspace_id,
        required_capabilities: ["filesystem:write"],
        allowed_capabilities: shell.allowed_capabilities,
        placement: :local
      )

    case ControllerJournal.commit_intent(shell.effect_journal, job, shell.effect_fault_hook) do
      {:ok, ^job} -> {shell, job}
      {:error, reason} -> raise "controller intent persistence failed: #{inspect(reason)}"
    end
  end

  defp commit_tool_intent(shell, _effect_id, %Request{mutating: false} = request, _tool),
    do: {shell, request, nil}

  defp commit_tool_intent(shell, effect_id, request, tool) do
    shell = ensure_effect_journal(shell)

    job =
      Job.new(effect_id,
        operation_kind: :run_tool,
        tool_call_id: request.tool_call_id,
        tool_name: request.tool_name,
        tool_version: request.tool_version,
        arguments: request.arguments,
        workspace_id: request.workspace_id,
        required_capabilities: request.required_capabilities,
        allowed_capabilities: shell.allowed_capabilities,
        placement: tool.placement
      )

    case ControllerJournal.commit_intent(shell.effect_journal, job, shell.effect_fault_hook) do
      {:ok, ^job} ->
        request = %{
          request
          | job_id: job.job_id,
            operation_digest: job.operation_digest
        }

        {shell, request, job}

      {:error, reason} ->
        raise "controller intent persistence failed: #{inspect(reason)}"
    end
  end

  defp ensure_effect_journal(%{effect_journal: nil} = shell) do
    case ControllerJournal.start_link(path: shell.effect_journal_path) do
      {:ok, journal} -> %{shell | effect_journal: journal}
      {:error, reason} -> raise "controller journal failed to open: #{inspect(reason)}"
    end
  end

  defp ensure_effect_journal(shell), do: shell

  defp close_effect_journal(nil), do: :ok

  defp close_effect_journal(journal) do
    if Process.alive?(journal), do: ControllerJournal.close(journal), else: :ok
  end

  defp capabilities_allowed?(_required, :all), do: true

  defp capabilities_allowed?(required, allowed) when is_list(allowed) do
    allowed = MapSet.new(allowed)
    Enum.all?(required, &MapSet.member?(allowed, &1))
  end
end
