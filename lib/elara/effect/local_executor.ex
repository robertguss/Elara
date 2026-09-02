defmodule Elara.Effect.LocalExecutor do
  @moduledoc "Supervised durable executor for receipt-backed local effects."

  alias Elara.Effect.Executor
  alias Elara.Session.Store

  @spec open(String.t(), String.t()) :: {:ok, Executor.t()} | {:error, term()}
  def open(cwd, workspace_id) when is_binary(cwd) and is_binary(workspace_id) do
    cwd = Path.expand(cwd)
    id = executor_id(cwd, workspace_id)
    name = name(id)

    case Registry.lookup(Elara.EffectExecutors, id) do
      [{pid, _value}] ->
        if Process.alive?(pid), do: {:ok, name}, else: start(id, ledger_path(cwd, id), name)

      [] ->
        start(id, ledger_path(cwd, id), name)
    end
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
      name: name
    ]

    child = %{
      id: {Executor, id},
      start: {Executor, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }

    case DynamicSupervisor.start_child(Elara.EffectExecutorSup, child) do
      {:ok, _pid} -> {:ok, name}
      {:error, {:already_started, _pid}} -> {:ok, name}
      {:error, reason} -> {:error, reason}
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
