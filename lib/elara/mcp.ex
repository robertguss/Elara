defmodule Elara.MCP do
  @moduledoc "Approved, lazy MCP servers; lost calls return indeterminate and are never replayed."

  alias Elara.MCP.{Config, Server, Trust}

  def discover(cwd, name, opts \\ []), do: request(cwd, name, :discover, opts)
  def diagnostics(cwd, name, opts \\ []), do: request(cwd, name, :diagnostics, opts)
  def catalog(cwd, name, opts \\ []), do: request(cwd, name, :catalog, opts)

  def prepare_call(cwd, server, name, opts \\ []) when is_binary(name),
    do: request(cwd, server, {:prepare_call, name}, opts)

  def call(cwd, server, name, args, opts \\ []) when is_binary(name) and is_map(args),
    do: request(cwd, server, {:call, name, args, Keyword.get(opts, :guard)}, opts)

  defp request(cwd, name, operation, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 30_000)

    if is_integer(timeout) and timeout > 0 and timeout <= 3_600_000 do
      with {:ok, config} <- Config.read(cwd, name),
           :ok <- Trust.check_config(config),
           {:ok, pid} <- server(config) do
        deadline = System.monotonic_time(:millisecond) + timeout
        GenServer.call(pid, {operation, config, cwd, deadline}, timeout + 100)
      end
    else
      {:error, :invalid_mcp_timeout}
    end
  catch
    :exit, {:timeout, _} -> {:indeterminate, :mcp_timeout}
    :exit, _ -> {:indeterminate, :mcp_connection_lost}
  end

  defp server(config) do
    key = {config.path, config.name}

    case Registry.lookup(Elara.MCPRegistry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(Elara.MCPSup, {Server, key}) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          result -> result
        end
    end
  end
end
