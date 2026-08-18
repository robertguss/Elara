defmodule Harness.Plugin.Server do
  @moduledoc false

  use GenServer

  alias Harness.Plugin.{Info, Loader}
  alias Harness.Tool
  alias Harness.Tool.{Ctx, PluginRef}

  defmodule State do
    @moduledoc false
    defstruct [
      :owner,
      :owner_ref,
      :path,
      :cwd,
      :module,
      :metadata,
      :tools,
      :plugin_state,
      :active,
      :pending,
      generation: 1
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec info(pid()) :: Info.t()
  def info(server), do: GenServer.call(server, :info)

  @spec tools(pid()) :: [Tool.t()]
  def tools(server), do: GenServer.call(server, :tools)

  @spec prepare_reload(pid()) :: {:ok, [Tool.t()]} | {:error, term()}
  def prepare_reload(server), do: GenServer.call(server, :prepare_reload, :infinity)

  @spec commit_reload(pid()) :: :ok
  def commit_reload(server), do: GenServer.call(server, :commit_reload)

  @spec abort_reload(pid()) :: :ok
  def abort_reload(server), do: GenServer.call(server, :abort_reload)

  @spec checkout(pid(), pos_integer()) ::
          {:ok, reference(), module(), term()} | {:error, :busy | :stale_generation}
  def checkout(server, generation), do: GenServer.call(server, {:checkout, generation})

  @spec commit_invocation(pid(), reference(), term()) :: :ok | {:error, :stale_lease}
  def commit_invocation(server, lease, plugin_state) do
    GenServer.call(server, {:commit_invocation, lease, plugin_state})
  end

  @spec abort_invocation(pid(), reference()) :: :ok
  def abort_invocation(server, lease) do
    GenServer.call(server, {:abort_invocation, lease})
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    cwd = Keyword.fetch!(opts, :cwd)
    path = opts |> Keyword.fetch!(:path) |> Path.expand(cwd)

    with {:ok, candidate} <- Loader.load(path),
         {:ok, plugin_state} <- initialize(candidate.module, cwd) do
      {:ok,
       %State{
         owner: owner,
         owner_ref: Process.monitor(owner),
         path: path,
         cwd: cwd,
         module: candidate.module,
         metadata: candidate.metadata,
         tools: candidate.tools,
         plugin_state: plugin_state
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, plugin_info(state), state}
  def handle_call(:tools, _from, state), do: {:reply, tool_values(state), state}

  def handle_call(:prepare_reload, _from, %State{active: active} = state)
      when not is_nil(active) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:prepare_reload, _from, %State{pending: pending} = state)
      when not is_nil(pending) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:prepare_reload, _from, state) do
    with {:ok, candidate} <- Loader.load(state.path),
         :ok <- same_plugin?(state, candidate) do
      if candidate.module == state.module do
        {:reply, {:ok, tool_values(state)}, state}
      else
        case migrate(state, candidate) do
          {:ok, plugin_state} ->
            pending = %{candidate: candidate, plugin_state: plugin_state}
            next = %{state | pending: pending}
            {:reply, {:ok, tool_values(next, candidate, state.generation + 1)}, next}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:commit_reload, _from, %State{pending: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:commit_reload, _from, state) do
    %{candidate: candidate, plugin_state: plugin_state} = state.pending

    next = %{
      state
      | module: candidate.module,
        metadata: candidate.metadata,
        tools: candidate.tools,
        plugin_state: plugin_state,
        generation: state.generation + 1,
        pending: nil
    }

    {:reply, :ok, next}
  end

  def handle_call(:abort_reload, _from, state), do: {:reply, :ok, %{state | pending: nil}}

  def handle_call({:checkout, generation}, _from, %State{generation: current} = state)
      when generation != current do
    {:reply, {:error, :stale_generation}, state}
  end

  def handle_call({:checkout, _generation}, _from, %State{pending: pending} = state)
      when not is_nil(pending) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:checkout, _generation}, _from, %State{active: active} = state)
      when not is_nil(active) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:checkout, _generation}, {caller, _}, state) do
    lease = make_ref()
    active = %{lease: lease, caller: caller, monitor: Process.monitor(caller)}
    reply = {:ok, lease, state.module, state.plugin_state}
    {:reply, reply, %{state | active: active}}
  end

  def handle_call({:commit_invocation, lease, plugin_state}, {caller, _}, state) do
    case state.active do
      %{lease: ^lease, caller: ^caller, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, %{state | plugin_state: plugin_state, active: nil}}

      _ ->
        {:reply, {:error, :stale_lease}, state}
    end
  end

  def handle_call({:abort_invocation, lease}, {caller, _}, state) do
    case state.active do
      %{lease: ^lease, caller: ^caller, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, %{state | active: nil}}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, owner, _reason},
        %State{owner_ref: ref, owner: owner} = state
      ) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, caller, _reason}, state) do
    case state.active do
      %{monitor: ^ref, caller: ^caller} -> {:noreply, %{state | active: nil}}
      _ -> {:noreply, state}
    end
  end

  defp initialize(module, cwd) do
    with {:ok, result} <- Loader.call(module, :init, [%Ctx{cwd: cwd}]) do
      case result do
        {:ok, plugin_state} -> {:ok, plugin_state}
        {:error, reason} -> {:error, {:init_failed, reason}}
        _ -> {:error, :invalid_init_result}
      end
    end
  end

  defp migrate(state, candidate) do
    if function_exported?(candidate.module, :migrate, 2) do
      with {:ok, result} <-
             Loader.call(candidate.module, :migrate, [state.plugin_state, state.metadata]) do
        case result do
          {:ok, plugin_state} -> {:ok, plugin_state}
          {:error, reason} -> {:error, {:migration_failed, reason}}
          _ -> {:error, :invalid_migration_result}
        end
      end
    else
      {:ok, state.plugin_state}
    end
  end

  defp same_plugin?(state, candidate) do
    if candidate.metadata.id == state.metadata.id do
      :ok
    else
      {:error, {:plugin_id_changed, state.metadata.id, candidate.metadata.id}}
    end
  end

  defp plugin_info(state) do
    %Info{
      id: state.metadata.id,
      version: state.metadata.version,
      generation: state.generation,
      path: state.path,
      module: state.module,
      pid: self()
    }
  end

  defp tool_values(state), do: tool_values(state, state, state.generation)

  defp tool_values(_state, candidate, generation) do
    plugin = %PluginRef{
      id: candidate.metadata.id,
      version: candidate.metadata.version,
      generation: generation,
      server: self()
    }

    Enum.map(candidate.tools, fn spec ->
      %Tool{
        name: spec.name,
        version: candidate.metadata.version,
        description: spec.description,
        parameters: spec.parameters,
        run: {Harness.Plugin, :run},
        plugin: plugin,
        placement: :local
      }
    end)
  end
end
