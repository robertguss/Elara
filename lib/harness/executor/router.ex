defmodule Harness.Executor.Router do
  @moduledoc "Capability-, health-, affinity-, and load-aware executor selection."

  use GenServer

  alias Harness.Executor.Request

  defmodule Worker do
    @moduledoc false
    defstruct [:id, :executor, :capabilities, :workspaces, :placement, healthy?: true, load: 0]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec register(GenServer.server(), keyword()) :: :ok
  def register(router \\ __MODULE__, opts) do
    GenServer.call(router, {:register, opts})
  end

  @spec unregister(GenServer.server(), String.t()) :: :ok
  def unregister(router \\ __MODULE__, id), do: GenServer.call(router, {:unregister, id})

  @spec workers(GenServer.server()) :: [map()]
  def workers(router \\ __MODULE__), do: GenServer.call(router, :workers)

  @spec execute(GenServer.server(), Request.t(), Harness.Tool.t(), String.t()) ::
          Harness.Tool.outcome()
  def execute(router, %Request{} = request, tool, cwd) do
    if request_matches_tool?(request, tool) do
      attempt(router, request, tool, cwd, MapSet.new())
    else
      {:error, "executor request metadata does not match tool"}
    end
  end

  @impl true
  def init(_opts) do
    local = %Worker{
      id: "local",
      executor: {Harness.Executor.Local, :session_cwd},
      capabilities: :all,
      workspaces: :all,
      placement: :local
    }

    {:ok, %{workers: %{local.id => local}, affinity: %{}}}
  end

  @impl true
  def handle_call({:register, opts}, _from, state) do
    worker = %Worker{
      id: Keyword.fetch!(opts, :id),
      executor: Keyword.fetch!(opts, :executor),
      capabilities: MapSet.new(Keyword.fetch!(opts, :capabilities)),
      workspaces: MapSet.new(Keyword.get(opts, :workspaces, [])),
      placement: :remote
    }

    {:reply, :ok, put_in(state.workers[worker.id], worker)}
  end

  def handle_call({:unregister, id}, _from, state) do
    {:reply, :ok, %{state | workers: Map.delete(state.workers, id)}}
  end

  def handle_call(:workers, _from, state) do
    rows = Enum.map(state.workers, fn {_id, worker} -> Map.from_struct(worker) end)
    {:reply, rows, state}
  end

  def handle_call({:checkout, request, excluded}, _from, state) do
    case select_worker(state, request, excluded) do
      nil ->
        {:reply, {:error, :no_executor}, state}

      worker ->
        workers = Map.update!(state.workers, worker.id, &%{&1 | load: &1.load + 1})
        affinity = Map.put(state.affinity, request.workspace_id, worker.id)
        {:reply, {:ok, worker}, %{state | workers: workers, affinity: affinity}}
    end
  end

  @impl true
  def handle_cast({:complete, id, healthy?}, state) do
    workers =
      Map.update(state.workers, id, nil, fn worker ->
        %{worker | load: max(worker.load - 1, 0), healthy?: worker.healthy? and healthy?}
      end)
      |> Enum.reject(fn {_id, worker} -> is_nil(worker) end)
      |> Map.new()

    {:noreply, %{state | workers: workers}}
  end

  defp attempt(router, request, tool, cwd, excluded) do
    case GenServer.call(router, {:checkout, request, excluded}) do
      {:ok, worker} ->
        try do
          result = invoke(worker, request, tool, cwd)
          healthy? = not match?({:executor_error, :transport, _}, result)
          GenServer.cast(router, {:complete, worker.id, healthy?})

          case result do
            {kind, text} when kind in [:ok, :error, :indeterminate] ->
              {kind, text}

            {:executor_error, :transport, message} when request.mutating ->
              {:indeterminate, "remote outcome unknown: #{message}"}

            {:executor_error, :rejected, message} ->
              {:error, "executor rejected request: #{message}"}

            {:executor_error, _kind, _message} ->
              attempt(router, request, tool, cwd, MapSet.put(excluded, worker.id))
          end
        catch
          kind, reason ->
            GenServer.cast(router, {:complete, worker.id, true})
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, :no_executor} ->
        if request.mutating and MapSet.size(excluded) > 0 do
          {:indeterminate, "remote outcome unknown: executor became unavailable"}
        else
          {:error, "no healthy executor satisfies the tool placement and capabilities"}
        end
    end
  end

  defp invoke(%Worker{executor: {module, :session_cwd}}, request, tool, cwd) do
    module.execute(%{cwd: cwd}, request, tool)
  end

  defp invoke(%Worker{executor: {module, config}}, request, tool, _cwd) do
    module.execute(config, request, tool)
  rescue
    error -> {:executor_error, :transport, Exception.message(error)}
  catch
    kind, reason -> {:executor_error, :transport, Exception.format_banner(kind, reason)}
  end

  defp select_worker(state, request, excluded) do
    affinity = Map.get(state.affinity, request.workspace_id)

    state.workers
    |> Map.values()
    |> Enum.filter(&eligible?(&1, request, excluded))
    |> Enum.min_by(fn worker -> {worker.load, worker.id != affinity, worker.id} end, fn -> nil end)
  end

  defp eligible?(worker, request, excluded) do
    worker.healthy? and not MapSet.member?(excluded, worker.id) and
      placement_matches?(worker.placement, request.placement) and
      capabilities_match?(worker.capabilities, request.required_capabilities) and
      workspace_matches?(worker.workspaces, request.workspace_id)
  end

  defp placement_matches?(:local, placement), do: placement in [:local, :any]
  defp placement_matches?(:remote, placement), do: placement in [:remote, :any]
  defp capabilities_match?(:all, _required), do: true

  defp capabilities_match?(available, required),
    do: Enum.all?(required, &MapSet.member?(available, &1))

  defp workspace_matches?(:all, _workspace), do: true
  defp workspace_matches?(available, workspace), do: MapSet.member?(available, workspace)

  defp request_matches_tool?(request, tool) do
    request.tool_name == tool.name and request.tool_version == tool.version and
      MapSet.new(request.required_capabilities) == MapSet.new(tool.capabilities) and
      request.placement == tool.placement and request.mutating == tool.mutating
  end
end
