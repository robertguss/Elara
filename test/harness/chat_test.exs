defmodule Harness.ChatTest do
  use ExUnit.Case, async: false

  alias Harness.Message

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Harness.Provider.Scripted, agent}
  end

  defp asst(text, calls \\ []) do
    {:ok, a} = Message.assistant(text, calls)
    a
  end

  defp await_output(out, snippet, attempts \\ 100) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      {_input, body} = StringIO.contents(out)

      if String.contains?(body, snippet) do
        {:halt, body}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end) || flunk("did not see #{inspect(snippet)} in output")
  end

  defp await_idle_after(out, snippet, attempts \\ 100) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      {_input, body} = StringIO.contents(out)

      if String.contains?(body, snippet) and String.ends_with?(body, "> ") do
        {:halt, body}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end) || flunk("did not return to prompt after #{inspect(snippet)}")
  end

  test "two scripted turns then /quit" do
    provider = script([{:ok, asst("alpha")}, {:ok, asst("beta")}])
    {:ok, session} = Harness.start_session(provider: provider, tools: [])
    {:ok, out} = StringIO.open("")

    task = Task.async(fn -> Harness.Chat.run(session, out) end)
    chat = task.pid

    assert await_output(out, "> ")
    send(chat, {:stdin, "first\n"})
    assert await_idle_after(out, "alpha")
    send(chat, {:stdin, "second\n"})
    assert await_idle_after(out, "beta")
    send(chat, {:stdin, "/quit\n"})

    assert 0 = Task.await(task, 5_000)

    {_input, body} = StringIO.contents(out)
    assert body =~ ~r/alpha.*beta/s
    assert body =~ "  you\n  first\n"
    assert body =~ "  you\n  second\n"
    refute body =~ ">   you"
    refute body =~ "\e["
  end

  test "killed session returns status 1" do
    provider = script([{:ok, asst("hello")}])
    {:ok, session} = Harness.start_session(provider: provider, tools: [])
    {:ok, out} = StringIO.open("")

    task = Task.async(fn -> Harness.Chat.run(session, out) end)
    assert await_output(out, "harness")
    Process.exit(session, :kill)

    assert 1 = Task.await(task, 5_000)
  end
end
