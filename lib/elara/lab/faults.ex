defmodule Elara.Lab.Faults do
  @moduledoc """
  Named fault points for lab scenarios (RQ-1 fault model). Lab-only: never wired
  into production providers or tools.

  Code at a fault point calls the hook with the point and a key (`"sim_id:request"`
  from `Elara.Provider.Simulated`). A scheduled
  entry for `{key, point}` names a target to fail abruptly:

    * `:session`: kill the owning session process.
    * `:task`: kill the calling provider or tool task.
    * `:exec_stub`: SIGKILL the Rust execution stub's OS process.

  Points: `:provider_started` (before the first byte), `:provider_streaming`
  (after the first delta), and `:tool_running` (inside a mutating lab tool,
  after its write). Client-connection and VM-restart faults need an attached
  protocol client or a separate VM; they arrive with LAB-4/LAB-5.

  Every firing is reported to the collector as `{:lab_fault, key, point, target}`.
  """

  @type point :: :provider_started | :provider_streaming | :tool_running
  @type target :: :session | :task | :exec_stub
  @type schedule :: %{{term(), point()} => target()}

  @doc """
  Build a hook that fires the scheduled fault for `{key, point}` at most once. A
  request retried after its provider task died reuses its key, and must not
  fault again. The hook's state is an Agent linked to the caller.
  """
  @spec hook(schedule(), pid() | nil) :: (point(), term() -> :ok)
  def hook(schedule, collector \\ nil) when is_map(schedule) do
    {:ok, pending} = Agent.start_link(fn -> schedule end)

    fn point, key ->
      case Agent.get_and_update(pending, &Map.pop(&1, {key, point})) do
        nil ->
          :ok

        target ->
          if collector, do: send(collector, {:lab_fault, key, point, target})
          inject(target)
      end
    end
  end

  @doc "Fail the target abruptly from the calling (task) process."
  @spec inject(target()) :: :ok
  def inject(:session) do
    case owning_session() do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end

    :ok
  end

  def inject(:task), do: Process.exit(self(), :kill)

  def inject(:exec_stub) do
    case Elara.Exec.status() do
      %{os_pid: os_pid} when is_integer(os_pid) ->
        {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
        :ok

      _ ->
        :ok
    end
  end

  # The session is the caller registered in Elara.Sessions, however many tasks
  # sit between it and the fault point.
  defp owning_session do
    (Process.get(:"$callers") || [])
    |> Enum.find(&(Registry.keys(Elara.Sessions, &1) != []))
  end
end

defmodule Elara.Lab.Tools do
  @moduledoc "Lab-only tools with fault points."

  alias Elara.Tool

  @doc "Register a fault hook under `id` for lab tools to find by their `hook` argument."
  @spec register_hook(String.t(), (atom(), term() -> :ok)) :: :ok
  def register_hook(id, hook) when is_binary(id), do: :persistent_term.put({__MODULE__, id}, hook)

  @spec unregister_hook(String.t()) :: :ok
  def unregister_hook(id) do
    :persistent_term.erase({__MODULE__, id})
    :ok
  end

  @doc """
  A mutating tool that appends `label` to `path`, then reaches the `:tool_running`
  fault point with its `key`, so a fault there models a partial mutation. Its
  `hook` argument names a hook registered with `register_hook/2`.
  """
  @spec marker() :: Tool.t()
  def marker do
    %Tool{
      name: "lab_marker",
      version: "1",
      description: "Append a label to a file (lab fault point).",
      parameters: %{"type" => "object"},
      capabilities: ["filesystem:write"],
      mutating: true,
      placement: :local,
      run: {__MODULE__, :run_marker}
    }
  end

  @doc false
  def run_marker(%{"path" => path, "label" => label, "hook" => hook_id, "key" => key}, ctx) do
    File.write!(Path.expand(path, ctx.cwd), label <> "\n", [:append])
    hook = :persistent_term.get({__MODULE__, hook_id}, fn _point, _key -> :ok end)
    hook.(:tool_running, key)
    {:ok, "marked #{label}"}
  end
end
