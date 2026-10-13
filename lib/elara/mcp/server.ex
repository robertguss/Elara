defmodule Elara.MCP.Server do
  @moduledoc "Serial MCP connection owner; reconnect never replays an interrupted call."
  use GenServer

  alias Elara.MCP.{Config, Protocol, Transport, Trust}

  def start_link(key),
    do: GenServer.start_link(__MODULE__, key, name: {:via, Registry, {Elara.MCPRegistry, key}})

  @impl true
  def init(_key) do
    Process.flag(:trap_exit, true)
    {:ok, %{config: nil, transport: nil, version: nil, server_info: nil, seq: 0}}
  end

  @impl true
  def format_status(_status), do: %{state: :private_mcp_connection}

  @impl true
  def handle_call({operation, config, cwd, deadline}, {caller, _}, state) do
    monitor = Process.monitor(caller)

    state =
      if state.config && state.config.sha256 != config.sha256,
        do: disconnected(state),
        else: state

    {result, state} =
      with :ok <-
             if(System.monotonic_time(:millisecond) < deadline and Process.alive?(caller),
               do: :ok,
               else: {:error, :deadline_before_send}
             ),
           {:ok, current} <- Config.read(cwd, config.name),
           true <- current.path == config.path and current.sha256 == config.sha256,
           :ok <- Trust.check_config(config) do
        case connect(state, config, deadline, monitor) do
          {:ok, ready} -> perform(operation, ready, deadline, monitor)
          {error, failed} -> {error, disconnected(failed)}
        end
      else
        false -> {{:error, :mcp_config_changed}, state}
        error -> {error, state}
      end

    Process.demonitor(monitor, [:flush])

    state =
      case result do
        {:indeterminate, _} -> disconnected(state)
        _ -> state
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info({port, {:exit_status, _}}, %{transport: %{port: port}} = state),
    do: {:noreply, disconnected(state)}

  def handle_info({:EXIT, port, _}, %{transport: %{port: port}} = state),
    do: {:noreply, disconnected(state)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: Transport.close(state.transport)

  defp disconnected(state) do
    Transport.close(state.transport)
    %{state | config: nil, transport: nil, version: nil, server_info: nil}
  end

  defp connect(%{version: version} = state, _config, _deadline, _monitor) when is_binary(version),
    do: {:ok, state}

  defp connect(state, config, deadline, monitor) do
    case Transport.open(config) do
      {:ok, transport} ->
        state = %{state | config: config, transport: transport, version: Protocol.modern()}
        {result, state} = rpc(state, "server/discover", %{}, [], deadline, monitor)

        case result do
          {:ok, %{"supportedVersions" => versions}} when is_list(versions) ->
            if Protocol.modern() in versions,
              do: {:ok, state},
              else: {{:error, :unsupported_protocol}, state}

          {:rpc_error, %{"code" => -32022, "data" => %{"supported" => versions}}}
          when is_list(versions) ->
            if Enum.any?(Protocol.legacy(), &(&1 in versions)) and
                 Protocol.modern() not in versions,
               do: legacy(state, deadline, monitor),
               else: {{:error, :unsupported_protocol}, state}

          {:rpc_error, %{"code" => code}} when code not in [-32020, -32021, -32022] ->
            legacy(state, deadline, monitor)

          {:legacy_http, _} ->
            legacy(state, deadline, monitor)

          {:ok, _} ->
            {{:error, :invalid_discovery}, state}

          other ->
            {sanitize(other), state}
        end

      error ->
        {error, state}
    end
  end

  defp legacy(state, deadline, monitor) do
    state = %{state | version: hd(Protocol.legacy())}

    params = %{
      "protocolVersion" => state.version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "elara", "version" => "0.1.0"}
    }

    {result, state} = rpc(state, "initialize", params, [], deadline, monitor)

    case result do
      {:ok, %{"protocolVersion" => version}} ->
        if version in Protocol.legacy() and
             (state.config.transport == :stdio or version != "2024-11-05") do
          state = %{state | version: version}

          {result, transport} =
            Transport.rpc(
              state.transport,
              %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}},
              version,
              [],
              deadline,
              monitor
            )

          case result do
            :ok -> {:ok, %{state | transport: transport}}
            error -> {sanitize(error), %{state | transport: transport}}
          end
        else
          {{:error, :unsupported_protocol}, state}
        end

      other ->
        {sanitize(other), state}
    end
  end

  defp perform(:diagnostics, state, _deadline, _monitor) do
    {{:ok, diagnostics(state)}, state}
  end

  defp perform(operation, state, deadline, monitor) do
    case list_tools(state, deadline, monitor, nil, [], [], 0) do
      {{:ok, tools}, state} ->
        case operation do
          :discover ->
            {{:ok, %{config: state.config, tools: tools, diagnostics: diagnostics(state)}}, state}

          :catalog ->
            case Trust.check_catalog(state.config, tools) do
              {:ok, marks} ->
                {{:ok, %{tools: tools, read_only: marks, digest: Trust.digest(tools, marks)}},
                 state}

              error ->
                {error, state}
            end

          {:call, name, args} ->
            invoke(state, tools, name, args, deadline, monitor)
        end

      {error, state} ->
        {sanitize(error), state}
    end
  end

  defp list_tools(state, deadline, monitor, cursor, seen, tools, bytes) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}
    {result, state} = rpc(state, "tools/list", params, [], deadline, monitor)

    case result do
      {:ok, %{"tools" => page} = result} when is_list(page) ->
        bytes = bytes + byte_size(JSON.encode!(page))
        next = result["nextCursor"]

        cond do
          bytes > 8_388_608 or length(seen) >= 100 ->
            {{:error, :catalog_too_large}, state}

          next == nil ->
            case Protocol.catalog(tools ++ page) do
              {:ok, catalog} ->
                if state.config.transport == :http and
                     Enum.any?(
                       catalog,
                       &match?({:error, _}, Protocol.tool_headers(&1["inputSchema"], %{}))
                     ) do
                  {{:error, :invalid_catalog_header_annotation}, state}
                else
                  {{:ok, catalog}, state}
                end

              error ->
                {error, state}
            end

          not is_binary(next) or next in seen ->
            {{:error, :invalid_catalog_cursor}, state}

          true ->
            list_tools(state, deadline, monitor, next, [next | seen], tools ++ page, bytes)
        end

      {:ok, _} ->
        {{:error, :invalid_catalog}, state}

      other ->
        {other, state}
    end
  end

  defp invoke(state, tools, name, args, deadline, monitor) do
    with {:ok, marks} <- Trust.check_catalog(state.config, tools),
         %{} = tool <- Enum.find(tools, &(&1["name"] == name)),
         {:ok, headers} <- headers(state, tool, args) do
      {result, state} =
        rpc(
          state,
          "tools/call",
          %{"name" => name, "arguments" => args},
          headers,
          deadline,
          monitor
        )

      case result do
        {:indeterminate, {:response_too_large, bytes, _limit}} ->
          kind = if name in marks, do: :error, else: :indeterminate
          reason = "result too large: at least #{bytes} bytes, limit 16 MiB"
          {{kind, reason}, disconnected(state)}

        _ ->
          {sanitize(result), state}
      end
    else
      nil -> {{:error, :unknown_mcp_tool}, state}
      error -> {error, state}
    end
  end

  defp headers(%{config: %{transport: :http}}, tool, args),
    do: Protocol.tool_headers(tool["inputSchema"], args)

  defp headers(_state, _tool, _args), do: {:ok, []}

  defp rpc(state, method, params, headers, deadline, monitor) do
    seq = state.seq + 1
    message = Protocol.request(state.version, seq, method, params)

    {result, transport} =
      Transport.rpc(state.transport, message, state.version, headers, deadline, monitor)

    info =
      case result do
        {:ok, result} -> Protocol.server_info(result) || state.server_info
        _ -> state.server_info
      end

    {result, %{state | transport: transport, seq: seq, server_info: info}}
  end

  defp diagnostics(state),
    do: %{"protocol_version" => state.version, "server_info" => state.server_info}

  defp sanitize({:rpc_error, %{"code" => code}}), do: {:error, {:mcp_rpc_error, code}}
  defp sanitize({:legacy_http, _}), do: {:error, :bad_http_response}
  defp sanitize(result), do: result
end
