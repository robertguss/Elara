defmodule Elara.Chat.InputTest do
  use ExUnit.Case, async: true

  alias Elara.Chat.{Core, Input}

  test "multiline paste waits for Enter, preserving blank lines and slash text" do
    {state, []} = Input.feed(Input.new(), "before \e[200~first\n")
    {state, []} = Input.feed(state, "\n")
    {state, []} = Input.feed(state, "/quit\r\n")
    {state, []} = Input.feed(state, "last\e[201~ after")
    assert {state, [{:paste, text}]} = Input.feed(state, "\n")
    assert text == "before first\n\n/quit\nlast after"
    assert state == Input.new()
    assert {_, ["/quit\n"]} = Input.feed(state, "/quit\n")
  end

  test "multiple paste regions remain one draft and trailing paste newline does not submit" do
    {state, []} = Input.feed(Input.new(), "\e[200~one\n\e[201~\e[200~two\e[201~")
    assert {_, [{:paste, "one\ntwo"}]} = Input.feed(state, "\n")
    assert Input.finish(state) == [:eof]
    {unfinished, []} = Input.feed(Input.new(), "\e[200~do not send\n")
    assert Input.finish(unfinished) == [:eof]
  end

  test "real IO.gets reader emits one paste followed by distinct quit and EOF" do
    {:ok, io} = StringIO.open("\e[200~first\n/interrupt\nlast\e[201~\n/quit\n")
    Input.read(self(), io)
    assert_received {:stdin, {:paste, "first\n/interrupt\nlast"}}
    assert_received {:stdin, "/quit\n"}
    assert_received {:stdin, :eof}
    refute_received {:stdin, _}
    StringIO.close(io)
  end

  test "ordinary input including final unterminated command preserves line behavior" do
    {:ok, io} = StringIO.open("hello\n/quit")
    Input.read(self(), io)
    assert_received {:stdin, "hello\n"}
    assert_received {:stdin, "/quit\n"}
    assert_received {:stdin, :eof}
    StringIO.close(io)
  end

  test "pasted commands are literal in idle, busy and exiting phases" do
    for text <- ["/quit", "/interrupt", "/reload", "//quit", "/quit\nsecond"] do
      assert {{:in_turn, ^text}, [{:print, _}, {:ask, ^text}]} =
               Core.step(:idle, {:paste, text})

      assert {{:in_turn, "working"}, [{:print, _}]} =
               Core.step({:in_turn, "working"}, {:paste, text})

      assert {{:exiting, 0}, []} = Core.step({:exiting, 0}, {:paste, text})
    end

    assert {:idle, [{:halt, 0}]} = Core.step(:idle, {:line, "/quit\n"})
    assert {:idle, [{:print, _}]} = Core.step(:idle, {:paste, " \n"})
    assert {{:in_turn, "working"}, []} = Core.step({:in_turn, "working"}, {:paste, "\n"})
  end
end
