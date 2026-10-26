defmodule Elara.ProviderLegacyStreamTest do
  use ExUnit.Case, async: false

  defmodule PausedCodexStream do
    @loopback_timeout 10_000

    def stream(owner, request, sink) do
      item = %{
        "id" => "m",
        "type" => "message",
        "role" => "assistant",
        "phase" => "final_answer",
        "content" => [%{"type" => "output_text", "text" => "legacy answer"}]
      }

      events = [
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => item},
        %{
          "type" => "response.output_text.delta",
          "output_index" => 0,
          "delta" => "legacy answer"
        },
        %{"type" => "response.completed", "response" => %{"output" => [item]}}
      ]

      frames = Enum.map(events, &("data: " <> JSON.encode!(&1) <> "\n\n"))
      server = start_loopback_server(fn socket -> send_chunked_response(socket, frames) end)

      config =
        Elara.Provider.OpenAICodex.new(
          %Elara.Auth.OpenAICodex{
            access_token: "access",
            refresh_token: "refresh",
            expires_at: System.system_time(:second) + 3_600,
            account_id: "account"
          },
          base_url: "http://127.0.0.1:#{server.port}"
        )

      result =
        Elara.Provider.OpenAICodex.stream(config, request, fn delta ->
          :ok = sink.(delta)

          if is_binary(delta) do
            send(owner, {:legacy_binary_pending, self()})

            receive do
              :finish -> :ok
            after
              5000 -> raise "completion gate timed out"
            end
          end

          :ok
        end)

      _ = await_server(server.task)

      case result do
        {:ok, assistant, _config} -> {:ok, assistant, owner}
        {:error, error, _config} -> {:error, error, owner}
      end
    end

    defp start_loopback_server(send_response) do
      {:ok, listener} =
        :gen_tcp.listen(0, [
          :binary,
          packet: :raw,
          active: false,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ])

      {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

      task =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, @loopback_timeout)

          try do
            request_body = receive_request_body(socket)
            :ok = send_response.(socket)
            request_body
          after
            :gen_tcp.close(socket)
            :gen_tcp.close(listener)
          end
        end)

      %{port: port, task: task}
    end

    defp receive_request_body(socket) do
      {header, buffered_body} = receive_headers(socket, "")

      content_length =
        header
        |> String.split("\r\n", trim: true)
        |> Enum.find_value(0, fn line ->
          case String.split(line, ":", parts: 2) do
            [name, value] ->
              if String.downcase(name) == "content-length",
                do: value |> String.trim() |> String.to_integer()

            _other ->
              nil
          end
        end)

      receive_body(socket, buffered_body, content_length)
    end

    defp receive_headers(socket, buffer) do
      case :binary.match(buffer, "\r\n\r\n") do
        {index, 4} ->
          header = binary_part(buffer, 0, index)
          body_offset = index + 4
          body = binary_part(buffer, body_offset, byte_size(buffer) - body_offset)
          {header, body}

        :nomatch ->
          {:ok, data} = :gen_tcp.recv(socket, 0, @loopback_timeout)
          receive_headers(socket, buffer <> data)
      end
    end

    defp receive_body(_socket, body, content_length) when byte_size(body) >= content_length,
      do: binary_part(body, 0, content_length)

    defp receive_body(socket, body, content_length) do
      {:ok, data} =
        :gen_tcp.recv(socket, content_length - byte_size(body), @loopback_timeout)

      receive_body(socket, body <> data, content_length)
    end

    defp send_chunked_response(socket, fragments) do
      _ =
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\n",
          "content-type: text/event-stream\r\n",
          "transfer-encoding: chunked\r\n",
          "connection: close\r\n\r\n"
        ])

      Enum.each(fragments, fn fragment ->
        size = fragment |> byte_size() |> Integer.to_string(16)
        _ = :gen_tcp.send(socket, [size, "\r\n", fragment, "\r\n"])
      end)

      :gen_tcp.send(socket, "0\r\n\r\n")
    end

    defp await_server(task) do
      case Task.yield(task, @loopback_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, request_body} -> request_body
        {:exit, reason} -> exit(reason)
        nil -> exit(:timeout)
      end
    end
  end

  test "CLI and unnegotiated v2 receive answer bytes before provider completion" do
    provider = {PausedCodexStream, self()}
    {:ok, server} = Elara.Server.start_link(port: 0, provider: provider)

    {:ok, session} = Elara.start_session(provider: provider, tools: [], persist: false)
    :ok = Elara.subscribe(session)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Elara.Server.port(server), [
        :binary,
        packet: :line,
        active: false
      ])

    :ok =
      :gen_tcp.send(
        socket,
        Elara.Protocol.encode(%{
          "version" => 2,
          "token" => System.fetch_env!("ELARA_SERVER_TOKEN"),
          "command" => "attach",
          "session_id" => session,
          "mode" => "observe"
        })
      )

    assert %{"type" => "attached"} = recv(socket)
    :ok = Elara.ask_async(session, "question")
    assert_receive {:legacy_binary_pending, provider_task}, 2000
    assert receive_answer(socket) == "legacy answer"
    assert Elara.materialized_view(session)["turn"]["state"] == "calling_provider"
    assert_receive {:elara, ^session, {:content_delta, _id, "legacy answer"} = event}
    assert IO.iodata_to_binary(Elara.CLI.render(event)) == "legacy answer"
    send(provider_task, :finish)
    assert_receive {:elara, ^session, {:turn_ended, {:completed, "legacy answer"}}}, 2000

    assert_receive {:elara, ^session,
                    {:message_appended, %Elara.Message.Assistant{}, :streamed} = completed}

    assert IO.iodata_to_binary(Elara.CLI.render(completed)) == "\n"
    :gen_tcp.close(socket)
    {:ok, pid} = Elara.session_pid(session)
    GenServer.stop(pid)
  end

  defp recv(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2000)
    JSON.decode!(line)
  end

  defp receive_answer(socket) do
    case recv(socket) do
      %{"type" => "patch", "ops" => ops} ->
        refute Enum.any?(ops, &(&1["op"] == "set_provider_view"))

        case Enum.find(ops, &(&1["op"] == "append_content_delta")) do
          nil -> receive_answer(socket)
          delta -> delta["text"]
        end

      _ ->
        receive_answer(socket)
    end
  end
end
