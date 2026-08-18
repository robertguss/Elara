defmodule Harness.Worker.Server do
  @moduledoc "Authenticated capability-limited worker for built-in tools."

  use GenServer

  alias Harness.Executor.Request
  alias Harness.Tool.Ctx

  @protocol_version 1

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec port(pid()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @spec capabilities(pid()) :: [String.t()]
  def capabilities(server), do: GenServer.call(server, :capabilities)

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 0)
    token = Keyword.fetch!(opts, :token)
    capabilities = Keyword.fetch!(opts, :capabilities) |> MapSet.new()
    workspaces = Keyword.fetch!(opts, :workspaces)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    listen_opts = [:binary, packet: :line, active: false, reuseaddr: true, ip: ip]

    case :gen_tcp.listen(port, listen_opts) do
      {:ok, listen} ->
        {:ok, actual_port} = :inet.port(listen)
        config = %{token: token, capabilities: capabilities, workspaces: workspaces}
        acceptor = spawn_link(fn -> accept_loop(listen, config) end)

        {:ok,
         %{
           listen: listen,
           port: actual_port,
           acceptor: acceptor,
           capabilities: capabilities
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:capabilities, _from, state),
    do: {:reply, MapSet.to_list(state.capabilities), state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    :ok
  end

  defp accept_loop(listen, config) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid =
          spawn_link(fn ->
            receive do
              {:socket, socket} -> handle_connection(socket, config)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, {:socket, socket})
        accept_loop(listen, config)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listen, config)
    end
  end

  defp handle_connection(socket, config) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, line} ->
        case decode_request(line, config) do
          {:ok, request, cwd} -> run_request(socket, request, cwd)
          {:error, reason} -> :gen_tcp.send(socket, encode_error(reason))
        end

      {:error, _reason} ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp run_request(socket, request, cwd) do
    parent = self()
    job = spawn_link(fn -> send(parent, {:job_result, self(), invoke(request, cwd)}) end)
    :ok = :inet.setopts(socket, active: :once)

    receive do
      {:job_result, ^job, outcome} ->
        :gen_tcp.send(socket, encode_result(outcome))

      {:tcp_closed, ^socket} ->
        Process.exit(job, :kill)

      {:tcp_error, ^socket, _reason} ->
        Process.exit(job, :kill)
    after
      max(request.deadline_ms - System.system_time(:millisecond), 0) ->
        Process.exit(job, :kill)
        :gen_tcp.send(socket, encode_error(:deadline_exceeded))
    end
  end

  defp decode_request(line, config) do
    with {:ok, %{"version" => @protocol_version, "token" => token, "request" => encoded}} <-
           JSON.decode(line),
         true <- secure_equal?(token, config.token),
         {:ok, request} <- Request.from_map(encoded),
         :ok <- validate_deadline(request),
         :ok <- validate_capabilities(request, config.capabilities),
         {:ok, cwd} <- Map.fetch(config.workspaces, request.workspace_id),
         :ok <- validate_tool(request) do
      {:ok, request, cwd}
    else
      false -> {:error, :unauthorized}
      :error -> {:error, :unknown_workspace}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_deadline(request) do
    if request.deadline_ms > System.system_time(:millisecond),
      do: :ok,
      else: {:error, :deadline_exceeded}
  end

  defp validate_capabilities(request, available) do
    if Enum.all?(request.required_capabilities, &MapSet.member?(available, &1)),
      do: :ok,
      else: {:error, :capability_denied}
  end

  defp validate_tool(%Request{tool_name: name, tool_version: "1"})
       when name in ["read", "write", "edit", "bash"],
       do: :ok

  defp validate_tool(_request), do: {:error, :unknown_tool_version}

  defp invoke(request, cwd) do
    tool = Map.fetch!(Harness.Tool.table(Harness.Tool.builtins()), request.tool_name)
    {module, function} = tool.run
    apply(module, function, [request.arguments, %Ctx{cwd: cwd, tool_name: request.tool_name}])
  rescue
    error -> {:error, "worker tool crashed: #{Exception.message(error)}"}
  catch
    kind, reason -> {:error, "worker tool crashed: #{Exception.format_banner(kind, reason)}"}
  end

  defp encode_result({kind, text}) when kind in [:ok, :error] do
    [JSON.encode!(%{"type" => "result", "outcome" => %{Atom.to_string(kind) => text}}), "\n"]
  end

  defp encode_error(reason) do
    [JSON.encode!(%{"type" => "error", "error" => format_reason(reason)}), "\n"]
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_equal?(_left, _right), do: false
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
