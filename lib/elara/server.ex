defmodule Elara.Server do
  @moduledoc "Local TCP gateway for detachable sessions."

  use GenServer

  alias Elara.Protocol

  @default_port 4_048
  @max_packet_bytes Protocol.max_line_bytes()
  @protocol_versions Protocol.versions()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec port(pid()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    provider = Keyword.get(opts, :provider)

    listen_opts = [
      :binary,
      packet: :line,
      packet_size: @max_packet_bytes,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1}
    ]

    case :gen_tcp.listen(port, listen_opts) do
      {:ok, listen} ->
        {:ok, actual_port} = :inet.port(listen)
        acceptor = spawn_link(fn -> accept_loop(listen, provider) end)
        {:ok, %{listen: listen, port: actual_port, acceptor: acceptor}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    :ok
  end

  defp accept_loop(listen, provider) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {:ok, pid} =
          Task.Supervisor.start_child(Elara.TaskSup, fn ->
            receive do
              {:socket, socket} -> connection(socket, provider)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, {:socket, socket})
        accept_loop(listen, provider)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listen, provider)
    end
  end

  defp connection(socket, provider) do
    with {:ok, line} <- recv_line(socket, 30_000),
         {:ok, request} <- Protocol.decode(line) do
      establish_connection(socket, provider, request)
    else
      {:error, reason} -> send_error(socket, reason, Protocol.version())
    end

    :gen_tcp.close(socket)
  end

  defp establish_connection(socket, provider, request) do
    version = response_version(request)

    case request do
      %{"version" => 2, "command" => "list"} ->
        send_json(socket, sessions_message())

      _request ->
        with {:ok, version, session, mode, cursor, incarnation} <-
               prepare_attachment(request, provider),
             {:ok, attachment} <- attach(version, session, mode, cursor, incarnation) do
          send_json(socket, attached_message(version, mode, attachment))

          if version == 1 do
            Enum.each(attachment.replay, fn {seq, event} ->
              send_json(socket, Protocol.event(seq, event))
            end)
          end

          :ok = :inet.setopts(socket, active: :once)
          connection_loop(socket, session, version, Protocol.line_buffer())
        else
          {:error, reason} -> send_error(socket, reason, version)
        end
    end
  end

  defp prepare_attachment(%{"version" => version}, _provider)
       when version not in @protocol_versions,
       do: {:error, :unsupported_version}

  defp prepare_attachment(%{"version" => version, "command" => "create"} = request, provider) do
    mode = decode_mode(Map.get(request, "mode", "control"))
    cwd = Map.get(request, "cwd", File.cwd!())

    with {:ok, mode} <- mode,
         {:ok, provider} <- resolve_provider(provider),
         {:ok, session} <- Elara.start_session(provider: provider, cwd: cwd) do
      {:ok, version, session, mode, 0, nil}
    end
  end

  defp prepare_attachment(
         %{"version" => version, "command" => "attach", "session_id" => session} = request,
         _provider
       )
       when is_binary(session) do
    with {:ok, mode} <- decode_mode(Map.get(request, "mode", "control")),
         {:ok, cursor} <- decode_cursor(Map.get(request, "cursor", 0)) do
      {:ok, version, session, mode, cursor, Map.get(request, "incarnation")}
    end
  end

  defp prepare_attachment(_request, _provider), do: {:error, :invalid_command}

  defp attach(1, session, mode, cursor, incarnation),
    do: Elara.attach(session, mode, cursor, incarnation)

  defp attach(2, session, mode, cursor, incarnation),
    do: Elara.attach_v2(session, mode, cursor, incarnation)

  defp attached_message(1, mode, attachment) do
    %{
      "type" => "attached",
      "version" => 1,
      "session_id" => attachment.id,
      "incarnation" => attachment.incarnation,
      "head" => attachment.head,
      "mode" => Atom.to_string(mode)
    }
  end

  defp attached_message(2, mode, attachment) do
    %{
      "type" => "attached",
      "version" => 2,
      "session_id" => attachment.id,
      "incarnation" => attachment.incarnation,
      "head" => attachment.head,
      "mode" => Atom.to_string(mode),
      "snapshot" => attachment.snapshot
    }
  end

  defp sessions_message do
    sessions =
      Enum.map(Elara.live_sessions(), fn status ->
        %{
          "id" => status.id,
          "incarnation" => status.incarnation,
          "cwd" => status.cwd,
          "state" => phase_name(status.phase),
          "head" => status.event_head
        }
      end)

    %{"type" => "sessions", "version" => 2, "sessions" => sessions}
  end

  defp phase_name(:idle), do: "idle"
  defp phase_name({:calling_provider, _ref, _iteration}), do: "calling_provider"
  defp phase_name({:running_tool, _ref, _call, _remaining, _iteration}), do: "running_tool"

  defp connection_loop(socket, session, version, line_buffer) do
    receive do
      {:tcp, ^socket, chunk} ->
        case Protocol.push_line(line_buffer, chunk) do
          {:ok, line} ->
            response = handle_command(session, version, Protocol.decode(line))
            send_json(socket, response)
            :ok = :inet.setopts(socket, active: :once)
            connection_loop(socket, session, version, Protocol.line_buffer())

          {:more, line_buffer} ->
            :ok = :inet.setopts(socket, active: :once)
            connection_loop(socket, session, version, line_buffer)

          {:error, reason} ->
            send_error(socket, reason, version)
        end

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _reason} ->
        :ok

      {:elara_event, ^session, incarnation, seq, event} ->
        message = Protocol.event(seq, event) |> Map.put("incarnation", incarnation)

        case send_json(socket, message) do
          :ok -> connection_loop(socket, session, version, line_buffer)
          {:error, _} -> :ok
        end

      {:elara_patch, ^session, incarnation, seq, ops} ->
        message = Protocol.patch(seq, ops) |> Map.put("incarnation", incarnation)

        case send_json(socket, message) do
          :ok -> connection_loop(socket, session, version, line_buffer)
          {:error, _} -> :ok
        end
    end
  end

  defp handle_command(session, version, {:ok, %{"version" => version} = request}),
    do: handle_versioned_command(session, version, request)

  defp handle_command(_session, version, {:ok, _request}),
    do: error_message(:unsupported_version, version)

  defp handle_command(_session, version, {:error, reason}), do: error_message(reason, version)

  defp handle_versioned_command(session, version, %{"command" => "ask", "prompt" => prompt})
       when is_binary(prompt) do
    command_result(Elara.attached_command(session, {:ask, prompt}), version)
  end

  defp handle_versioned_command(session, version, %{"command" => "interrupt"}) do
    command_result(Elara.attached_command(session, :interrupt), version)
  end

  defp handle_versioned_command(session, version, %{"command" => "inspect"}) do
    case Elara.status(session) do
      %{} = status ->
        %{"type" => "status", "version" => version, "status" => json_status(status)}

      {:error, reason} ->
        error_message(reason, version)
    end
  end

  defp handle_versioned_command(session, 2, %{"command" => "resnapshot"}) do
    case Elara.snapshot(session) do
      %{} = snapshot -> snapshot_message(snapshot)
      {:error, reason} -> error_message(reason, 2)
    end
  end

  defp handle_versioned_command(_session, version, _request),
    do: error_message(:invalid_command, version)

  defp command_result(:ok, version), do: %{"type" => "ok", "version" => version}
  defp command_result({:error, reason}, version), do: error_message(reason, version)

  defp snapshot_message(snapshot) do
    %{
      "type" => "snapshot",
      "version" => 2,
      "session_id" => snapshot.id,
      "incarnation" => snapshot.incarnation,
      "head" => snapshot.head,
      "snapshot" => snapshot.snapshot
    }
  end

  defp decode_mode("control"), do: {:ok, :control}
  defp decode_mode("observe"), do: {:ok, :observe}
  defp decode_mode(_mode), do: {:error, :invalid_mode}

  defp decode_cursor(cursor) when is_integer(cursor) and cursor >= 0, do: {:ok, cursor}
  defp decode_cursor(_cursor), do: {:error, :invalid_cursor}

  defp resolve_provider(nil), do: Elara.Config.resolve()
  defp resolve_provider(provider), do: {:ok, provider}

  defp response_version(%{"version" => version}) when version in @protocol_versions, do: version
  defp response_version(_request), do: Protocol.version()

  defp send_error(socket, reason, version), do: send_json(socket, error_message(reason, version))

  defp error_message(reason, version) do
    %{"type" => "error", "version" => version, "error" => format_reason(reason)}
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp send_json(socket, message), do: :gen_tcp.send(socket, Protocol.encode(message))

  defp recv_line(socket, timeout, line_buffer \\ {[], 0}) do
    with {:ok, chunk} <- :gen_tcp.recv(socket, 0, timeout) do
      case Protocol.push_line(line_buffer, chunk) do
        {:ok, line} -> {:ok, line}
        {:more, line_buffer} -> recv_line(socket, timeout, line_buffer)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp json_status(status) do
    %{
      "id" => status.id,
      "incarnation" => status.incarnation,
      "phase" => inspect(status.phase),
      "current_effect" => inspect(status.current_effect),
      "mailbox_length" => status.mailbox_length,
      "task_count" => status.task_count,
      "subscriber_count" => status.subscriber_count,
      "event_head" => status.event_head,
      "event_retained" => status.event_retained,
      "recording_path" => status.recording_path,
      "recorded_transitions" => status.recorded_transitions,
      "worker_health" =>
        Enum.map(status.worker_health, fn worker ->
          %{
            "id" => worker.id,
            "healthy" => worker.healthy?,
            "load" => worker.load,
            "placement" => Atom.to_string(worker.placement)
          }
        end)
    }
  end
end
