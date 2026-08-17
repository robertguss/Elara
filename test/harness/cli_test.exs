defmodule Harness.CLITest do
  use ExUnit.Case, async: true

  alias Harness.CLI
  alias Harness.Message.{Assistant, ToolCall, ToolResult}
  alias Harness.Provider.Error

  test "render turn_started" do
    assert IO.iodata_to_binary(CLI.render({:turn_started, "hi"})) == "[turn] hi\n"
  end

  test "render tool_started" do
    call = %ToolCall{id: "1", name: "bash", args: {:ok, %{"command" => "ls"}}}
    out = IO.iodata_to_binary(CLI.render({:tool_started, call}))
    assert out =~ "-> bash"
    assert out =~ "command=ls"
  end

  test "render tool results" do
    ok = %ToolResult{call_id: "1", name: "bash", outcome: {:ok, "a\nb\n"}}
    err = %ToolResult{call_id: "1", name: "bash", outcome: {:error, "boom\nmore"}}

    assert IO.iodata_to_binary(CLI.render({:message_appended, ok})) == "  <- ok (3 lines)\n"
    assert IO.iodata_to_binary(CLI.render({:message_appended, err})) == "  <- error: boom\n"
  end

  test "render assistant text and turn endings" do
    asst = %Assistant{text: "hello", tool_calls: []}
    assert IO.iodata_to_binary(CLI.render({:message_appended, asst})) == "hello\n"

    assert IO.iodata_to_binary(CLI.render({:turn_ended, {:completed, "x"}})) == "[done]\n"
    assert IO.iodata_to_binary(CLI.render({:turn_ended, :turn_limit})) == "[done] turn limit\n"
    assert IO.iodata_to_binary(CLI.render({:turn_ended, :interrupted})) == "[done] interrupted\n"

    err = %Error{kind: :http, message: "nope"}
    assert IO.iodata_to_binary(CLI.render({:turn_ended, {:provider_error, err}})) =~ "nope"
  end
end
