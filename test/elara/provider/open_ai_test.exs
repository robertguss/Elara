defmodule Elara.Provider.OpenAITest do
  use ExUnit.Case, async: true

  # Content/transport checks allow scheduler and socket delay; this is a bounded
  # fixture wait, not an assertion that the provider responds within two seconds.
  @loopback_timeout 10_000

  alias Elara.Message
  alias Elara.Message.{ToolCall, ToolResult, User}
  alias Elara.Provider
  alias Elara.Provider.Error
  alias Elara.Provider.OpenAI
  alias Elara.Tool

  defp config do
    %OpenAI{api_key: "sk-test", base_url: "https://api.example.com/v1", model: "test-model"}
  end

  test "build_body maps history and tools" do
    {:ok, asst} =
      Message.assistant("thinking", [
        %ToolCall{id: "1", name: "read", args: {:ok, %{"path" => "a"}}},
        %ToolCall{id: "2", name: "bash", args: {:malformed, "{nope"}}
      ])

    request = %Provider.Request{
      system: "sys",
      messages: [
        %User{text: "hi"},
        asst,
        %ToolResult{call_id: "1", name: "read", outcome: {:ok, "data"}},
        %ToolResult{call_id: "2", name: "bash", outcome: {:error, "bad"}}
      ],
      tools: Tool.builtins()
    }

    body = OpenAI.build_body(config(), request)

    assert body["model"] == "test-model"
    assert hd(body["messages"]) == %{"role" => "system", "content" => "sys"}
    assert Enum.at(body["messages"], 1) == %{"role" => "user", "content" => "hi"}

    asst_msg = Enum.at(body["messages"], 2)
    assert asst_msg["role"] == "assistant"
    assert asst_msg["content"] == "thinking"
    assert [c1, c2] = asst_msg["tool_calls"]
    assert c1["function"]["arguments"] == ~s({"path":"a"})
    assert c2["function"]["arguments"] == "{nope"

    tool_ok = Enum.at(body["messages"], 3)
    assert tool_ok == %{"role" => "tool", "tool_call_id" => "1", "content" => "data"}

    tool_err = Enum.at(body["messages"], 4)
    assert tool_err["content"] == "ERROR: bad"

    assert Enum.all?(body["tools"], fn t ->
             t["type"] == "function" and is_binary(t["function"]["name"])
           end)
  end

  test "parse_response success with tool calls and malformed args" do
    raw =
      JSON.encode!(%{
        "choices" => [
          %{
            "message" => %{
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "c1",
                  "type" => "function",
                  "function" => %{"name" => "read", "arguments" => ~s({"path":"x"})}
                },
                %{
                  "id" => "c2",
                  "type" => "function",
                  "function" => %{"name" => "bash", "arguments" => "not-json"}
                }
              ]
            }
          }
        ]
      })

    assert {:ok, %Message.Assistant{tool_calls: [c1, c2]}} =
             OpenAI.parse_response({:ok, %Req.Response{status: 200, body: raw}})

    assert c1.args == {:ok, %{"path" => "x"}}
    assert c2.args == {:malformed, "not-json"}
  end

  test "build_body sends empty string not null for tool-only assistant" do
    {:ok, asst} =
      Message.assistant(nil, [%ToolCall{id: "1", name: "read", args: {:ok, %{"path" => "a"}}}])

    body =
      OpenAI.build_body(config(), %Provider.Request{
        system: "sys",
        messages: [asst],
        tools: []
      })

    asst_msg = Enum.at(body["messages"], 1)
    assert asst_msg["content"] == ""
    refute asst_msg["content"] == nil
    assert length(asst_msg["tool_calls"]) == 1
  end

  test "parse_response classifies http, transport, bad_response" do
    assert {:error, %Error{kind: :http, status: 500, message: msg}} =
             OpenAI.parse_response({:ok, %Req.Response{status: 500, body: "oops"}})

    assert msg =~ "500"

    assert {:error, %Error{kind: :http, status: 403}} =
             OpenAI.parse_response({:ok, %Req.Response{status: 403, body: "nope"}})

    assert {:error, %Error{kind: :transport}} =
             OpenAI.parse_response({:error, %Req.TransportError{reason: :timeout}})

    empty =
      JSON.encode!(%{"choices" => [%{"message" => %{"content" => nil, "tool_calls" => []}}]})

    assert {:error, %Error{kind: :bad_response}} =
             OpenAI.parse_response({:ok, %Req.Response{status: 200, body: empty}})
  end

  test "stream parser reassembles arbitrary chunks, content deltas, and tool calls" do
    frames = [
      %{"choices" => [%{"delta" => %{"role" => "assistant", "content" => "Hel"}}]},
      %{
        "choices" => [
          %{
            "delta" => %{
              "content" => "lo ",
              "tool_calls" => [
                %{
                  "index" => 1,
                  "id" => "second",
                  "function" => %{"name" => "bash", "arguments" => ~s({"co)}
                },
                %{
                  "index" => 0,
                  "id" => "first",
                  "function" => %{"name" => "read", "arguments" => ~s({"pa)}
                }
              ]
            }
          }
        ]
      },
      %{
        "choices" => [
          %{
            "delta" => %{
              "content" => "é",
              "tool_calls" => [
                %{"index" => 0, "function" => %{"arguments" => ~s(th":"x"})}},
                %{"index" => 1, "function" => %{"arguments" => ~s(mmand":"true"})}}
              ]
            }
          }
        ]
      }
    ]

    wire =
      Enum.map_join(frames, fn frame -> "data: #{JSON.encode!(frame)}\r\n\r\n" end) <>
        "data: [DONE]\r\n\r\n"

    chunks = for <<byte <- wire>>, do: <<byte>>
    parent = self()

    assert {:ok, %Message.Assistant{text: "Hello é", tool_calls: [first, second]}} =
             OpenAI.parse_stream_chunks(chunks, fn text ->
               send(parent, {:delta, text})
               :ok
             end)

    assert first == %ToolCall{id: "first", name: "read", args: {:ok, %{"path" => "x"}}}

    assert second ==
             %ToolCall{id: "second", name: "bash", args: {:ok, %{"command" => "true"}}}

    assert_receive {:delta, "Hel"}
    assert_receive {:delta, "lo "}
    assert_receive {:delta, "é"}
  end

  test "stream parser fails malformed or truncated streams closed" do
    assert {:error, %Error{kind: :bad_response, message: malformed}} =
             OpenAI.parse_stream_chunks(["data: {nope}\n\n"], fn _ -> :ok end)

    assert malformed =~ "invalid SSE JSON"

    event = JSON.encode!(%{"choices" => [%{"delta" => %{"content" => "partial"}}]})

    assert {:error, %Error{kind: :bad_response, message: truncated}} =
             OpenAI.parse_stream_chunks(["data: #{event}\n\n"], fn _ -> :ok end)

    assert truncated =~ "before [DONE]"
  end

  test "chat succeeds through the loopback HTTP transport" do
    body =
      JSON.encode!(%{
        "choices" => [%{"message" => %{"content" => "ok", "tool_calls" => []}}]
      })

    server = start_loopback_server(fn socket -> send_content_length_response(socket, body) end)

    assert {:ok, %Message.Assistant{text: "ok"}, _config} =
             run_provider(fn -> OpenAI.chat(loopback_config(server.port), request()) end)

    request_body = await_server(server.task)
    assert {:ok, %{"model" => "test-model"}} = JSON.decode(request_body)
  end

  test "stream succeeds when SSE frames are fragmented across HTTP chunks" do
    event = JSON.encode!(%{"choices" => [%{"delta" => %{"content" => "ok"}}]})

    fragments = [
      "data: " <> binary_part(event, 0, 12),
      binary_part(event, 12, byte_size(event) - 12) <> "\n",
      "\ndata: [DO",
      "NE]\n\n"
    ]

    server = start_loopback_server(fn socket -> send_chunked_response(socket, fragments) end)
    owner = self()

    assert {:ok, %Message.Assistant{text: "ok"}, _config} =
             run_provider(fn ->
               OpenAI.stream(loopback_config(server.port), request(), fn delta ->
                 send(owner, {:delta, delta})
                 :ok
               end)
             end)

    assert_receive {:delta, "ok"}
    request_body = await_server(server.task)
    assert {:ok, %{"stream" => true}} = JSON.decode(request_body)
  end

  test "stream rejects an invalid HTTP chunk-size tail as a transport error" do
    event = JSON.encode!(%{"choices" => [%{"delta" => %{"content" => "ok"}}]})
    body = "data: #{event}\n\ndata: [DONE]\n\n"

    server =
      start_loopback_server(fn socket ->
        send_malformed_chunk_tail_response(socket, body)
      end)

    result =
      run_provider(fn ->
        OpenAI.stream(loopback_config(server.port), request(), fn _delta -> :ok end)
      end)

    request_body = await_server(server.task)
    assert {:ok, %{"stream" => true}} = JSON.decode(request_body)
    assert {:error, %Error{kind: :transport}, _config} = result
  end

  test "chat accepts a valid loopback response delayed beyond two seconds" do
    body = JSON.encode!(%{"choices" => [%{"message" => %{"content" => "delayed"}}]})

    server =
      start_loopback_server(fn socket ->
        Process.sleep(2_100)
        send_content_length_response(socket, body)
      end)

    assert {:ok, %Message.Assistant{text: "delayed"}, _config} =
             run_provider(fn -> OpenAI.chat(loopback_config(server.port), request()) end)

    assert {:ok, %{"model" => "test-model"}} = JSON.decode(await_server(server.task))
  end

  test "stream accepts valid fragmented SSE delayed beyond two seconds" do
    event = JSON.encode!(%{"choices" => [%{"delta" => %{"content" => "delayed"}}]})
    fragments = ["data: " <> event <> "\n", "\ndata: [DO", "NE]\n\n"]
    owner = self()

    server =
      start_loopback_server(fn socket ->
        Process.sleep(2_100)
        send_chunked_response(socket, fragments)
      end)

    assert {:ok, %Message.Assistant{text: "delayed"}, _config} =
             run_provider(fn ->
               OpenAI.stream(loopback_config(server.port), request(), fn delta ->
                 send(owner, {:delayed_delta, delta})
                 :ok
               end)
             end)

    assert_receive {:delayed_delta, "delayed"}
    assert {:ok, %{"stream" => true}} = JSON.decode(await_server(server.task))
  end

  defp loopback_config(port) do
    %OpenAI{
      api_key: "test-key",
      base_url: "http://127.0.0.1:#{port}/v1",
      model: "test-model"
    }
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

  defp send_content_length_response(socket, body) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 200 OK\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ])
  end

  defp send_chunked_response(socket, fragments) do
    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\n",
        "content-type: text/event-stream\r\n",
        "transfer-encoding: chunked\r\n",
        "connection: close\r\n\r\n"
      ])

    Enum.each(fragments, fn fragment ->
      size = fragment |> byte_size() |> Integer.to_string(16)
      :ok = :gen_tcp.send(socket, [size, "\r\n", fragment, "\r\n"])
    end)

    :gen_tcp.send(socket, "0\r\n\r\n")
  end

  defp send_malformed_chunk_tail_response(socket, body) do
    size = body |> byte_size() |> Integer.to_string(16)

    # Mint 1.9.3 accepted the valid hexadecimal size prefix and ignored this
    # invalid "Z" tail; 1.10.2 rejects the chunk-size line before exposing body.
    :gen_tcp.send(socket, [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/event-stream\r\n",
      "transfer-encoding: chunked\r\n",
      "connection: close\r\n\r\n",
      size,
      "Z\r\n",
      body,
      "\r\n0\r\n\r\n"
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
