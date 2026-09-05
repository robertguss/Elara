defmodule Elara do
  @moduledoc "Public API. Callers never see GenServer message shapes or wire types."

  alias Elara.Effect.LocalExecutor
  alias Elara.Plugin
  alias Elara.Prompt
  alias Elara.Session
  alias Elara.Session.Core
  alias Elara.Session.Store
  alias Elara.Tool

  @type ask_error ::
          :busy | :turn_limit | :interrupted | {:provider_error, Elara.Provider.Error.t()}

  @type session_ref :: String.t() | pid()

  @spec start_session(keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_session(opts \\ []) do
    start_session_under(Elara.SessionSup, opts)
  end

  @doc false
  @spec start_session_under(Supervisor.supervisor(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def start_session_under(supervisor, opts) do
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)
    tools = Keyword.get_lazy(opts, :tools, &Tool.builtins/0)
    system = Keyword.get_lazy(opts, :system, fn -> Prompt.system(cwd) end)
    max_iterations = Keyword.get(opts, :max_iterations, 12)
    max_tool_output_bytes = Keyword.get(opts, :max_tool_output_bytes, 16_384)
    tool_timeout_ms = Keyword.get(opts, :tool_timeout_ms, 30_000)
    plugin_paths = Keyword.get_lazy(opts, :plugins, fn -> Plugin.discover(cwd) end)
    router = Keyword.get(opts, :router, Elara.Executor.Router)
    workspace_id = Keyword.get_lazy(opts, :workspace_id, fn -> workspace_id(cwd) end)
    allowed_capabilities = Keyword.get(opts, :allowed_capabilities, :all)

    with {:ok, provider} <- fetch_provider(opts),
         {:ok, store} <- prepare_store(opts, cwd),
         {:ok, store} <- seed_store(store, Keyword.get(opts, :seed_history, [])),
         {:ok, effect_executor, effect_executor_explicit?} <-
           prepare_effect_executor(opts, tools, cwd, workspace_id) do
      effect_journal_path = Keyword.get(opts, :effect_journal_path) || effect_journal_path(store)

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
        allowed_capabilities: allowed_capabilities,
        effect_journal_path: effect_journal_path,
        effect_executor: effect_executor,
        effect_executor_explicit?: effect_executor_explicit?,
        effect_fault_hook: Keyword.get(opts, :effect_fault_hook, fn _point -> :ok end)
      ]

      case DynamicSupervisor.start_child(supervisor, {Session, child_opts}) do
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

  @doc "Accept model and effort for the next provider request; an in-flight request is unchanged."
  def set_provider_settings(session, settings), do: call(session, {:provider_settings, settings})

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
  @spec attach_v2(session_ref(), :control | :observe, non_neg_integer(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def attach_v2(session, mode, cursor \\ 0, incarnation \\ nil)
      when (is_pid(session) or is_binary(session)) and mode in [:control, :observe] and
             is_integer(cursor) and cursor >= 0 do
    call(session, {:attach_v2, mode, cursor, incarnation})
  end

  @doc false
  @spec snapshot(session_ref()) :: map() | {:error, :session_not_found}
  def snapshot(session) when is_pid(session) or is_binary(session), do: call(session, :snapshot)

  @spec materialized_view(session_ref()) :: map() | {:error, :session_not_found}
  def materialized_view(session) when is_pid(session) or is_binary(session),
    do: call(session, :materialized_view)

  @doc false
  @spec attached_command(session_ref(), term()) :: :ok | {:error, term()}
  def attached_command(session, command) when is_pid(session) or is_binary(session) do
    call(session, {:attached_command, command})
  end

  @spec status(session_ref()) :: map() | {:error, :session_not_found}
  def status(session) when is_pid(session) or is_binary(session), do: call(session, :status)

  @spec recording(session_ref()) :: Elara.FlightRecorder.Recording.t()
  def recording(session) when is_pid(session) or is_binary(session), do: call(session, :recording)

  @spec why(session_ref(), :latest | pos_integer() | {:transition, pos_integer()}) ::
          {:ok, map()} | {:error, :not_found | :session_not_found}
  def why(session, selector \\ :latest) when is_pid(session) or is_binary(session),
    do: call(session, {:why, selector})

  @spec replay(Elara.FlightRecorder.Recording.t() | String.t(), keyword()) ::
          {:ok, Elara.FlightRecorder.Report.t()} | {:error, term()}
  def replay(recording, opts \\ []), do: Elara.FlightRecorder.replay(recording, opts)

  @spec register_worker(keyword()) :: :ok
  def register_worker(opts), do: Elara.Executor.Router.register(opts)

  @spec workers() :: [map()]
  def workers, do: Elara.Executor.Router.workers()

  @spec start_coordinator(session_ref(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_coordinator(parent, opts) when is_pid(parent) or is_binary(parent) do
    with {:ok, _pid} <- session_pid(parent) do
      DynamicSupervisor.start_child(
        Elara.CoordinatorSup,
        {Elara.Coordinator, Keyword.put(opts, :parent, parent)}
      )
    end
  end

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

  @spec transcript(session_ref()) :: [Elara.Message.t()]
  def transcript(session) when is_pid(session) or is_binary(session) do
    call(session, :transcript)
  end

  @spec cwd(session_ref()) :: String.t()
  def cwd(session) when is_pid(session) or is_binary(session) do
    call(session, :cwd)
  end

  @doc false
  @spec replace_effect_executor(session_ref(), GenServer.server()) ::
          :ok | {:error, :session_not_found}
  def replace_effect_executor(session, executor) when is_pid(session) or is_binary(session) do
    call(session, {:replace_effect_executor, executor})
  end

  @doc false
  @spec child_config(session_ref()) :: map() | {:error, :session_not_found}
  def child_config(session) when is_pid(session) or is_binary(session),
    do: call(session, :child_config)

  @spec user_entries(session_ref()) :: [%{id: String.t(), text: String.t()}]
  def user_entries(session) when is_pid(session) or is_binary(session),
    do: call(session, :user_entries)

  @doc false
  @spec history_before(session_ref(), String.t()) ::
          {:ok, [Elara.Message.t()]} | {:error, term()}
  def history_before(session, id)
      when (is_pid(session) or is_binary(session)) and is_binary(id) do
    call(session, {:history_before, id})
  end

  @spec tree(session_ref(), String.t()) ::
          {:ok, String.t(), [Elara.Message.t()]} | {:error, term()}
  def tree(session, id) when (is_pid(session) or is_binary(session)) and is_binary(id) do
    call(session, {:tree, id})
  end

  @spec fork(session_ref(), String.t()) ::
          {:ok, String.t(), [Elara.Message.t()]} | {:error, term()}
  def fork(session, id) when (is_pid(session) or is_binary(session)) and is_binary(id) do
    call(session, {:fork, id})
  end

  @spec clone_session(session_ref()) :: {:ok, nil, [Elara.Message.t()]} | {:error, term()}
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

  @doc false
  @spec live_sessions() :: [map()]
  def live_sessions do
    Elara.Sessions
    |> Registry.select([
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.flat_map(fn {_id, pid} ->
      try do
        [GenServer.call(pid, :listing)]
      catch
        :exit, _reason -> []
      end
    end)
    |> Enum.sort_by(& &1.id)
  end

  @spec resume(session_ref(), String.t()) :: {:ok, [Elara.Message.t()]} | {:error, term()}
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
    case Registry.lookup(Elara.Sessions, id) do
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
      :error -> Elara.Config.resolve()
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

  defp seed_store(store, []), do: {:ok, store}

  defp seed_store(store, history) when is_list(history) do
    Enum.reduce_while(history, {:ok, store}, fn message, {:ok, current} ->
      case Store.append(current, message) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp prepare_effect_executor(opts, tools, cwd, workspace_id) do
    case Keyword.get(opts, :effect_executor) do
      nil ->
        if Enum.any?(tools, &Tool.builtin_write?/1) do
          case LocalExecutor.open(cwd, workspace_id) do
            {:ok, executor} -> {:ok, executor, false}
            {:error, reason} -> {:error, {:effect_executor_start_failed, reason}}
          end
        else
          {:ok, nil, false}
        end

      executor ->
        {:ok, executor, true}
    end
  end

  defp workspace_id(cwd) do
    :sha256
    |> :crypto.hash(Path.expand(cwd))
    |> Base.url_encode64(padding: false)
  end

  defp effect_journal_path(%Store{id: id, path: nil}) do
    root =
      case Store.root() do
        {:ok, root} -> root
        {:error, :no_home} -> System.tmp_dir!()
      end

    Path.join([root, "_effect_journals", "#{id}.sqlite3"])
  end

  defp effect_journal_path(%Store{path: path}), do: Path.rootname(path) <> ".effects.sqlite3"
end
