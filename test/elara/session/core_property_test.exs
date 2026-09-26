defmodule Elara.Session.CorePropertyTest do
  @moduledoc """
  RQ-1 (LAB-1): properties of the pure session reducer over generated fact
  sequences. Generation is state-aware: each abstract action is interpreted
  against the current phase, so most facts carry the live ref, `{:stale, _}`
  actions carry a ref that can never be live, and actions that do not apply
  in the current phase exercise the reducer's ignore paths.

  Set LAB_PROPERTY_RUNS for a longer opt-in run (default 200).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Elara.{FlightRecorder, Message, Provider, Tool}
  alias Elara.Message.{Assistant, ToolCall, ToolResult}
  alias Elara.Session.Core

  @max_iterations 3
  @runs String.to_integer(System.get_env("LAB_PROPERTY_RUNS", "200"))

  # ── Generators ──────────────────────────────────────────────────────────

  defp text(min), do: string(:alphanumeric, min_length: min, max_length: 5)

  # A small argument space makes identical consecutive calls likely.
  defp call_spec,
    do: tuple({member_of(["look", "change", "missing"]), integer(0..1), boolean()})

  defp action do
    frequency([
      {4, tuple({constant(:ask), text(1)})},
      {3, tuple({constant(:delta), text(1)})},
      {5,
       tuple(
         {constant(:reply), list_of(call_spec(), max_length: 3),
          member_of([:match, :match, :mismatch]), text(0)}
       )},
      {1, constant(:provider_error)},
      {5, tuple({constant(:tool), member_of([:ok, :error, :indeterminate])})},
      {1, constant(:crash)},
      {1, constant(:timeout)},
      {1, constant(:deferred)},
      {1, constant(:usage)},
      {2, constant(:interrupt)},
      {2, constant(:steer)},
      {2,
       tuple(
         {constant(:stale),
          member_of([:delta, :reply, :provider_error, :tool, :crash, :timeout, :deferred])}
       )},
      {1, constant(:settings)},
      {1, constant(:instruction)},
      {1, constant(:inbox)}
    ])
  end

  defp actions, do: list_of(action(), max_length: 40)

  # ── Interpretation ──────────────────────────────────────────────────────

  defp tools do
    %{
      "look" => %Tool{name: "look", description: "read", parameters: %{}, run: {__MODULE__, :run}},
      "change" => %Tool{
        name: "change",
        description: "write",
        parameters: %{},
        run: {__MODULE__, :run},
        mutating: true
      }
    }
  end

  defp new_core,
    do: Core.new(%Core.Config{system: "sys", tools: tools(), max_iterations: @max_iterations})

  defp live_ref(%Core.State{phase: {:calling_provider, ref, _}}), do: ref
  defp live_ref(%Core.State{phase: {:running_tool, ref, _, _, _}}), do: ref
  defp live_ref(%Core.State{}), do: 0

  # Refs are a positive monotonic counter, so a large offset is never live.
  defp stale_ref(core), do: core.next_ref + 1_000

  defp interpret({:stale, kind}, core, n) do
    {fact, n} = concrete(kind, core, stale_ref(core), n)
    {fact, true, n}
  end

  defp interpret(action, core, n) do
    {fact, n} = concrete(action, core, live_ref(core), n)
    {fact, false, n}
  end

  defp concrete({:ask, prompt}, _core, _ref, n), do: {{:ask, prompt}, n}
  defp concrete({:delta, t}, _core, ref, n), do: {{:provider_delta, ref, t}, n}
  defp concrete(:delta, _core, ref, n), do: {{:provider_delta, ref, "d"}, n}

  defp concrete({:reply, specs, mode, t}, core, ref, n) do
    {calls, n} =
      Enum.map_reduce(specs, n, fn {name, arg, malformed?}, n ->
        args = if malformed?, do: {:malformed, "{"}, else: {:ok, %{"n" => arg}}
        {%ToolCall{id: "c#{n}", name: name, args: args}, n + 1}
      end)

    streamed = if core.streaming, do: core.streaming.text, else: ""

    text =
      cond do
        mode == :mismatch and streamed != "" -> streamed <> "x"
        streamed != "" -> streamed
        t != "" -> t
        calls == [] -> "done"
        true -> nil
      end

    {:ok, assistant} = Message.assistant(text, calls)
    {{:provider_result, ref, {:ok, assistant}}, n}
  end

  defp concrete(:reply, core, ref, n), do: concrete({:reply, [], :match, ""}, core, ref, n)

  defp concrete(:provider_error, _core, ref, n),
    do: {{:provider_result, ref, {:error, %Provider.Error{kind: :transport, message: "x"}}}, n}

  defp concrete({:tool, kind}, _core, ref, n), do: {{:tool_result, ref, {kind, "out"}}, n}
  defp concrete(:tool, core, ref, n), do: concrete({:tool, :ok}, core, ref, n)
  defp concrete(:crash, _core, ref, n), do: {{:tool_crashed, ref, "boom"}, n}
  defp concrete(:timeout, _core, ref, n), do: {{:tool_timeout, ref}, n}
  defp concrete(:deferred, _core, ref, n), do: {{:tool_deferred, ref, "sys2"}, n}
  defp concrete(:usage, _core, ref, n), do: {{:tool_usage, ref, %{"input_tokens" => 1}}, n}
  defp concrete(:interrupt, _core, _ref, n), do: {:interrupt, n}
  defp concrete(:steer, _core, _ref, n), do: {:steer, n}
  defp concrete(:settings, _core, _ref, n), do: {{:provider_settings, %{"model" => "m"}}, n}
  defp concrete(:instruction, _core, _ref, n), do: {{:instruction_context, "sys3"}, n}
  defp concrete(:inbox, _core, _ref, n), do: {:inbox_changed, n}

  # Feed every action through Core and the flight recorder, keeping each step.
  defp run(actions) do
    core = new_core()
    recorder = FlightRecorder.new(core, "prop", "inc", nil)

    {core, recorder, _n, steps} =
      Enum.reduce(actions, {core, recorder, 0, []}, fn action, {core, recorder, n, steps} ->
        {fact, stale?, n} = interpret(action, core, n)
        {recorder, core2, effects} = feed(recorder, core, fact)
        step = %{fact: fact, stale?: stale?, before: core, after: core2, effects: effects}
        {core2, recorder, n, [step | steps]}
      end)

    %{core: core, recorder: recorder, steps: Enum.reverse(steps)}
  end

  defp feed(recorder, core, fact) do
    {recorder, begin} = FlightRecorder.begin_transition(recorder, core, fact)
    {core2, effects} = Core.step(core, fact)
    {recorder, _} = FlightRecorder.complete_transition(recorder, begin, core2, effects)
    {recorder, core2, effects}
  end

  # Answer whatever Core is waiting for until it is idle: the provider with a
  # final text matching any streamed content, and tools with success.
  defp drain(core, steps \\ [], budget \\ 50)
  defp drain(%Core.State{phase: :idle} = core, steps, _budget), do: {core, Enum.reverse(steps)}
  defp drain(core, _steps, 0), do: flunk("Core did not drain: #{inspect(core.phase)}")

  defp drain(core, steps, budget) do
    fact =
      case core.phase do
        {:calling_provider, ref, _} ->
          text = if core.streaming.text == "", do: "final", else: core.streaming.text
          {:ok, assistant} = Message.assistant(text, [])
          {:provider_result, ref, {:ok, assistant}}

        {:running_tool, ref, _, _, _} ->
          {:tool_result, ref, {:ok, "drained"}}
      end

    {core2, effects} = Core.step(core, fact)

    drain(
      core2,
      [%{fact: fact, before: core, after: core2, effects: effects} | steps],
      budget - 1
    )
  end

  # ── Observations ────────────────────────────────────────────────────────

  defp emitted(steps), do: Enum.flat_map(steps, & &1.effects)

  defp turn_event?({:emit, {:turn_started, _}}), do: :started
  defp turn_event?({:emit, {:turn_ended, _}}), do: :ended
  defp turn_event?({:emit, {:turn_ended, _, _}}), do: :ended
  defp turn_event?(_), do: nil

  # Returns :open or :closed, or {:violation, reason} at the first bad event.
  defp turn_protocol(effects) do
    Enum.reduce_while(effects, :closed, fn effect, status ->
      case {turn_event?(effect), status} do
        {nil, status} -> {:cont, status}
        {:started, :closed} -> {:cont, :open}
        {:ended, :open} -> {:cont, :closed}
        {event, status} -> {:halt, {:violation, {event, status}}}
      end
    end)
  end

  defp call_ids(history) do
    for %Assistant{tool_calls: calls} <- history, call <- calls, do: call.id
  end

  defp result_counts(history) do
    history
    |> Enum.filter(&match?(%ToolResult{}, &1))
    |> Enum.frequencies_by(& &1.call_id)
  end

  # ── Properties ──────────────────────────────────────────────────────────

  property "the same facts produce the same states and effects" do
    check all(actions <- actions(), max_runs: @runs) do
      first = run(actions)
      facts = Enum.map(first.steps, & &1.fact)

      {final, effects} =
        Enum.reduce(facts, {new_core(), []}, fn fact, {core, effects} ->
          {core, more} = Core.step(core, fact)
          {core, effects ++ more}
        end)

      assert final == first.core
      assert effects == emitted(first.steps)
    end
  end

  property "stale-ref facts change nothing" do
    check all(actions <- actions(), max_runs: @runs) do
      for step <- run(actions).steps, step.stale? do
        assert step.after == step.before, "stale #{inspect(step.fact)} changed state"
        assert step.effects == [], "stale #{inspect(step.fact)} produced effects"
      end
    end
  end

  property "history is append-only" do
    check all(actions <- actions(), max_runs: @runs) do
      for step <- run(actions).steps do
        assert List.starts_with?(step.after.history, step.before.history)
      end
    end
  end

  property "turns end at most once on every prefix and exactly once after a drain" do
    check all(actions <- actions(), max_runs: @runs) do
      %{core: core, steps: steps} = run(actions)
      status = turn_protocol(emitted(steps))
      refute match?({:violation, _}, status), "turn protocol: #{inspect(status)}"

      {_core, drained} = drain(core)
      assert turn_protocol(emitted(steps ++ drained)) == :closed
    end
  end

  property "each call gets at most one result on every prefix and exactly one after a drain" do
    check all(actions <- actions(), max_runs: @runs) do
      %{core: core} = run(actions)

      counts = result_counts(core.history)
      assert Enum.all?(counts, fn {_id, count} -> count == 1 end), inspect(counts)
      assert MapSet.subset?(MapSet.new(Map.keys(counts)), MapSet.new(call_ids(core.history)))

      {drained, _steps} = drain(core)
      counts = result_counts(drained.history)
      assert Enum.sort(Map.keys(counts)) == Enum.sort(call_ids(drained.history))
      assert Enum.all?(counts, fn {_id, count} -> count == 1 end), inspect(counts)
    end
  end

  property "each turn calls the provider at most max_iterations times" do
    check all(actions <- actions(), max_runs: @runs) do
      %{core: core, steps: steps} = run(actions)
      {_core, drained} = drain(core)

      (steps ++ drained)
      |> emitted()
      |> Enum.chunk_while(
        0,
        fn
          {:emit, {:turn_started, _}}, _count -> {:cont, 0}
          {:call_provider, _, _}, count -> {:cont, count + 1}
          {:emit, {:turn_ended, _}}, count -> {:cont, count, 0}
          {:emit, {:turn_ended, _, _}}, count -> {:cont, count, 0}
          _effect, count -> {:cont, count}
        end,
        fn count -> {:cont, count, 0} end
      )
      |> Enum.each(&assert(&1 <= @max_iterations))
    end
  end

  property "an interrupted, timed-out or crashed running mutating call is indeterminate" do
    check all(actions <- actions(), max_runs: @runs) do
      for %{before: %{phase: {:running_tool, ref, call, _rest, _}}} = step <- run(actions).steps,
          call.name == "change",
          step.fact in [:interrupt, {:tool_timeout, ref}] or
            match?({:tool_crashed, ^ref, _}, step.fact) do
        result =
          Enum.find(step.after.history, &match?(%ToolResult{call_id: id} when id == call.id, &1))

        assert {:indeterminate, _} = result.outcome,
               "#{inspect(step.fact)}: #{inspect(result.outcome)}"
      end
    end
  end

  property "calls not yet started report a truthful non-success" do
    check all(actions <- actions(), max_runs: @runs) do
      for %{before: %{phase: {:running_tool, _ref, _call, rest, _}}} = step <- run(actions).steps,
          step.fact == :interrupt,
          pending <- rest do
        result =
          Enum.find(
            step.after.history,
            &match?(%ToolResult{call_id: id} when id == pending.id, &1)
          )

        assert {:error, _} = result.outcome
      end
    end
  end

  property "recorded facts replay to :match" do
    check all(actions <- actions(), max_runs: @runs) do
      %{recorder: recorder} = run(actions)
      assert {:ok, %{status: :match}} = FlightRecorder.replay(FlightRecorder.snapshot(recorder))
    end
  end
end
