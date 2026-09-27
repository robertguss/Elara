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

  test "rules script a response for a matching request and fall through otherwise" do
    bad = %Provider.Error{kind: :bad_response, message: "scripted"}

    rules = [
      {&match?([%Message.User{text: "start"}], &1), {:tool, "job", %{"action" => "start"}}},
      {fn messages -> match?(%ToolResult{name: "job"}, List.last(messages)) end, {:error, bad}}
    ]

    {_m, config} = Simulated.new(seed: 1, id: "r", profile: @fast ++ [rules: rules])
    config = %{config | collector: self()}

    assert {:ok, %Assistant{tool_calls: [%ToolCall{name: "job", args: {:ok, args}} = call]},
            config} =
             Simulated.stream(config, request([Message.user("start")]), fn _ -> :ok end)

    assert args == %{"action" => "start"}
    assert_received {:lab_choice, "r", 1, {:rule, 0}}

    history = [Message.user("start"), elem(Message.assistant(nil, [call]), 1)]
    history = history ++ [Message.tool_result(call, {:ok, "running"})]

    assert {:error, ^bad, config} =
             Simulated.stream(config, request(history), fn _ -> :ok end)

    assert_received {:lab_choice, "r", 2, {:rule, 1}}

    assert {:ok, %Assistant{text: text}, _} =
             Simulated.stream(config, request([Message.user("other")]), fn _ -> :ok end)

    assert byte_size(text) == 12
    assert_received {:lab_choice, "r", 3, :answer}
  end

  test "a matched rule does not shift the seeded choices or text of later requests" do
    bad = %Provider.Error{kind: :bad_response, message: "scripted"}
    turn2 = [{&match?(%Message.User{text: "turn 2"}, List.last(&1)), {:error, bad}}]
    profile = @fast ++ [errors: [rate_limited: 0.4]]

    {plain, _} = converse(Simulated.new(seed: 9, id: "k", profile: profile), 8)
    {ruled, _} = converse(Simulated.new(seed: 9, id: "k", profile: profile ++ [rules: turn2]), 8)

    assert Enum.at(ruled, 1) == {:error, :bad_response, nil}
    assert Enum.at(plain, 1) != Enum.at(ruled, 1)
    assert Enum.drop(plain, 2) == Enum.drop(ruled, 2)
  end

  describe "stamped deltas and the request ledger" do
    defp ledger, do: :ets.new(:ledger, [:ordered_set, :public])

    test "stamped deltas name their request and index and keep their byte size" do
      profile = [ttft_ms: 1, deltas_per_sec: 1000, delta_bytes: 20, answer_deltas: 3]
      profile = profile ++ [stamp_deltas: true]
      {_m, config} = Simulated.new(seed: 1, id: "st", profile: profile)
      parent = self()

      sink = fn part ->
        send(parent, {:part, part})
        :ok
      end

      assert {:ok, %Assistant{text: text}, config} =
               Simulated.stream(config, request([Message.user("a")]), sink)

      assert {:ok, _, _} = Simulated.stream(config, request([Message.user("b")]), sink)

      parts = for _ <- 1..6, do: receive(do: ({:part, part} -> part))

      assert parts ==
               Enum.map(
                 ["1:0", "1:1", "1:2", "2:0", "2:1", "2:2"],
                 &String.pad_trailing(&1, 20, ".")
               )

      assert text == Enum.join(Enum.take(parts, 3))
    end

    test "a stamp that cannot fit its delta is refused when the provider is built" do
      profile = [delta_bytes: 12, answer_deltas: 250, stamp_deltas: true]

      assert_raise ArgumentError, ~r/stamp/, fn ->
        Simulated.new(seed: 1, id: "x", profile: profile)
      end

      profile = Keyword.put(profile, :delta_bytes, 13)
      assert {Simulated, _} = Simulated.new(seed: 1, id: "x", profile: profile)
    end

    test "the ledger row precedes the first delta and completes after the last" do
      table = ledger()
      parent = self()
      profile = [ttft_ms: 1, deltas_per_sec: 1000, delta_bytes: 20, answer_deltas: 3]
      {_m, config} = Simulated.new(seed: 1, id: "l", profile: profile, ledger: table)

      sink = fn _part ->
        send(parent, {:row_at_delta, :ets.lookup(table, {"l", 1})})
        :ok
      end

      started = System.monotonic_time(:millisecond)
      assert {:ok, _, _} = Simulated.stream(config, request([Message.user("a")]), sink)

      rows = for _ <- 1..3, do: receive(do: ({:row_at_delta, [row]} -> row))
      assert Enum.map(rows, &elem(&1, 3)) == [1, 2, 3]
      assert Enum.all?(rows, &(elem(&1, 4) == :started))
      assert [{{"l", 1}, at, :answer, 3, :completed}] = :ets.lookup(table, {"l", 1})
      assert (at - started) in 0..5
    end

    test "the ledger row is written before the start fault hook and stays started when killed" do
      table = ledger()
      parent = self()

      hook = fn :provider_started, key ->
        send(parent, {:row_at_hook, :ets.lookup(table, {"k", 1})})
        if key == "k:1", do: Process.sleep(:infinity)
      end

      profile = [ttft_ms: 1, deltas_per_sec: 1000, answer_deltas: 3]
      {_m, config} = Simulated.new(seed: 1, id: "k", profile: profile, ledger: table, fault: hook)

      task = Task.async(fn -> Simulated.stream(config, request([Message.user("a")]), & &1) end)
      assert_receive {:row_at_hook, [{{"k", 1}, _at, :answer, 0, :started}]}
      Task.shutdown(task, :brutal_kill)

      assert [{{"k", 1}, _at, :answer, 0, :started}] = :ets.lookup(table, {"k", 1})
    end

    test "tool-call requests complete their row; no options leave text and digests unchanged" do
      table = ledger()
      plan = [{"read", %{"path" => "a"}}]
      profile = @fast ++ [tool_plan: plan, tool_rounds: 1]
      {_m, config} = Simulated.new(seed: 7, id: "t", profile: profile, ledger: table)

      assert {:ok, %Assistant{tool_calls: [_]}, _} =
               Simulated.stream(config, request([Message.user("a")]), fn _ -> :ok end)

      assert [{{"t", 1}, _, {:tool, "read"}, 0, :completed}] = :ets.lookup(table, {"t", 1})

      plain = converse(Simulated.new(seed: 7, id: "s1", profile: @fast), 2)
      ledgered = converse(Simulated.new(seed: 7, id: "s1", profile: @fast, ledger: ledger()), 2)
      assert plain == ledgered
    end
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
