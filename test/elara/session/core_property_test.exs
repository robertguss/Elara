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
  alias Elara.Provider.Retry
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
      {3, constant(:provider_error)},
      {1, constant(:terminal_provider_error)},
      {4, constant(:retry_elapsed)},
      {5, tuple({constant(:tool), member_of([:ok, :error, :indeterminate])})},
      {2, constant(:crash)},
      {2, constant(:timeout)},
      {2, constant(:deferred)},
      {1, constant(:usage)},
      {2, constant(:interrupt)},
      {2, constant(:steer)},
      {2,
       tuple(
         {constant(:stale),
          member_of([
            :delta,
            :reply,
            :provider_error,
            :retry_elapsed,
            :tool,
            :crash,
            :timeout,
            :deferred
          ])}
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

  # One retry per provider call keeps both the replay and the exhausted path common.
  @retry %Retry.Policy{
    max_attempts: 2,
    base_delay_ms: 1,
    max_delay_ms: 2,
    max_total_wait_ms: 4
  }

  defp new_core,
    do:
      Core.new(%Core.Config{
        system: "sys",
        tools: tools(),
        max_iterations: @max_iterations,
        retry: @retry
      })

  defp live_ref(%Core.State{phase: {:calling_provider, ref, _}}), do: ref
  defp live_ref(%Core.State{phase: {:awaiting_retry, ref, _, _, _}}), do: ref
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

  # A transport failure is retryable; a 400 never is.
  defp concrete(:provider_error, _core, ref, n),
    do: {{:provider_result, ref, {:error, %Provider.Error{kind: :transport, message: "x"}}}, n}

  defp concrete(:terminal_provider_error, _core, ref, n),
    do:
      {{:provider_result, ref,
        {:error, %Provider.Error{kind: :http, status: 400, message: "bad"}}}, n}

  defp concrete(:retry_elapsed, _core, ref, n), do: {{:retry_elapsed, ref}, n}

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

        {:awaiting_retry, ref, _, _, _} ->
          {:retry_elapsed, ref}

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

  property "no call is dispatched twice or gets two results at any step" do
    check all(actions <- actions(), max_runs: @runs) do
      %{core: core, steps: steps} = run(actions)
      {drained_core, drained} = drain(core)

      {_refs, _dispatched, resulted} =
        Enum.reduce(steps ++ drained, {MapSet.new(), MapSet.new(), MapSet.new()}, fn step,
                                                                                     {refs,
                                                                                      dispatched,
                                                                                      resulted} ->
          Enum.reduce(step.effects, {refs, dispatched, resulted}, fn
            {:run_tool, ref, call, _tool}, {refs, dispatched, resulted} ->
              refute MapSet.member?(refs, ref), "ref #{ref} dispatched twice"
              refute MapSet.member?(dispatched, call.id), "call #{call.id} dispatched twice"

              refute MapSet.member?(resulted, call.id),
                     "call #{call.id} dispatched after its result"

              {MapSet.put(refs, ref), MapSet.put(dispatched, call.id), resulted}

            {:emit, {:message_appended, %ToolResult{call_id: id}}},
            {refs, dispatched, resulted} ->
              refute MapSet.member?(resulted, id), "call #{id} emitted two results"
              {refs, dispatched, MapSet.put(resulted, id)}

            _effect, acc ->
              acc
          end)
        end)

      # Every result in the drained history was emitted exactly once, and vice versa.
      history_ids =
        for %ToolResult{call_id: id} <- drained_core.history, into: MapSet.new(), do: id

      assert resulted == history_ids
    end
  end

  property "calls rejected without dispatch get an error result" do
    check all(actions <- actions(), max_runs: @runs) do
      %{core: core, steps: steps} = run(actions)
      {drained, drain_steps} = drain(core)

      dispatched =
        for step <- steps ++ drain_steps,
            {:run_tool, _ref, call, _tool} <- step.effects,
            into: MapSet.new(),
            do: call.id

      for %ToolResult{call_id: id, outcome: outcome} <- drained.history,
          not MapSet.member?(dispatched, id) do
        assert {:error, _} = outcome
      end
    end
  end

  property "each turn starts at most max_iterations provider calls" do
    check all(actions <- actions(), max_runs: @runs) do
      %{core: core, steps: steps} = run(actions)
      {_core, drained} = drain(core)

      (steps ++ drained)
      |> Enum.flat_map(&first_attempts/1)
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

  # A retry re-dispatches the same iteration, so only an attempt that is not a
  # replay counts against the iteration limit.
  defp first_attempts(%{fact: {:retry_elapsed, _}, effects: effects}),
    do: Enum.reject(effects, &match?({:call_provider, _, _}, &1))

  defp first_attempts(%{effects: effects}), do: effects

  property "retries stay inside the configured attempt and wait bounds" do
    check all(actions <- actions(), max_runs: @runs) do
      %{core: core, steps: steps} = run(actions)
      {drained, drain_steps} = drain(core)

      for step <- steps ++ drain_steps, retry = step.after.retry, retry != nil do
        assert retry.attempts < @retry.max_attempts, inspect(retry)
        assert retry.waited_ms <= @retry.max_total_wait_ms, inspect(retry)
      end

      for step <- steps ++ drain_steps,
          {:await_retry, _ref, min_ms, max_ms} <- step.effects do
        assert min_ms <= max_ms
        assert max_ms <= @retry.max_delay_ms
      end

      assert drained.retry == nil
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

  # ── Coverage and boundary traces ────────────────────────────────────────

  defp reached(%{steps: steps}) do
    Enum.flat_map(steps, fn step ->
      running = match?(%{phase: {:running_tool, _, _, _, _}}, step.before)

      mutating_running =
        match?(%{phase: {:running_tool, _, %ToolCall{name: "change"}, _, _}}, step.before)

      [
        (running and step.fact == :steer) && :steer_during_tool,
        (running and match?({:tool_deferred, _, _}, step.fact) and not step.stale?) && :deferral,
        (mutating_running and step.fact == :interrupt) && :interrupt_running_mutation,
        (mutating_running and match?({t, _} when t == :tool_timeout, step.fact) and
           not step.stale?) &&
          :timeout_running_mutation,
        step.stale? && :stale_fact,
        Enum.any?(step.effects, &match?({:await_retry, _, _, _}, &1)) && :provider_retry,
        (match?({:awaiting_retry, _, _, _, _}, step.before.phase) and
           match?({:retry_elapsed, _}, step.fact) and not step.stale?) && :retry_replayed,
        (match?({:calling_provider, _, _}, step.before.phase) and step.before.retry != nil and
           Enum.any?(
             step.effects,
             &match?({:emit, {:turn_ended, {:provider_error, _}}}, &1)
           )) && :retry_exhausted,
        Enum.any?(step.effects, &match?({:emit, {:turn_ended, :turn_limit}}, &1)) && :turn_limit,
        Enum.any?(
          step.effects,
          &match?(
            {:emit, {:message_appended, %ToolResult{outcome: {:error, "repeated tool call"}}}},
            &1
          )
        ) &&
          :repeated_call_rejected
      ]
      |> Enum.filter(& &1)
    end)
    |> MapSet.new()
  end

  test "generated traces reach the states the properties depend on" do
    counts =
      actions()
      |> Enum.take(2_000)
      |> Enum.map(&reached(run(&1)))
      |> Enum.flat_map(&MapSet.to_list/1)
      |> Enum.frequencies()

    if System.get_env("LAB_PROPERTY_COVERAGE"), do: IO.inspect(counts, label: "traces reaching")

    for state <- [
          :steer_during_tool,
          :deferral,
          :interrupt_running_mutation,
          :timeout_running_mutation,
          :stale_fact,
          :provider_retry,
          :retry_replayed,
          :retry_exhausted,
          :turn_limit,
          :repeated_call_rejected
        ] do
      assert Map.get(counts, state, 0) >= 5,
             "only #{Map.get(counts, state, 0)} traces reach #{state}"
    end
  end

  defp results_by_id(core),
    do: Map.new(for %ToolResult{} = r <- core.history, do: {r.call_id, r.outcome})

  test "boundary: steering during a tool supersedes calls not yet started" do
    %{core: core, steps: steps} =
      run([
        {:ask, "a"},
        {:reply, [{"change", 0, false}, {"look", 1, false}], :match, ""},
        :steer,
        {:tool, :ok}
      ])

    assert %{"c0" => {:ok, "out"}, "c1" => {:error, "not started: superseded by steering input"}} =
             results_by_id(core)

    assert {:emit, {:turn_ended, :interrupted}} in emitted(steps)
    assert core.phase == :idle
  end

  test "boundary: a deferred call is not executed and the turn continues" do
    %{core: core} = run([{:ask, "a"}, {:reply, [{"change", 0, false}], :match, ""}, :deferred])

    assert %{"c0" => {:error, "Not executed: " <> _}} = results_by_id(core)
    assert {:calling_provider, _ref, 2} = core.phase
  end

  test "boundary: the iteration limit ends the turn" do
    reply = fn arg -> {:reply, [{"look", arg, false}], :match, ""} end

    %{core: core, steps: steps} =
      run([
        {:ask, "a"},
        reply.(0),
        {:tool, :ok},
        reply.(1),
        {:tool, :ok},
        reply.(0),
        {:tool, :ok}
      ])

    assert {:emit, {:turn_ended, :turn_limit}} in emitted(steps)
    assert Enum.count(emitted(steps), &match?({:call_provider, _, _}, &1)) == @max_iterations
    assert core.phase == :idle
  end

  for {fact, label} <- [interrupt: "interrupted", timeout: "timed out", crash: "tool crashed"] do
    test "boundary: #{fact} of a running mutating call is indeterminate, of a read is an error" do
      fact = unquote(fact)
      label = unquote(label)

      %{core: mutating} = run([{:ask, "a"}, {:reply, [{"change", 0, false}], :match, ""}, fact])
      assert %{"c0" => {:indeterminate, message}} = results_by_id(mutating)
      assert message =~ label

      %{core: reading} = run([{:ask, "a"}, {:reply, [{"look", 0, false}], :match, ""}, fact])
      assert %{"c0" => {:error, message}} = results_by_id(reading)
      assert message =~ label
    end
  end
end
