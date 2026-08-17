defmodule Harness do
  @moduledoc "Public API. Callers never see GenServer message shapes or wire types."

  alias Harness.Prompt
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
        tool_timeout_ms: tool_timeout_ms
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

  @spec interrupt(pid()) :: :ok
  def interrupt(session) when is_pid(session) do
    GenServer.cast(session, :interrupt)
  end

  @spec transcript(pid()) :: [Harness.Message.t()]
  def transcript(session) when is_pid(session) do
    GenServer.call(session, :transcript)
  end

  @spec resume(pid(), String.t()) :: :ok | {:error, term()}
  def resume(session, path) when is_pid(session) and is_binary(path) do
    GenServer.call(session, {:resume, path})
  end

  defp fetch_provider(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, provider} -> {:ok, provider}
      :error -> Harness.Config.resolve()
    end
  end

  defp prepare_store(opts, cwd) do
    resume = Keyword.get(opts, :resume)
    continue? = Keyword.get(opts, :continue, false)

    cond do
      not is_nil(resume) and continue? == true ->
        {:error, :ambiguous}

      resume == :latest ->
        open_newest(cwd)

      is_binary(resume) ->
        Store.open(resume, cwd)

      not is_nil(resume) ->
        {:error, :invalid_resume}

      continue? == true ->
        open_newest(cwd)

      continue? == false ->
        {:ok, Store.new(cwd)}

      true ->
        {:error, :invalid_continue}
    end
  end

  defp open_newest(cwd) do
    with {:ok, info} <- Store.newest(cwd) do
      Store.open(info.path, cwd)
    end
  end
end
