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

    {:ok, assistant} =
      OpenAICodex.parse_stream_chunks(chunks, fn delta ->
        send(self(), {:public_test, delta})
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

    assert {:ok, %{text: "ok"}} =
             OpenAICodex.parse_stream_chunks(for(<<byte <- event>>, do: <<byte>>), fn _ -> :ok end)
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

    {:ok, assistant} =
      OpenAICodex.parse_stream_chunks(Enum.map(events, &event/1), fn delta ->
        send(self(), {:compatibility, delta})
        :ok
      end)

    assert assistant.text == "Answer"
    assert_received {:compatibility, "Answer"}
    refute_received {:compatibility, "Working"}
    refute_received {:compatibility, "Thinking"}
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
