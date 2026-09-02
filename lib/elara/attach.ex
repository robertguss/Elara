defmodule Elara.Attach do
  @moduledoc false

  alias Elara.Protocol

  @default_port 4_048
  @max_packet_bytes Protocol.max_line_bytes()

  defmodule Projector do
    @moduledoc false

    alias Elara.Protocol

    @enforce_keys [:view, :incarnation, :head]
    defstruct [:view, :incarnation, :head, awaiting_snapshot?: false]

    @type t :: %__MODULE__{
            view: map(),
            incarnation: String.t(),
            head: non_neg_integer(),
            awaiting_snapshot?: boolean()
          }

    @spec new(map(), String.t(), non_neg_integer()) :: t()
    def new(view, incarnation, head)
        when is_map(view) and is_binary(incarnation) and is_integer(head) and head >= 0 do
      %__MODULE__{view: view, incarnation: incarnation, head: head}
    end

    @spec install_snapshot(t(), map(), String.t(), non_neg_integer()) :: t()
    def install_snapshot(projector, view, incarnation, head)
        when is_map(view) and is_binary(incarnation) and is_integer(head) and head >= 0 do
      %{projector | view: view, incarnation: incarnation, head: head, awaiting_snapshot?: false}
    end

    @spec ingest_patch(t(), String.t(), non_neg_integer(), [map()]) ::
            {:applied | :ignored | :resnapshot, t()}
    def ingest_patch(%__MODULE__{awaiting_snapshot?: true} = projector, _incarnation, _seq, _ops),
      do: {:ignored, projector}

    def ingest_patch(%__MODULE__{} = projector, incarnation, seq, ops)
        when is_binary(incarnation) and is_integer(seq) and seq >= 0 and is_list(ops) do
      cond do
        incarnation != projector.incarnation ->
          request_resnapshot(projector)

        seq <= projector.head ->
          {:ignored, projector}

        seq != projector.head + 1 ->
          request_resnapshot(projector)

        true ->
          case Protocol.apply_patch(projector.view, ops) do
            {:ok, view} -> {:applied, %{projector | view: view, head: seq}}
            {:error, :invalid_patch} -> request_resnapshot(projector)
          end
      end
    end

    def ingest_patch(%__MODULE__{} = projector, _incarnation, _seq, _ops),
      do: request_resnapshot(projector)

    defp request_resnapshot(projector),
      do: {:resnapshot, %{projector | awaiting_snapshot?: true}}
  end

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
           :gen_tcp.connect(
             {127, 0, 0, 1},
             port,
             [:binary, packet: :line, packet_size: @max_packet_bytes, active: false]
           ),
         :ok <- :gen_tcp.send(socket, Protocol.encode(attach_request(target, mode))),
         {:ok, line} <- recv_line(socket, 30_000),
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
           "version" => 2,
           "session_id" => session,
           "incarnation" => incarnation,
           "head" => head,
           "snapshot" => snapshot
         },
         socket,
         mode
       ) do
    with :ok <- render_snapshot(snapshot),
         :ok <- write_cursor(session, incarnation, head) do
      IO.puts("attached #{session} (#{mode}); snapshot head #{head}")

      {:ok,
       %{
         socket: socket,
         session: session,
         mode: mode,
         version: 2,
         line_buffer: Protocol.line_buffer(),
         projector: Projector.new(snapshot, incarnation, head)
       }}
    end
  end

  defp attached_state(%{"type" => "error", "error" => error}, _socket, _mode),
    do: {:error, error}

  defp attached_state(_response, _socket, _mode), do: {:error, :invalid_response}

  defp loop(state) do
    receive do
      {:tcp, socket, chunk} when socket == state.socket ->
        case Protocol.push_line(state.line_buffer, chunk) do
          {:ok, line} ->
            state =
              state
              |> Map.put(:line_buffer, Protocol.line_buffer())
              |> then(&handle_server_message(Protocol.decode(line), &1))

            :ok = :inet.setopts(socket, active: :once)
            loop(state)

          {:more, line_buffer} ->
            :ok = :inet.setopts(socket, active: :once)
            loop(%{state | line_buffer: line_buffer})

          {:error, reason} ->
            fail("invalid server message: #{format_reason(reason)}")
        end

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
         {:ok,
          %{
            "type" => "patch",
            "version" => 2,
            "incarnation" => incarnation,
            "seq" => seq,
            "ops" => ops
          }},
         state
       ) do
    case Projector.ingest_patch(state.projector, incarnation, seq, ops) do
      {:applied, projector} ->
        render_patch(ops)
        write_cursor(state.session, projector.incarnation, projector.head)
        %{state | projector: projector}

      {:ignored, projector} ->
        %{state | projector: projector}

      {:resnapshot, projector} ->
        send_json(state.socket, %{"version" => state.version, "command" => "resnapshot"})
        %{state | projector: projector}
    end
  end

  defp handle_server_message(
         {:ok,
          %{
            "type" => "snapshot",
            "version" => 2,
            "incarnation" => incarnation,
            "head" => head,
            "snapshot" => snapshot
          }},
         state
       ) do
    case render_snapshot(snapshot) do
      :ok ->
        projector =
          Projector.install_snapshot(state.projector, snapshot, incarnation, head)

        write_cursor(state.session, incarnation, head)
        IO.puts("resynchronized at head #{head}")
        %{state | projector: projector}

      {:error, reason} ->
        IO.puts(:stderr, "invalid snapshot: #{format_reason(reason)}")
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
    send_json(state.socket, %{"version" => state.version, "command" => "interrupt"})
  end

  defp send_command(state, "/inspect") do
    send_json(state.socket, %{"version" => state.version, "command" => "inspect"})
  end

  defp send_command(state, prompt) when prompt != "" do
    send_json(state.socket, %{
      "version" => state.version,
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

  defp recv_line(socket, timeout, line_buffer \\ {[], 0}) do
    with {:ok, chunk} <- :gen_tcp.recv(socket, 0, timeout) do
      case Protocol.push_line(line_buffer, chunk) do
        {:ok, line} -> {:ok, line}
        {:more, line_buffer} -> recv_line(socket, timeout, line_buffer)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp render_snapshot(snapshot) do
    case Protocol.snapshot_events(snapshot) do
      {:ok, events} ->
        Enum.each(events, &IO.write(Elara.CLI.render(&1)))
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp render_patch(ops) do
    case Protocol.patch_events(ops) do
      {:ok, events} -> Enum.each(events, &IO.write(Elara.CLI.render(&1)))
      {:error, reason} -> IO.puts(:stderr, "invalid patch: #{format_reason(reason)}")
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
