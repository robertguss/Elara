defmodule Elara.Session.CoreRetryTest do
  @moduledoc """
  ROB-1343: the retry decision inside the pure reducer. Core chooses whether to
  replay a provider attempt and how long to wait; it never waits itself.
  """
  use ExUnit.Case, async: true

  alias Elara.Message
  alias Elara.Provider
  alias Elara.Provider.Retry
  alias Elara.Session.Core
  alias Elara.Tool

  defp config(opts) do
    tools =
      Tool.table([
        %Tool{
          name: "echo",
          description: "echo",
          parameters: %{"type" => "object", "properties" => %{}},
          run: {__MODULE__, :echo}
        }
      ])

    %Core.Config{
      system: "test",
      tools: tools,
      max_iterations: Keyword.get(opts, :max_iterations, 12),
      retry:
        Keyword.get_lazy(opts, :retry, fn ->
          Retry.new(max_attempts: 3, base_delay_ms: 100, max_delay_ms: 1_000)
        end)
    }
  end

  def echo(_args, _ctx), do: {:ok, "ok"}

  defp new(opts \\ []), do: Core.new(config(opts))

  defp asst(text, calls \\ []) do
    {:ok, assistant} = Message.assistant(text, calls)
    assistant
  end

  defp overloaded(opts \\ []),
    do: struct!(%Provider.Error{kind: :http, status: 503, message: "503 overloaded"}, opts)

  defp ask(state), do: Core.step(state, {:ask, "hi"})

  # Fail the live provider call and walk through the scheduled wait.
  defp fail_and_wait(state, error) do
    {:calling_provider, ref, _} = state.phase
    {state, effects} = Core.step(state, {:provider_result, ref, {:error, error}})
    {:awaiting_retry, wait_ref, _, _, _} = state.phase
    {state, more} = Core.step(state, {:retry_elapsed, wait_ref})
    {state, effects ++ more}
  end

  test "a retryable failure with nothing published waits, then repeats the same request" do
    {state, [_started, _appended, {:call_provider, first_ref, request}]} = ask(new())

    {waiting, effects} = Core.step(state, {:provider_result, first_ref, {:error, overloaded()}})

    assert {:awaiting_retry, wait_ref, 1, 2, 100} = waiting.phase
    assert waiting.streaming == nil

    assert [
             {:emit,
              {:provider_retry,
               %{attempt: 2, max_attempts: 3, delay_ms: 100, error: %Provider.Error{status: 503}}}},
             {:await_retry, ^wait_ref, 50, 100}
           ] = effects

    {retrying, effects} = Core.step(waiting, {:retry_elapsed, wait_ref})

    assert {:calling_provider, retry_ref, 1} = retrying.phase
    assert retry_ref != first_ref
    assert [{:call_provider, ^retry_ref, ^request}] = effects
    assert retrying.history == [Message.user("hi")]
  end

  test "a retried turn completes once and appends no duplicate messages" do
    {state, _} = ask(new())
    {state, _} = fail_and_wait(state, overloaded())
    {state, _} = fail_and_wait(state, overloaded())

    assert {:calling_provider, ref, 1} = state.phase
    {state, effects} = Core.step(state, {:provider_result, ref, {:ok, asst("done")}})

    assert Core.idle?(state)
    assert state.retry == nil
    assert state.history == [Message.user("hi"), asst("done")]

    assert [
             {:emit, {:message_appended, %Message.Assistant{text: "done"}}},
             {:emit, {:turn_ended, {:completed, "done"}}}
           ] = effects
  end

  test "exhausting the attempts surfaces the final error, not the first" do
    {state, _} = ask(new())
    {state, _} = fail_and_wait(state, overloaded())
    {state, _} = fail_and_wait(state, overloaded())

    {:calling_provider, ref, _} = state.phase
    last = overloaded(message: "503 still overloaded")
    {state, effects} = Core.step(state, {:provider_result, ref, {:error, last}})

    assert Core.idle?(state)
    assert state.retry == nil
    assert state.history == [Message.user("hi")]
    assert [{:emit, {:turn_ended, {:provider_error, ^last}}}] = effects
  end

  test "a server Retry-After sets the wait exactly, with no jitter window" do
    {state, _} = ask(new())
    {:calling_provider, ref, _} = state.phase
    error = %Provider.Error{kind: :http, status: 429, message: "429", retry_after_ms: 2_500}

    {waiting, effects} = Core.step(state, {:provider_result, ref, {:error, error}})

    assert {:awaiting_retry, wait_ref, 1, 2, 2_500} = waiting.phase
    assert {:await_retry, ^wait_ref, 2_500, 2_500} = List.last(effects)
  end

  test "non-retryable failures end the turn without a wait" do
    terminal = [
      %Provider.Error{kind: :http, status: 401, message: "401 unauthorized"},
      %Provider.Error{kind: :http, status: 400, message: "400 invalid request"},
      %Provider.Error{kind: :resource_limit, message: "context too long"},
      %Provider.Error{kind: :entitlement, message: "no entitlement"},
      %Provider.Error{kind: :crash, message: "provider task crashed"}
    ]

    for error <- terminal do
      {state, _} = ask(new())
      {:calling_provider, ref, _} = state.phase
      {state, effects} = Core.step(state, {:provider_result, ref, {:error, error}})

      assert Core.idle?(state), "#{error.message} should not be retried"
      assert [{:emit, {:turn_ended, {:provider_error, ^error}}}] = effects
    end
  end

  test "a failure after streamed text is surfaced rather than replayed" do
    {state, _} = ask(new())
    {:calling_provider, ref, _} = state.phase
    {state, _} = Core.step(state, {:provider_delta, ref, "partial"})

    {state, effects} = Core.step(state, {:provider_result, ref, {:error, overloaded()}})

    assert Core.idle?(state)
    assert [{:emit, {:turn_ended, {:provider_error, _}, :streamed}}] = effects
  end

  test "a failure after a typed public part is surfaced rather than replayed" do
    part = %{
      "kind" => "final_answer",
      "item_id" => "msg-1",
      "output_index" => 0,
      "part_index" => 0,
      "text" => "shown"
    }

    {state, _} = ask(new())
    {:calling_provider, ref, _} = state.phase
    {state, _} = Core.step(state, {:provider_delta, ref, {:public_content, part}})

    {state, effects} = Core.step(state, {:provider_result, ref, {:error, overloaded()}})

    assert Core.idle?(state)

    assert [
             {:emit, {:message_appended, %Message.Assistant{interrupted: true}}},
             {:emit, {:turn_ended, {:provider_error, _}}}
           ] = effects
  end

  test "interrupt and steer during the wait end the turn once" do
    for fact <- [:interrupt, :steer] do
      {state, _} = ask(new())
      {:calling_provider, ref, _} = state.phase
      {waiting, _} = Core.step(state, {:provider_result, ref, {:error, overloaded()}})
      {:awaiting_retry, wait_ref, _, _, _} = waiting.phase

      {stopped, effects} = Core.step(waiting, fact)

      assert Core.idle?(stopped)
      assert stopped.retry == nil
      assert effects == [{:emit, {:turn_ended, :interrupted}}]

      # A wait that already fired cannot resurrect the abandoned attempt.
      assert {^stopped, []} = Core.step(stopped, {:retry_elapsed, wait_ref})
    end
  end

  test "a stale elapsed ref changes nothing while a wait is live" do
    {state, _} = ask(new())
    {:calling_provider, ref, _} = state.phase
    {waiting, _} = Core.step(state, {:provider_result, ref, {:error, overloaded()}})

    assert {^waiting, []} = Core.step(waiting, {:retry_elapsed, waiting.next_ref + 1_000})
  end

  test "retries do not consume iterations and the budget resets per provider call" do
    {state, _} = ask(new(max_iterations: 2))
    {state, _} = fail_and_wait(state, overloaded())
    {state, _} = fail_and_wait(state, overloaded())

    assert {:calling_provider, ref, 1} = state.phase
    call = %Message.ToolCall{id: "c1", name: "echo", args: {:ok, %{}}}
    {state, _} = Core.step(state, {:provider_result, ref, {:ok, asst(nil, [call])}})

    {:running_tool, tool_ref, _, _, 1} = state.phase
    {state, _} = Core.step(state, {:tool_result, tool_ref, {:ok, "ok"}})

    assert {:calling_provider, _, 2} = state.phase
    assert state.retry == nil

    # The second iteration gets its own attempts rather than inheriting the first's.
    {state, _} = fail_and_wait(state, overloaded())
    assert {:calling_provider, final_ref, 2} = state.phase
    {state, effects} = Core.step(state, {:provider_result, final_ref, {:ok, asst("done")}})

    assert Core.idle?(state)
    assert Enum.any?(effects, &match?({:emit, {:turn_ended, {:completed, "done"}}}, &1))
  end

  test "a disabled policy leaves the first failure unchanged" do
    {state, _} = ask(new(retry: Retry.disabled()))
    {:calling_provider, ref, _} = state.phase
    error = overloaded()
    {state, effects} = Core.step(state, {:provider_result, ref, {:error, error}})

    assert Core.idle?(state)
    assert [{:emit, {:turn_ended, {:provider_error, ^error}}}] = effects
  end

  test "the total wait budget stops retrying even with attempts left" do
    policy = Retry.new(max_attempts: 9, base_delay_ms: 100, max_total_wait_ms: 150)
    {state, _} = ask(new(retry: policy))

    # 100ms, then 50ms clamped to what the budget still allows, then nothing.
    {state, first} = fail_and_wait(state, overloaded())
    assert Enum.any?(first, &match?({:await_retry, _, 50, 100}, &1))

    {state, second} = fail_and_wait(state, overloaded())
    assert Enum.any?(second, &match?({:await_retry, _, 25, 50}, &1))

    {:calling_provider, ref, _} = state.phase
    {state, effects} = Core.step(state, {:provider_result, ref, {:error, overloaded()}})

    assert Core.idle?(state)
    assert [{:emit, {:turn_ended, {:provider_error, _}}}] = effects
  end
end
