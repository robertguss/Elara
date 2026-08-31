defmodule Elara.Attach do
  @moduledoc false

  alias Elara.Protocol

  @default_port 4_048

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [observe: :boolean, port: :integer],
        aliases: [o: :observe]
      )

    case {args, invalid} do
      {[target], []} -> run(target, opts)
      _ -> fail("usage: mix elara.attach SESSION|new [--observe] [--port PORT]")
    end
  end

  defp run(target, opts) do
    port = Keyword.get(opts, :port, env_port())
    mode = if Keyword.get(opts, :observe, false), do: "observe", else: "control"

    with {:ok, socket} <-
           :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false]),
         :ok <- :gen_tcp.send(socket, Protocol.encode(attach_request(target, mode))),
         {:ok, line} <- :gen_tcp.recv(socket, 0, 30_000),
         {:ok, response} <- Protocol.decode(line),
         {:ok, state} <- attached_state(response, socket, mode) do
      parent = self()
      if mode == "control", do: spawn_link(fn -> read_stdin(parent) end)
      :ok = :inet.setopts(socket, active: :once)
      loop(state)
    else
      {:error, reason} -> fail("attach failed: #{format_reason(reason)}")
    end
  end

  defp attach_request("new", mode) do
    %{
      "version" => Protocol.version(),
      "command" => "create",
      "mode" => mode,
      "cwd" => File.cwd!()
    }
  end

  defp attach_request(session, mode) do
    cursor = read_cursor(session)

    %{
      "version" => Protocol.version(),
      "command" => "attach",
      "session_id" => session,
      "mode" => mode,
      "cursor" => cursor.cursor,
      "incarnation" => cursor.incarnation
    }
  end

  defp attached_state(
         %{
           "type" => "attached",
           "session_id" => session,
           "incarnation" => incarnation,
           "head" => head
         },
         socket,
         mode
       ) do
    IO.puts("attached #{session} (#{mode}); replay head #{head}")
    {:ok, %{socket: socket, session: session, incarnation: incarnation, cursor: 0, mode: mode}}
  end

  defp attached_state(%{"type" => "error", "error" => error}, _socket, _mode),
    do: {:error, error}

  defp attached_state(_response, _socket, _mode), do: {:error, :invalid_response}

  defp loop(state) do
    receive do
      {:tcp, socket, line} when socket == state.socket ->
        state = handle_server_message(Protocol.decode(line), state)
        :ok = :inet.setopts(socket, active: :once)
        loop(state)

      {:tcp_closed, socket} when socket == state.socket ->
        exit({:shutdown, 0})

      {:tcp_error, socket, reason} when socket == state.socket ->
        fail("connection failed: #{format_reason(reason)}")

      {:stdin, :eof} ->
        :gen_tcp.close(state.socket)
        exit({:shutdown, 0})

      {:stdin, line} ->
        case send_command(state, String.trim(line)) do
          :quit ->
            :gen_tcp.close(state.socket)
            exit({:shutdown, 0})

          :ok ->
            loop(state)
        end
    end
  end

  defp handle_server_message(
         {:ok, %{"type" => "event", "seq" => seq, "event" => encoded}},
         state
       ) do
    case Protocol.decode_event(encoded) do
      {:ok, event} ->
        IO.write(Elara.CLI.render(event))
        write_cursor(state.session, state.incarnation, seq)
        %{state | cursor: seq}

      {:error, reason} ->
        IO.puts(:stderr, "invalid event: #{format_reason(reason)}")
        state
    end
  end

  defp handle_server_message({:ok, %{"type" => "error", "error" => error}}, state) do
    IO.puts(:stderr, "server error: #{error}")
    state
  end

  defp handle_server_message({:ok, %{"type" => "status", "status" => status}}, state) do
    IO.puts(JSON.encode!(status))
    state
  end

  defp handle_server_message({:ok, %{"type" => "ok"}}, state), do: state

  defp handle_server_message({:error, reason}, state) do
    IO.puts(:stderr, "invalid server message: #{format_reason(reason)}")
    state
  end

  defp handle_server_message(_message, state), do: state

  defp send_command(_state, "/quit"), do: :quit
  defp send_command(_state, "/exit"), do: :quit

  defp send_command(state, "/interrupt") do
    send_json(state.socket, %{"version" => Protocol.version(), "command" => "interrupt"})
  end

  defp send_command(state, "/inspect") do
    send_json(state.socket, %{"version" => Protocol.version(), "command" => "inspect"})
  end

  defp send_command(state, prompt) when prompt != "" do
    send_json(state.socket, %{
      "version" => Protocol.version(),
      "command" => "ask",
      "prompt" => prompt
    })
  end

  defp send_command(_state, ""), do: :ok

  defp send_json(socket, message) do
    case :gen_tcp.send(socket, Protocol.encode(message)) do
      :ok -> :ok
      {:error, reason} -> fail("send failed: #{format_reason(reason)}")
    end
  end

  defp read_stdin(parent) do
    case IO.gets("> ") do
      :eof ->
        send(parent, {:stdin, :eof})

      {:error, _} ->
        send(parent, {:stdin, :eof})

      line ->
        send(parent, {:stdin, line})
        read_stdin(parent)
    end
  end

  defp read_cursor(session) do
    with {:ok, raw} <- File.read(cursor_path(session)),
         {:ok, %{"cursor" => cursor, "incarnation" => incarnation}} <- JSON.decode(raw),
         true <- is_integer(cursor) and cursor >= 0 and is_binary(incarnation) do
      %{cursor: cursor, incarnation: incarnation}
    else
      _ -> %{cursor: 0, incarnation: nil}
    end
  end

  defp write_cursor(session, incarnation, cursor) do
    path = cursor_path(session)
    :ok = File.mkdir_p(Path.dirname(path))
    File.write(path, JSON.encode!(%{"cursor" => cursor, "incarnation" => incarnation}))
  end

  defp cursor_path(session) do
    Path.join([System.user_home!(), ".elara", "attach", "#{session}.json"])
  end

  defp env_port do
    case Integer.parse(System.get_env("ELARA_SERVER_PORT", Integer.to_string(@default_port))) do
      {port, ""} when port in 1..65_535 -> port
      _ -> @default_port
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp fail(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end
end
