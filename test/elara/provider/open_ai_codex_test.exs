defmodule Elara.Provider.OpenAICodexTest do
  use ExUnit.Case, async: true

  alias Elara.Auth.OpenAICodex, as: Tokens
  alias Elara.Message
  alias Elara.Message.ToolCall
  alias Elara.Provider
  alias Elara.Provider.Error
  alias Elara.Provider.OpenAICodex
  alias Elara.Tool

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

    assert {:ok, assistant} =
             OpenAICodex.parse_stream_chunks(chunks, fn text ->
               send(parent, {:delta, text})
               :ok
             end)

    assert assistant.text == "Hello"

    assert assistant.tool_calls == [
             %ToolCall{
               id: "call_1|fc_1",
               name: "read",
               args: {:ok, %{"path" => "README.md"}}
             }
           ]

    assert %{"openai_codex" => %{"output" => [reasoning, message, function_call]}} =
             assistant.provider_state

    assert reasoning["encrypted_content"] == "encrypted"
    assert message["id"] == "msg_1"
    assert function_call["id"] == "fc_1"
    assert_receive {:delta, "Hel"}
    assert_receive {:delta, "lo"}
  end

  test "stream parser fails malformed, incomplete, and unterminated streams closed" do
    assert {:error, %Error{kind: :bad_response, message: "invalid SSE JSON"}} =
             OpenAICodex.parse_stream_chunks(["data: {bad}\n\n"], fn _ -> :ok end)

    incomplete =
      event(%{
        "type" => "response.incomplete",
        "response" => %{
          "status" => "incomplete",
          "incomplete_details" => %{"reason" => "max_output_tokens"}
        }
      })

    assert {:error, %Error{kind: :bad_response, message: message}} =
             OpenAICodex.parse_stream_chunks([incomplete], fn _ -> :ok end)

    assert message =~ "max_output_tokens"

    assert {:error, %Error{kind: :bad_response, message: unterminated}} =
             OpenAICodex.parse_stream_chunks([], fn _ -> :ok end)

    assert unterminated =~ "before a terminal response"

    complete =
      event(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed", "output" => []}
      })

    assert {:error, %Error{kind: :bad_response, message: trailing}} =
             OpenAICodex.parse_stream_chunks([complete <> "data: {"], fn _ -> :ok end)

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

    assert {:ok, assistant} =
             OpenAICodex.parse_stream_chunks([completed], fn _ -> :ok end)

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
end
