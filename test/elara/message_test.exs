defmodule Elara.MessageTest do
  use ExUnit.Case, async: true

  alias Elara.Message
  alias Elara.Message.ToolCall

  test "assistant/2 rejects empty message" do
    assert {:error, :empty_assistant} = Message.assistant(nil, [])
    assert {:error, :empty_assistant} = Message.assistant("", [])
  end

  test "assistant/2 accepts text or tool calls" do
    assert {:ok, %Message.Assistant{text: "hi", tool_calls: []}} = Message.assistant("hi", [])

    call = %ToolCall{id: "1", name: "read", args: {:ok, %{}}}

    assert {:ok, %Message.Assistant{text: nil, tool_calls: [^call]}} =
             Message.assistant(nil, [call])
  end

  test "user/1 and tool_result/2 constructors" do
    assert %Message.User{text: "q"} = Message.user("q")

    call = %ToolCall{id: "1", name: "bash", args: {:ok, %{}}}

    assert %Message.ToolResult{call_id: "1", name: "bash", outcome: {:ok, "out"}} =
             Message.tool_result(call, {:ok, "out"})
  end
end
