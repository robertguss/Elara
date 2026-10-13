defmodule Elara.CLITest do
  use ExUnit.Case, async: true

  alias Elara.CLI
  alias Elara.Message.{Assistant, ToolCall, ToolResult}
  alias Elara.Provider.Error

  @tag :tmp_dir
  test "ask refuses approval without executing and reports failure only when it ends there", %{
    tmp_dir: cwd
  } do
    File.mkdir_p!(Path.join(cwd, ".elara"))
    File.write!(Path.join(cwd, ".elara/command-rules.json"), ~s({"ask":["printf guarded"]}))

    guarded = %ToolCall{
      id: "guarded",
      name: "bash",
      args: {:ok, %{"command" => "printf guarded > guarded"}}
    }

    for continue? <- [false, true] do
      turns =
        if continue? do
          [
            {:ok, %Assistant{tool_calls: [guarded]}},
            {:ok,
             %Assistant{
               tool_calls: [
                 %ToolCall{
                   id: "fallback",
                   name: "read",
                   args: {:ok, %{"path" => ".elara/command-rules.json"}}
                 }
               ]
             }},
            {:ok, %Assistant{text: "read instead"}}
          ]
        else
          [{:ok, %Assistant{tool_calls: [guarded]}}, {:ok, %Assistant{text: "approval needed"}}]
        end

      {:ok, agent} = Agent.start_link(fn -> turns end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          run = fn ->
            CLI.main(["--cwd", cwd, "inspect"], provider: {Elara.Provider.Scripted, agent})
          end

          if continue?,
            do: assert(run.() == :ok),
            else: assert(catch_exit(run.()) == {:shutdown, 1})
        end)

      assert output =~ "approval required:"
      assert output =~ "printf guarded"
      assert output =~ "TUI"
      assert output =~ if(continue?, do: "read instead", else: "approval needed")
      refute File.exists?(Path.join(cwd, "guarded"))
    end
  end

  test "ask parses explicit workspace without changing the process directory" do
    cwd = File.cwd!()

    assert {:ok, "inspect files", [cwd: ^cwd]} =
             CLI.parse_args(["--cwd", ".", "inspect", "files"])

    assert {:ok, "inspect files", []} = CLI.parse_args(["inspect files"])
    assert {:ok, "--cwd literal", []} = CLI.parse_args(["--", "--cwd", "literal"])
    assert File.cwd!() == cwd
  end

  @tag :tmp_dir
  test "ask selects a different workspace with spaces", %{tmp_dir: tmp_dir} do
    target = Path.join(tmp_dir, "target workspace")
    File.mkdir_p!(target)
    invoking = File.cwd!()

    assert {:ok, "inspect", [cwd: ^target]} = CLI.parse_args(["--cwd", target, "inspect"])
    refute target == invoking
    assert File.cwd!() == invoking
  end

  test "ask rejects invalid workspaces and missing values before startup" do
    for cwd <- ["", __ENV__.file, Path.join(__DIR__, "missing-cwd-directory")] do
      assert {:error, message} = CLI.parse_args(["--cwd", cwd, "inspect"])
      assert message =~ "--cwd must name an existing directory"
    end

    assert {:error, "unknown or missing option value: --cwd"} = CLI.parse_args(["--cwd"])

    assert {:error, "unknown or missing option value: --unknown"} =
             CLI.parse_args(["--unknown", "inspect"])
  end

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
    assert IO.iodata_to_binary(CLI.render({:content_delta, "assistant-1", "hel"})) == "hel"
    assert IO.iodata_to_binary(CLI.render({:message_appended, asst, :streamed})) == "\n"

    assert IO.iodata_to_binary(CLI.render({:turn_ended, {:completed, "x"}})) == "[done]\n"
    assert IO.iodata_to_binary(CLI.render({:turn_ended, :turn_limit})) == "[done] turn limit\n"
    assert IO.iodata_to_binary(CLI.render({:turn_ended, :interrupted})) == "[done] interrupted\n"

    assert IO.iodata_to_binary(CLI.render({:turn_ended, :interrupted, :streamed})) ==
             "\n[done] interrupted\n"

    err = %Error{kind: :http, message: "nope"}
    assert IO.iodata_to_binary(CLI.render({:turn_ended, {:provider_error, err}})) =~ "nope"
  end
end
