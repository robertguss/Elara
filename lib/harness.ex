defmodule Harness do
  @moduledoc "Public API. Callers never see GenServer message shapes or wire types."

  alias Harness.Prompt
  alias Harness.Plugin
  alias Harness.Session
  alias Harness.Session.Core
  alias Harness.Session.Store
  alias Harness.Tool

  @type ask_error ::
          :busy | :turn_limit | :interrupted | {:provider_error, Harness.Provider.Error.t()}

  @type session_ref :: String.t() | pid()

  @spec start_session(keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_session(opts \\ []) do
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)
    tools = Keyword.get_lazy(opts, :tools, &Tool.builtins/0)
    system = Keyword.get_lazy(opts, :system, fn -> Prompt.system(cwd) end)
    max_iterations = Keyword.get(opts, :max_iterations, 12)
    max_tool_output_bytes = Keyword.get(opts, :max_tool_output_bytes, 16_384)
    tool_timeout_ms = Keyword.get(opts, :tool_timeout_ms, 30_000)
    plugin_paths = Keyword.get_lazy(opts, :plugins, fn -> Plugin.discover(cwd) end)
    router = Keyword.get(opts, :router, Harness.Executor.Router)
    workspace_id = Keyword.get_lazy(opts, :workspace_id, fn -> workspace_id(cwd) end)
    allowed_capabilities = Keyword.get(opts, :allowed_capabilities, :all)

    with {:ok, provider} <- fetch_provider(opts),
         {:ok, store} <- prepare_store(opts, cwd) do
      core_config = %Core.Config{
        system: system,
        tools: Tool.table(tools),
        max_iterations: max_iterations,
        max_tool_output_bytes: max_tool_output_bytes
      }

      child_opts = [
        core_config: core_config,
        provider: provider,
        cwd: cwd,
        store: store,
        tool_timeout_ms: tool_timeout_ms,
        plugin_paths: plugin_paths,
        router: router,
        workspace_id: workspace_id,
        allowed_capabilities: allowed_capabilities
      ]

      case DynamicSupervisor.start_child(Harness.SessionSup, {Session, child_opts}) do
        {:ok, pid} -> {:ok, GenServer.call(pid, :session_id)}
        error -> error
      end
    end
  end

  @spec ask(session_ref(), String.t(), timeout()) :: {:ok, String.t()} | {:error, ask_error()}
  def ask(session, prompt, timeout \\ :infinity)
      when (is_pid(session) or is_binary(session)) and is_binary(prompt) do
    call(session, {:ask, prompt}, timeout)
  end

  @spec ask_async(session_ref(), String.t()) :: :ok | {:error, :busy}
  def ask_async(session, prompt)
      when (is_pid(session) or is_binary(session)) and is_binary(prompt) do
    call(session, {:ask_async, prompt})
  end

  @spec subscribe(session_ref()) :: :ok
  def subscribe(session) when is_pid(session) or is_binary(session) do
    call(session, :subscribe)
  end

  @doc false
  @spec attach(session_ref(), :control | :observe, non_neg_integer(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def attach(session, mode, cursor \\ 0, incarnation \\ nil)
      when (is_pid(session) or is_binary(session)) and mode in [:control, :observe] and
             is_integer(cursor) and cursor >= 0 do
    call(session, {:attach, mode, cursor, incarnation})
  end

  @doc false
  @spec attached_command(session_ref(), term()) :: :ok | {:error, term()}
  def attached_command(session, command) when is_pid(session) or is_binary(session) do
    call(session, {:attached_command, command})
  end

  @spec status(session_ref()) :: map() | {:error, :session_not_found}
  def status(session) when is_pid(session) or is_binary(session), do: call(session, :status)

  @spec register_worker(keyword()) :: :ok
  def register_worker(opts), do: Harness.Executor.Router.register(opts)

  @spec workers() :: [map()]
  def workers, do: Harness.Executor.Router.workers()

  @spec plugins(session_ref()) :: [Plugin.Info.t()]
  def plugins(session) when is_pid(session) or is_binary(session) do
    call(session, :plugins)
  end

  @spec reload_plugins(session_ref()) ::
          {:ok, [Plugin.Info.t()]} | {:error, :busy | {:plugin_reload_failed, String.t(), term()}}
  def reload_plugins(session) when is_pid(session) or is_binary(session) do
    call(session, :reload_plugins, :infinity)
  end

  @spec interrupt(session_ref()) :: :ok
  def interrupt(session) when is_pid(session) or is_binary(session) do
    cast(session, :interrupt)
  end

  @spec transcript(session_ref()) :: [Harness.Message.t()]
  def transcript(session) when is_pid(session) or is_binary(session) do
    call(session, :transcript)
  end

  @spec cwd(session_ref()) :: String.t()
  def cwd(session) when is_pid(session) or is_binary(session) do
    call(session, :cwd)
  end

  @spec user_entries(session_ref()) :: [%{id: String.t(), text: String.t()}]
  def user_entries(session) when is_pid(session) or is_binary(session),
    do: call(session, :user_entries)

  @spec tree(session_ref(), String.t()) ::
          {:ok, String.t(), [Harness.Message.t()]} | {:error, term()}
  def tree(session, id) when (is_pid(session) or is_binary(session)) and is_binary(id) do
    call(session, {:tree, id})
  end

  @spec fork(session_ref(), String.t()) ::
          {:ok, String.t(), [Harness.Message.t()]} | {:error, term()}
  def fork(session, id) when (is_pid(session) or is_binary(session)) and is_binary(id) do
    call(session, {:fork, id})
  end

  @spec clone_session(session_ref()) :: {:ok, nil, [Harness.Message.t()]} | {:error, term()}
  def clone_session(session) when is_pid(session) or is_binary(session), do: call(session, :clone)

  @spec name_session(session_ref(), String.t()) :: :ok | {:error, term()}
  def name_session(session, name)
      when (is_pid(session) or is_binary(session)) and is_binary(name) and name != "" do
    call(session, {:name, name})
  end

  @spec list_sessions(String.t()) :: [Store.Info.t()]
  def list_sessions(cwd) when is_binary(cwd) do
    Store.list(cwd)
  end

  @spec resume(session_ref(), String.t()) :: {:ok, [Harness.Message.t()]} | {:error, term()}
  def resume(session, path) when (is_pid(session) or is_binary(session)) and is_binary(path) do
    cwd = cwd(session)

    with {:ok, store} <- Store.open(path, cwd) do
      call(session, {:hydrate, store})
    end
  end

  @doc "Resolve a stable session ID (or compatibility PID) to its live process."
  @spec session_pid(session_ref()) :: {:ok, pid()} | {:error, :session_not_found}
  def session_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :session_not_found}
  end

  def session_pid(id) when is_binary(id) do
    case Registry.lookup(Harness.Sessions, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :session_not_found}
    end
  end

  defp call(session, message, timeout \\ 5_000) do
    case session_pid(session) do
      {:ok, pid} -> GenServer.call(pid, message, timeout)
      error -> error
    end
  end

  defp cast(session, message) do
    case session_pid(session) do
      {:ok, pid} -> GenServer.cast(pid, message)
      {:error, :session_not_found} -> :ok
    end
  end

  defp fetch_provider(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, provider} -> {:ok, provider}
      :error -> Harness.Config.resolve()
    end
  end

  defp prepare_store(opts, cwd) do
    persist? = Keyword.get(opts, :persist, true)
    resume = Keyword.get(opts, :resume)

    cond do
      persist? == false and not is_nil(resume) ->
        {:error, :invalid_persist}

      persist? == false ->
        {:ok, Store.memory(cwd)}

      persist? != true ->
        {:error, :invalid_persist}

      true ->
        with {:ok, _root} <- Store.root() do
          case resume do
            nil -> {:ok, Store.new(cwd, Keyword.get(opts, :name))}
            :latest -> open_newest(cwd)
            path when is_binary(path) -> Store.open(path, cwd)
            _ -> {:error, :invalid_resume}
          end
        end
    end
  end

  defp open_newest(cwd) do
    with {:ok, info} <- Store.newest(cwd) do
      Store.open(info.path, cwd)
    end
  end

  defp workspace_id(cwd) do
    :sha256
    |> :crypto.hash(Path.expand(cwd))
    |> Base.url_encode64(padding: false)
  end
end
