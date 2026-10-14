defmodule Elara.Session do
  @moduledoc """
  Mechanical shell around Core. Bookkeeping only: tasks, timers, subscribers.
  """

  use GenServer

  alias Elara.Effect.{ControllerJournal, DeclarativeWrite, Executor, Job, Sidecar}
  alias Elara.Effect.ExecutorLedger
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.CommandRules

  require ExecutorLedger
  alias Elara.FlightRecorder
  alias Elara.Message
  alias Elara.Message.{Assistant, ToolCall, ToolResult}
  alias Elara.Output
  alias Elara.Plugin.Server, as: PluginServer
  alias Elara.Protocol
  alias Elara.Provider
  alias Elara.Executor.{Request, Router}
  alias Elara.Session.{Context, Core, Handoff, Store}
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
            effect_journal: pid() | nil,
            effect_journal_path: String.t(),
            effect_executor: GenServer.server() | nil,
            effect_executor_explicit?: boolean(),
            base_tools: %{String.t() => Tool.t()},
            plugins: [%{pid: pid(), path: String.t()}],
            subscribers: %{pid() => reference()},
            pending_reply: GenServer.from() | nil,
            tasks: %{
              reference() =>
                {:provider | :tool, Core.ref(), pid(), {pid(), reference(), boolean()} | nil}
            },
            pending_effects: %{Core.ref() => Job.t()},
            timers: %{Core.ref() => reference()},
            retry_timer: {Core.ref(), reference()} | nil
          }

    defstruct [
      :core,
      :store,
      :provider,
      :cwd,
      :id,
      :incarnation,
      :router,
      :workspace_id,
      :allowed_capabilities,
      :recorder,
      :effect_journal_path,
      :effect_executor,
      :effect_executor_explicit?,
      :effect_recovery_task,
      :catalog_task,
      :catalog_timer,
      :effect_fault_hook,
      :base_system,
      :context_limit,
      :handoff_fault_hook,
      :workspace_diff,
      :undo_preview,
      :undo_recovery,
      :command_rules,
      :approval_wait,
      skills: %{skills: %{}, diagnostics: []},
      skill_options: [],
      instructions: %{},
      presented_instructions: %{},
      instruction_targets: [],
      base_tools: %{},
      plugins: [],
      discover_plugins?: false,
      subscribers: %{},
      attachments: %{},
      controller: nil,
      next_event_seq: 1,
      effect_journal: nil,
      pending_reply: nil,
      tasks: %{},
      pending_effects: %{},
      effect_recovery_pending: [],
      timers: %{},
      retry_timer: nil,
      consuming_id: nil,
      completion_waiters: %{},
      completion_claims: %{}
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def start_handoff(id, paused) do
    with {:ok, pid} <- Elara.session_pid(id), do: GenServer.call(pid, {:start_handoff, paused})
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
    core_config = %{core_config | command_preflight: true}
    provider = Keyword.fetch!(opts, :provider)
    cwd = Keyword.fetch!(opts, :cwd)
    store = Keyword.fetch!(opts, :store)

    core_config = restore_provider_settings(core_config, store, provider)

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
      {:ok, store, core, effect_journal, effect_recovery_pending} ->
        store =
          if Keyword.get(opts, :pause_inputs, false),
            do: %{store | inputs_paused: true},
            else: store

        with {:ok, store} <- Handoff.recover(store),
             {:ok, store} <- Store.set_provider_settings(store, core.config.provider_settings),
             {:ok, rules} <-
               CommandRules.review(
                 cwd,
                 store.context["command_rules"],
                 Application.fetch_env!(:elara, :command_rules)
               ),
             {:ok, store} <-
               if(
                 rules.retained == %{"deny" => [], "ask" => []} and
                   not Map.has_key?(store.context, "command_rules"),
                 do: {:ok, store},
                 else:
                   Store.save(%{
                     store
                     | context: Map.put(store.context, "command_rules", rules.retained)
                   })
               ),
             {:ok, _} <- Registry.register(Elara.Sessions, store.id, nil),
             {:ok, plugins, tools} <- start_plugins(plugin_paths, cwd, core.config.tools) do
          incarnation = new_incarnation()
          core = Context.restore(core, store)

          core = %{
            core
            | read_only:
                Map.get(store.context, "read_only", Keyword.get(opts, :read_only, false)),
              web_content_entered:
                core.web_content_entered or Keyword.get(opts, :web_content_entered, false)
          }

          store =
            if core.read_only and store.context["read_only"] != true do
              {:ok, store} =
                Store.save(%{store | context: Map.put(store.context, "read_only", true)})

              store
            else
              store
            end

          store =
            if core.web_content_entered and store.context["web_content_entered"] != true do
              {:ok, store} =
                Store.save(%{
                  store
                  | context: Map.put(store.context, "web_content_entered", true)
                })

              store
            else
              store
            end

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
            effect_recovery_pending: effect_recovery_pending,
            provider: provider,
            cwd: cwd,
            base_system: Keyword.get(opts, :base_system, core.config.system),
            skill_options: Keyword.get(opts, :skill_options, []),
            skills: Keyword.get(opts, :skills, %{skills: %{}, diagnostics: []}),
            instructions: Keyword.get(opts, :instructions, %{}),
            context_limit: Keyword.get(opts, :context_limit),
            handoff_fault_hook: Keyword.fetch!(opts, :handoff_fault_hook),
            workspace_diff: Elara.WorkspaceDiff.open(store),
            command_rules: Application.fetch_env!(:elara, :command_rules),
            approval_wait: Keyword.fetch!(opts, :approval_wait),
            base_tools: core.config.tools,
            discover_plugins?: Keyword.get(opts, :discover_plugins?, false),
            plugins: plugins
          }

          shell = %{shell | effect_recovery_pending: pending_receipt_effects(shell)}
          {shell, recovered?} = finish_restart_recovery(shell)
          recorder = FlightRecorder.new(shell.core, shell.id, incarnation, store.path)
          shell = recover_workspace_undo(%{shell | recorder: recorder})
          if recovered?, do: send(self(), :inbox_changed)
          if shell.effect_recovery_pending == [], do: send(self(), :drain_inputs)
          if shell.effect_recovery_pending != [], do: send(self(), :check_effect_recovery)
          if Handoff.frozen?(store), do: send(self(), :advance_handoff)
          send(self(), :refresh_catalog)
          {:ok, shell}
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
    if shell.effect_recovery_task, do: Task.shutdown(shell.effect_recovery_task, :brutal_kill)
    if shell.catalog_task, do: Task.shutdown(shell.catalog_task, :brutal_kill)
    if shell.catalog_timer, do: Process.cancel_timer(shell.catalog_timer)
    close_effect_journal(shell.effect_journal)
    FlightRecorder.close(shell.recorder)
    Store.release(shell.store)
    :ok
  end

  @impl true
  def handle_call({:ask, _} = command, from, %{store: %{context: %{"handoff" => _}}} = shell) do
    relay_handoff_ask(shell, command, from)
  end

  def handle_call({:ask, prompt}, from, shell) do
    with :ok <- input_ready(shell, []) do
      {:noreply, feed({:ask, prompt}, %{shell | pending_reply: from})}
    else
      {:error, reason} -> {:reply, {:error, reason}, shell}
    end
  end

  def handle_call(
        {:ask_input, _, _, _} = command,
        from,
        %{store: %{context: %{"handoff" => _}}} = shell
      ) do
    relay_handoff_ask(shell, command, from)
  end

  def handle_call({:ask_input, prompt, references, images}, from, shell) do
    with :ok <- input_ready(shell, images),
         {:ok, user} <- Elara.Attachment.prepare(shell.cwd, prompt, references, images) do
      {:noreply, feed({:ask_input, user}, %{shell | pending_reply: from})}
    else
      {:error, reason} -> {:reply, {:error, reason}, shell}
    end
  end

  def handle_call(:session_id, _from, shell), do: {:reply, shell.id, shell}

  def handle_call(:listing, _from, shell) do
    {:reply,
     %{
       id: shell.id,
       incarnation: shell.incarnation,
       cwd: shell.cwd,
       name: shell.store.name,
       updated_at: listing_updated_at(shell.store),
       model: shell.core.config.provider_settings && shell.core.config.provider_settings["model"],
       provider: shell.provider |> elem(0) |> inspect(),
       phase: shell.core.phase,
       event_head: shell.next_event_seq - 1
     }, shell}
  end

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
      recording_path: FlightRecorder.path(shell.recorder),
      recorded_transitions: shell.recorder.sequence,
      instructions: shell.instructions,
      skills: shell.skills,
      worker_health: Router.workers(shell.router)
    }

    {:reply, status, shell}
  end

  def handle_call(
        {:ask_async, _} = command,
        _from,
        %{store: %{context: %{"handoff" => _}}} = shell
      ) do
    {:reply, forward_handoff(shell, command), shell}
  end

  def handle_call({:ask_async, prompt}, _from, shell) do
    with :ok <- input_ready(shell, []) do
      {:reply, :ok, feed({:ask, prompt}, shell)}
    else
      {:error, reason} -> {:reply, {:error, reason}, shell}
    end
  end

  def handle_call(:transcript, _from, shell) do
    {:reply, shell.core.history, shell}
  end

  def handle_call(:thread_store, _from, shell), do: {:reply, shell.store, shell}

  def handle_call({:start_handoff, paused}, _from, shell) do
    if shell.store.context["activated"] == false do
      context = Map.put(shell.store.context, "activated", true)

      case Store.save(%{shell.store | context: context, inputs_paused: paused}) do
        {:ok, store} ->
          shell.handoff_fault_hook.("activation_persisted")
          send(self(), :drain_inputs)
          {:reply, :ok, inbox_changed(%{shell | store: store})}

        error ->
          {:reply, error, shell}
      end
    else
      {:reply, :ok, shell}
    end
  end

  def handle_call(:materialized_view, _from, shell) do
    {:reply, materialized_view(shell), shell}
  end

  def handle_call(:snapshot, _from, shell) do
    {:reply, snapshot(shell), shell}
  end

  def handle_call({:provider_settings, settings}, _from, shell),
    do: change_provider_settings(shell, settings)

  def handle_call({:runtime_limits, changes}, _from, shell),
    do: change_runtime_limits(shell, changes)

  def handle_call({:read_only, enabled}, _from, shell),
    do: change_read_only(shell, enabled)

  def handle_call({:approve, id}, {caller, _}, shell) do
    source = shell.store.context["source"]
    source_pid = if is_binary(source), do: Elara.session_pid(source), else: nil

    if caller == shell.controller or source_pid == {:ok, caller},
      do: approve_command(shell, id),
      else: {:reply, {:error, :not_controller}, shell}
  end

  def handle_call(:read_only_view, _from, shell),
    do: {:reply, Handoff.read_only_status(shell), shell}

  def handle_call(:web_content_view, _from, shell),
    do: {:reply, Handoff.web_content(shell), shell}

  def handle_call(:runtime_limits_view, _from, shell),
    do: {:reply, runtime_limits_view(shell), shell}

  def handle_call({:workspace_diff, scope} = command, _from, shell)
      when scope in [:turn, :session] do
    result =
      if Handoff.frozen?(shell.store),
        do: forward_handoff(shell, command, :infinity),
        else: Elara.WorkspaceDiff.report(shell.workspace_diff, shell.store, scope)

    {:reply, result, shell}
  end

  def handle_call(:recording, _from, shell) do
    {:reply, FlightRecorder.snapshot(shell.recorder), shell}
  end

  # Run the Git transaction while this session cannot dispatch a new turn.
  # Git's index checks additionally protect against edits outside this VM.
  def handle_call(
        {:workspace_operation, _, _} = command,
        _from,
        %{store: %{context: %{"handoff" => _}}} = shell
      ) do
    {:reply, forward_handoff(shell, command), shell}
  end

  def handle_call(
        {:acknowledged_parent_workspace_operation, _operation},
        _from,
        %{store: %{context: %{"handoff" => _}}} = shell
      ) do
    {:reply, {:error, :handoff_context_rejected}, shell}
  end

  def handle_call({:workspace_operation, operation, retire?}, _from, shell) do
    uncertain? =
      Enum.any?(
        shell.core.history,
        &match?(%Message.ToolResult{outcome: {:indeterminate, _}}, &1)
      )

    if Core.idle?(shell.core) and map_size(shell.tasks) == 0 and
         shell.effect_recovery_pending == [] and not uncertain? do
      result = operation.()

      if retire? and result == :ok,
        do: {:stop, :normal, :ok, shell},
        else: {:reply, result, shell}
    else
      {:reply, {:error, :stop_or_reconcile_effects_first}, shell}
    end
  end

  def handle_call({:acknowledged_parent_workspace_operation, operation}, _from, shell) do
    uncertain? =
      Enum.any?(
        shell.core.history,
        &match?(%Message.ToolResult{outcome: {:indeterminate, _}}, &1)
      )

    if Core.idle?(shell.core) and map_size(shell.tasks) == 0 and
         shell.effect_recovery_pending == [] and not uncertain? do
      {:reply, operation.(), shell}
    else
      {:reply, {:error, :stop_or_reconcile_effects_first}, shell}
    end
  end

  # Unlike the general workspace callback, this authority is limited to the
  # registered Threads process and never follows a handoff or runs offline.
  def handle_call(
        {:child_workspace_operation, _expected_id, _operation, _retire?},
        _from,
        %{store: %{context: %{"handoff" => _}}} = shell
      ) do
    {:reply, {:error, :child_handoff_context_rejected}, shell}
  end

  def handle_call(
        {:child_workspace_operation, expected_id, operation, retire?},
        {caller, _},
        shell
      ) do
    threads = Process.whereis(Elara.Threads)

    if caller == threads and shell.id == expected_id and
         shell.store.context["sources"] in [nil, []] and
         Core.idle?(shell.core) and map_size(shell.tasks) == 0 and
         shell.effect_recovery_pending == [] do
      occurrences =
        shell.store.entries
        |> Enum.filter(
          &match?(%Store.Entry{message: %Message.ToolResult{outcome: {:indeterminate, _}}}, &1)
        )
        |> Enum.map(fn %Store.Entry{
                         id: entry_id,
                         message: %Message.ToolResult{
                           call_id: call_id,
                           name: tool,
                           outcome: {:indeterminate, text}
                         }
                       } ->
          %{
            session_id: shell.id,
            entry_id: entry_id,
            call_id: call_id,
            tool: tool,
            text: text
          }
        end)

      result = operation.(%{session_id: shell.id, cwd: shell.cwd, occurrences: occurrences})

      if retire? and result == :ok,
        do: {:stop, :normal, :ok, shell},
        else: {:reply, result, shell}
    else
      {:reply, {:error, :child_workspace_operation_rejected}, shell}
    end
  end

  def handle_call({:why, selector}, _from, shell) do
    {:reply, FlightRecorder.why(shell.recorder, selector), shell}
  end

  def handle_call(:cwd, _from, shell) do
    {:reply, shell.cwd, shell}
  end

  def handle_call({:tool_evidence, evidence}, {caller, _}, shell) do
    with {:ok, _ref, _call} <- active_tool(shell, caller),
         true <- Elara.CheckEvidence.valid?(evidence),
         {:ok, store} <-
           Store.save(%{shell.store | check_evidence: evidence}) do
      {:reply, :ok, %{shell | store: store}}
    else
      _ ->
        {:reply, {:error, "Check evidence could not be retained for this active invocation"},
         shell}
    end
  end

  def handle_call(:tool_evidence, {caller, _}, shell) do
    case active_tool(shell, caller) do
      {:ok, _, _} -> {:reply, {:ok, shell.store.check_evidence}, shell}
      error -> {:reply, error, shell}
    end
  end

  def handle_call(:tool_provider_context, {caller, _}, shell) do
    with {:ok, ref, _call} <- active_tool(shell, caller) do
      context = %{
        provider:
          Provider.Visibility.configure(shell.provider, shell.core.config.provider_settings),
        settings: shell.core.config.provider_settings,
        system: instruction_system(shell),
        operation_id: "#{shell.incarnation}:#{ref}"
      }

      {:reply, {:ok, context}, shell}
    else
      {:error, reason} -> {:reply, {:error, reason}, shell}
    end
  end

  def handle_call(
        {:tool_provider_result, operation_id, {module, config}, usage},
        {caller, _},
        shell
      ) do
    with {:ok, ref, _call} <- active_tool(shell, caller),
         true <- operation_id == "#{shell.incarnation}:#{ref}",
         true <- module == elem(shell.provider, 0),
         true <- Provider.Visibility.valid_usage?(usage) do
      shell = %{shell | provider: {module, config}}
      shell = if usage, do: feed({:tool_usage, ref, usage}, shell), else: shell
      {:reply, :ok, shell}
    else
      _ -> {:reply, {:error, "Tool provider invocation is no longer active"}, shell}
    end
  end

  def handle_call({:replace_effect_executor, executor}, _from, shell) do
    shell = %{shell | effect_executor: executor, effect_executor_explicit?: true}
    {:reply, :ok, resume_pending_effects(shell)}
  end

  def handle_call(:child_config, _from, shell) do
    limits = Core.runtime_limits(shell.core)

    history =
      if map_size(shell.core.cleared_tools) > 0 do
        Enum.map(shell.core.history, fn
          %Message.Assistant{} = assistant -> %{assistant | usage: nil}
          message -> message
        end)
      else
        shell.core.history
      end

    config = %{
      provider:
        Elara.Provider.Visibility.configure(shell.provider, shell.core.config.provider_settings),
      cwd: shell.cwd,
      output_owner: shell.store.id,
      tools: Map.values(shell.base_tools),
      system: shell.base_system,
      skill_options: shell.skill_options,
      max_iterations: limits.max_iterations,
      max_tool_output_bytes: shell.core.config.max_tool_output_bytes,
      context_keep_results: shell.core.config.context_keep_results,
      context_keep_tokens: shell.core.config.context_keep_tokens,
      history: history,
      provider_retry: shell.core.config.retry,
      tool_timeout_ms: limits.tool_timeout_ms,
      max_tool_timeout_ms: limits.max_tool_timeout_ms,
      router: shell.router,
      workspace_id: shell.workspace_id,
      allowed_capabilities: shell.allowed_capabilities,
      read_only: Handoff.read_only(shell),
      web_content_entered: Handoff.web_content(shell),
      command_rules: shell.store.context["command_rules"],
      approval_wait: shell.approval_wait,
      context_limit: shell.context_limit
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
    if Elara.Threads.managed?(shell.id) do
      {:reply, {:error, :managed_child_use_delegate_history}, shell}
    else
      idle_store_change(shell, fn store ->
        with {:ok, target} <- Store.clone(store) do
          {:ok, target, nil}
        end
      end)
    end
  end

  def handle_call({:fork, id}, _from, shell) do
    if Elara.Threads.managed?(shell.id) do
      {:reply, {:error, :managed_child_use_delegate_history}, shell}
    else
      idle_store_change(shell, fn store -> Store.fork_before_user(store, id) end)
    end
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
    cond do
      Elara.Threads.managed?(shell.id) or Elara.Threads.managed?(store.id) or
        shell.store.context != %{} or store.context != %{} ->
        {:reply, {:error, :managed_child_open_independently}, shell}

      Core.idle?(shell.core) ->
        config = restore_provider_settings(shell.core.config, store, shell.provider)

        case hydrate(store, config) do
          {:ok, store, core} ->
            case Store.set_provider_settings(store, config.provider_settings) do
              {:ok, store} ->
                if store.path != shell.store.path, do: Store.release(shell.store)

                core = Core.rebase_history(shell.core, core.history)
                recorder = FlightRecorder.segment(shell.recorder, core, :history_rebased)

                shell = %{
                  shell
                  | store: store,
                    core: core,
                    recorder: recorder,
                    workspace_diff: Elara.WorkspaceDiff.open(store)
                }

                shell = feed({:provider_settings, config.provider_settings}, shell)

                shell =
                  if config.provider_catalog == shell.core.config.provider_catalog,
                    do: shell,
                    else: feed({:provider_catalog, config.provider_catalog}, shell)

                {:reply, {:ok, shell.core.history}, shell}

              {:error, reason} ->
                if store.path != shell.store.path, do: Store.release(store)
                {:reply, {:error, reason}, shell}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, shell}
        end

      true ->
        {:reply, {:error, :busy}, shell}
    end
  end

  def handle_call(:subscribe, {pid, _}, shell) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{shell | subscribers: Map.put(shell.subscribers, pid, ref)}}
  end

  def handle_call({:attach, mode}, {pid, _}, shell)
      when mode in [:control, :observe] do
    case grant_control(mode, pid, shell) do
      :ok ->
        ref = Process.monitor(pid)
        attachment = %{monitor: ref, mode: mode}

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
    if shell.controller == pid or match?({:input_status, _}, command) do
      handle_attached_command(command, shell)
    else
      {:reply, {:error, :not_controller}, shell}
    end
  end

  def handle_call({:attached_input, {:ask_input, _, _, _} = command}, _from, shell),
    do: handle_attached_command(command, shell)

  def handle_call({:undo_input, {:undo, _, _} = command}, _from, shell),
    do: handle_attached_command(command, shell)

  def handle_call(:pause_handoff, _from, shell),
    do: handle_attached_command(:interrupt, shell)

  def handle_call({:await_completion, correlation}, from, shell),
    do: handle_call({:await_completion, correlation, nil}, from, shell)

  def handle_call({:await_completion, correlation, dependency}, {caller, _} = from, shell) do
    if is_map(correlation) and Elara.Completion.valid_correlation?(correlation) and
         Process.alive?(caller) do
      ref = Process.monitor(caller)

      waiter = %{
        from: from,
        correlation: correlation,
        dependency: if(is_pid(dependency), do: Process.monitor(dependency))
      }

      shell = put_in(shell.completion_waiters[ref], waiter)
      {:noreply, resolve_completion_waiters(shell)}
    else
      {:reply, {:error, :invalid_completion_target}, shell}
    end
  end

  def handle_call({:submit_input, attrs}, _from, shell), do: submit_input(attrs, shell)
  def handle_call({:cancel_input, id}, _from, shell), do: cancel_input(id, shell)

  def handle_call({:input_status, id}, _from, shell),
    do: {:reply, {:ok, find_input(shell, id)}, shell}

  def handle_call(:resume_inputs, _from, %{store: %{context: %{"handoff" => _}}} = shell) do
    {:reply, forward_handoff(shell, :resume_inputs), shell}
  end

  def handle_call(:resume_inputs, _from, shell) do
    with {:ok, store} <-
           Store.put_inbox(
             %{shell.store | agent_wake_count: 0},
             shell.store.inbox,
             false,
             nil,
             shell.store.active_input_id
           ) do
      shell = %{shell | store: store}
      send(self(), :drain_inputs)
      {:reply, :ok, inbox_changed(shell)}
    else
      {:error, reason} -> {:reply, {:error, reason}, shell}
    end
  end

  def handle_call(:session_clone, {caller, _}, shell) do
    controlled_store_copy(caller, shell, &Store.clone/1)
  end

  def handle_call({:session_fork, entry_id}, {caller, _}, shell) do
    controlled_store_copy(caller, shell, fn store -> Store.fork_before_user(store, entry_id) end)
  end

  def handle_call({:session_delete, requesting_cwd}, _from, shell) do
    cond do
      not Store.same_cwd?(requesting_cwd, shell.cwd) ->
        {:reply, {:error, :session_not_found}, shell}

      Handoff.frozen?(shell.store) ->
        {:reply, {:error, :handoff_evidence_retained}, shell}

      not Core.idle?(shell.core) ->
        {:reply, {:error, :active_stop_first}, shell}

      not is_nil(shell.controller) ->
        {:reply, {:error, :control_taken}, shell}

      Enum.any?(shell.store.inbox, &(&1.state in [:queued, :accepted])) ->
        {:reply, {:error, :pending_inputs}, shell}

      true ->
        case Store.delete(shell.store) do
          :ok -> {:stop, :normal, :ok, shell}
          {:error, {:recordings_cleanup, _} = reason} -> {:stop, :normal, {:error, reason}, shell}
          {:error, reason} -> {:reply, {:error, reason}, shell}
        end
    end
  end

  @impl true
  def handle_cast(:interrupt, shell) do
    shell = %{abort_running_tasks(shell) | pending_effects: %{}}
    shell = shell |> stop_handoff() |> pause_existing_inputs()
    store = shell.store
    {:noreply, feed(:interrupt, if(store.inbox == [], do: shell, else: inbox_changed(shell)))}
  end

  def handle_info({:completion_disconnected, correlation}, shell) do
    waiters =
      Enum.reduce(shell.completion_waiters, %{}, fn {ref, waiter}, acc ->
        if waiter.correlation == correlation do
          Process.demonitor(ref, [:flush])
          if waiter.dependency, do: Process.demonitor(waiter.dependency, [:flush])
          GenServer.reply(waiter.from, {:error, :thread_disconnected_no_replay})
          acc
        else
          Map.put(acc, ref, waiter)
        end
      end)

    {:noreply, %{shell | completion_waiters: waiters}}
  end

  def handle_info(:drain_inputs, shell), do: {:noreply, drain_inputs(shell)}
  def handle_info(:inbox_changed, shell), do: {:noreply, inbox_changed(shell)}

  def handle_info(:refresh_catalog, shell) do
    if shell.core.config.provider_catalog &&
         Application.get_env(:elara, :model_catalog_online, true) && shell.catalog_task == nil do
      provider = shell.provider
      previous = shell.core.config.provider_catalog

      task =
        Task.Supervisor.async_nolink(Elara.TaskSup, fn ->
          Provider.Catalog.refresh(provider, previous)
        end)

      timer = Process.send_after(self(), {:catalog_timeout, task.ref}, 5_500)
      {:noreply, %{shell | catalog_task: task, catalog_timer: timer}}
    else
      {:noreply, shell}
    end
  end

  def handle_info({ref, catalog}, %{catalog_task: %Task{ref: ref}} = shell) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(shell.catalog_timer)
    Process.send_after(self(), :refresh_catalog, 300_000)
    shell = %{shell | catalog_task: nil, catalog_timer: nil}

    catalog =
      case shell.core.config.provider_catalog["settings_notice"] do
        nil -> Map.delete(catalog, "settings_notice")
        notice -> Map.put(catalog, "settings_notice", notice)
      end

    {:noreply,
     if(catalog == shell.core.config.provider_catalog,
       do: shell,
       else: feed({:provider_catalog, catalog}, shell)
     )}
  end

  def handle_info({:catalog_timeout, ref}, %{catalog_task: %Task{ref: ref}} = shell) do
    Task.shutdown(shell.catalog_task, :brutal_kill)
    catalog_refresh_failed(shell)
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{catalog_task: %Task{ref: ref}} = shell
      ),
      do: catalog_refresh_failed(shell)

  def handle_info(:advance_handoff, shell) do
    case Handoff.outgoing(shell.store) do
      %{"stage" => stage}
      when stage in ["prepared", "created", "transferred", "started", "failed", "stopped"] ->
        case Handoff.advance(shell) do
          {:ok, shell} ->
            shell.handoff_fault_hook.(Handoff.outgoing(shell.store)["stage"])

            if stage in ["prepared", "created", "transferred"],
              do: send(self(), :advance_handoff)

            {:noreply, inbox_changed(shell)}

          {:error, reason} ->
            {:ok, shell} = Handoff.fail(shell, reason)
            {:noreply, inbox_changed(shell)}
        end

      _ ->
        {:noreply, shell}
    end
  end

  def handle_info(:check_effect_recovery, %{effect_recovery_task: %Task{}} = shell),
    do: {:noreply, shell}

  def handle_info(:check_effect_recovery, shell) do
    pending = pending_receipt_effects(shell)

    if pending == [] do
      {:noreply, finish_effect_recovery(%{shell | effect_recovery_pending: []})}
    else
      executor = shell.effect_executor
      owner = self()

      task =
        Task.Supervisor.async_nolink(Elara.TaskSup, fn ->
          watch_recovery_owner(owner)

          for %Job{} = job <- pending do
            {job, safe_executor_query(executor, job.job_id)}
          end
        end)

      {:noreply, %{shell | effect_recovery_pending: pending, effect_recovery_task: task}}
    end
  end

  def handle_info({ref, observations}, %{effect_recovery_task: %Task{ref: ref}} = shell) do
    Process.demonitor(ref, [:flush])

    for {%Job{operation_digest: digest}, {state, %Record{operation_digest: digest} = record}} <-
          observations,
        ExecutorLedger.is_terminal_state(state) do
      ControllerJournal.observe(shell.effect_journal, record)
    end

    shell = %{shell | effect_recovery_task: nil}

    {:noreply,
     finish_effect_recovery(%{shell | effect_recovery_pending: pending_receipt_effects(shell)})}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{effect_recovery_task: %Task{ref: ref}} = shell
      ) do
    Process.send_after(self(), :check_effect_recovery, 25)
    {:noreply, %{shell | effect_recovery_task: nil}}
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

        {:mcp_check, decision} ->
          feed({:tool_checked, core_ref, decision}, shell)

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
          shell = consume_claimed_completion(shell, core_ref, outcome)
          shell = record_web_content(shell, core_ref, outcome)
          feed({:tool_result, core_ref, outcome}, shell)
      end

    {:noreply, shell}
  end

  def handle_info({:provider_delta, pid, core_ref, text}, shell)
      when is_pid(pid) and (is_binary(text) or is_tuple(text)) do
    case find_task_by_core_ref(shell, core_ref, :provider) do
      {_task_ref, ^pid, _plugin_lease} ->
        {:noreply, feed({:provider_delta, core_ref, text}, shell)}

      _stale_or_unknown_provider ->
        {:noreply, shell}
    end
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, shell)
      when is_map_key(shell.tasks, task_ref) do
    {kind, core_ref, _pid, plugin_lease} = Map.fetch!(shell.tasks, task_ref)
    shell = untrack_task(shell, task_ref, core_ref)
    abort_plugin_invocation(plugin_lease)
    shell = %{shell | completion_claims: Map.delete(shell.completion_claims, core_ref)}

    shell =
      case kind do
        :tool ->
          feed({:tool_crashed, core_ref, Exception.format_exit(reason)}, shell)

        :mcp_check ->
          feed(
            {:tool_checked, core_ref, {:deny, "MCP preparation failed before dispatch"}},
            shell
          )

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
    waiters =
      Enum.reduce(shell.completion_waiters, %{}, fn {ref, waiter}, acc ->
        if mon_ref in [ref, waiter.dependency] do
          Process.demonitor(ref, [:flush])
          if waiter.dependency, do: Process.demonitor(waiter.dependency, [:flush])

          if mon_ref == waiter.dependency,
            do:
              GenServer.reply(waiter.from, {:error, :completion_transport_disconnected_no_replay})

          acc
        else
          Map.put(acc, ref, waiter)
        end
      end)

    shell = %{shell | completion_waiters: waiters}

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

  def handle_info({:retry_elapsed, core_ref}, %{retry_timer: {core_ref, _timer}} = shell) do
    {:noreply, feed({:retry_elapsed, core_ref}, %{shell | retry_timer: nil})}
  end

  def handle_info({:retry_elapsed, _core_ref}, shell), do: {:noreply, shell}

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
      {:ok, store, core} -> {:ok, store, core, nil, []}
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
        # Fix the possibly running call before reconciliation resolves any call,
        # so a resolved boundary cannot move it to a call that never started.
        boundary =
          case store |> Store.history() |> unresolved_tool_calls() do
            [first | _] -> first.id
            [] -> nil
          end

        case recover_store(store, config.tools, journal, recovery) do
          {:ok, store} ->
            core = Core.new(config, Store.history(store), boundary: boundary)

            case persist_repairs(store, core) do
              {:ok, store, core} ->
                pending = recovery_barrier_jobs(store, config.tools, journal, recovery)
                {:ok, store, core, journal, pending}

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

  # Input receipts make restarting an active turn observable. Do not fail that
  # receipt (and thereby release the next queued input) while a durable effect
  # from the interrupted turn can still complete in its executor. This includes
  # jobs for which an indeterminate ToolResult was already written.
  defp recovery_barrier_jobs(_store, tools, journal, recovery) do
    # New submissions must obey the same barrier as inputs restored at startup.
    case ControllerJournal.all(journal) do
      {:ok, jobs} ->
        Enum.filter(jobs, fn job ->
          declarative_write_job?(job) or
            (recovery.executor_explicit? and receipt_routed_job?(job, tools))
        end)

      {:error, _reason} ->
        [:journal_unavailable]
    end
  end

  defp receipt_routed_job?(%Job{operation_kind: :run_tool, tool_name: name}, tools) do
    match?(%Tool{plugin: nil, mutating: true}, Map.get(tools, name))
  end

  defp receipt_routed_job?(%Job{}, _tools), do: false

  defp pending_receipt_effects(%Shell{effect_recovery_pending: pending} = shell) do
    Enum.reject(pending, &receipt_effect_terminal?(shell, &1))
  end

  defp receipt_effect_terminal?(_shell, :journal_unavailable), do: false

  defp receipt_effect_terminal?(shell, %Job{} = job) do
    case ControllerJournal.observation(shell.effect_journal, job.job_id) do
      {:ok, %{executor_record: %Record{state: state, operation_digest: digest}}}
      when ExecutorLedger.is_terminal_state(state) and digest == job.operation_digest ->
        true

      _ ->
        false
    end
  end

  defp watch_recovery_owner(owner) do
    worker = self()

    # A blocked GenServer.call cannot handle DOWN itself. This linked watcher
    # also covers :kill, which bypasses the session's terminate callback.
    spawn_link(fn ->
      owner_ref = Process.monitor(owner)
      worker_ref = Process.monitor(worker)

      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _} -> Process.exit(worker, :kill)
        {:DOWN, ^worker_ref, :process, ^worker, _} -> :ok
      end
    end)
  end

  defp finish_effect_recovery(%{effect_recovery_pending: []} = shell) do
    {shell, recovered?} = finish_restart_recovery(shell)
    if recovered?, do: send(self(), :inbox_changed)
    send(self(), :drain_inputs)
    shell
  end

  defp finish_effect_recovery(shell) do
    Process.send_after(self(), :check_effect_recovery, 25)
    shell
  end

  defp safe_executor_query(nil, _job_id), do: :unavailable

  defp safe_executor_query(executor, job_id) do
    Executor.query(executor, job_id)
  catch
    :exit, _reason -> :unavailable
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
        {:ok, store}
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
      DeclarativeWrite.matches_call?(job, args) and
      job.workspace_id == recovery.workspace_id and
      job.required_capabilities == ["filesystem:write"] and
      job.authority_scope == authority_scope
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
      Map.delete(job.authority_scope, :mcp_guard) == authority_scope
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
      mcp_guard: Map.get(job.authority_scope, :mcp_guard),
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

  defp restore_provider_settings(config, store, provider) do
    {settings, notice} =
      case Elara.Provider.Visibility.settings(provider) do
        nil ->
          {nil, nil}

        defaults ->
          saved = store.provider_settings || config.provider_settings

          cond do
            saved == nil ->
              {defaults, nil}

            is_map(saved) and Map.keys(saved) == Map.keys(defaults) ->
              {saved, nil}

            true ->
              old = if is_map(saved) and Map.has_key?(saved, "effort"), do: "Codex", else: "Grok"
              new = if Map.has_key?(defaults, "effort"), do: "Codex", else: "Grok"
              model = if is_map(saved), do: saved["model"], else: "unknown"

              {defaults,
               "saved #{old} model #{model} not applied under #{new}; using #{defaults["model"]}"}
          end
      end

    catalog = Provider.Catalog.offline(provider)
    catalog = if notice, do: Map.put(catalog, "settings_notice", notice), else: catalog
    %{config | provider_settings: settings, provider_catalog: catalog}
  end

  defp catalog_refresh_failed(shell) do
    Process.cancel_timer(shell.catalog_timer)
    Process.send_after(self(), :refresh_catalog, 300_000)

    catalog =
      Map.put(
        shell.core.config.provider_catalog,
        "error",
        "Model listing unavailable; using offline catalog"
      )

    {:noreply,
     feed({:provider_catalog, catalog}, %{shell | catalog_task: nil, catalog_timer: nil})}
  end

  defp hydrate(store, config) do
    with {:ok, store} <- Store.claim(store) do
      persist_repairs(store, Core.new(config, Store.history(store)))
    end
  end

  defp copy_store(shell) do
    context =
      case Handoff.read_only_status(shell) do
        {:known, enabled} ->
          if enabled or shell.store.context != %{},
            do: Map.put(shell.store.context, "read_only", enabled),
            else: shell.store.context

        :owner_unavailable ->
          shell.store.context
          |> Map.put("read_only", true)
          |> Map.put(
            "read_only_notice",
            "Delivery owner unavailable; this copy is read-only. /read-only off lifts it."
          )
      end

    context =
      if Handoff.web_content(shell),
        do: Map.put(context, "web_content_entered", true),
        else: context

    %{shell.store | context: context}
  end

  defp idle_store_change(shell, change) do
    if Core.idle?(shell.core) do
      case change.(copy_store(shell)) do
        {:ok, store, prompt} when shell.store.context != %{} and store.path != shell.store.path ->
          case Elara.start_session(
                 Handoff.options(shell) ++ [provider: shell.provider, resume: store.path]
               ) do
            {:ok, id} -> {:reply, {:ok, id, prompt, Store.history(store)}, shell}
            {:error, reason} -> {:reply, {:error, reason}, shell}
          end

        {:ok, store, prompt} ->
          case Store.claim(store) do
            {:ok, store} ->
              shell =
                if store.path != shell.store.path do
                  Store.release(shell.store)
                  close_effect_journal(shell.effect_journal)

                  if shell.effect_recovery_task,
                    do: Task.shutdown(shell.effect_recovery_task, :brutal_kill)

                  %{
                    shell
                    | effect_journal: nil,
                      effect_journal_path: Path.rootname(store.path) <> ".effects.sqlite3",
                      effect_recovery_pending: [],
                      effect_recovery_task: nil
                  }
                else
                  shell
                end

              core =
                shell.core |> Core.rebase_history(Store.history(store)) |> Context.restore(store)

              recorder = FlightRecorder.segment(shell.recorder, core, :history_rebased)

              {:reply, {:ok, prompt, core.history},
               %{
                 shell
                 | store: store,
                   core: core,
                   recorder: recorder,
                   workspace_diff: Elara.WorkspaceDiff.open(store)
               }}

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

  # One save, so a crash cannot persist part of a repair and move the boundary.
  defp persist_repairs(store, core) do
    extras = Enum.drop(core.history, length(Store.history(store)))

    case Store.append_all(store, extras) do
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
    shell =
      case fact do
        {kind, _} when kind in [:ask, :ask_input] -> refresh_instructions(shell)
        _ -> shell
      end

    {recorder, begin} = FlightRecorder.begin_transition(shell.recorder, shell.core, fact)
    message_offset = length(shell.core.history)
    previous_streaming = shell.core.streaming
    previous_phase = shell.core.phase
    {core, effects} = Core.step(shell.core, fact)
    {recorder, transition} = FlightRecorder.complete_transition(recorder, begin, core, effects)
    shell = settle_retry_timer(previous_phase, %{shell | core: core, recorder: recorder})

    patch_context = %{
      message_offset: message_offset,
      messages: Enum.drop(core.history, message_offset),
      supersedes: superseded_content(previous_streaming, core.streaming)
    }

    effects
    |> Enum.with_index()
    |> Enum.reduce(shell, fn {effect, index}, shell ->
      effect_id = Map.merge(transition.id, %{effect_index: index})
      run_effect(effect, effect_id, shell, patch_context)
    end)
    |> then(fn shell ->
      if Core.idle?(shell.core), do: Elara.Threads.release_slot()
      shell
    end)
  end

  defp run_effect(
         {:emit, {:message_appended, message} = event},
         effect_id,
         shell,
         patch_context
       ) do
    consuming? =
      case shell.consuming_id do
        {:completion, call_id} -> match?(%Message.ToolResult{call_id: ^call_id}, message)
        nil -> false
        _ -> is_struct(message, Message.User)
      end

    store =
      if is_struct(message, Message.User) and shell.consuming_id != "handoff:" <> shell.id,
        do: %{shell.store | completion_occurrence: nil},
        else: shell.store

    result =
      if consuming?,
        do:
          Store.put_inbox(
            store,
            store.inbox,
            store.inputs_paused,
            message,
            store.active_input_id
          ),
        else: Store.append(store, message)

    case result do
      {:ok, store} ->
        shell =
          if is_struct(message, Message.User),
            do: %{
              shell
              | workspace_diff: Elara.WorkspaceDiff.admit(shell.workspace_diff, store.leaf)
            },
            else: shell

        shell = emit(event, effect_id, %{shell | store: store, consuming_id: nil}, patch_context)
        if consuming?, do: inbox_changed(shell), else: shell

      {:error, reason} ->
        raise "session persistence failed: #{inspect(reason)}"
    end
  end

  defp run_effect(
         {:emit, {:message_appended, message, :streamed} = event},
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

  defp run_effect({:emit, {kind, pending} = event}, effect_id, shell, patch_context)
       when kind in [:approval_required, :approval_granted] do
    shell = record_command_guard(shell, Map.put(pending, "event", Atom.to_string(kind)))
    emit(event, effect_id, shell, patch_context)
  end

  defp run_effect(
         {:emit, {:command_blocked, call, reason} = event},
         effect_id,
         shell,
         patch_context
       ) do
    {:ok, args} = call.args

    shell =
      record_command_guard(shell, %{
        "event" => "command_blocked",
        "call_id" => call.id,
        "tool" => call.name,
        "args" => args,
        "reason" => reason
      })

    emit(event, effect_id, shell, patch_context)
  end

  defp run_effect({:emit, event}, effect_id, shell, patch_context) do
    emit(event, effect_id, shell, patch_context)
  end

  defp run_effect(:persist_context_clearing, _effect_id, shell, _patch_context) do
    entries = Store.path_entries(shell.store, shell.store.leaf)

    clearing = %{
      "entries" =>
        shell.core.cleared_tools |> Map.values() |> Enum.map(& &1.entry_id) |> Enum.sort(),
      "usage_reset_entry" => Enum.at(entries, shell.core.context_usage_after - 1).id
    }

    case Store.save(%{shell.store | context: Map.put(shell.store.context, "clearing", clearing)}) do
      {:ok, store} -> %{shell | store: store}
      {:error, reason} -> raise "context clearing persistence failed: #{inspect(reason)}"
    end
  end

  defp run_effect(:persist_web_content, _effect_id, shell, _patch_context) do
    context = Map.put(shell.store.context, "web_content_entered", true)

    case Store.save(%{shell.store | context: context}) do
      {:ok, store} -> %{shell | store: store}
      {:error, reason} -> raise "web provenance persistence failed: #{inspect(reason)}"
    end
  end

  defp run_effect(:persist_read_only, _effect_id, shell, _patch_context) do
    transition = %{
      "read_only" => shell.core.read_only,
      "after_entry" => shell.store.leaf,
      "turn" => Protocol.snapshot(shell.id, shell.incarnation, shell.core)["turn"]
    }

    context =
      shell.store.context
      |> Map.put("read_only", shell.core.read_only)
      |> Map.delete("read_only_notice")
      |> Map.update("read_only_changes", [transition], &(&1 ++ [transition]))

    case Store.save(%{shell.store | context: context}) do
      {:ok, store} -> %{shell | store: store}
      {:error, reason} -> raise "read-only persistence failed: #{inspect(reason)}"
    end
  end

  defp run_effect({:call_provider, core_ref, request}, effect_id, shell, _patch_context) do
    budget = Context.budget(shell.core, shell.context_limit, shell.provider)
    frozen = Handoff.frozen?(shell.store)

    {entries, freed} =
      if not frozen and budget["handoff_required"],
        do: Context.clearing(shell.core, shell.store, shell.context_limit, shell.provider),
        else: {[], 0}

    branch =
      cond do
        frozen -> :interrupt_frozen
        entries != [] -> :clear_tool_results
        budget["handoff_required"] -> :attempt_handoff
        true -> :attempt_dispatch
      end

    recorder = FlightRecorder.context_decision(shell.recorder, effect_id, budget, frozen, branch)
    shell = %{shell | recorder: recorder}

    case branch do
      :interrupt_frozen -> feed(:interrupt, shell)
      :clear_tool_results -> feed({:clear_tool_results, core_ref, entries, freed}, shell)
      :attempt_handoff -> begin_handoff(shell, core_ref)
      :attempt_dispatch -> run_effect({:dispatch_provider, core_ref, request}, nil, shell, nil)
    end
  end

  # Core sized the window; the shell picks the actual wait inside it so
  # concurrent sessions do not re-converge on one retry instant. A
  # server-directed delay arrives as a single point and is honored exactly.
  defp run_effect({:await_retry, core_ref, min_ms, max_ms}, _effect_id, shell, _patch_context) do
    delay = min_ms + :rand.uniform(max_ms - min_ms + 1) - 1
    timer = Process.send_after(self(), {:retry_elapsed, core_ref}, delay)
    %{cancel_retry_timer(shell) | retry_timer: {core_ref, timer}}
  end

  defp run_effect({:dispatch_provider, core_ref, request}, _, shell, _) do
    if Elara.Threads.acquire_slot(shell.id) do
      shell = %{shell | presented_instructions: shell.instructions}
      {mod, cfg} = Elara.Provider.Visibility.configure(shell.provider, request.settings)

      owner = self()

      correlations =
        Map.new(shell.store.inbox, &{&1.user.agent_source, Map.get(&1, :correlation)})

      task =
        Task.Supervisor.async_nolink(Elara.TaskSup, fn ->
          call_provider(mod, cfg, request, owner, core_ref, correlations)
        end)

      track_task(shell, task, :provider, core_ref)
    else
      feed(
        {:provider_result, core_ref,
         {:error,
          %Elara.Provider.Error{
            kind: :resource_limit,
            message:
              "Child concurrency limit #{Elara.Threads.limit()} reached; retry explicitly when a slot is free"
          }}},
        shell
      )
    end
  end

  defp run_effect({:check_tool, ref, call}, _effect_id, shell, _patch_context) do
    tool = Map.fetch!(shell.core.config.tools, call.name)

    if match?(%Tool{plugin: nil, run: {Elara.MCP.Tools, :call}}, tool) do
      if capabilities_allowed?(tool.capabilities, shell.allowed_capabilities) do
        {:ok, args} = call.args

        task =
          Task.Supervisor.async_nolink(Elara.TaskSup, Elara.MCP.Tools, :prepare, [
            args,
            shell.cwd,
            min(shell.core.config.tool_timeout_ms, 30_000)
          ])

        track_task(shell, task, :mcp_check, ref)
      else
        feed(
          {:tool_checked, ref, {:deny, "permission denied: required capability not granted"}},
          shell
        )
      end
    else
      {shell, decision} = command_decision(shell, ref, call)

      decision =
        case decision do
          {:ask, pending} when not shell.approval_wait ->
            {:deny,
             "approval required: #{pending["reason"]}; call refused without executing. Run this task in the TUI and use /approve"}

          other ->
            other
        end

      feed({:tool_checked, ref, decision}, shell)
    end
  end

  defp run_effect({:run_tool, core_ref, call, tool}, effect_id, shell, patch_context) do
    cond do
      shell.core.read_only and tool.mutating ->
        feed(
          {:tool_result, core_ref,
           {:error,
            "permission denied: session is read-only; /read-only off restores mutating tools"}},
          shell
        )

      not capabilities_allowed?(tool.capabilities, shell.allowed_capabilities) ->
        feed(
          {:tool_result, core_ref,
           {:error, "permission denied: required capability not granted"}},
          shell
        )

      true ->
        run_authorized_tool({:run_tool, core_ref, call, tool}, effect_id, shell, patch_context)
    end
  end

  defp run_authorized_tool(
         {:run_tool, core_ref, call, %Tool{plugin: %PluginRef{} = plugin} = tool},
         effect_id,
         shell,
         _patch_context
       ) do
    {:ok, args} = call.args

    case PluginServer.checkout(plugin.server, plugin.generation) do
      {:ok, lease, module, plugin_state} ->
        request = tool_request(shell, call, tool, args)
        {shell, request, _job} = commit_tool_intent(shell, effect_id, request, tool)

        ctx = %Ctx{
          cwd: shell.cwd,
          session_id: shell.id,
          output_owner: request.output_owner,
          fnox_config: request.fnox_config,
          tool_name: tool.name,
          plugin: plugin,
          job_id: request.job_id,
          timeout_ms: shell.core.config.tool_timeout_ms,
          max_output_bytes: request.max_output_bytes
        }

        config = %{module: module, plugin_state: plugin_state, ctx: ctx}

        task =
          Task.Supervisor.async_nolink(
            Elara.TaskSup,
            Elara.Executor.PluginLocal,
            :execute,
            [config, request, tool]
          )

        track_tool_task(shell, task, core_ref, {plugin.server, lease, tool.cancel_on_interrupt})

      {:error, :busy} ->
        feed({:tool_result, core_ref, {:error, "plugin is busy"}}, shell)

      {:error, :stale_generation} ->
        feed({:tool_result, core_ref, {:error, "plugin generation is stale"}}, shell)
    end
  end

  defp run_authorized_tool({:run_tool, core_ref, call, tool}, effect_id, shell, _patch_context) do
    {:ok, args} = call.args

    case instruction_preflight(shell, tool, args) do
      {:defer, shell} ->
        feed({:tool_deferred, core_ref, instruction_system(shell)}, shell)

      {:error, reason, shell} ->
        feed({:tool_result, core_ref, {:error, reason}}, sync_instruction_context(shell))

      {:ok, shell} ->
        shell = sync_instruction_context(shell)

        cond do
          tool.run == {Elara.Completion, :run} ->
            ctx = %Tool.Ctx{
              session_id: shell.id,
              tool_name: tool.name,
              cwd: shell.cwd,
              max_output_bytes: shell.core.config.max_tool_output_bytes
            }

            task =
              Task.Supervisor.async_nolink(Elara.TaskSup, fn ->
                Elara.Completion.run(args, ctx)
              end)

            track_task(shell, task, :tool, core_ref)

          tool.run == {Elara.Skills, :load} ->
            feed({:tool_result, core_ref, Elara.Skills.load(shell.skills, args["name"])}, shell)

          Tool.builtin_write?(tool) ->
            run_declarative_write(shell, effect_id, core_ref, call, args)

          true ->
            run_routed_tool(shell, effect_id, core_ref, call, tool, args)
        end
    end
  end

  defp instruction_preflight(shell, %Tool{run: {Elara.Tools, action}}, %{"path" => path})
       when action in [:read, :write, :edit] and is_binary(path) do
    with {:ok, {_root, full}} <- Elara.Tools.FileFence.resolve(path, shell.cwd) do
      applicable = Elara.Prompt.instructions(shell.cwd, [full])
      targets = Enum.uniq([full | shell.instruction_targets])
      instructions = Elara.Prompt.instructions(shell.cwd, targets)
      shell = %{shell | instruction_targets: targets, instructions: instructions}

      cond do
        Enum.any?(applicable, fn {_path, result} -> match?({:error, _}, result) end) ->
          {:error, "Cannot execute with unreadable project instructions: #{inspect(applicable)}",
           shell}

        Enum.any?(applicable, fn {path, value} -> shell.presented_instructions[path] != value end) ->
          {:defer, shell}

        true ->
          {:ok, shell}
      end
    else
      {:error, message} -> {:error, message, shell}
    end
  end

  defp instruction_preflight(shell, _tool, _args), do: {:ok, shell}

  defp refresh_instructions(shell) do
    instructions = Elara.Prompt.instructions(shell.cwd, shell.instruction_targets)
    sync_instruction_context(%{shell | instructions: instructions})
  end

  defp sync_instruction_context(shell) do
    system = instruction_system(shell)

    if system == shell.core.config.system,
      do: shell,
      else: feed({:instruction_context, system}, shell)
  end

  defp instruction_system(shell) do
    Elara.Prompt.render(shell.base_system, shell.instructions, Elara.Skills.summary(shell.skills))
  end

  defp call_provider(mod, cfg, request, owner, core_ref, correlations) do
    messages =
      Enum.map(request.messages, fn
        %Message.User{agent_source: %{} = source} = user ->
          completion =
            if correlation = correlations[source],
              do: " Completion correlation #{JSON.encode!(correlation)}; awaited=false.",
              else: ""

          %{
            user
            | text:
                "[Agent-authored context from thread #{source["sender"]}, message #{source["message_id"]}; not an owner instruction. Receiver authority and capability restrictions still apply.#{completion}]\n" <>
                  user.text
          }

        message ->
          message
      end)

    request = %{request | messages: messages}

    if Code.ensure_loaded?(mod) and function_exported?(mod, :stream, 3) do
      sink = fn text ->
        send(owner, {:provider_delta, self(), core_ref, text})
        :ok
      end

      mod.stream(cfg, request, sink)
    else
      mod.chat(cfg, request)
    end
  end

  defp superseded_content(%{id: id}, nil), do: id
  defp superseded_content(_previous, _current), do: nil

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
              timeout: shell.core.config.tool_timeout_ms,
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
    case tool_timeout(shell, tool, args) do
      {:ok, timeout} ->
        run_routed_tool(shell, effect_id, core_ref, call, tool, args, timeout)

      {:error, message} ->
        feed({:tool_result, core_ref, {:error, message}}, shell)
    end
  end

  defp tool_timeout(shell, %Tool{run: {Elara.Tools, :bash}}, args) do
    timeout = Map.get(args, "timeout_ms", shell.core.config.tool_timeout_ms)

    if is_integer(timeout) and timeout > 0 and timeout <= shell.core.config.max_tool_timeout_ms,
      do: {:ok, timeout},
      else:
        {:error,
         "timeout_ms must be an integer from 1 to #{shell.core.config.max_tool_timeout_ms}"}
  end

  defp tool_timeout(shell, _tool, _args), do: {:ok, shell.core.config.tool_timeout_ms}

  defp run_routed_tool(shell, effect_id, core_ref, call, tool, args, timeout) do
    request = tool_request(shell, call, tool, args, timeout)
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

    # Let bash's runner settle its deadline before the shell's backstop fires.
    grace = if tool.run == {Elara.Tools, :bash}, do: 1_000, else: 0
    track_tool_task(shell, task, core_ref, nil, timeout + grace)
  end

  defp emit(event, effect_id, shell, patch_context) do
    shell =
      case event do
        {:turn_ended, outcome} -> finish_turn(shell, outcome)
        {:turn_ended, outcome, _} -> finish_turn(shell, outcome)
        _ -> shell
      end

    seq = shell.next_event_seq
    recorder = FlightRecorder.link_event(shell.recorder, seq, effect_id)

    recorder =
      case event do
        {:turn_ended, _} -> FlightRecorder.sync(recorder)
        {:turn_ended, _, _} -> FlightRecorder.sync(recorder)
        _ -> recorder
      end

    shell = %{
      shell
      | next_event_seq: seq + 1,
        recorder: recorder
    }

    Enum.each(shell.subscribers, fn {pid, _} ->
      send(pid, {:elara, shell.id, event})
    end)

    patch_ops = Protocol.patch_ops(event, shell.core, patch_context)

    patch_ops =
      if Handoff.frozen?(shell.store) do
        limits = runtime_limits_view(shell)

        Enum.map(patch_ops, fn
          %{"op" => "set_runtime_limits"} = op -> Map.put(op, "runtime_limits", limits)
          op -> op
        end)
      else
        patch_ops
      end

    patch_ops =
      if event in [:inbox_changed, :provider_view_changed] or
           match?({:message_appended, _}, event) or
           match?({:message_appended, _, :streamed}, event),
         do: patch_ops ++ [%{"op" => "set_inbox", "inbox" => inbox_view(shell)}],
         else: patch_ops

    Enum.each(shell.attachments, fn {pid, _attachment} ->
      send(pid, {:elara_patch, shell.id, shell.incarnation, seq, patch_ops})
    end)

    shell =
      case {event, shell.pending_reply} do
        {{:turn_ended, {:completed, text}}, from} when from != nil ->
          GenServer.reply(from, {:ok, text})
          %{shell | pending_reply: nil}

        {{:turn_ended, outcome, :streamed}, from} when from != nil ->
          GenServer.reply(from, {:error, outcome})
          %{shell | pending_reply: nil}

        {{:turn_ended, outcome}, from} when from != nil ->
          GenServer.reply(from, {:error, outcome})
          %{shell | pending_reply: nil}

        _ ->
          shell
      end

    unless Handoff.frozen?(shell.store) do
      Elara.Threads.lifecycle(shell.id, event)
      Elara.Threads.Communication.lifecycle(shell.store, event)
    end

    case event do
      {:turn_ended, _} -> send(self(), :drain_inputs)
      {:turn_ended, _, _} -> send(self(), :drain_inputs)
      _ -> :ok
    end

    shell
  end

  defp finish_turn(shell, outcome) do
    shell = shell |> finish_workspace_diff(outcome) |> finish_active_input(outcome)
    :ok = Store.sync(shell.store)
    shell
  end

  defp finish_workspace_diff(shell, outcome) do
    settled? =
      outcome != :interrupted and map_size(shell.tasks) == 0 and
        map_size(shell.pending_effects) == 0 and pending_receipt_effects(shell) == []

    %{shell | workspace_diff: Elara.WorkspaceDiff.finish(shell.workspace_diff, settled?)}
  end

  defp track_task(shell, %Task{ref: ref, pid: pid}, kind, core_ref, plugin_lease \\ nil) do
    %{shell | tasks: Map.put(shell.tasks, ref, {kind, core_ref, pid, plugin_lease})}
  end

  defp active_tool(%{core: %{phase: {:running_tool, ref, call, _, _}}} = shell, caller) do
    case find_task_by_core_ref(shell, ref, :tool) do
      {_monitor, ^caller, _lease} -> {:ok, ref, call}
      _ -> {:error, "Caller does not own the active tool invocation"}
    end
  end

  defp active_tool(_shell, _caller), do: {:error, "No active tool invocation"}

  defp track_tool_task(shell, task, core_ref, plugin_lease, timeout \\ nil) do
    timer =
      Process.send_after(
        self(),
        {:tool_deadline, core_ref},
        timeout || shell.core.config.tool_timeout_ms
      )

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

  # A retry wait belongs to the one awaiting_retry phase that armed it, so any
  # transition out of that phase — interrupt, steer, handoff — cancels it at once.
  defp settle_retry_timer({:awaiting_retry, ref, _, _, _}, shell) do
    case shell.core.phase do
      {:awaiting_retry, ^ref, _, _, _} -> shell
      _other_phase -> cancel_retry_timer(shell)
    end
  end

  defp settle_retry_timer(_previous_phase, shell), do: shell

  defp cancel_retry_timer(%{retry_timer: nil} = shell), do: shell

  defp cancel_retry_timer(%{retry_timer: {core_ref, timer}} = shell) do
    Process.cancel_timer(timer)

    receive do
      {:retry_elapsed, ^core_ref} -> :ok
    after
      0 -> :ok
    end

    %{shell | retry_timer: nil}
  end

  defp find_task_by_core_ref(shell, core_ref, kind) do
    Enum.find_value(shell.tasks, fn
      {task_ref, {^kind, ^core_ref, pid, plugin_lease}} -> {task_ref, pid, plugin_lease}
      _ -> nil
    end)
  end

  defp abort_running_tasks(shell) do
    shell = %{shell | completion_claims: %{}}

    Enum.reduce(Map.keys(shell.tasks), shell, fn task_ref, shell ->
      {kind, core_ref, pid, plugin_lease} = Map.fetch!(shell.tasks, task_ref)
      _ = kind

      # Ordinary plugin invocations drain; explicitly cancellable tools release
      # their lease on interruption like builtin/provider tasks.
      if match?({_, _, false}, plugin_lease) do
        shell
      else
        Process.demonitor(task_ref, [:flush])
        Process.exit(pid, :kill)

        receive do
          {^task_ref, _result} -> :ok
        after
          0 -> :ok
        end

        abort_plugin_invocation(plugin_lease)
        untrack_task(shell, task_ref, core_ref)
      end
    end)
  end

  defp record_web_content(shell, ref, {:ok, _}) do
    case shell.core.phase do
      {:running_tool, ^ref, %ToolCall{name: name, args: {:ok, args}}, _, _} ->
        tool = Map.fetch!(shell.core.config.tools, name)

        web? =
          case tool do
            %Tool{plugin: nil, run: {Elara.WebFetch, :run}} ->
              true

            %Tool{plugin: nil, run: {Elara.Tools, :output_read}} ->
              Output.web_content?(
                %Tool.Ctx{session_id: shell.id, output_owner: shell.store.id, cwd: shell.cwd},
                args["handle"]
              )

            _ ->
              false
          end

        if web?, do: feed({:web_content_entered, ref}, shell), else: shell

      _ ->
        shell
    end
  end

  defp record_web_content(shell, _, _), do: shell

  defp settle_tool_result(nil, outcome), do: outcome

  defp settle_tool_result({server, lease, _cancel}, {:commit, outcome, plugin_state}) do
    case PluginServer.commit_invocation(server, lease, plugin_state) do
      :ok -> outcome
      {:error, :stale_lease} -> {:error, "plugin invocation expired"}
    end
  end

  defp settle_tool_result({server, lease, _cancel}, {:abort, outcome}) do
    :ok = PluginServer.abort_invocation(server, lease)
    outcome
  end

  defp settle_tool_result(plugin_lease, _result) do
    abort_plugin_invocation(plugin_lease)
    {:error, "plugin returned an invalid invocation result"}
  end

  defp abort_plugin_invocation(nil), do: :ok

  defp abort_plugin_invocation({server, lease, _cancel}) do
    PluginServer.abort_invocation(server, lease)
  end

  defp start_plugins(paths, cwd, base_tools, ids \\ MapSet.new())

  defp start_plugins(paths, cwd, base_tools, ids) when is_list(paths) do
    paths
    |> Enum.reduce_while({:ok, [], ids, []}, fn
      path, {:ok, plugins, ids, tools} when is_binary(path) ->
        expanded = Path.expand(path, cwd)
        opts = [owner: self(), cwd: cwd, path: expanded]

        case DynamicSupervisor.start_child(Elara.PluginSup, {PluginServer, opts}) do
          {:ok, pid} ->
            info = PluginServer.info(pid)
            plugin = %{pid: pid, path: expanded}
            plugins = [plugin | plugins]

            if MapSet.member?(ids, info.id) do
              {:halt, {:error, plugins, expanded, {:duplicate_plugin_id, info.id}}}
            else
              {:cont, {:ok, plugins, MapSet.put(ids, info.id), PluginServer.tools(pid) ++ tools}}
            end

          {:error, reason} ->
            {:halt, {:error, plugins, expanded, reason}}
        end

      _path, {:ok, plugins, _, _} ->
        {:halt, {:error, plugins, "<plugins>", :invalid_plugin_path}}
    end)
    |> case do
      {:ok, plugins, _ids, plugin_tools} ->
        case tool_table(Map.values(base_tools) ++ plugin_tools) do
          {:ok, tools} ->
            {:ok, Enum.reverse(plugins), tools}

          {:error, reason} ->
            stop_plugins(plugins)
            {:error, {:plugin_load_failed, "<registry>", reason}}
        end

      {:error, plugins, path, reason} ->
        stop_plugins(plugins)
        {:error, {:plugin_load_failed, path, reason}}
    end
  end

  defp start_plugins(_paths, _cwd, _base_tools, _ids) do
    {:error, {:plugin_load_failed, "<plugins>", :invalid_plugins}}
  end

  defp stop_plugins(plugins) do
    Enum.each(plugins, &DynamicSupervisor.terminate_child(Elara.PluginSup, &1.pid))
  end

  defp reload_plugins(shell) do
    case prepare_plugins(shell.plugins) do
      {:ok, prepared} ->
        with {:ok, tools} <- prepared_tool_table(shell.base_tools, prepared),
             ids = MapSet.new(shell.plugins, &PluginServer.info(&1.pid).id),
             paths = new_plugin_paths(shell),
             {:ok, added, tools} <- start_plugins(paths, shell.cwd, tools, ids) do
          Enum.each(prepared, fn %{plugin: plugin} ->
            :ok = PluginServer.commit_reload(plugin.pid)
          end)

          plugins = shell.plugins ++ added
          core = Core.replace_tools(shell.core, tools)
          recorder = FlightRecorder.segment(shell.recorder, core, :plugins_reloaded)
          infos = Enum.map(plugins, &PluginServer.info(&1.pid))
          {:ok, %{shell | core: core, recorder: recorder, plugins: plugins}, infos}
        else
          {:error, {:plugin_load_failed, path, reason}} ->
            abort_prepared(prepared)
            {:error, shell, {:plugin_reload_failed, path, reason}}

          {:error, path, reason} ->
            abort_prepared(prepared)
            {:error, shell, {:plugin_reload_failed, path, reason}}
        end

      {:error, prepared, path, reason} ->
        abort_prepared(prepared)
        {:error, shell, {:plugin_reload_failed, path, reason}}
    end
  end

  defp new_plugin_paths(%{discover_plugins?: true} = shell) do
    Elara.Plugin.discover(shell.cwd) -- Enum.map(shell.plugins, & &1.path)
  end

  defp new_plugin_paths(_shell), do: []

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
    handle_call({:ask_async, prompt}, nil, shell)
  end

  defp handle_attached_command(:input_workspace, shell), do: {:reply, {:ok, shell.cwd}, shell}

  defp handle_attached_command(:reload_plugins, shell),
    do: handle_call(:reload_plugins, nil, shell)

  defp handle_attached_command(
         {:ask_input, _, _, _} = command,
         %{store: %{context: %{"handoff" => _}}} = shell
       ) do
    {:reply, forward_handoff(shell, {:attached_input, command}), shell}
  end

  defp handle_attached_command({:ask_input, prompt, references, images}, shell) do
    with :ok <- input_ready(shell, images),
         {:ok, user} <- Elara.Attachment.prepare(shell.cwd, prompt, references, images) do
      {:reply, :ok, feed({:ask_input, user}, shell)}
    else
      {:error, reason} -> {:reply, {:error, reason}, shell}
    end
  end

  defp handle_attached_command(:interrupt, shell) do
    shell = shell |> abort_running_tasks() |> stop_handoff() |> pause_existing_inputs()
    store = shell.store
    {:reply, :ok, feed(:interrupt, if(store.inbox == [], do: shell, else: inbox_changed(shell)))}
  end

  defp handle_attached_command({:submit_input, attrs}, shell), do: submit_input(attrs, shell)
  defp handle_attached_command({:cancel_input, id}, shell), do: cancel_input(id, shell)

  defp handle_attached_command({:input_status, id}, shell),
    do: {:reply, {:ok, find_input(shell, id)}, shell}

  defp handle_attached_command(:resume_inputs, shell), do: handle_call(:resume_inputs, nil, shell)

  defp handle_attached_command({:name, name}, shell) when is_binary(name) and name != "" do
    if Core.idle?(shell.core) do
      case Store.rename(shell.store, name) do
        {:ok, store} -> {:reply, :ok, %{shell | store: store}}
        {:error, reason} -> {:reply, {:error, reason}, shell}
      end
    else
      {:reply, {:error, :busy}, shell}
    end
  end

  defp handle_attached_command({:provider_settings, settings}, shell),
    do: change_provider_settings(shell, settings)

  defp handle_attached_command({:runtime_limits, changes}, shell),
    do: change_runtime_limits(shell, changes)

  defp handle_attached_command({:read_only, enabled}, shell),
    do: change_read_only(shell, enabled)

  defp handle_attached_command({:approve, id}, shell), do: approve_command(shell, id)

  defp handle_attached_command({:undo, _, _} = command, shell) do
    if Handoff.frozen?(shell.store),
      do: {:reply, forward_handoff(shell, {:undo_input, command}, :infinity), shell},
      else: workspace_undo(command, shell)
  end

  defp handle_attached_command(_command, shell), do: {:reply, {:error, :invalid_command}, shell}

  defp workspace_undo({:undo, :cancel, token}, shell) do
    preview =
      if shell.undo_preview && shell.undo_preview.plan.id == token,
        do: nil,
        else: shell.undo_preview

    {:reply, :ok, %{shell | undo_preview: preview}}
  end

  defp workspace_undo({:undo, action, value}, shell) when action in [:preview, :apply] do
    with :ok <- input_ready(shell, []),
         true <- map_size(shell.tasks) == 0 and map_size(shell.pending_effects) == 0 do
      case action do
        :preview ->
          case Elara.WorkspaceDiff.undo_preview(shell.workspace_diff, shell.store, value) do
            {:ok, plan} ->
              preview = %{plan: plan, leaf: shell.store.leaf}

              response = %{
                token: plan.id,
                turn_id: plan.turn,
                files: Elara.WorkspaceDiff.undo_paths(plan),
                notice: Elara.WorkspaceDiff.undo_limits()
              }

              {:reply, {:ok, response}, %{shell | undo_preview: preview}}

            {:error, reason} ->
              {:reply, {:error, reason}, %{shell | undo_preview: nil}}
          end

        :apply ->
          case shell.undo_preview do
            %{plan: %{id: ^value} = plan, leaf: leaf} when leaf == shell.store.leaf ->
              shell = %{shell | undo_preview: nil}

              case Elara.WorkspaceDiff.undo_apply(shell.workspace_diff, plan) do
                {:notice, notice, result} ->
                  shell = feed({:system_notice, notice}, shell)
                  shell = undo_recorded(shell, notice.undo_id)

                  response =
                    if result == :ok, do: {:ok, %{text: notice.text}}, else: {:error, notice.text}

                  {:reply, response, shell}

                {:error, reason} ->
                  {:reply, {:error, reason}, recover_workspace_undo(shell)}
              end

            _ ->
              {:reply, {:error, "Undo confirmation expired; run /undo again."},
               %{shell | undo_preview: nil}}
          end
      end
    else
      {:error, :busy} ->
        {:reply, {:error, "Undo refused: interrupt first."}, %{shell | undo_preview: nil}}

      false ->
        {:reply, {:error, "Undo refused: interrupt first; tool work is still outstanding."},
         %{shell | undo_preview: nil}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{shell | undo_preview: nil}}
    end
  end

  defp workspace_undo(_command, shell), do: {:reply, {:error, :invalid_command}, shell}

  defp recover_workspace_undo(shell) do
    case Elara.WorkspaceDiff.undo_recovery(shell.workspace_diff) do
      :none ->
        %{shell | undo_recovery: nil}

      {:error, reason} ->
        %{shell | undo_recovery: reason}

      {:notice, notice} ->
        recorded? =
          Enum.any?(
            shell.core.history,
            &match?(%Message.System{undo_id: id} when id == notice.undo_id, &1)
          )

        shell = if recorded?, do: shell, else: feed({:system_notice, notice}, shell)
        undo_recorded(shell, notice.undo_id)
    end
  end

  defp undo_recorded(shell, id) do
    case Elara.WorkspaceDiff.undo_recorded(shell.workspace_diff, id) do
      :ok ->
        %{shell | undo_recovery: nil}

      _ ->
        %{
          shell
          | undo_recovery:
              "Undo notice recorded, but recovery cleanup failed; reopen before continuing."
        }
    end
  end

  defp command_decision(shell, ref, call) do
    {:ok, args} = call.args

    case CommandRules.review(shell.cwd, shell.store.context["command_rules"], shell.command_rules) do
      {:ok, review} ->
        shell = save_command_rules(shell, review.retained)

        if is_binary(args["command"]) do
          case {CommandRules.classify(review.effective, args["command"]), review.loosening} do
            {{:deny, rule}, _} ->
              {shell,
               {:deny, "permission denied: command matches deny rule #{JSON.encode!(rule)}"}}

            {_, true} ->
              {shell, {:ask, command_pending(shell, ref, call, "rules", review.bytes)}}

            {{:ask, rule}, false} ->
              pending = command_pending(shell, ref, call, "call", nil)

              pending =
                Map.put(
                  pending,
                  "reason",
                  "Command matches ask rule #{JSON.encode!(rule)}; approve this exact call"
                )

              fnox_decision(shell, ref, call, {:ask, pending})

            {:allow, false} ->
              fnox_decision(shell, ref, call, :allow)
          end
        else
          if call.name in ["job", "test_job"] and args["action"] != "start",
            do: {shell, :allow},
            else: fnox_decision(shell, ref, call, :allow)
        end

      {:error, reason} ->
        {shell, {:deny, "permission denied: #{reason}"}}
    end
  end

  defp fnox_decision(shell, ref, call, otherwise) do
    approved = shell.store.context["fnox_config"]

    case Elara.Fnox.review(shell.cwd) do
      {:ok, ^approved} ->
        {shell, otherwise}

      {:ok, config} ->
        pending = command_pending(shell, ref, call, "fnox", config)

        pending =
          pending
          |> Map.delete("rule_bytes")
          |> Map.put("fnox_config", config)
          |> Map.put(
            "reason",
            if(config,
              do: "Project fnox configuration needs approval; approve these exact file digests",
              else: "Project fnox configuration removed; approve commands without fnox secrets"
            )
          )

        {shell, {:ask, pending}}

      {:error, reason} ->
        {shell, {:deny, reason}}
    end
  end

  defp command_pending(shell, ref, call, kind, bytes) do
    {:ok, args} = call.args

    digest =
      :crypto.hash(:sha256, JSON.encode!([call.name, args, bytes])) |> Base.encode16(case: :lower)

    %{
      "id" => "#{shell.incarnation}:#{ref}:#{kind}:#{digest}",
      "kind" => kind,
      "call_id" => call.id,
      "tool" => call.name,
      "args" => args,
      "rule_bytes" => bytes,
      "reason" =>
        if(kind == "rules",
          do: "Repo rules loosen limits; approve these exact bytes",
          else: "Command matches an ask rule; approve this exact call"
        )
    }
  end

  defp approve_command(%{store: %{context: %{"handoff" => _}}} = shell, id),
    do: {:reply, forward_handoff(shell, {:approve, id}), shell}

  defp approve_command(
         %{core: %{phase: {:approval_waiting, ref, call, _, _, pending}}} = shell,
         id
       )
       when is_binary(id) do
    if id == pending["id"] do
      {shell, decision} = command_decision(shell, ref, call)
      expected_bytes = pending["rule_bytes"]
      expected_config = pending["fnox_config"]

      case {pending["kind"], decision} do
        {"call", :allow} ->
          {:reply, :ok, feed({:tool_approved, ref}, shell)}

        {"call", {:ask, %{"kind" => "call"}}} ->
          {:reply, :ok, feed({:tool_approved, ref}, shell)}

        {"rules", {:ask, %{"kind" => "rules", "rule_bytes" => ^expected_bytes}}} ->
          bytes = expected_bytes
          {:ok, rules} = CommandRules.parse(bytes)
          {:reply, :ok, feed({:tool_approved, ref}, save_command_rules(shell, rules))}

        {"fnox", {:ask, %{"kind" => "fnox", "fnox_config" => ^expected_config}}} ->
          {:ok, store} =
            Store.save(%{
              shell.store
              | context: Map.put(shell.store.context, "fnox_config", expected_config)
            })

          {:reply, :ok, feed({:tool_approved, ref}, %{shell | store: store})}

        _ ->
          {:reply, {:error, :approval_changed}, feed({:tool_checked, ref, decision}, shell)}
      end
    else
      {:reply, {:error, :stale_approval}, shell}
    end
  end

  defp approve_command(shell, _), do: {:reply, {:error, :no_pending_approval}, shell}

  defp save_command_rules(shell, rules) do
    if shell.store.context["command_rules"] == rules or
         (not Map.has_key?(shell.store.context, "command_rules") and
            rules == %{"deny" => [], "ask" => []}) do
      shell
    else
      {:ok, store} =
        Store.save(%{shell.store | context: Map.put(shell.store.context, "command_rules", rules)})

      %{shell | store: store}
    end
  end

  defp record_command_guard(shell, entry) do
    entry = Map.put(entry, "after_entry", shell.store.leaf)
    context = Map.update(shell.store.context, "command_approvals", [entry], &(&1 ++ [entry]))
    {:ok, store} = Store.save(%{shell.store | context: context})
    %{shell | store: store}
  end

  defp input_ready(shell, images, queue? \\ false) do
    with :ok <- effect_input_ready(shell, queue?) do
      cond do
        Handoff.frozen?(shell.store) ->
          {:error, :handoff_source_open_successor}

        not Core.idle?(shell.core) ->
          {:error, :busy}

        images != [] and
            elem(shell.provider, 0) not in [Elara.Provider.OpenAICodex, Elara.Provider.Scripted] ->
          {:error, :images_unsupported_by_provider}

        true ->
          :ok
      end
    end
  end

  defp effect_input_ready(shell, queue?) do
    legacy =
      Enum.find(shell.effect_recovery_pending, fn
        %Job{} = job ->
          case ControllerJournal.observation(shell.effect_journal, job.job_id) do
            {:ok,
             %{
               executor_record: %Record{
                 state: :accepted,
                 callback_attempt_count: 1,
                 attempt_incarnation: nil,
                 operation_digest: digest
               }
             }}
            when digest == job.operation_digest ->
              true

            _ ->
              false
          end

        _ ->
          false
      end)

    cond do
      shell.undo_recovery ->
        {:error, shell.undo_recovery}

      legacy ->
        {:error,
         {:legacy_effect_ownership_unknown, legacy.job_id,
          "Cannot prove earlier writer/callback ownership ended: this legacy attempted job has no " <>
            "recorded incarnation or callback lifetime lock. Its outcome stays unknown and it will not be retried. " <>
            "Use /clone to carry this history into a usable session, or /fork before an earlier turn."}}

      not queue? and shell.effect_recovery_pending != [] ->
        {:error, :effect_recovery_pending}

      true ->
        :ok
    end
  end

  defp change_read_only(%{store: %{context: %{"handoff" => _}}} = shell, enabled) do
    result = forward_handoff(shell, {:read_only, enabled})
    shell = if match?({:ok, _}, result), do: feed(:inbox_changed, shell), else: shell
    {:reply, result, shell}
  end

  defp change_read_only(shell, enabled) when is_boolean(enabled) or enabled == :toggle do
    enabled = if enabled == :toggle, do: not shell.core.read_only, else: enabled
    {:reply, {:ok, enabled}, feed({:read_only, enabled}, shell)}
  end

  defp change_read_only(shell, _enabled), do: {:reply, {:error, :invalid_read_only}, shell}

  defp change_runtime_limits(%{store: %{context: %{"handoff" => _}}} = shell, changes) do
    result = forward_handoff(shell, {:runtime_limits, changes})

    shell =
      if match?({:ok, _}, result),
        do: feed(:runtime_limits_changed, shell),
        else: shell

    {:reply, result, shell}
  end

  defp change_runtime_limits(shell, changes) do
    valid =
      is_map(changes) and map_size(changes) > 0 and
        Enum.all?(changes, fn {key, value} ->
          key in [:max_iterations, :tool_timeout_ms] and is_integer(value) and value > 0
        end)

    if valid do
      current = Core.runtime_limits(shell.core)
      proposed = Map.merge(current, changes)

      case Elara.Config.runtime_limits(Map.to_list(proposed), %{}) do
        {:ok, limits} ->
          shell = feed({:runtime_limits, Map.new(limits), Map.keys(changes)}, shell)
          {:reply, {:ok, shell.core.pending_runtime_limits != nil}, shell}

        {:error, {:invalid_runtime_limit, :tool_timeout_ms}} ->
          {:reply, {:error, {:timeout_exceeds_ceiling, current.max_tool_timeout_ms}}, shell}
      end
    else
      {:reply, {:error, :invalid_runtime_limits}, shell}
    end
  end

  defp change_provider_settings(%{store: %{context: %{"handoff" => _}}} = shell, settings) do
    {:reply, forward_handoff(shell, {:provider_settings, settings}), shell}
  end

  defp change_provider_settings(shell, settings) do
    settings = Provider.Visibility.normalize(settings, shell.core.config.provider_catalog)

    with true <- shell.core.config.provider_settings != nil,
         :ok <- Elara.Provider.Visibility.validate(settings, shell.core.config.provider_catalog),
         {:ok, store} <- Store.set_provider_settings(shell.store, settings) do
      {:reply, :ok, feed({:provider_settings, settings}, %{shell | store: store})}
    else
      false -> {:reply, {:error, :provider_controls_unavailable}, shell}
      {:error, reason} -> {:reply, {:error, reason}, shell}
    end
  end

  defp snapshot(shell) do
    %{
      id: shell.id,
      incarnation: shell.incarnation,
      head: shell.next_event_seq - 1,
      snapshot: materialized_view(shell) |> Map.put("inbox", inbox_view(shell))
    }
  end

  defp controlled_store_copy(caller, shell, copy) do
    cond do
      shell.controller != caller ->
        {:reply, {:error, :not_controller}, shell}

      Elara.Threads.managed?(shell.id) ->
        {:reply, {:error, :managed_child_use_delegate_history}, shell}

      not Core.idle?(shell.core) ->
        {:reply, {:error, :busy}, shell}

      true ->
        case copy.(copy_store(shell)) do
          {:ok, store} ->
            Store.release(store)
            {:reply, {:ok, store.id, nil}, shell}

          {:ok, store, prompt} ->
            Store.release(store)
            {:reply, {:ok, store.id, prompt}, shell}

          {:error, reason} ->
            {:reply, {:error, reason}, shell}
        end
    end
  end

  defp listing_updated_at(%Store{path: path}) when is_binary(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> stat.mtime * 1_000
      _ -> System.system_time(:millisecond)
    end
  end

  defp listing_updated_at(_store), do: System.system_time(:millisecond)

  defp materialized_view(shell) do
    Protocol.snapshot(shell.id, shell.incarnation, shell.core)
    |> Map.put("runtime_limits", runtime_limits_view(shell))
  end

  defp runtime_limits_view(shell) do
    if Handoff.frozen?(shell.store) do
      case forward_handoff(shell, :runtime_limits_view) do
        %{} = limits -> limits
        _ -> nil
      end
    else
      Protocol.runtime_limits_view(shell.core)
    end
  end

  defp submit_input(
         %{id: id, sender_id: sender, kind: kind, user: %Message.User{} = user} = attrs,
         shell
       )
       when is_binary(id) and id != "" and is_binary(sender) and sender != "" and
              kind in [:normal, :steer, :agent, :report] do
    correlation = Map.get(attrs, :correlation)

    cond do
      not Elara.Completion.valid_correlation?(correlation) or
          (not is_nil(correlation) and kind != :report) ->
        {:reply, {:error, :invalid_input}, shell}

      Handoff.frozen?(shell.store) ->
        attrs = %{id: id, sender_id: sender, kind: kind, user: user, correlation: correlation}
        {:reply, forward_handoff(shell, {:submit_input, attrs}), shell}

      true ->
        accept_input(id, sender, kind, user, correlation, shell)
    end
  end

  defp submit_input(_, shell), do: {:reply, {:error, :invalid_input}, shell}

  defp accept_input(id, sender, kind, user, correlation, shell) do
    case find_input(shell, id) do
      nil ->
        size = byte_size(JSON.encode!(Store.encode_message(user)))

        if input_admissible(shell, user) != :ok do
          {:reply, input_admissible(shell, user), shell}
        else
          if size > Protocol.max_line_bytes() do
            {:reply, {:error, :message_too_large}, shell}
          else
            entry = %{
              id: id,
              session_id: shell.id,
              sender_id: sender,
              kind: kind,
              state: if(Core.idle?(shell.core), do: :accepted, else: :queued),
              user: user,
              created_at: System.system_time(:millisecond),
              error: nil
            }

            entry = if correlation, do: Map.put(entry, :correlation, correlation), else: entry
            paused = if kind == :normal, do: false, else: shell.store.inputs_paused

            base_store =
              if kind in [:normal, :steer],
                do: %{shell.store | agent_wake_count: 0},
                else: shell.store

            prospective = shell.store.inbox ++ [entry]

            with true <- durable_input_size(shell, prospective) <= Protocol.max_line_bytes(),
                 {:ok, store} <-
                   Store.put_inbox(
                     base_store,
                     prospective,
                     paused,
                     nil,
                     shell.store.active_input_id
                   ) do
              shell = inbox_changed(%{shell | store: store}) |> resolve_completion_waiters()
              shell = if kind == :steer, do: steer(shell), else: shell
              send(self(), :drain_inputs)
              {:reply, {:ok, entry}, shell}
            else
              false -> {:reply, {:error, :message_too_large}, shell}
              {:error, reason} -> {:reply, {:error, reason}, shell}
            end
          end
        end

      existing ->
        previous = Map.get(existing, :correlation)

        if existing.sender_id == sender and existing.kind == kind and existing.user == user and
             (previous == correlation or is_nil(previous) or is_nil(correlation)) do
          if is_nil(previous) and not is_nil(correlation) do
            updated = Map.put(existing, :correlation, correlation)
            inbox = Enum.map(shell.store.inbox, &if(&1.id == id, do: updated, else: &1))

            case Store.put_inbox(
                   shell.store,
                   inbox,
                   shell.store.inputs_paused,
                   nil,
                   shell.store.active_input_id
                 ) do
              {:ok, store} ->
                {:reply, {:ok, updated}, resolve_completion_waiters(%{shell | store: store})}

              {:error, reason} ->
                {:reply, {:error, reason}, shell}
            end
          else
            {:reply, {:ok, existing}, shell}
          end
        else
          {:reply, {:error, :submission_conflict}, shell}
        end
    end
  end

  defp resolve_completion_waiters(shell) do
    Enum.reduce(shell.completion_waiters, shell, fn {ref, waiter}, shell ->
      entry =
        Enum.find(
          shell.store.inbox,
          &(Map.get(&1, :correlation) == waiter.correlation)
        )

      if entry do
        response = %{
          "awaited" => true,
          "already_consumed" => entry.state in [:consumed, :failed],
          "input_state" => Atom.to_string(entry.state),
          "input_error" => entry.error,
          "correlation" => waiter.correlation,
          "input_id" => entry.id,
          "preview_only" => true,
          "evidence" => %{
            "text" => String.slice(entry.user.text, 0, 2_000),
            "agent_source" => entry.user.agent_source
          }
        }

        caller = elem(waiter.from, 0)

        core_ref =
          Enum.find_value(shell.tasks, fn
            {_, {:tool, core_ref, ^caller, _}} -> core_ref
            _ -> nil
          end)

        shell =
          if core_ref && entry.state in [:queued, :accepted],
            do: put_in(shell.completion_claims[core_ref], {entry.id, waiter.correlation}),
            else: shell

        Process.demonitor(ref, [:flush])
        if waiter.dependency, do: Process.demonitor(waiter.dependency, [:flush])

        result =
          if entry.state == :cancelled,
            do: {:error, :completion_input_cancelled},
            else: {:ok, response}

        GenServer.reply(waiter.from, result)
        %{shell | completion_waiters: Map.delete(shell.completion_waiters, ref)}
      else
        shell
      end
    end)
  end

  defp consume_claimed_completion(shell, core_ref, outcome) do
    {claim, claims} = Map.pop(shell.completion_claims, core_ref)
    shell = %{shell | completion_claims: claims}

    case {claim, shell.core.phase, outcome} do
      {{id, correlation}, {:running_tool, ^core_ref, call, _, _}, {:ok, json}} ->
        if match?(
             {:ok, %{"awaited" => true, "input_id" => ^id, "correlation" => ^correlation}},
             JSON.decode(json)
           ) and
             Enum.any?(shell.store.inbox, fn entry ->
               entry.id == id and entry.state in [:queued, :accepted] and
                 Map.get(entry, :correlation) == correlation
             end) do
          inbox =
            Enum.map(shell.store.inbox, &if(&1.id == id, do: %{&1 | state: :consumed}, else: &1))

          %{shell | store: %{shell.store | inbox: inbox}, consuming_id: {:completion, call.id}}
        else
          shell
        end

      _ ->
        shell
    end
  end

  defp cancel_input(id, %{store: %{context: %{"handoff" => _}}} = shell) do
    {:reply, forward_handoff(shell, {:cancel_input, id}), shell}
  end

  defp cancel_input(id, shell) when is_binary(id) do
    case find_input(shell, id) do
      nil ->
        {:reply, {:ok, nil}, shell}

      %{state: state} = entry when state in [:consumed, :cancelled, :failed] ->
        {:reply, {:ok, entry}, shell}

      entry ->
        updated = %{entry | state: :cancelled}
        inbox = Enum.map(shell.store.inbox, &if(&1.id == id, do: updated, else: &1))

        case Store.put_inbox(
               shell.store,
               inbox,
               shell.store.inputs_paused,
               nil,
               shell.store.active_input_id
             ) do
          {:ok, store} ->
            shell = inbox_changed(%{shell | store: store})
            {:reply, {:ok, updated}, shell}

          {:error, reason} ->
            {:reply, {:error, reason}, shell}
        end
    end
  end

  defp cancel_input(_, shell), do: {:reply, {:error, :invalid_input}, shell}

  defp find_input(shell, id) do
    local = Enum.find(shell.store.inbox, &(&1.id == id))

    if Handoff.frozen?(shell.store) and (is_nil(local) or local.state in [:queued, :accepted]) do
      case forward_handoff(shell, {:input_status, id}) do
        {:ok, entry} -> entry
        _ -> local
      end
    else
      local ||
        Enum.find_value(shell.store.context["sources"] || [], fn source ->
          with {:ok, store} <- Store.open(source["path"]) do
            Enum.find(
              store.inbox,
              &(&1.id == id and &1.state in [:consumed, :cancelled, :failed])
            )
          else
            _ -> nil
          end
        end)
    end
  end

  defp drain_inputs(%{effect_recovery_pending: [_ | _]} = shell), do: shell
  defp drain_inputs(%{store: %{inputs_paused: true}} = shell), do: shell
  defp drain_inputs(%{store: %{active_input_id: id}} = shell) when not is_nil(id), do: shell
  defp drain_inputs(%{store: %{context: %{"handoff" => _}}} = shell), do: shell

  defp drain_inputs(shell) do
    if Core.idle?(shell.core) do
      pending = Enum.filter(shell.store.inbox, &(&1.state in [:queued, :accepted]))
      entry = Enum.find(pending, &(&1.kind == :steer)) || List.first(pending)

      continuation? =
        not is_nil(entry) and is_binary(shell.store.context["source"]) and
          entry.id == "handoff:" <> shell.id

      if entry &&
           (continuation? or
              not (entry.kind in [:agent, :report] and shell.store.agent_wake_count >= 8)) do
        jobs =
          if shell.effect_journal do
            recovery_barrier_jobs(shell.store, shell.core.config.tools, shell.effect_journal, %{
              executor_explicit?: shell.effect_executor_explicit?
            })
          else
            []
          end

        unsettled = pending_receipt_effects(%{shell | effect_recovery_pending: jobs})

        if unsettled != [] do
          Process.send_after(self(), :check_effect_recovery, 25)
          %{shell | effect_recovery_pending: unsettled}
        else
          consumed = %{entry | state: :consumed}
          inbox = Enum.map(shell.store.inbox, &if(&1.id == entry.id, do: consumed, else: &1))

          # Commit consumption and the User append together, never separately.
          count =
            cond do
              continuation? -> shell.store.agent_wake_count
              entry.kind in [:agent, :report] -> shell.store.agent_wake_count + 1
              true -> 0
            end

          store = %{
            shell.store
            | inbox: inbox,
              active_input_id: entry.id,
              agent_wake_count: count
          }

          feed({:ask_input, entry.user}, %{shell | store: store, consuming_id: entry.id})
        end
      else
        shell
      end
    else
      shell
    end
  end

  defp steer(shell) do
    case shell.core.phase do
      {:calling_provider, _, _} -> feed(:steer, abort_running_tasks(shell))
      {:awaiting_retry, _, _, _, _} -> feed(:steer, shell)
      {:running_tool, _, _, _, _} -> feed(:steer, shell)
      {:checking_tool, _, _, _, _} -> feed(:steer, shell)
      {:approval_waiting, _, _, _, _, _} -> feed(:steer, shell)
      _ -> shell
    end
  end

  defp inbox_changed(shell) do
    feed(:inbox_changed, shell)
  end

  defp pause_existing_inputs(shell) do
    {:ok, store} =
      Store.put_inbox(shell.store, shell.store.inbox, true, nil, shell.store.active_input_id)

    %{shell | store: store}
  end

  defp finish_active_input(%{store: %{active_input_id: nil}} = shell, _outcome), do: shell

  defp finish_active_input(shell, outcome) do
    id = shell.store.active_input_id
    failed? = match?({:provider_error, _}, outcome)
    error = if failed?, do: inspect(outcome), else: nil

    inbox =
      Enum.map(shell.store.inbox, fn
        %{id: ^id} = entry ->
          %{entry | state: if(failed?, do: :failed, else: :consumed), error: error}

        entry ->
          entry
      end)

    case Store.put_inbox(shell.store, inbox, shell.store.inputs_paused) do
      {:ok, store} -> inbox_changed(%{shell | store: store})
      {:error, reason} -> raise "failed to persist completed input: #{inspect(reason)}"
    end
  end

  defp fail_restarted_input(%{active_input_id: nil} = store), do: {store, false}

  defp fail_restarted_input(store) do
    id = store.active_input_id

    inbox =
      Enum.map(
        store.inbox,
        &if(&1.id == id, do: %{&1 | state: :failed, error: "session restarted"}, else: &1)
      )

    paused =
      store.inputs_paused or (is_binary(store.context["source"]) and id == "handoff:" <> store.id)

    case Store.put_inbox(store, inbox, paused) do
      {:ok, store} -> {store, true}
      {:error, _} -> {store, false}
    end
  end

  defp finish_restart_recovery(%Shell{effect_recovery_pending: [_ | _]} = shell),
    do: {shell, false}

  defp finish_restart_recovery(shell) do
    {store, recovered?} = fail_restarted_input(shell.store)
    {%{shell | store: store}, recovered?}
  end

  defp input_admissible(shell, user) do
    images = Enum.filter(user.attachments, &(&1["kind"] == "image"))
    input_ready(%{shell | core: %{shell.core | phase: :idle}}, images, true)
  end

  defp durable_input_size(shell, inbox) do
    prospective = %{shell | store: %{shell.store | inbox: inbox}}
    view = Map.put(materialized_view(shell), "inbox", inbox_view(prospective))

    # Include immutable payloads, not just public attachment metadata, and
    # reserve room for pending User messages when they enter the transcript.
    byte_size(JSON.encode!(view)) +
      Enum.sum(Enum.map(inbox, &byte_size(JSON.encode!(Store.encode_message(&1.user)))))
  end

  defp inbox_view(shell) do
    %{
      "entries" =>
        Enum.map(shell.store.inbox, fn e ->
          %{
            "id" => e.id,
            "session_id" => e.session_id,
            "sender_id" => e.sender_id,
            "kind" => Atom.to_string(e.kind),
            "state" => Atom.to_string(e.state),
            "text" => e.user.text,
            "attachments" => Enum.map(e.user.attachments, &Elara.Attachment.metadata/1),
            "error" => e.error
          }
          |> then(fn view ->
            if correlation = Map.get(e, :correlation),
              do: Map.put(view, "correlation", correlation),
              else: view
          end)
        end),
      "paused" => shell.store.inputs_paused,
      "context" => Context.budget(shell.core, shell.context_limit, shell.provider),
      "web_content_entered" => Handoff.web_content(shell),
      "handoff" =>
        case Handoff.outgoing(shell.store) || shell.store.context["last_handoff"] do
          nil -> nil
          h -> Map.drop(h, ["path"])
        end,
      "source" => shell.store.context["source"],
      "wake_budget_exhausted" => shell.store.agent_wake_count >= 8,
      "execution" => %{
        "mode" => "trusted_local",
        "read_only" => Handoff.read_only(shell),
        "read_only_notice" => shell.store.context["read_only_notice"],
        "allowed_capabilities" => shell.allowed_capabilities
      }
    }
  end

  defp begin_handoff(shell, core_ref) do
    jobs =
      if shell.effect_journal do
        recovery_barrier_jobs(shell.store, shell.core.config.tools, shell.effect_journal, %{
          executor_explicit?: shell.effect_executor_explicit?
        })
      else
        []
      end

    shell = %{
      shell
      | effect_recovery_pending: pending_receipt_effects(%{shell | effect_recovery_pending: jobs})
    }

    if shell.effect_recovery_pending != [], do: send(self(), :check_effect_recovery)

    case Handoff.prepare(shell) do
      {:ok, shell} ->
        shell.handoff_fault_hook.("prepared")
        shell = feed(:interrupt, shell)
        send(self(), :advance_handoff)
        inbox_changed(shell)

      {:error, reason} ->
        feed(
          {:provider_result, core_ref,
           {:error,
            %Provider.Error{
              kind: :resource_limit,
              message:
                "Context handoff blocked: #{inspect(reason)}; original evidence preserved. Fork before an earlier turn to start a fresh chain, or select a model with a larger context window."
            }}},
          shell
        )
    end
  end

  defp stop_handoff(shell) do
    case Handoff.outgoing(shell.store) do
      nil ->
        shell

      %{"id" => id} ->
        if id, do: Elara.interrupt(id)
        {:ok, shell} = Handoff.stage(shell, "stopped")
        shell

      _ ->
        shell
    end
  end

  defp forward_handoff(shell, command, timeout \\ 5000) do
    case Handoff.outgoing(shell.store) do
      %{"delivery_owner" => id} ->
        with {:ok, pid} <- Elara.session_pid(id), do: GenServer.call(pid, command, timeout)

      _ ->
        {:error, :handoff_not_ready}
    end
  catch
    :exit, _ -> {:error, :handoff_successor_unavailable}
  end

  defp relay_handoff_ask(shell, command, from) do
    {:ok, _} =
      Task.Supervisor.start_child(Elara.TaskSup, fn ->
        GenServer.reply(from, forward_handoff(shell, command, :infinity))
      end)

    {:noreply, shell}
  end

  defp grant_control(:observe, _pid, _shell), do: :ok

  defp grant_control(:control, pid, %{controller: controller}) when controller in [nil, pid],
    do: :ok

  defp grant_control(:control, _pid, _shell), do: {:error, :control_taken}

  defp current_effect(:idle), do: nil
  defp current_effect({:calling_provider, ref, _}), do: %{kind: :provider, ref: ref}

  defp current_effect({:awaiting_retry, ref, _, attempt, delay_ms}),
    do: %{kind: :provider_retry, ref: ref, attempt: attempt, delay_ms: delay_ms}

  defp current_effect({:running_tool, ref, call, _rest, _}),
    do: %{kind: :tool, ref: ref, name: call.name}

  defp current_effect({:checking_tool, _, _, _, _}), do: nil
  defp current_effect({:approval_waiting, _, _, _, _, _}), do: nil

  defp new_incarnation do
    12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp new_cancellation_id do
    12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp tool_request(shell, call, tool, args, timeout \\ nil) do
    %Request{
      tool_call_id: call.id,
      session_id: shell.id,
      output_owner: shell.store.id,
      fnox_config: shell.store.context["fnox_config"],
      mcp_guard: shell.core.mcp_guard,
      tool_name: call.name,
      tool_version: tool.version,
      arguments: args,
      workspace_id: shell.workspace_id,
      deadline_ms:
        System.system_time(:millisecond) + (timeout || shell.core.config.tool_timeout_ms),
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
        mcp_guard: request.mcp_guard,
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
