defmodule Elara.Effect.LocalExecutor do
  @moduledoc "Supervised durable executor for receipt-backed local effects."

  alias Elara.Effect.Executor
  alias Elara.Session.Store

  @lock_wait_notice "waiting for the previous session's lock to clear"

  @spec open(String.t(), String.t(), keyword()) :: {:ok, Executor.t()} | {:error, term()}
  def open(cwd, workspace_id, opts \\ []) when is_binary(cwd) and is_binary(workspace_id) do
    cwd = Path.expand(cwd)
    id = executor_id(cwd, workspace_id)
    name = name(id)
    on_status = Keyword.get(opts, :on_status, &print_status/1)
    task = Task.async(fn -> open_registered(ledger_path(cwd, id), id, name) end)
    await_open(task, name, on_status, nil)
  end

  defp open_registered(path, id, name) do
    case Registry.lookup(Elara.EffectExecutors, id) do
      [{_pid, nil}] ->
        {:ok, name}

      [{_pid, {:failed, reason}}] ->
        {:error, reason}

      [{_pid, status}] when status in [:initializing, :waiting_for_lock] ->
        Process.sleep(25)
        open_registered(path, id, name)

      [] ->
        start(id, path, name)
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp await_open(task, name, on_status, previous) do
    case Task.yield(task, 25) do
      {:ok, result} ->
        if previous, do: on_status.(nil)
        result

      nil ->
        notice = lock_wait_notice(name)
        if notice != previous, do: on_status.(notice)
        await_open(task, name, on_status, notice)
    end
  end

  defp print_status(nil), do: :ok
  defp print_status(notice), do: IO.puts(:stderr, notice)

  @doc false
  def lock_wait_notice({:via, Registry, {Elara.EffectExecutors, id}}) do
    case Registry.lookup(Elara.EffectExecutors, id) do
      [{_pid, :waiting_for_lock}] -> @lock_wait_notice
      _ -> nil
    end
  end

  def lock_wait_notice(_executor), do: nil

  @doc false
  def lock_status(id, status) do
    Registry.update_value(Elara.EffectExecutors, id, fn _ -> status end)

    for pid <- Registry.select(Elara.Sessions, [{{:_, :"$1", :_}, [], [:"$1"]}]) do
      send(pid, {:effect_lock_status, name(id)})
    end

    :ok
  end

  @doc false
  @spec ledger_path(String.t(), String.t()) :: String.t()
  def ledger_path(cwd, id) do
    with {:ok, root} <- Store.root() do
      Path.join([root, "_effect_executors", Store.cwd_key(cwd), "#{id}.sqlite3"])
    else
      {:error, :no_home} -> Path.join(System.tmp_dir!(), "elara-#{id}.sqlite3")
    end
  end

  defp start(id, path, name) do
    opts = [
      id: id,
      path: path,
      name: {:via, Registry, {Elara.EffectExecutors, id, :initializing}}
    ]

    child = %{
      id: {Executor, id},
      start: {Executor, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }

    case DynamicSupervisor.start_child(Elara.EffectExecutorSup, child) do
      {:ok, _pid} ->
        {:ok, name}

      {:error, {:already_started, _pid}} ->
        open_registered(path, id, name)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp name(id), do: {:via, Registry, {Elara.EffectExecutors, id}}

  defp executor_id(cwd, workspace_id) do
    digest =
      :sha256
      |> :crypto.hash([cwd, <<0>>, workspace_id])
      |> Base.url_encode64(padding: false)

    "local_v1_#{digest}"
  end
end
