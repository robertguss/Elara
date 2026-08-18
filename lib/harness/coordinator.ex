defmodule Harness.Coordinator do
  @moduledoc "Supervises bounded child-session orchestration without entering the session loop."

  use GenServer

  alias Harness.Coordinator.Engine

  defmodule Result do
    @moduledoc "Compact child result; transcripts stay in child sessions."
    @type t :: %__MODULE__{}
    defstruct [:id, :role, :status, :answer, :error, :session_id, :worktree, :duration_ms]
  end

  defmodule Run do
    @moduledoc "Structured coordination outcome."
    @type t :: %__MODULE__{}
    defstruct [
      :pattern,
      :selected,
      :judge,
      results: [],
      failures: [],
      token_estimate: 0,
      elapsed_ms: 0,
      worker_health: []
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

  @spec run(pid(), :parallel | :specialists | :candidates | :map_reduce, [map()], keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def run(coordinator, pattern, specs, opts \\ []) do
    GenServer.call(coordinator, {:run, pattern, specs, opts}, :infinity)
  end

  @spec status(pid()) :: map()
  def status(coordinator), do: GenServer.call(coordinator, :status)

  @spec kill_child(pid(), String.t()) :: :ok | {:error, :child_not_found}
  def kill_child(coordinator, id), do: GenServer.call(coordinator, {:kill_child, id})

  @impl true
  def init(opts) do
    parent = Keyword.fetch!(opts, :parent)
    parent_config = Harness.child_config(parent)
    parent_session_id = Harness.status(parent).id
    {:ok, child_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    config = %{
      parent: parent,
      parent_session_id: parent_session_id,
      parent_config: parent_config,
      provider_factory: Keyword.get(opts, :provider_factory, fn _ -> parent_config.provider end),
      max_concurrency: Keyword.get(opts, :max_concurrency, 3),
      token_budget: Keyword.get(opts, :token_budget, 100_000),
      time_budget_ms: Keyword.get(opts, :time_budget_ms, 300_000),
      max_result_bytes: Keyword.get(opts, :max_result_bytes, 4_096),
      child_opts: Keyword.get(opts, :child_opts, [])
    }

    {:ok,
     %{
       child_sup: child_sup,
       config: config,
       run: nil,
       children: %{},
       worktrees: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:run, _pattern, _specs, _opts}, _from, %{run: run} = state)
      when not is_nil(run) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:run, pattern, specs, opts}, from, state)
      when pattern in [:parallel, :specialists, :candidates, :map_reduce] and is_list(specs) do
    owner = self()
    run_id = new_run_id()

    task =
      Task.Supervisor.async_nolink(Harness.TaskSup, fn ->
        Engine.run(owner, run_id, state.child_sup, state.config, pattern, specs, opts)
      end)

    run = %{
      id: run_id,
      task: task,
      from: from,
      pattern: pattern,
      started_at: now_ms(),
      progress: %{token_estimate: 0, active: 0, queued: length(specs), completed: 0}
    }

    {:noreply, %{state | run: run, children: %{}}}
  end

  def handle_call({:run, _pattern, _specs, _opts}, _from, state),
    do: {:reply, {:error, :invalid_pattern}, state}

  def handle_call(:status, _from, state) do
    status = %{
      running?: not is_nil(state.run),
      pattern: if(state.run, do: state.run.pattern),
      parent_session_id: state.config.parent_session_id,
      child_supervisor: state.child_sup,
      run: run_status(state),
      children: Map.values(state.children),
      worker_health: Harness.workers()
    }

    {:reply, status, state}
  end

  def handle_call({:kill_child, id}, _from, state) do
    case Map.get(state.children, id) do
      nil ->
        {:reply, {:error, :child_not_found}, state}

      child ->
        Process.exit(child.pid, :kill)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:coordinator_child_started, run_id, child}, %{run: %{id: run_id}} = state) do
    worktrees =
      if child.worktree, do: MapSet.put(state.worktrees, child.worktree), else: state.worktrees

    {:noreply,
     %{state | children: Map.put(state.children, child.id, child), worktrees: worktrees}}
  end

  def handle_info({:coordinator_progress, run_id, progress}, %{run: %{id: run_id}} = state) do
    {:noreply, put_in(state.run.progress, progress)}
  end

  def handle_info(
        {:coordinator_child_finished, run_id, id, status},
        %{run: %{id: run_id}} = state
      ) do
    children = Map.update(state.children, id, nil, &Map.put(&1, :status, status))
    {:noreply, %{state | children: children}}
  end

  def handle_info({ref, result}, %{run: %{task: %Task{ref: ref}} = run} = state) do
    Process.demonitor(ref, [:flush])
    GenServer.reply(run.from, result)
    {:noreply, %{state | run: nil}}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{run: %{task: %Task{ref: ref}} = run} = state
      ) do
    GenServer.reply(run.from, {:error, {:coordinator_crashed, reason}})
    {:noreply, %{state | run: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.run, do: Process.exit(state.run.task.pid, :kill)
    Process.unlink(state.child_sup)
    Supervisor.stop(state.child_sup, :shutdown)

    Enum.each(state.worktrees, fn path ->
      System.cmd("git", ["worktree", "remove", "--force", path],
        cd: state.config.parent_config.cwd,
        stderr_to_stdout: true
      )
    end)

    :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp run_status(%{run: nil}), do: nil

  defp run_status(state) do
    run = state.run
    progress = run.progress
    elapsed = now_ms() - run.started_at
    token_limit = state.config.token_budget
    time_limit = state.config.time_budget_ms

    %{
      id: run.id,
      pattern: run.pattern,
      started_at: run.started_at,
      budgets: %{
        token_estimate: %{
          used: progress.token_estimate,
          limit: token_limit,
          remaining: max(token_limit - progress.token_estimate, 0)
        },
        time_ms: %{elapsed: elapsed, limit: time_limit, remaining: max(time_limit - elapsed, 0)},
        concurrency: %{active: progress.active, limit: state.config.max_concurrency},
        queued: progress.queued,
        completed: progress.completed
      }
    }
  end

  defp new_run_id do
    12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
