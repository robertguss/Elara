defmodule Harness do
  @moduledoc "Public API. Callers never see GenServer message shapes or wire types."

  alias Harness.Prompt
  alias Harness.Session
  alias Harness.Session.Core
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

    provider =
      case Keyword.fetch(opts, :provider) do
        {:ok, provider} -> provider
        :error -> default_provider()
      end

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
      tool_timeout_ms: tool_timeout_ms
    ]

    DynamicSupervisor.start_child(Harness.SessionSup, {Session, child_opts})
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

  defp default_provider do
    case Harness.Config.resolve() do
      {:ok, provider} -> provider
      {:error, reason} -> raise ArgumentError, "no provider configured: #{inspect(reason)}"
    end
  end
end
