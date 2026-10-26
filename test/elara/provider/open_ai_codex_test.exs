defmodule Elara.Provider.OpenAICodexTest do
  use ExUnit.Case, async: true

  alias Elara.Auth.OpenAICodex, as: Tokens
  alias Elara.Message
  alias Elara.Message.ToolCall
  alias Elara.Provider
  alias Elara.Provider.Error
  alias Elara.Provider.OpenAICodex
  alias Elara.Tool

  @loopback_timeout 10_000

  defp config do
    OpenAICodex.new(
      %Tokens{
        access_token: "access",
        refresh_token: "refresh",
        expires_at: System.system_time(:second) + 3_600,
        account_id: "account"
      },
      model: "gpt-test"
    )
  end

  test "public summaries preserve parts and phases across every byte boundary" do
    output = [
      %{
        "id" => "r1",
        "type" => "reasoning",
        "encrypted_content" => "SECRET",
        "summary" => [
          %{"type" => "summary_text", "text" => "Plan α"},
          %{"type" => "summary_text", "text" => "Check"}
        ]
      },
      %{
        "id" => "m1",
        "type" => "message",
        "role" => "assistant",
        "phase" => "commentary",
        "content" => [%{"type" => "output_text", "text" => "Working"}]
      },
      %{
        "id" => "m2",
        "type" => "message",
        "role" => "assistant",
        "phase" => "final_answer",
        "content" => [%{"type" => "output_text", "text" => "Done"}]
      }
    ]

    events = [
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => hd(output)},
      %{
        "type" => "response.reasoning_summary_text.delta",
        "output_index" => 0,
        "item_id" => "r1",
        "summary_index" => 0,
        "delta" => "Plan α"
      },
      %{
        "type" => "response.reasoning_summary_text.delta",
        "output_index" => 0,
        "item_id" => "r1",
        "summary_index" => 1,
        "delta" => "Check"
      },
      %{
        "type" => "response.completed",
        "response" => %{
          "model" => "gpt-5.5",
          "output" => output,
          "usage" => %{
            "input_tokens" => 12,
            "output_tokens" => 8,
            "input_tokens_details" => %{"cache_write_tokens" => 4, "cached_tokens" => 2},
            "output_tokens_details" => %{"reasoning_tokens" => 3}
          }
        }
      }
    ]

    data = Enum.map_join(events, &("data: " <> JSON.encode!(&1) <> "\r\n\r\n"))
    chunks = for <<byte <- data>>, do: <<byte>>

    parent = self()

    {:ok, assistant, _config} =
      stream_chunks(chunks, fn delta ->
        send(parent, {:public_test, delta})
        :ok
      end)

    assert Enum.map(assistant.public_content, & &1["kind"]) == [
             "reasoning_summary",
             "reasoning_summary",
             "commentary",
             "final_answer"
           ]

    assert Enum.map(assistant.public_content, & &1["text"]) == [
             "Plan α",
             "Check",
             "Working",
             "Done"
           ]

    assert assistant.text == "Done"
    assert assistant.usage["cache_write_tokens"] == 4
    assert assistant.usage["input_tokens"] == 12
    assert assistant.usage["reasoning_tokens"] == 3
    refute JSON.encode!(assistant.public_content) =~ "SECRET"
    assert_received {:public_test, {:public_content, %{"text" => "Plan α", "part_index" => 0}}}
  end

  test "SSE multiline data preserves split CRLF boundaries" do
    event =
      "data: {\r\ndata: \"type\":\"response.completed\",\"response\":{\"output\":[{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}}\r\n\r\n"

    assert {:ok, %{text: "ok"}, _config} =
             stream_chunks(for(<<byte <- event>>, do: <<byte>>), fn _ -> :ok end)
  end

  test "build_body maps instructions, messages, and function tools" do
    request = %Provider.Request{
      system: "system",
      messages: [Message.user("inspect")],
      tools: Tool.builtins()
    }

    body = OpenAICodex.build_body(config(), request)

    assert body["model"] == "gpt-test"
    assert body["instructions"] == "system"
    assert body["store"] == false
    assert body["stream"] == true
    assert body["include"] == ["reasoning.encrypted_content"]

    assert body["input"] == [
             %{
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "inspect"}]
             }
           ]

    assert Enum.all?(body["tools"], fn tool ->
             tool["type"] == "function" and is_binary(tool["name"]) and
               is_map(tool["parameters"]) and tool["strict"] == false
           end)
  end

  test "native reasoning and function IDs survive tool-result continuation" do
    output = [
      %{
        "type" => "reasoning",
        "id" => "rs_1",
        "summary" => [],
        "encrypted_content" => "encrypted"
      },
      %{
        "type" => "function_call",
        "id" => "fc_1",
        "call_id" => "call_1",
        "name" => "read",
        "arguments" => ~s({"path":"README.md"})
      }
    ]

    call = %ToolCall{
      id: "call_1|fc_1",
      name: "read",
      args: {:ok, %{"path" => "README.md"}}
    }

    {:ok, assistant} =
      Message.assistant(nil, [call], %{"openai_codex" => %{"output" => output}})

    request = %Provider.Request{
      system: "system",
      messages: [Message.user("read it"), assistant, Message.tool_result(call, {:ok, "data"})],
      tools: []
    }

    assert %{"input" => [user, reasoning, function_call, result]} =
             OpenAICodex.build_body(config(), request)

    assert user["role"] == "user"
    assert reasoning == hd(output)
    assert function_call == Enum.at(output, 1)

    assert result == %{
             "type" => "function_call_output",
             "call_id" => "call_1",
             "output" => "data"
           }
  end

  test "stream parser reassembles text, calls, and encrypted reasoning at every byte" do
    events = [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{"type" => "reasoning", "id" => "rs_1", "summary" => []}
      },
      %{
        "type" => "response.output_item.done",
        "output_index" => 0,
        "item" => %{
          "type" => "reasoning",
          "id" => "rs_1",
          "summary" => [],
          "encrypted_content" => "encrypted"
        }
      },
      %{
        "type" => "response.output_item.added",
        "output_index" => 1,
        "item" => %{
          "type" => "message",
          "id" => "msg_1",
          "role" => "assistant",
          "status" => "in_progress",
          "content" => []
        }
      },
      %{"type" => "response.output_text.delta", "output_index" => 1, "delta" => "Hel"},
      %{"type" => "response.output_text.delta", "output_index" => 1, "delta" => "lo"},
      %{
        "type" => "response.output_item.done",
        "output_index" => 1,
        "item" => %{
          "type" => "message",
          "id" => "msg_1",
          "role" => "assistant",
          "status" => "completed",
          "content" => [%{"type" => "output_text", "text" => "Hello"}]
        }
      },
      %{
        "type" => "response.output_item.added",
        "output_index" => 2,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => "call_1",
          "name" => "read",
          "arguments" => ""
        }
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "output_index" => 2,
        "delta" => ~s({"path":)
      },
      %{
        "type" => "response.function_call_arguments.done",
        "output_index" => 2,
        "arguments" => ~s({"path":"README.md"})
      },
      %{
        "type" => "response.output_item.done",
        "output_index" => 2,
        "item" => %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => "call_1",
          "name" => "read",
          "arguments" => ~s({"path":"README.md"})
        }
      },
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_1",
          "status" => "completed",
          "usage" => %{"input_tokens" => 5, "output_tokens" => 3, "total_tokens" => 8}
        }
      }
    ]

    wire = Enum.map_join(events, fn event -> "data: #{JSON.encode!(event)}\r\n\r\n" end)
    chunks = for <<byte <- wire>>, do: <<byte>>
    parent = self()

    assert {:ok, assistant, _config} =
             stream_chunks(chunks, fn text ->
               send(parent, {:delta, text})
               :ok
             end)

    assert assistant.text == "Hello"

    assert assistant.tool_calls == [
             %ToolCall{
               id: "call_1|fc_1",
               name: "read",
               args: {:ok, %{"path" => "README.md"}},
               output_index: 2
             }
           ]

    assert %{"openai_codex" => %{"output" => [reasoning, message, function_call]}} =
             assistant.provider_state

    assert reasoning["encrypted_content"] == "encrypted"
    assert message["id"] == "msg_1"
    assert function_call["id"] == "fc_1"
    assert_receive {:delta, {:public_content, %{"text" => "Hel"}}}
    assert_receive {:delta, {:public_content, %{"text" => "Hello"}}}
    assert_receive {:delta, "Hel"}
    assert_receive {:delta, "lo"}
  end

  test "compatibility deltas contain final answers but never commentary or reasoning" do
    commentary = %{
      "id" => "commentary",
      "type" => "message",
      "role" => "assistant",
      "phase" => "commentary",
      "content" => [%{"type" => "output_text", "text" => "Working"}]
    }

    final = %{
      "id" => "final",
      "type" => "message",
      "role" => "assistant",
      "phase" => "final_answer",
      "content" => [%{"type" => "output_text", "text" => "Answer"}]
    }

    events = [
      %{
        "type" => "response.reasoning_summary_text.delta",
        "item_id" => "r",
        "output_index" => 0,
        "summary_index" => 0,
        "delta" => "Thinking"
      },
      %{"type" => "response.output_item.added", "output_index" => 1, "item" => commentary},
      %{"type" => "response.output_text.delta", "output_index" => 1, "delta" => "Working"},
      %{"type" => "response.output_item.added", "output_index" => 2, "item" => final},
      %{"type" => "response.output_text.delta", "output_index" => 2, "delta" => "Answer"},
      %{"type" => "response.completed", "response" => %{"output" => [commentary, final]}}
    ]

    parent = self()

    {:ok, assistant, _config} =
      stream_chunks(Enum.map(events, &event/1), fn delta ->
        send(parent, {:compatibility, delta})
        :ok
      end)

    assert assistant.text == "Answer"
    assert_received {:compatibility, "Answer"}
    refute_received {:compatibility, "Working"}
    refute_received {:compatibility, "Thinking"}
  end

  test "stream parser fails malformed, incomplete, and unterminated streams closed" do
    assert {:error, %Error{kind: :bad_response, message: "invalid SSE JSON"}, _config} =
             stream_chunks(["data: {bad}\n\n"], fn _ -> :ok end)

    incomplete =
      event(%{
        "type" => "response.incomplete",
        "response" => %{
          "status" => "incomplete",
          "incomplete_details" => %{"reason" => "max_output_tokens"}
        }
      })

    assert {:error, %Error{kind: :bad_response, message: message}, _config} =
             stream_chunks([incomplete], fn _ -> :ok end)

    assert message =~ "max_output_tokens"

    assert {:error, %Error{kind: :bad_response, message: unterminated}, _config} =
             stream_chunks([], fn _ -> :ok end)

    assert unterminated =~ "before a terminal response"

    complete =
      event(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed", "output" => []}
      })

    assert {:error, %Error{kind: :bad_response, message: trailing}, _config} =
             stream_chunks([complete <> "data: {"], fn _ -> :ok end)

    assert trailing =~ "incomplete SSE frame"
  end

  test "terminal output preserves complete native items for stateless replay" do
    output = [
      %{
        "type" => "reasoning",
        "id" => "rs_1",
        "summary" => [],
        "encrypted_content" => "encrypted",
        "provider_extension" => %{"opaque" => true}
      },
      %{
        "type" => "message",
        "id" => "msg_1",
        "role" => "assistant",
        "status" => "completed",
        "phase" => "final_answer",
        "content" => [%{"type" => "output_text", "text" => "answer"}]
      }
    ]

    completed =
      event(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed", "output" => output}
      })

    assert {:ok, assistant, _config} = stream_chunks([completed], fn _ -> :ok end)

    assert assistant.provider_state == %{"openai_codex" => %{"output" => output}}

    body =
      OpenAICodex.build_body(config(), %Provider.Request{
        system: "system",
        messages: [assistant],
        tools: []
      })

    assert body["input"] == output
  end

  test "provider config inspect redacts subscription tokens" do
    inspected = inspect(config())
    refute inspected =~ "access"
    refute inspected =~ "refresh"
    assert inspected =~ "#Elara.Provider.OpenAICodex<"
  end

  defp event(map), do: "data: #{JSON.encode!(map)}\n\n"

  defp stream_chunks(chunks, sink) do
    server = start_loopback_server(fn socket -> send_chunked_response(socket, chunks) end)

    result =
      run_provider(fn ->
        OpenAICodex.stream(
          %{config() | base_url: "http://127.0.0.1:#{server.port}"},
          request(),
          sink
        )
      end)

    _ = Task.yield(server.task, @loopback_timeout) || Task.shutdown(server.task, :brutal_kill)
    result
  end

  defp request do
    %Provider.Request{system: "system", messages: [Message.user("inspect")], tools: []}
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

  defp run_provider(fun) do
    task = Task.async(fun)

    case Task.yield(task, @loopback_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> flunk("provider task exited: #{inspect(reason)}")
      nil -> flunk("provider task timed out after #{@loopback_timeout}ms")
    end
  end
end
