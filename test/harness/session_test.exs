defmodule Harness.SessionTest do
  use ExUnit.Case, async: false

  alias Harness.Message
  alias Harness.Message.ToolCall
  alias Harness.Provider.Error
  alias Harness.Tool

  defmodule CrashTool do
    def run(_args, _ctx), do: raise("boom")
  end

  defmodule SlowTool do
    def run(_args, _ctx) do
      Process.sleep(5_000)
      {:ok, "late"}
    end
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Harness.Provider.Scripted, agent}
  end

  defp asst(text, calls \\ []) do
    {:ok, a} = Message.assistant(text, calls)
    a
  end

  test "sync ask returns final text and fans events" do
    provider = script([{:ok, asst("hello")}])
    {:ok, session} = Harness.start_session(provider: provider, tools: [])
    :ok = Harness.subscribe(session)

    task = Task.async(fn -> Harness.ask(session, "hi") end)

    assert_receive {:harness, ^session, {:turn_started, "hi"}}, 1_000
    assert_receive {:harness, ^session, {:message_appended, %Message.User{}}}, 1_000

    assert_receive {:harness, ^session, {:message_appended, %Message.Assistant{text: "hello"}}},
                   1_000

    assert_receive {:harness, ^session, {:turn_ended, {:completed, "hello"}}}, 1_000

    assert {:ok, "hello"} = Task.await(task)
  end

  test "busy rejection" do
    provider =
      script([
        {:ok, asst(nil, [%ToolCall{id: "1", name: "slow", args: {:ok, %{}}}])}
      ])

    tools = [
      %Tool{
        name: "slow",
        description: "slow",
        parameters: %{"type" => "object", "properties" => %{}},
        run: {SlowTool, :run}
      }
    ]

    {:ok, session} =
      Harness.start_session(provider: provider, tools: tools, tool_timeout_ms: 10_000)

    assert :ok = Harness.ask_async(session, "go")
    assert {:error, :busy} = Harness.ask_async(session, "again")
  end

  test "tool crash isolates and continues" do
    provider =
      script([
        {:ok, asst(nil, [%ToolCall{id: "1", name: "crash", args: {:ok, %{}}}])},
        {:ok, asst("recovered")}
      ])

    tools = [
      %Tool{
        name: "crash",
        description: "crash",
        parameters: %{"type" => "object", "properties" => %{}},
        run: {CrashTool, :run}
      }
    ]

    {:ok, session} = Harness.start_session(provider: provider, tools: tools)
    assert {:ok, "recovered"} = Harness.ask(session, "go")
    assert Process.alive?(session)
  end

  test "tool timeout becomes error and continues" do
    provider =
      script([
        {:ok, asst(nil, [%ToolCall{id: "1", name: "slow", args: {:ok, %{}}}])},
        {:ok, asst("after timeout")}
      ])

    tools = [
      %Tool{
        name: "slow",
        description: "slow",
        parameters: %{"type" => "object", "properties" => %{}},
        run: {SlowTool, :run}
      }
    ]

    {:ok, session} =
      Harness.start_session(provider: provider, tools: tools, tool_timeout_ms: 50)

    assert {:ok, "after timeout"} = Harness.ask(session, "go")
  end

  test "provider error surfaces" do
    err = %Error{kind: :http, message: "nope"}
    provider = script([{:error, err}])
    {:ok, session} = Harness.start_session(provider: provider, tools: [])
    assert {:error, {:provider_error, ^err}} = Harness.ask(session, "go")
  end
end
