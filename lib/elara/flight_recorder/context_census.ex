defmodule Elara.FlightRecorder.ContextCensus do
  @moduledoc """
  Offline context-cutoff comparison, conditional on each recorded segment's seed.

  `compare(recording_or_path, cutoff)` holds the observed estimate and reserves
  fixed and compares their sum with a positive integer cutoff (inclusive).
  This does not simulate a different context limit, successful handoff/dispatch,
  or outcomes after divergence. No Core, provider, tool or catalog is invoked.

  Each segment stops at its first different branch or unknown observation.
  `compared` includes a divergent decision; `excluded` includes an unknown
  decision and its suffix. Later segments are independent baseline conditions,
  never a continuation of the counterfactual. Legacy flights are unsupported.
  """

  alias Elara.FlightRecorder
  alias Elara.FlightRecorder.Recording

  def compare(recording, cutoff)

  def compare(_, cutoff) when not is_integer(cutoff) or cutoff <= 0,
    do: {:error, :invalid_cutoff}

  def compare(path, cutoff) when is_binary(path) do
    with {:ok, recording} <- FlightRecorder.load(path), do: compare(recording, cutoff)
  end

  def compare(%Recording{} = recording, cutoff) do
    with :ok <- supported(recording),
         {:ok, gates} <- gates(recording),
         {:ok, observations} <- observations(recording, gates) do
      segments =
        Enum.map(recording.segments, fn segment ->
          expected = Enum.filter(gates, &(&1.segment == segment.segment))

          result = %{
            segment: segment.segment,
            reason: segment.reason,
            status: if(expected == [], do: :no_decisions, else: :match),
            eligible: length(expected),
            compared: 0,
            excluded: length(expected),
            divergence: nil,
            unknown: nil
          }

          Enum.reduce_while(expected, result, fn gate, result ->
            case decision(Map.get(observations, gate.effect), cutoff) do
              {:ok, baseline, candidate} ->
                result = %{result | compared: result.compared + 1, excluded: result.excluded - 1}

                if baseline == candidate do
                  {:cont, result}
                else
                  {:halt,
                   %{
                     result
                     | status: :diverged,
                       divergence: %{
                         effect: gate.effect,
                         baseline: baseline,
                         candidate: candidate
                       }
                   }}
                end

              {:error, reason} ->
                {:halt,
                 %{result | status: :unknown, unknown: %{effect: gate.effect, reason: reason}}}
            end
          end)
        end)

      {:ok, %{cutoff: cutoff, semantics: :fixed_reserves_v1, segments: segments}}
    end
  end

  defp supported(%Recording{
         header: %{format_version: 1, capabilities: %{context_gate: 1}},
         incomplete: []
       }),
       do: :ok

  defp supported(%Recording{incomplete: [_ | _]}), do: {:error, :incomplete_recording}
  defp supported(_), do: {:error, :unsupported_context_observations}

  defp gates(recording) do
    segments = Enum.map(recording.segments, & &1.segment)

    if length(Enum.uniq(segments)) == length(segments) do
      Enum.reduce_while(recording.transitions, {:ok, [], 0}, fn transition,
                                                                {:ok, gates, previous} ->
        case transition_gates(transition, recording.header.recording_id, segments, previous) do
          {:ok, next, sequence} -> {:cont, {:ok, gates ++ next, sequence}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, gates, _} -> {:ok, gates}
        error -> error
      end
    else
      {:error, :invalid_context_reference}
    end
  end

  # Validate the coverage denominator before filtering: a malformed envelope
  # must not silently erase a provider gate and make its missing observation pass.
  defp transition_gates(
         %{
           id: %{recording_id: recording_id, sequence: sequence} = id,
           segment: segment,
           effects: effects
         },
         recording_id,
         segments,
         previous
       )
       when is_integer(sequence) and sequence > previous and map_size(id) == 2 and
              is_list(effects) do
    if segment in segments do
      effects
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], sequence}, fn
        {%{index: index, value: %{kind: kind}}, index}, {:ok, gates, sequence}
        when kind in [:call_provider, :run_tool, :emit] ->
          next =
            if kind == :call_provider,
              do: gates ++ [%{effect: Map.put(id, :effect_index, index), segment: segment}],
              else: gates

          {:cont, {:ok, next, sequence}}

        _, _ ->
          {:halt, {:error, :invalid_context_reference}}
      end)
    else
      {:error, :invalid_context_reference}
    end
  end

  defp transition_gates(_, _, _, _), do: {:error, :invalid_context_reference}

  defp observations(recording, gates) do
    expected = Map.new(gates, &{&1.effect, &1.segment})

    Enum.reduce_while(recording.context_decisions, {:ok, %{}}, fn
      %{effect: effect, segment: segment} = observation, {:ok, seen} ->
        if Map.has_key?(expected, effect) and expected[effect] == segment and
             not Map.has_key?(seen, effect) do
          {:cont, {:ok, Map.put(seen, effect, observation)}}
        else
          {:halt, {:error, :invalid_context_reference}}
        end

      _, _ ->
        {:halt, {:error, :invalid_context_reference}}
    end)
  end

  defp decision(nil, _), do: {:error, :missing_observation}

  defp decision(%{version: 1, semantics: :fixed_reserves_v1} = observation, cutoff) do
    case observation do
      %{
        estimate_tokens: estimate,
        limit: limit,
        reserves:
          %{
            "output" => output,
            "handoff" => handoff,
            "tools" => tools,
            "uncertainty" => uncertainty
          } = reserves,
        frozen: frozen,
        branch: baseline
      }
      when is_integer(estimate) and estimate >= 0 and is_integer(limit) and limit > 0 and
             is_integer(output) and output >= 0 and is_integer(handoff) and handoff >= 0 and
             is_integer(tools) and tools >= 0 and is_integer(uncertainty) and uncertainty >= 0 and
             is_boolean(frozen) and map_size(reserves) == 4 ->
        total = estimate + output + handoff + tools + uncertainty

        if branch(frozen, total, limit) == baseline,
          do: {:ok, baseline, branch(frozen, total, cutoff)},
          else: {:error, :inconsistent_baseline}

      _ ->
        {:error, :invalid_observation}
    end
  end

  defp decision(_, _), do: {:error, :unsupported_semantics}

  defp branch(true, _, _), do: :interrupt_frozen
  defp branch(false, total, cutoff) when total >= cutoff, do: :attempt_handoff
  defp branch(false, _, _), do: :attempt_dispatch
end
