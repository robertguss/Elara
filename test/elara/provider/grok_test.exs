defmodule Elara.Provider.GrokTest do
  use ExUnit.Case, async: true

  alias Elara.Auth
  alias Elara.Message.User
  alias Elara.Provider
  alias Elara.Provider.Error
  alias Elara.Provider.Grok

  @loopback_timeout 10_000

  test "new stores tokens without closures" do
    tokens = %Auth{access_token: "a", refresh_token: "r", expires_at: 1}
    config = Grok.new(tokens)
    assert config.tokens == tokens
    refute Map.has_key?(config, :now_s)
    refute Map.has_key?(config, :refresh)
  end

  test "chat and stream remap HTTP 403 to entitlement" do
    for mode <- [:chat, :stream] do
      server = start_loopback_server(fn socket -> send_status_response(socket, 403, "nope") end)
      config = grok_config(server.port)

      assert {:error, %Error{kind: :entitlement, status: 403, message: message}, _config} =
               run_provider(fn ->
                 if mode == :chat,
                   do: Grok.chat(config, request()),
                   else: Grok.stream(config, request(), fn _ -> :ok end)
               end)

      assert message =~ "XAI_API_KEY"
      assert message =~ "Re-login will not help"
      _ = await_server(server.task)
    end
  end

  test "chat and stream leave other errors alone" do
    for mode <- [:chat, :stream] do
      server = start_loopback_server(fn socket -> send_status_response(socket, 500, "oops") end)
      config = grok_config(server.port)

      assert {:error, %Error{kind: :http, status: 500, message: message}, _config} =
               run_provider(fn ->
                 if mode == :chat,
                   do: Grok.chat(config, request()),
                   else: Grok.stream(config, request(), fn _ -> :ok end)
               end)

      assert message =~ "500"
      refute message =~ "XAI_API_KEY"
      _ = await_server(server.task)
    end
  end

  defp grok_config(port) do
    Grok.new(%Auth{access_token: "fixture", expires_at: 9_999_999_999},
      base_url: "http://127.0.0.1:#{port}/v1"
    )
  end

  defp request do
    %Provider.Request{system: "system", messages: [%User{text: "hello"}], tools: []}
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
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)

      if Process.alive?(task.pid) do
        Task.shutdown(task, :brutal_kill)
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

  defp send_status_response(socket, status, body) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} X\r\n",
      "content-type: text/plain\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ])
  end

  defp run_provider(fun) do
    task = Task.async(fun)

    case Task.yield(task, @loopback_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> flunk("provider task exited: #{inspect(reason)}")
      nil -> flunk("provider task timed out after #{@loopback_timeout}ms")
    end
  end

  defp await_server(task) do
    case Task.yield(task, @loopback_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, request_body} -> request_body
      {:exit, reason} -> flunk("loopback server task exited: #{inspect(reason)}")
      nil -> flunk("loopback server task timed out after #{@loopback_timeout}ms")
    end
  end
end
