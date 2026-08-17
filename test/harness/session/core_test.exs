defmodule Harness.Session.CoreTest do
  use ExUnit.Case, async: true

  alias Harness.Message
  alias Harness.Message.ToolCall
  alias Harness.Provider
  alias Harness.Session.Core
  alias Harness.Tool

  defp config(opts) do
    tools =
      Tool.table([
        %Tool{
          name: "echo",
          description: "echo",
          parameters: %{"type" => "object", "properties" => %{}},
          run: {__MODULE__, :echo}
        },
        %Tool{
          name: "other",
          description: "other",
          parameters: %{"type" => "object", "properties" => %{}},
          run: {__MODULE__, :echo}
        }
      ])

    %Core.Config{
      system: "test",
      tools: tools,
      max_iterations: Keyword.get(opts, :max_iterations, 12),
      max_tool_output_bytes: Keyword.get(opts, :max_tool_output_bytes, 16_384)
    }
  end

  def echo(_args, _ctx), do: {:ok, "ok"}

  defp new(opts \\ []), do: Core.new(config(opts))

  defp ask(state, prompt \\ "hi") do
    Core.step(state, {:ask, prompt})
  end

  defp asst(text, calls \\ []) do
    {:ok, a} = Message.assistant(text, calls)
    a
  end

  defp call(id, name, args \\ {:ok, %{}}) do
    %ToolCall{id: id, name: name, args: args}
  end

  test "row 1: ask from idle appends user and calls provider" do
    {state, effects} = ask(new())

    assert match?({:calling_provider, 1, 1}, state.phase)
    assert [%Message.User{text: "hi"}] = state.history

    assert [
             {:emit, {:turn_started, "hi"}},
             {:emit, {:message_appended, %Message.User{}}},
             {:call_provider, 1, %Provider.Request{}}
           ] = effects
  end

  test "row 2: idle ignores task facts and interrupt" do
    state = new()
    assert {^state, []} = Core.step(state, :interrupt)
    assert {^state, []} = Core.step(state, {:tool_result, 1, {:ok, "x"}})
    assert {^state, []} = Core.step(state, {:provider_result, 1, {:ok, asst("x")}})
  end

  test "row 3: text-only provider result completes the turn" do
    {state, _} = ask(new())
    {state, effects} = Core.step(state, {:provider_result, 1, {:ok, asst("done")}})

    assert Core.idle?(state)
    assert [%Message.User{}, %Message.Assistant{text: "done", tool_calls: []}] = state.history

    assert [
             {:emit, {:message_appended, %Message.Assistant{}}},
             {:emit, {:turn_ended, {:completed, "done"}}}
           ] = effects
  end

  test "row 4a: provider tool calls dispatch first valid tool" do
    {state, _} = ask(new())
    calls = [call("c1", "echo", {:ok, %{"x" => 1}}), call("c2", "other", {:ok, %{}})]
    {state, effects} = Core.step(state, {:provider_result, 1, {:ok, asst(nil, calls)}})

    assert match?({:running_tool, 2, %ToolCall{id: "c1"}, [%ToolCall{id: "c2"}], 1}, state.phase)

    assert [
             {:emit, {:message_appended, %Message.Assistant{}}},
             {:emit, {:tool_started, %ToolCall{id: "c1"}}},
             {:run_tool, 2, %ToolCall{id: "c1"}, %Tool{name: "echo"}}
           ] = effects
  end

  test "row 4b: all-invalid tools append errors and call provider again" do
    {state, _} = ask(new())
    calls = [call("c1", "missing", {:ok, %{}}), call("c2", "echo", {:malformed, "{"})]
    {state, effects} = Core.step(state, {:provider_result, 1, {:ok, asst(nil, calls)}})

    assert match?({:calling_provider, 2, 2}, state.phase)
    assert Enum.count(state.history) == 4

    assert Enum.any?(effects, &match?({:call_provider, 2, _}, &1))

    assert Enum.count(effects, &match?({:emit, {:message_appended, %Message.ToolResult{}}}, &1)) ==
             2
  end

  test "row 5: provider error ends turn without appending assistant" do
    {state, _} = ask(new())
    err = %Provider.Error{kind: :http, message: "500"}
    {state, effects} = Core.step(state, {:provider_result, 1, {:error, err}})

    assert Core.idle?(state)
    assert [%Message.User{}] = state.history
    assert [{:emit, {:turn_ended, {:provider_error, ^err}}}] = effects
  end

  test "row 6: tool result continues to next tool then provider" do
    {state, _} = ask(new())
    calls = [call("c1", "echo"), call("c2", "other")]
    {state, _} = Core.step(state, {:provider_result, 1, {:ok, asst(nil, calls)}})
    {state, effects} = Core.step(state, {:tool_result, 2, {:ok, "one"}})

    assert match?({:running_tool, 3, %ToolCall{id: "c2"}, [], 1}, state.phase)
    assert Enum.any?(effects, &match?({:run_tool, 3, %ToolCall{id: "c2"}, _}, &1))

    {state, effects} = Core.step(state, {:tool_result, 3, {:ok, "two"}})
    assert match?({:calling_provider, 4, 2}, state.phase)
    assert Enum.any?(effects, &match?({:call_provider, 4, _}, &1))
  end

  test "row 7: tool crash becomes error result" do
    {state, _} = ask(new())
    {state, _} = Core.step(state, {:provider_result, 1, {:ok, asst(nil, [call("c1", "echo")])}})
    {state, effects} = Core.step(state, {:tool_crashed, 2, :boom})

    assert [%Message.User{}, %Message.Assistant{}, %Message.ToolResult{outcome: {:error, msg}}] =
             state.history

    assert msg =~ "tool crashed"
    assert Enum.any?(effects, &match?({:call_provider, _, _}, &1))
  end

  test "row 8: tool timeout becomes error result" do
    {state, _} = ask(new())
    {state, _} = Core.step(state, {:provider_result, 1, {:ok, asst(nil, [call("c1", "echo")])}})
    {state, _} = Core.step(state, {:tool_timeout, 2})

    assert %Message.ToolResult{outcome: {:error, "timed out"}} = List.last(state.history)
  end

  test "row 9 I2: interrupt mid-tool synthesizes results for current and remaining" do
    {state, _} = ask(new())
    calls = [call("c1", "echo"), call("c2", "other"), call("c3", "echo")]
    {state, _} = Core.step(state, {:provider_result, 1, {:ok, asst(nil, calls)}})
    {state, effects} = Core.step(state, :interrupt)

    assert Core.idle?(state)

    results =
      state.history
      |> Enum.filter(&match?(%Message.ToolResult{}, &1))

    assert length(results) == 3
    assert Enum.all?(results, &match?(%Message.ToolResult{outcome: {:error, "interrupted"}}, &1))
    assert List.last(effects) == {:emit, {:turn_ended, :interrupted}}

    # Wire-legal: every assistant tool_call has exactly one result
    assert_wire_legal(state.history)
  end

  test "row 10: interrupt while calling provider ends turn" do
    {state, _} = ask(new())
    {state, effects} = Core.step(state, :interrupt)
    assert Core.idle?(state)
    assert [{:emit, {:turn_ended, :interrupted}}] = effects
  end

  test "row 11 I4: mismatched refs are dropped" do
    {state, _} = ask(new())
    assert {^state, []} = Core.step(state, {:provider_result, 99, {:ok, asst("x")}})

    {state, _} = Core.step(state, {:provider_result, 1, {:ok, asst(nil, [call("c1", "echo")])}})
    frozen = state
    assert {^frozen, []} = Core.step(state, {:tool_result, 99, {:ok, "x"}})
    assert {^frozen, []} = Core.step(state, {:tool_timeout, 99})
    assert {^frozen, []} = Core.step(state, {:tool_crashed, 99, :x})
  end

  test "I5: iteration never exceeds max_iterations" do
    {state, _} = ask(new(max_iterations: 1))
    {state, _} = Core.step(state, {:provider_result, 1, {:ok, asst(nil, [call("c1", "echo")])}})
    {state, effects} = Core.step(state, {:tool_result, 2, {:ok, "x"}})

    assert Core.idle?(state)

    assert [
             {:emit, {:message_appended, %Message.ToolResult{}}},
             {:emit, {:turn_ended, :turn_limit}}
           ] =
             effects
  end

  test "output truncation before history append" do
    {state, _} = ask(new(max_tool_output_bytes: 5))
    {state, _} = Core.step(state, {:provider_result, 1, {:ok, asst(nil, [call("c1", "echo")])}})
    {state, _} = Core.step(state, {:tool_result, 2, {:ok, "abcdefgh"}})

    %Message.ToolResult{outcome: {:ok, text}} = List.last(state.history)
    assert text =~ "[truncated"
    assert String.starts_with?(text, "abcde")
    assert String.valid?(text)
  end

  test "truncation does not split a UTF-8 character" do
    {state, _} = ask(new(max_tool_output_bytes: 3))
    {state, _} = Core.step(state, {:provider_result, 1, {:ok, asst(nil, [call("c1", "echo")])}})
    {state, _} = Core.step(state, {:tool_result, 2, {:ok, "éééé"}})

    %Message.ToolResult{outcome: {:ok, text}} = List.last(state.history)
    assert String.valid?(text)
    [kept | _] = String.split(text, "\n")
    assert kept == "é"
    assert text =~ "[truncated"
  end

  test "invalid UTF-8 tool output becomes an error-safe placeholder" do
    {state, _} = ask(new(max_tool_output_bytes: 16_384))
    {state, _} = Core.step(state, {:provider_result, 1, {:ok, asst(nil, [call("c1", "echo")])}})
    {state, _} = Core.step(state, {:tool_result, 2, {:ok, <<255, 216, 1, 2, 3>>}})

    %Message.ToolResult{outcome: {:ok, text}} = List.last(state.history)
    assert String.valid?(text)
    assert text =~ "not valid UTF-8"
    assert is_binary(JSON.encode!(text))
  end

  test "repeated identical tool calls are rejected without run_tool" do
    {state, _} = ask(new())
    args = {:ok, %{"n" => 1}}
    calls = [call("c1", "echo", args), call("c2", "echo", args)]
    {state, _} = Core.step(state, {:provider_result, 1, {:ok, asst(nil, calls)}})
    {state, effects} = Core.step(state, {:tool_result, 2, {:ok, "first"}})

    # Second identical call should append error and go to provider, not run_tool
    assert Enum.any?(effects, fn
             {:emit,
              {:message_appended, %Message.ToolResult{outcome: {:error, "repeated tool call"}}}} ->
               true

             _ ->
               false
           end)

    refute Enum.any?(effects, &match?({:run_tool, _, _, _}, &1))
    assert match?({:calling_provider, _, 2}, state.phase)
  end

  test "stale provider result after interrupt converges idle" do
    {state, _} = ask(new())
    {state, _} = Core.step(state, :interrupt)
    assert Core.idle?(state)
    {state, effects} = Core.step(state, {:provider_result, 1, {:ok, asst("late")}})
    assert Core.idle?(state)
    assert effects == []
    assert [%Message.User{}] = state.history
  end

  defp assert_wire_legal(history) do
    history
    |> Enum.with_index()
    |> Enum.each(fn
      {%Message.Assistant{tool_calls: calls}, idx} when calls != [] ->
        ids = MapSet.new(Enum.map(calls, & &1.id))

        results =
          history
          |> Enum.drop(idx + 1)
          |> Enum.take_while(fn
            %Message.ToolResult{} -> true
            %Message.Assistant{} -> false
            %Message.User{} -> false
          end)
          |> Enum.map(& &1.call_id)
          |> MapSet.new()

        assert MapSet.equal?(ids, results),
               "assistant tool_calls #{inspect(MapSet.to_list(ids))} missing results #{inspect(MapSet.to_list(results))}"

      _ ->
        :ok
    end)
  end
end
