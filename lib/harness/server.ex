defmodule Harness.Server do
  @moduledoc "Local TCP gateway for detachable sessions."

  use GenServer

  alias Harness.Protocol

  @default_port 4_048
  @protocol_version Protocol.version()

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

    listen_opts = [:binary, packet: :line, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]

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
          Task.Supervisor.start_child(Harness.TaskSup, fn ->
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
    with {:ok, line} <- :gen_tcp.recv(socket, 0, 30_000),
         {:ok, request} <- Protocol.decode(line),
         {:ok, session, mode, cursor, incarnation} <- prepare_attachment(request, provider),
         {:ok, attachment} <- Harness.attach(session, mode, cursor, incarnation) do
      send_json(socket, %{
        "type" => "attached",
        "version" => Protocol.version(),
        "session_id" => attachment.id,
        "incarnation" => attachment.incarnation,
        "head" => attachment.head,
        "mode" => Atom.to_string(mode)
      })

      Enum.each(attachment.replay, fn {seq, event} ->
        send_json(socket, Protocol.event(seq, event))
      end)

      :ok = :inet.setopts(socket, active: :once)
      connection_loop(socket, session)
    else
      {:error, reason} -> send_error(socket, reason)
    end

    :gen_tcp.close(socket)
  end

  defp prepare_attachment(%{"version" => version}, _provider)
       when version != @protocol_version,
       do: {:error, :unsupported_version}

  defp prepare_attachment(%{"version" => _, "command" => "create"} = request, provider) do
    mode = decode_mode(Map.get(request, "mode", "control"))
    cwd = Map.get(request, "cwd", File.cwd!())

    with {:ok, mode} <- mode,
         {:ok, provider} <- resolve_provider(provider),
         {:ok, session} <- Harness.start_session(provider: provider, cwd: cwd) do
      {:ok, session, mode, 0, nil}
    end
  end

  defp prepare_attachment(
         %{"version" => _, "command" => "attach", "session_id" => session} = request,
         _provider
       )
       when is_binary(session) do
    with {:ok, mode} <- decode_mode(Map.get(request, "mode", "control")),
         {:ok, cursor} <- decode_cursor(Map.get(request, "cursor", 0)) do
      {:ok, session, mode, cursor, Map.get(request, "incarnation")}
    end
  end

  defp prepare_attachment(_request, _provider), do: {:error, :invalid_command}

  defp connection_loop(socket, session) do
    receive do
      {:tcp, ^socket, line} ->
        response = handle_command(session, Protocol.decode(line))
        send_json(socket, response)
        :ok = :inet.setopts(socket, active: :once)
        connection_loop(socket, session)

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _reason} ->
        :ok

      {:harness_event, ^session, incarnation, seq, event} ->
        message = Protocol.event(seq, event) |> Map.put("incarnation", incarnation)

        case send_json(socket, message) do
          :ok -> connection_loop(socket, session)
          {:error, _} -> :ok
        end
    end
  end

  defp handle_command(_session, {:ok, %{"version" => version}})
       when version != @protocol_version,
       do: error_message(:unsupported_version)

  defp handle_command(session, {:ok, %{"command" => "ask", "prompt" => prompt}})
       when is_binary(prompt) do
    command_result(Harness.attached_command(session, {:ask, prompt}))
  end

  defp handle_command(session, {:ok, %{"command" => "interrupt"}}) do
    command_result(Harness.attached_command(session, :interrupt))
  end

  defp handle_command(session, {:ok, %{"command" => "inspect"}}) do
    case Harness.status(session) do
      %{} = status ->
        %{"type" => "status", "version" => Protocol.version(), "status" => json_status(status)}

      {:error, reason} ->
        error_message(reason)
    end
  end

  defp handle_command(_session, {:ok, _request}), do: error_message(:invalid_command)
  defp handle_command(_session, {:error, reason}), do: error_message(reason)

  defp command_result(:ok), do: %{"type" => "ok", "version" => Protocol.version()}
  defp command_result({:error, reason}), do: error_message(reason)

  defp decode_mode("control"), do: {:ok, :control}
  defp decode_mode("observe"), do: {:ok, :observe}
  defp decode_mode(_mode), do: {:error, :invalid_mode}

  defp decode_cursor(cursor) when is_integer(cursor) and cursor >= 0, do: {:ok, cursor}
  defp decode_cursor(_cursor), do: {:error, :invalid_cursor}

  defp resolve_provider(nil), do: Harness.Config.resolve()
  defp resolve_provider(provider), do: {:ok, provider}

  defp send_error(socket, reason), do: send_json(socket, error_message(reason))

  defp error_message(reason) do
    %{"type" => "error", "version" => Protocol.version(), "error" => format_reason(reason)}
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp send_json(socket, message), do: :gen_tcp.send(socket, Protocol.encode(message))

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
      "event_retained" => status.event_retained
    }
  end
end
