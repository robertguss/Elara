defmodule Harness.Session do
  @moduledoc """
  Mechanical shell around Core. Bookkeeping only: tasks, timers, subscribers.
  """

  use GenServer

  alias Harness.Plugin.Server, as: PluginServer
  alias Harness.Provider
  alias Harness.Session.{Core, Store}
  alias Harness.Tool
  alias Harness.Tool.Ctx

  defmodule Shell do
    @moduledoc false
    @type t :: %__MODULE__{
            core: Core.State.t(),
            store: Store.t(),
            provider: {module(), term()},
            cwd: String.t(),
            tool_timeout_ms: pos_integer(),
            base_tools: %{String.t() => Tool.t()},
            plugins: [%{pid: pid(), path: String.t()}],
            subscribers: %{pid() => reference()},
            pending_reply: GenServer.from() | nil,
            tasks: %{reference() => {:provider | :tool, Core.ref(), pid()}},
            timers: %{Core.ref() => reference()}
          }

    defstruct [
      :core,
      :store,
      :provider,
      :cwd,
      :tool_timeout_ms,
      base_tools: %{},
      plugins: [],
      subscribers: %{},
      pending_reply: nil,
      tasks: %{},
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

    case hydrate(store, core_config) do
      {:ok, store, core} ->
        case start_plugins(plugin_paths, cwd, core.config.tools) do
          {:ok, plugins, tools} ->
            {:ok,
             %Shell{
               core: Core.replace_tools(core, tools),
               store: store,
               provider: provider,
               cwd: cwd,
               tool_timeout_ms: tool_timeout_ms,
               base_tools: core.config.tools,
               plugins: plugins
             }}

          {:error, reason} ->
            Store.release(store)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, shell) do
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

  def handle_call(:cwd, _from, shell) do
    {:reply, shell.cwd, shell}
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
          {:reply, {:ok, core.history}, %{shell | store: store, core: core}}

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

  @impl true
  def handle_cast(:interrupt, shell) do
    {:noreply, feed(:interrupt, shell)}
  end

  @impl true
  def handle_info({task_ref, result}, shell) when is_map_key(shell.tasks, task_ref) do
    Process.demonitor(task_ref, [:flush])
    {kind, core_ref, _pid} = Map.fetch!(shell.tasks, task_ref)
    shell = untrack_task(shell, task_ref, core_ref)

    shell =
      case {kind, result} do
        {:provider, {:ok, assistant, new_cfg}} ->
          shell = %{shell | provider: {elem(shell.provider, 0), new_cfg}}
          feed({:provider_result, core_ref, {:ok, assistant}}, shell)

        {:provider, {:error, error, new_cfg}} ->
          shell = %{shell | provider: {elem(shell.provider, 0), new_cfg}}
          feed({:provider_result, core_ref, {:error, error}}, shell)

        {:tool, outcome} ->
          feed({:tool_result, core_ref, outcome}, shell)
      end

    {:noreply, shell}
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, shell)
      when is_map_key(shell.tasks, task_ref) do
    {kind, core_ref, _pid} = Map.fetch!(shell.tasks, task_ref)
    shell = untrack_task(shell, task_ref, core_ref)

    shell =
      case kind do
        :tool ->
          feed({:tool_crashed, core_ref, reason}, shell)

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

    {:noreply, %{shell | subscribers: subscribers}}
  end

  def handle_info({:tool_deadline, core_ref}, shell) do
    case find_task_by_core_ref(shell, core_ref, :tool) do
      nil ->
        {:noreply, shell}

      {task_ref, pid} ->
        Process.demonitor(task_ref, [:flush])
        Process.exit(pid, :kill)
        shell = untrack_task(shell, task_ref, core_ref)
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
              {:reply, {:ok, prompt, core.history}, %{shell | store: store, core: core}}

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

  defp feed(fact, shell) do
    {core, effects} = Core.step(shell.core, fact)
    Enum.reduce(effects, %{shell | core: core}, &run_effect/2)
  end

  defp run_effect({:emit, {:message_appended, message} = event}, shell) do
    case Store.append(shell.store, message) do
      {:ok, store} ->
        emit(event, %{shell | store: store})

      {:error, reason} ->
        raise "session persistence failed: #{inspect(reason)}"
    end
  end

  defp run_effect({:emit, event}, shell) do
    emit(event, shell)
  end

  defp run_effect({:call_provider, core_ref, request}, shell) do
    {mod, cfg} = shell.provider
    task = Task.Supervisor.async_nolink(Harness.TaskSup, mod, :chat, [cfg, request])
    track_task(shell, task, :provider, core_ref)
  end

  defp run_effect({:run_tool, core_ref, call, tool}, shell) do
    {:ok, args} = call.args
    {m, f} = tool.run
    ctx = %Ctx{cwd: shell.cwd, plugin: tool.plugin, tool_name: call.name}

    task = Task.Supervisor.async_nolink(Harness.TaskSup, m, f, [args, ctx])
    timer = Process.send_after(self(), {:tool_deadline, core_ref}, shell.tool_timeout_ms)

    shell
    |> track_task(task, :tool, core_ref)
    |> Map.update!(:timers, &Map.put(&1, core_ref, timer))
  end

  defp emit(event, shell) do
    Enum.each(shell.subscribers, fn {pid, _} ->
      send(pid, {:harness, self(), event})
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

  defp track_task(shell, %Task{ref: ref, pid: pid}, kind, core_ref) do
    %{shell | tasks: Map.put(shell.tasks, ref, {kind, core_ref, pid})}
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
      {task_ref, {^kind, ^core_ref, pid}} -> {task_ref, pid}
      _ -> nil
    end)
  end

  defp start_plugins(paths, cwd, base_tools) when is_list(paths) do
    paths
    |> Enum.reduce_while({:ok, [], MapSet.new(), []}, fn
      path, {:ok, plugins, ids, tools} when is_binary(path) ->
        expanded = Path.expand(path, cwd)
        opts = [owner: self(), cwd: cwd, path: expanded]

        case DynamicSupervisor.start_child(Harness.PluginSup, {PluginServer, opts}) do
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
    Enum.reduce_while(shell.plugins, {:ok, shell, []}, fn plugin, {:ok, shell, infos} ->
      case PluginServer.prepare_reload(plugin.pid) do
        {:ok, candidate_tools} ->
          case candidate_tool_table(shell, plugin.pid, candidate_tools) do
            {:ok, tools} ->
              :ok = PluginServer.commit_reload(plugin.pid)
              core = Core.replace_tools(shell.core, tools)
              {:cont, {:ok, %{shell | core: core}, [PluginServer.info(plugin.pid) | infos]}}

            {:error, reason} ->
              :ok = PluginServer.abort_reload(plugin.pid)
              error = {:plugin_reload_failed, plugin.path, reason}
              {:halt, {:error, shell, error}}
          end

        {:error, reason} ->
          error = {:plugin_reload_failed, plugin.path, reason}
          {:halt, {:error, shell, error}}
      end
    end)
    |> case do
      {:ok, shell, infos} -> {:ok, shell, Enum.reverse(infos)}
      {:error, shell, reason} -> {:error, shell, reason}
    end
  end

  defp candidate_tool_table(shell, candidate_pid, candidate_tools) do
    plugin_tools =
      Enum.flat_map(shell.plugins, fn
        %{pid: ^candidate_pid} -> candidate_tools
        %{pid: pid} -> PluginServer.tools(pid)
      end)

    tool_table(Map.values(shell.base_tools) ++ plugin_tools)
  end

  defp tool_table(tools) do
    try do
      {:ok, Tool.table(tools)}
    rescue
      error in ArgumentError -> {:error, Exception.message(error)}
    end
  end
end
