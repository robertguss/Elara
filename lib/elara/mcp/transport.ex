defmodule Elara.MCP.Transport do
  @moduledoc false

  alias Elara.MCP.Protocol
  @max_wire 8_388_608
  @max_result 16_777_216

  def open(%{transport: :http} = config),
    do: {:ok, %{config: config, port: nil, session: nil, buffer: ""}}

  def open(%{transport: :stdio} = config) do
    with {:ok, environment} <- environment(config.env) do
      unset =
        for key <- Map.keys(System.get_env()),
            not Map.has_key?(environment, key),
            do: {String.to_charlist(key), false}

      set =
        for {key, value} <- environment, do: {String.to_charlist(key), String.to_charlist(value)}

      port =
        Port.open({:spawn_executable, config.command}, [
          :binary,
          :use_stdio,
          :exit_status,
          args: config.args,
          cd: config.cwd,
          env: unset ++ set
        ])

      {:ok, %{config: config, port: port, session: nil, buffer: ""}}
    end
  rescue
    _ -> {:error, :stdio_start_failed}
  end

  def close(%{port: port}) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def close(_), do: :ok

  def rpc(transport, message, version, headers, deadline, caller_monitor) do
    bytes = JSON.encode!(message)
    limit = if message["method"] == "tools/call", do: @max_result, else: @max_wire
    transport = Map.put(transport, :response_limit, limit)

    cond do
      remaining(deadline) == 0 ->
        {{:error, :deadline_before_send}, transport}

      byte_size(bytes) > @max_wire ->
        {{:error, :request_too_large}, transport}

      true ->
        receive do
          {:DOWN, ^caller_monitor, :process, _, _} ->
            {{:error, :caller_stopped_before_send}, transport}
        after
          0 ->
            case transport.config.transport do
              :stdio -> stdio(transport, message["id"], bytes, deadline, caller_monitor)
              :http -> http(transport, message, version, headers, deadline, caller_monitor)
            end
        end
    end
  end

  defp environment(references) do
    defaults =
      Map.take(System.get_env(), ~w(PATH HOME USER LOGNAME LANG LC_ALL LC_CTYPE TMPDIR TMP TEMP))

    Enum.reduce_while(references, {:ok, defaults}, fn {name, source}, {:ok, env} ->
      case System.get_env(source) do
        nil -> {:halt, {:error, :missing_server_environment}}
        value -> {:cont, {:ok, Map.put(env, name, value)}}
      end
    end)
  end

  defp stdio(%{port: port} = transport, id, bytes, deadline, monitor) do
    if Port.command(port, bytes <> "\n") do
      if id == nil,
        do: {:ok, transport},
        else: read_stdio(transport, id, deadline, monitor, byte_size(transport.buffer))
    else
      {{:indeterminate, :connection_lost}, transport}
    end
  rescue
    ArgumentError -> {{:indeterminate, :connection_lost}, transport}
  end

  defp read_stdio(transport, id, deadline, monitor, total) do
    case :binary.split(transport.buffer, "\n") do
      [line, rest] ->
        next = %{transport | buffer: rest}

        case decode(line, id) do
          :notification -> read_stdio(next, id, deadline, monitor, total)
          answer -> {answer, next}
        end

      [_] ->
        port = transport.port

        receive do
          {^port, {:data, chunk}} ->
            if total + byte_size(chunk) <= transport.response_limit do
              read_stdio(
                %{transport | buffer: transport.buffer <> chunk},
                id,
                deadline,
                monitor,
                total + byte_size(chunk)
              )
            else
              {{:indeterminate,
                {:response_too_large, total + byte_size(chunk), transport.response_limit}},
               transport}
            end

          {^port, {:exit_status, _}} ->
            {{:indeterminate, :connection_lost}, transport}

          {:EXIT, ^port, _} ->
            {{:indeterminate, :connection_lost}, transport}

          {:DOWN, ^monitor, :process, _, _} ->
            {{:indeterminate, :caller_stopped}, transport}
        after
          remaining(deadline) -> {{:indeterminate, :timeout}, transport}
        end
    end
  end

  defp http(transport, message, version, extra, deadline, monitor) do
    task =
      Task.Supervisor.async(Elara.TaskSup, fn ->
        request_http(transport, message, version, extra, deadline)
      end)

    ref = task.ref

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, _, _} ->
        {{:indeterminate, :connection_lost}, transport}

      {:DOWN, ^monitor, :process, _, _} ->
        Task.shutdown(task, :brutal_kill)
        {{:indeterminate, :caller_stopped}, transport}
    after
      remaining(deadline) ->
        Task.shutdown(task, :brutal_kill)
        {{:indeterminate, :timeout}, transport}
    end
  end

  defp request_http(transport, message, version, extra, deadline) do
    with {:ok, auth} <- authorization(transport.config.token_env) do
      headers =
        [
          {"accept", "application/json, text/event-stream"},
          {"mcp-protocol-version", version},
          {"mcp-method", message["method"]}
        ] ++ extra ++ auth

      headers =
        if message["params"]["name"],
          do: [{"mcp-name", Protocol.header_value(message["params"]["name"])} | headers],
          else: headers

      headers =
        if transport.session, do: [{"mcp-session-id", transport.session} | headers], else: headers

      key = {__MODULE__, make_ref()}
      Process.put(key, %{total: 0, buffer: "", data: [], answer: nil, exceeded: false})

      into = fn {:data, chunk}, {request, response} ->
        state = Process.get(key)

        next =
          if state.total + byte_size(chunk) > transport.response_limit do
            %{state | total: state.total + byte_size(chunk), exceeded: true}
          else
            state = %{
              state
              | total: state.total + byte_size(chunk),
                buffer: state.buffer <> chunk
            }

            if sse?(response), do: consume_sse(state, message["id"]), else: state
          end

        Process.put(key, next)

        if next.exceeded or next.answer,
          do: {:halt, {request, response}},
          else: {:cont, {request, response}}
      end

      try do
        response =
          Req.post(transport.config.url,
            headers: headers,
            json: message,
            decode_body: false,
            retry: false,
            redirect: false,
            into: into,
            receive_timeout: max(remaining(deadline), 1),
            connect_options: [timeout: max(remaining(deadline), 1)]
          )

        state = Process.get(key)
        finish_http(response, state, transport, message["id"], version)
      after
        Process.delete(key)
      end
    else
      error -> {error, transport}
    end
  rescue
    _ -> {{:indeterminate, :connection_lost}, transport}
  end

  defp finish_http({:ok, response}, state, transport, id, version) do
    state =
      if sse?(response) and String.ends_with?(state.buffer, "\r"),
        do: consume_sse(%{state | buffer: state.buffer <> "\n"}, id),
        else: state

    session =
      if version == Protocol.modern(),
        do: nil,
        else: List.first(Req.Response.get_header(response, "mcp-session-id")) || transport.session

    next = %{transport | session: session}

    cond do
      state.exceeded ->
        {{:indeterminate, {:response_too_large, state.total, transport.response_limit}}, next}

      id == nil and response.status == 202 ->
        {:ok, next}

      response.status != 200 ->
        case state.answer || decode(state.buffer, id) do
          {:rpc_error, _} = error -> {error, next}
          _ when response.status == 400 -> {{:legacy_http, :bad_request}, next}
          _ -> {{:indeterminate, :bad_http_status}, next}
        end

      state.answer != nil ->
        {state.answer, next}

      sse?(response) ->
        {{:indeterminate, :incomplete_response}, next}

      true ->
        case decode(state.buffer, id) do
          :notification -> {{:indeterminate, :invalid_response}, next}
          answer -> {answer, next}
        end
    end
  end

  defp finish_http(_, _state, transport, _id, _version),
    do: {{:indeterminate, :connection_lost}, transport}

  defp authorization(nil), do: {:ok, []}

  defp authorization(name) do
    case System.get_env(name) do
      nil -> {:error, :missing_server_environment}
      value -> {:ok, [{"authorization", "Bearer " <> value}]}
    end
  end

  defp sse?(response),
    do:
      Enum.any?(
        Req.Response.get_header(response, "content-type"),
        &String.starts_with?(String.downcase(&1), "text/event-stream")
      )

  defp decode(bytes, id) do
    case JSON.decode(bytes) do
      {:ok, message} -> Protocol.response(message, id)
      _ -> {:indeterminate, :invalid_response}
    end
  end

  defp consume_sse(state, id) do
    case Regex.run(~r/\r\n|\n|\r/, state.buffer, return: :index) do
      [{offset, length}] ->
        if offset + length == byte_size(state.buffer) and
             binary_part(state.buffer, offset, length) == "\r" do
          state
        else
          line = binary_part(state.buffer, 0, offset)

          rest =
            binary_part(state.buffer, offset + length, byte_size(state.buffer) - offset - length)

          next = sse_line(%{state | buffer: rest}, line, id)
          if next.answer, do: next, else: consume_sse(next, id)
        end

      nil ->
        state
    end
  end

  defp sse_line(%{data: []} = state, "", _id), do: state

  defp sse_line(state, "", id) do
    answer = decode(Enum.reverse(state.data) |> Enum.join("\n"), id)
    %{state | data: [], answer: if(answer == :notification, do: nil, else: answer)}
  end

  defp sse_line(state, "data:" <> data, _id),
    do: %{state | data: [String.replace_prefix(data, " ", "") | state.data]}

  defp sse_line(state, _line, _id), do: state

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
