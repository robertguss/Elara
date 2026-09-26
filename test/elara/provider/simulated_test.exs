defmodule Elara.Provider.SimulatedTest do
  use ExUnit.Case, async: true

  alias Elara.Message
  alias Elara.Message.{Assistant, ToolCall, ToolResult}
  alias Elara.Provider
  alias Elara.Provider.Simulated

  @fast [ttft_ms: 5, deltas_per_sec: 1000, delta_bytes: 4, answer_deltas: 3]

  defp request(messages), do: %Provider.Request{system: "", messages: messages, tools: []}

  # Drive one simulated "session" through `turns` user turns, answering every
  # tool call with success. Returns the choices and final texts.
  defp converse({module, config}, turns) do
    Enum.reduce(1..turns, {config, [], []}, fn turn, {config, history, log} ->
      history = history ++ [Message.user("turn #{turn}")]
      step(module, config, history, log)
    end)
    |> then(fn {_config, history, log} -> {Enum.reverse(log), history} end)
  end

  defp step(module, config, history, log) do
    case module.stream(config, request(history), fn _ -> :ok end) do
      {:ok, %Assistant{tool_calls: [%ToolCall{} = call]} = assistant, config} ->
        result = Message.tool_result(call, {:ok, "done"})
        step(module, config, history ++ [assistant, result], [{:tool, call.name} | log])

      {:ok, %Assistant{text: text} = assistant, config} ->
        {config, history ++ [assistant], [{:answer, text} | log]}

      {:error, error, config} ->
        {config, history, [{:error, error.kind, error.status} | log]}
    end
  end

  test "the same seed and id reproduce the same choices and text" do
    profile = @fast ++ [tool_plan: [{"read", %{"path" => "a"}}, {"bash", %{"command" => "true"}}]]

    first = converse(Simulated.new(seed: 7, id: "s1", profile: profile), 3)
    second = converse(Simulated.new(seed: 7, id: "s1", profile: profile), 3)
    other = converse(Simulated.new(seed: 7, id: "s2", profile: profile), 3)

    assert first == second
    refute elem(first, 0) == elem(other, 0)
  end

  test "each user turn runs the tool plan for tool_rounds calls, then answers" do
    plan = [{"read", %{"path" => "a"}}, {"bash", %{"command" => "true"}}]

    {log, _history} =
      converse(Simulated.new(seed: 1, id: "t", profile: @fast ++ [tool_plan: plan]), 2)

    assert [
             {:tool, "read"},
             {:tool, "bash"},
             {:answer, a},
             {:tool, "read"},
             {:tool, "bash"},
             {:answer, b}
           ] =
             log

    assert byte_size(a) == 12 and byte_size(b) == 12
  end

  test "injected errors follow their configured rates" do
    profile = @fast ++ [answer_deltas: 1, errors: [rate_limited: 0.5, server_error: 0.25]]

    {log, _history} = converse(Simulated.new(seed: 3, id: "e", profile: profile), 400)
    counts = Enum.frequencies_by(log, &elem(&1, 0))

    statuses =
      log |> Enum.filter(&match?({:error, _, _}, &1)) |> Enum.frequencies_by(&elem(&1, 2))

    assert_in_delta statuses[429] / 400, 0.5, 0.08
    assert_in_delta statuses[503] / 400, 0.25, 0.08
    assert counts[:answer] + counts[:error] == 400
  end

  test "disconnects stream nothing, or some deltas, before a transport error" do
    {_m, before} =
      Simulated.new(seed: 1, id: "d", profile: @fast ++ [errors: [disconnect_before: 1.0]])

    {_m, after_} =
      Simulated.new(seed: 1, id: "d", profile: @fast ++ [errors: [disconnect_after: 1.0]])

    parent = self()

    sink = fn part ->
      send(parent, {:part, part})
      :ok
    end

    assert {:error, %Provider.Error{kind: :transport}, _} =
             Simulated.stream(before, request([Message.user("hi")]), sink)

    refute_received {:part, _}

    assert {:error, %Provider.Error{kind: :transport}, _} =
             Simulated.stream(after_, request([Message.user("hi")]), sink)

    assert_received {:part, _}
  end

  test "deltas report intended emission times on the configured schedule" do
    profile = [ttft_ms: 50, deltas_per_sec: 20, delta_bytes: 2, answer_deltas: 4]
    {_m, config} = Simulated.new(seed: 1, id: "sched", profile: profile, collector: self())

    started = System.monotonic_time(:millisecond)

    assert {:ok, %Assistant{}, _} =
             Simulated.stream(config, request([Message.user("hi")]), fn _ -> :ok end)

    assert_received {:lab_choice, "sched", 1, :answer}
    intended = for i <- 0..3, do: receive(do: ({:lab_delta, "sched", 1, ^i, at} -> at))

    assert Enum.map(intended, &(&1 - hd(intended))) == [0, 50, 100, 150]
    assert (hd(intended) - started) in 45..60
  end

  test "a real session completes tool rounds through the simulated provider" do
    dir = Path.join(System.tmp_dir!(), "sim-session-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.txt"), "fixture")
    on_exit(fn -> File.rm_rf!(dir) end)

    read = Enum.find(Elara.Tool.builtins(), &(&1.name == "read"))

    provider =
      Simulated.new(
        seed: 5,
        id: "live",
        profile: @fast ++ [tool_plan: [{"read", %{"path" => "a.txt"}}], tool_rounds: 1]
      )

    {:ok, session} =
      Elara.start_session(
        provider: provider,
        cwd: dir,
        persist: false,
        plugins: [],
        tools: [read]
      )

    assert {:ok, text} = Elara.ask(session, "go")
    assert byte_size(text) == 12

    assert [%ToolResult{outcome: {:ok, "fixture"}}] =
             Enum.filter(Elara.transcript(session), &is_struct(&1, ToolResult))
  end
end
