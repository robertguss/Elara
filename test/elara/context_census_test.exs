defmodule Elara.ContextCensusTest do
  use ExUnit.Case, async: true
  alias Elara.FlightRecorder.{ContextCensus, Recording}

  # Deliberately asymmetric reserves: total is estimate + 17. Expectations below
  # are independent of the comparator and do not call the live budget calculator.
  defp observation(sequence, estimate, opts \\ []) do
    %{
      type: :context_decision,
      version: 1,
      semantics: :fixed_reserves_v1,
      effect: %{recording_id: "fixture", sequence: sequence, effect_index: 1},
      segment: Keyword.get(opts, :segment, 0),
      estimate_tokens: estimate,
      limit: 100,
      reserves: %{"output" => 2, "handoff" => 3, "tools" => 5, "uncertainty" => 7},
      frozen: Keyword.get(opts, :frozen, false),
      branch: Keyword.get(opts, :branch, :attempt_dispatch)
    }
  end

  defp recording(observations) do
    %Recording{
      header: %{format_version: 1, recording_id: "fixture", capabilities: %{context_gate: 1}},
      segments:
        observations
        |> Enum.map(& &1.segment)
        |> Enum.uniq()
        |> Enum.map(&%{segment: &1, reason: if(&1 == 0, do: :init, else: :history_rebased)}),
      transitions:
        Enum.map(observations, fn observation ->
          %{
            id: Map.delete(observation.effect, :effect_index),
            segment: observation.segment,
            effects: [
              %{index: 0, value: %{kind: :emit}},
              %{index: 1, value: %{kind: :call_provider}}
            ]
          }
        end),
      context_decisions: observations
    }
  end

  defp segment(recording, cutoff) do
    assert {:ok, %{cutoff: ^cutoff, segments: [segment]}} =
             ContextCensus.compare(recording, cutoff)

    segment
  end

  test "inclusive cutoff boundaries, baseline handoff and frozen precedence" do
    for {estimate, status} <- [{62, :match}, {63, :diverged}, {64, :diverged}] do
      result = segment(recording([observation(1, estimate)]), 80)
      assert result.status == status
      assert result.compared == 1
      assert result.excluded == 0
    end

    result = segment(recording([observation(1, 83, branch: :attempt_handoff)]), 101)

    assert result.divergence == %{
             effect: %{recording_id: "fixture", sequence: 1, effect_index: 1},
             baseline: :attempt_handoff,
             candidate: :attempt_dispatch
           }

    frozen = recording([observation(1, 83, frozen: true, branch: :interrupt_frozen)])
    assert segment(frozen, 1).status == :match
    assert segment(frozen, 1000).status == :match
  end

  test "stop at first divergence or gap, independently conditional on each segment seed" do
    observations = [
      observation(1, 20),
      observation(2, 63),
      observation(3, 25),
      observation(4, 10, segment: 1)
    ]

    full = recording(observations)
    assert {:ok, %{segments: [first, second]}} = ContextCensus.compare(full, 80)
    assert %{status: :diverged, eligible: 3, compared: 2, excluded: 1} = first
    assert first.divergence.effect.sequence == 2
    assert %{status: :match, compared: 1, reason: :history_rebased} = second

    missing = %{full | context_decisions: List.delete_at(observations, 1)}
    assert {:ok, %{segments: [first, second]}} = ContextCensus.compare(missing, 80)
    assert %{status: :unknown, eligible: 3, compared: 1, excluded: 2} = first
    assert first.unknown.reason == :missing_observation
    assert second.status == :match

    # Malformed accounting after a divergence is excluded, not evaluated as an
    # alternative-world continuation. The prefix result remains the same.
    suffix = List.update_at(observations, 2, &Map.delete(&1, :reserves))

    assert {:ok, %{segments: [%{status: :diverged, compared: 2}, _]}} =
             ContextCensus.compare(%{full | context_decisions: suffix}, 80)
  end

  test "unsupported, incomplete and empty recordings do not claim a policy match" do
    full = recording([observation(1, 20)])
    legacy = %{full | header: Map.delete(full.header, :capabilities)}
    assert {:error, :unsupported_context_observations} = ContextCensus.compare(legacy, 100)

    assert {:error, :incomplete_recording} =
             ContextCensus.compare(%{full | incomplete: [%{}]}, 100)

    for cutoff <- [0, -1, 1.5, "100"],
        do: assert({:error, :invalid_cutoff} = ContextCensus.compare(full, cutoff))

    empty = %{full | transitions: [], context_decisions: []}
    assert %{status: :no_decisions, compared: 0, eligible: 0} = segment(empty, 100)
  end

  test "invalid links and duplicates fail closed rather than disappearing from coverage" do
    one = observation(1, 20)
    full = recording([one])

    for decisions <- [
          [one, one],
          [put_in(one.effect.effect_index, 0)],
          [put_in(one.effect.recording_id, "other")],
          [%{one | segment: 9}],
          [Map.delete(one, :effect)]
        ] do
      assert {:error, :invalid_context_reference} =
               ContextCensus.compare(%{full | context_decisions: decisions}, 100)
    end

    assert {:error, :invalid_context_reference} =
             ContextCensus.compare(
               %{full | transitions: full.transitions ++ full.transitions},
               100
             )
  end

  test "missing arithmetic, unknown versions and inconsistent baselines are unknown" do
    one = observation(1, 20)
    full = recording([one])

    for {bad, reason} <- [
          {Map.delete(one, :reserves), :invalid_observation},
          {%{one | reserves: Map.delete(one.reserves, "uncertainty")}, :invalid_observation},
          {%{one | reserves: Map.put(one.reserves, "extra", 1)}, :invalid_observation},
          {%{one | estimate_tokens: -1}, :invalid_observation},
          {%{one | limit: 0}, :invalid_observation},
          {%{one | frozen: nil}, :invalid_observation},
          {%{one | version: 2}, :unsupported_semantics},
          {%{one | semantics: :other}, :unsupported_semantics},
          {%{one | branch: :attempt_handoff}, :inconsistent_baseline}
        ] do
      result = segment(%{full | context_decisions: [bad]}, 80)
      assert %{status: :unknown, compared: 0, excluded: 1, unknown: %{reason: ^reason}} = result
    end
  end

  test "malformed expected effects cannot hide a gap before a later matching gate" do
    full = recording([observation(1, 20), observation(2, 20)])
    [first, second] = full.transitions

    for effects <- [
          List.update_at(first.effects, 1, &Map.delete(&1, :index)),
          List.update_at(first.effects, 1, &Map.delete(&1, :value)),
          List.update_at(first.effects, 1, &put_in(&1.value, %{})),
          List.update_at(first.effects, 1, &put_in(&1.value.kind, :unexpected)),
          List.update_at(first.effects, 1, &Map.put(&1, :index, 0)),
          %{},
          nil
        ] do
      broken = %{
        full
        | transitions: [%{first | effects: effects}, second],
          context_decisions: tl(full.context_decisions)
      }

      assert {:error, :invalid_context_reference} = ContextCensus.compare(broken, 100)
    end
  end
end
