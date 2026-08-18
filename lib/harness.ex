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

  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts \\ []) do
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)
    tools = Keyword.get_lazy(opts, :tools, &Tool.builtins/0)
    system = Keyword.get_lazy(opts, :system, fn -> Prompt.system(cwd) end)
    max_iterations = Keyword.get(opts, :max_iterations, 12)
    max_tool_output_bytes = Keyword.get(opts, :max_tool_output_bytes, 16_384)
    tool_timeout_ms = Keyword.get(opts, :tool_timeout_ms, 30_000)
    plugin_paths = Keyword.get_lazy(opts, :plugins, fn -> Plugin.discover(cwd) end)

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
        plugin_paths: plugin_paths
      ]

      DynamicSupervisor.start_child(Harness.SessionSup, {Session, child_opts})
    end
  end

  @spec ask(pid(), String.t(), timeout()) :: {:ok, String.t()} | {:error, ask_error()}
  def ask(session, prompt, timeout \\ :infinity)
      when is_pid(session) and is_binary(prompt) do
    GenServer.call(session, {:ask, prompt}, timeout)
  end

  @spec ask_async(pid(), String.t()) :: :ok | {:error, :busy}
  def ask_async(session, prompt) when is_pid(session) and is_binary(prompt) do
    GenServer.call(session, {:ask_async, prompt})
  end

  @spec subscribe(pid()) :: :ok
  def subscribe(session) when is_pid(session) do
    GenServer.call(session, :subscribe)
  end

  @spec plugins(pid()) :: [Plugin.Info.t()]
  def plugins(session) when is_pid(session) do
    GenServer.call(session, :plugins)
  end

  @spec reload_plugins(pid()) ::
          {:ok, [Plugin.Info.t()]} | {:error, :busy | {:plugin_reload_failed, String.t(), term()}}
  def reload_plugins(session) when is_pid(session) do
    GenServer.call(session, :reload_plugins, :infinity)
  end

  @spec interrupt(pid()) :: :ok
  def interrupt(session) when is_pid(session) do
    GenServer.cast(session, :interrupt)
  end

  @spec transcript(pid()) :: [Harness.Message.t()]
  def transcript(session) when is_pid(session) do
    GenServer.call(session, :transcript)
  end

  @spec cwd(pid()) :: String.t()
  def cwd(session) when is_pid(session) do
    GenServer.call(session, :cwd)
  end

  @spec user_entries(pid()) :: [%{id: String.t(), text: String.t()}]
  def user_entries(session) when is_pid(session), do: GenServer.call(session, :user_entries)

  @spec tree(pid(), String.t()) :: {:ok, String.t(), [Harness.Message.t()]} | {:error, term()}
  def tree(session, id) when is_pid(session) and is_binary(id) do
    GenServer.call(session, {:tree, id})
  end

  @spec fork(pid(), String.t()) :: {:ok, String.t(), [Harness.Message.t()]} | {:error, term()}
  def fork(session, id) when is_pid(session) and is_binary(id) do
    GenServer.call(session, {:fork, id})
  end

  @spec clone_session(pid()) :: {:ok, nil, [Harness.Message.t()]} | {:error, term()}
  def clone_session(session) when is_pid(session), do: GenServer.call(session, :clone)

  @spec name_session(pid(), String.t()) :: :ok | {:error, term()}
  def name_session(session, name) when is_pid(session) and is_binary(name) and name != "" do
    GenServer.call(session, {:name, name})
  end

  @spec list_sessions(String.t()) :: [Store.Info.t()]
  def list_sessions(cwd) when is_binary(cwd) do
    Store.list(cwd)
  end

  @spec resume(pid(), String.t()) :: {:ok, [Harness.Message.t()]} | {:error, term()}
  def resume(session, path) when is_pid(session) and is_binary(path) do
    cwd = cwd(session)

    with {:ok, store} <- Store.open(path, cwd) do
      GenServer.call(session, {:hydrate, store})
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
end
