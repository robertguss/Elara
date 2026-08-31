defmodule Elara.Provider.OpenAITest do
  use ExUnit.Case, async: true

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
end
