defmodule Harness.Session do
  @moduledoc """
  Mechanical shell around Core. Bookkeeping only: tasks, timers, subscribers.
  """

  use GenServer

  alias Harness.Provider
  alias Harness.Session.Core
  alias Harness.Tool.Ctx

  defmodule Shell do
    @moduledoc false
    @type t :: %__MODULE__{
            core: Core.State.t(),
            provider: {module(), term()},
            cwd: String.t(),
            tool_timeout_ms: pos_integer(),
            subscribers: %{pid() => reference()},
            pending_reply: GenServer.from() | nil,
            tasks: %{reference() => {:provider | :tool, Core.ref(), pid()}},
            timers: %{Core.ref() => reference()}
          }

    defstruct [
      :core,
      :provider,
      :cwd,
      :tool_timeout_ms,
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
    tool_timeout_ms = Keyword.get(opts, :tool_timeout_ms, 30_000)

    {:ok,
     %Shell{
       core: Core.new(core_config),
       provider: provider,
       cwd: cwd,
       tool_timeout_ms: tool_timeout_ms
     }}
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

  def handle_info(_msg, shell), do: {:noreply, shell}

  defp feed(fact, shell) do
    {core, effects} = Core.step(shell.core, fact)
    Enum.reduce(effects, %{shell | core: core}, &run_effect/2)
  end

  defp run_effect({:emit, event}, shell) do
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

  defp run_effect({:call_provider, core_ref, request}, shell) do
    {mod, cfg} = shell.provider
    task = Task.Supervisor.async_nolink(Harness.TaskSup, mod, :chat, [cfg, request])
    track_task(shell, task, :provider, core_ref)
  end

  defp run_effect({:run_tool, core_ref, call, tool}, shell) do
    {:ok, args} = call.args
    {m, f} = tool.run
    ctx = %Ctx{cwd: shell.cwd}

    task = Task.Supervisor.async_nolink(Harness.TaskSup, m, f, [args, ctx])
    timer = Process.send_after(self(), {:tool_deadline, core_ref}, shell.tool_timeout_ms)

    shell
    |> track_task(task, :tool, core_ref)
    |> Map.update!(:timers, &Map.put(&1, core_ref, timer))
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
end
