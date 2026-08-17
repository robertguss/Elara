defmodule Harness.Chat.CoreTest do
  use ExUnit.Case, async: true

  alias Harness.Chat.Core
  alias Harness.Message.{Assistant, ToolCall, ToolResult, User}
  alias Harness.Provider.Error
  alias Harness.Session.Store.Info

  defp norm({phase, effects}) do
    {phase,
     Enum.map(effects, fn
       {:print, io} -> {:print, IO.iodata_to_binary(io)}
       other -> other
     end)}
  end

  defp step(phase, input), do: norm(Core.step(phase, input))

  defp you(text) do
    "  you\n  #{text}\n\n"
  end

  @rows [
    {:idle_ask, :idle, {:line, "hi"}, {:in_turn, "hi"},
     [{:print, "  you\n  hi\n\n"}, {:ask, "hi"}]},
    {:idle_blank, :idle, {:line, "  \n"}, :idle, [{:print, "> "}]},
    {:idle_quit, :idle, {:line, "/quit"}, :idle, [{:halt, 0}]},
    {:idle_exit, :idle, {:line, "/exit"}, :idle, [{:halt, 0}]},
    {:idle_q, :idle, {:line, "/q"}, :idle, [{:halt, 0}]},
    {:idle_eof, :idle, :eof, :idle, [{:halt, 0}]},
    {:idle_interrupt, :idle, {:line, "/interrupt"}, :idle, [{:print, "> "}]},
    {:idle_resume_list, :idle, {:line, "/resume"}, :idle, [:list_sessions]},
    {:idle_resume_pick, :idle, {:line, "/resume 2"}, :idle, [{:resume_session, 2}]},
    {:idle_resume_bad_index, :idle, {:line, "/resume 0"}, :idle,
     [{:print, "usage: /resume or /resume N\n> "}]},
    {:idle_resume_bad_syntax, :idle, {:line, "/resume newest"}, :idle,
     [{:print, "usage: /resume or /resume N\n> "}]},
    {:idle_help, :idle, {:line, "/help"}, :idle,
     [
       {:print,
        "/help       this list\n/interrupt  cancel the current turn\n/resume     list saved sessions\n/resume N   resume saved session N\n/quit       exit\n> "}
     ]},
    {:idle_h, :idle, {:line, "/h"}, :idle,
     [
       {:print,
        "/help       this list\n/interrupt  cancel the current turn\n/resume     list saved sessions\n/resume N   resume saved session N\n/quit       exit\n> "}
     ]},
    {:idle_unknown, :idle, {:line, "/foo"}, :idle, [{:print, "unknown command /foo. /help\n> "}]},
    {:idle_escape, :idle, {:line, "//quit"}, {:in_turn, "/quit"},
     [{:print, "  you\n  /quit\n\n"}, {:ask, "/quit"}]},
    {:idle_rejected, :idle, :ask_rejected, :idle,
     [{:print, "busy. wait for the turn or /interrupt.\n> "}]},
    {:idle_session_down, :idle, {:session_down, :killed}, :idle,
     [{:print, "session ended\n"}, {:halt, 1}]},
    {:mid_refuse, {:in_turn, "hi"}, {:line, "more"}, {:in_turn, "hi"},
     [{:print, "in a turn. /interrupt to cancel.\n"}]},
    {:mid_unknown, {:in_turn, "hi"}, {:line, "/foo"}, {:in_turn, "hi"},
     [{:print, "in a turn. /interrupt to cancel.\n"}]},
    {:mid_resume_list, {:in_turn, "hi"}, {:line, "/resume"}, {:in_turn, "hi"},
     [{:print, "in a turn. /interrupt to cancel.\n"}]},
    {:mid_resume_pick, {:in_turn, "hi"}, {:line, "/resume 1"}, {:in_turn, "hi"},
     [{:print, "in a turn. /interrupt to cancel.\n"}]},
    {:mid_blank, {:in_turn, "hi"}, {:line, ""}, {:in_turn, "hi"}, []},
    {:interrupt_stays, {:in_turn, "hi"}, {:line, "/interrupt"}, {:in_turn, "hi"}, [:interrupt]},
    {:interrupt_stop, {:in_turn, "hi"}, {:line, "/stop"}, {:in_turn, "hi"}, [:interrupt]},
    {:quit_drain, {:in_turn, "hi"}, {:line, "/quit"}, {:exiting, 0}, [:interrupt]},
    {:eof_drain, {:in_turn, "hi"}, :eof, {:exiting, 0}, [:interrupt]},
    {:silent_started, {:in_turn, "hi"}, {:event, {:turn_started, "hi"}}, {:in_turn, "hi"}, []},
    {:silent_user, {:in_turn, "hi"}, {:event, {:message_appended, %User{text: "hi"}}},
     {:in_turn, "hi"}, []},
    {:silent_completed, {:in_turn, "hi"}, {:event, {:turn_ended, {:completed, "ok"}}}, :idle,
     [{:print, "\n> "}]},
    {:loud_interrupted, {:in_turn, "hi"}, {:event, {:turn_ended, :interrupted}}, :idle,
     [{:print, "    interrupted\n"}, {:print, "\n> "}]},
    {:loud_limit, {:in_turn, "hi"}, {:event, {:turn_ended, :turn_limit}}, :idle,
     [{:print, "    turn limit\n"}, {:print, "\n> "}]},
    {:exiting_quit_twice, {:exiting, 0}, {:line, "/quit"}, {:exiting, 0}, [{:halt, 0}]},
    {:exiting_eof, {:exiting, 0}, :eof, {:exiting, 0}, [{:halt, 0}]},
    {:exiting_other_line, {:exiting, 0}, {:line, "nope"}, {:exiting, 0}, []},
    {:exiting_halt, {:exiting, 0}, {:event, {:turn_ended, {:completed, "ok"}}}, {:exiting, 0},
     [{:halt, 0}]},
    {:exiting_loud, {:exiting, 0}, {:event, {:turn_ended, :interrupted}}, {:exiting, 0},
     [{:print, "    interrupted\n"}, {:halt, 0}]}
  ]

  for {name, phase, input, want_phase, want_effects} <- @rows do
    test "#{name}" do
      assert {unquote(want_phase), unquote(Macro.escape(want_effects))} ==
               step(unquote(Macro.escape(phase)), unquote(Macro.escape(input)))
    end
  end

  test "user block is printed on ask" do
    assert {{:in_turn, "what files are here?"}, [{:print, block}, {:ask, "what files are here?"}]} =
             step(:idle, {:line, "what files are here?"})

    assert block == you("what files are here?")
  end

  test "tool lines are faint metadata, not bodies" do
    call = %ToolCall{id: "1", name: "bash", args: {:ok, %{"command" => "ls"}}}

    ok = %ToolResult{
      call_id: "1",
      name: "bash",
      outcome: {:ok, "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl"}
    }

    err = %ToolResult{call_id: "1", name: "bash", outcome: {:error, "boom\nmore"}}

    assert {{:in_turn, "hi"}, [{:print, "    bash · ls\n"}]} =
             step({:in_turn, "hi"}, {:event, {:tool_started, call}})

    assert {{:in_turn, "hi"}, [{:print, "    ok · 12 lines\n\n"}]} =
             step({:in_turn, "hi"}, {:event, {:message_appended, ok}})

    assert {{:in_turn, "hi"}, [{:print, "    error · boom\n\n"}]} =
             step({:in_turn, "hi"}, {:event, {:message_appended, err}})
  end

  test "assistant is flush left via CLI.render" do
    asst = %Assistant{text: "here is the list...", tool_calls: []}

    assert {{:in_turn, "hi"}, [{:print, "here is the list...\n"}]} =
             step({:in_turn, "hi"}, {:event, {:message_appended, asst}})
  end

  test "provider error prints via CLI.render" do
    err = %Error{kind: :http, message: "nope"}

    assert {:idle, [{:print, "    error · nope\n"}, {:print, "\n> "}]} =
             step({:in_turn, "hi"}, {:event, {:turn_ended, {:provider_error, err}}})
  end

  test "session list uses absolute UTC timestamps and stable ids" do
    infos = [
      %Info{path: "/tmp/a", id: "session-a", cwd: "/repo", timestamp: 0},
      %Info{path: "/tmp/b", id: "session-b", cwd: "/repo", timestamp: 1}
    ]

    assert {:idle,
            [
              {:print,
               "saved sessions\n1  1970-01-01T00:00:00Z  session-a\n2  1970-01-01T00:00:01Z  session-b\n> "}
            ]} = step(:idle, {:sessions_listed, infos})
  end

  test "empty session list returns to the prompt" do
    assert {:idle, [{:print, "no saved sessions for this directory\n> "}]} =
             step(:idle, {:sessions_listed, []})
  end

  test "resume result renders domain history and prompts again" do
    user = %User{text: "question"}
    assistant = %Assistant{text: "answer", tool_calls: []}
    result = %ToolResult{call_id: "1", name: "read", outcome: {:error, "interrupted"}}

    assert {:idle,
            [
              {:print,
               "  you\n  question\n\nanswer\n    error · interrupted\n\n> "}
            ]} = step(:idle, {:resume_result, {:ok, [user, assistant, result]}})
  end

  test "resume failures are clear and return to the prompt" do
    assert {:idle, [{:print, "no saved session at index 4\n> "}]} =
             step(:idle, {:resume_result, {:error, {:invalid_index, 4}}})

    assert {:idle, [{:print, "session file no longer exists\n> "}]} =
             step(:idle, {:resume_result, {:error, :enoent}})
  end
end
