defmodule Elara.TestSupport.LiveSessionDriver do
  @moduledoc """
  Passive, opt-in experiment observation using public session APIs.

  A nil prompt observes retained work. A new prompt ignores older terminal events.
  `resume_inputs: true` authorizes one initial resume; later pauses are returned.
  `pending_jobs` names jobs whose later completion may recover a provider error.
  This helper never replaces a provider, retries a prompt, reopens a session, or
  cancels work on timeout. The caller owns those decisions and cleanup.
  """

  def run(session, prompt, opts) do
    marker = Keyword.fetch!(opts, :completion_marker)
    if not is_binary(marker) or marker == "", do: raise(ArgumentError, "nonempty marker required")

    # Give attachments their own lifetime and leave the caller's mailbox untouched.
    Task.async(fn -> observe(session, prompt, marker, opts) end) |> Task.await(:infinity)
  end

  defp observe(session, prompt, marker, opts) do
    started = now()

    state = %{
      session: session,
      marker: marker,
      started: started,
      deadline: started + Keyword.get(opts, :timeout_ms, 180_000),
      pending_jobs: Keyword.get(opts, :pending_jobs, []),
      sessions: [],
      cursors: %{},
      turns: [],
      errors: [],
      actions: [],
      gaps: [],
      event_count: 0,
      terminal: nil,
      inbox: %{},
      metadata: nil,
      outcome: nil
    }

    state = refresh(state)

    cond do
      state.outcome ->
        finish(state)

      state.inbox["paused"] and not Keyword.get(opts, :resume_inputs, false) ->
        finish(%{state | outcome: "paused"})

      true ->
        state = if prompt, do: ask(%{state | terminal: nil}, prompt), else: state

        state =
          if is_nil(state.outcome) and Keyword.get(opts, :resume_inputs, false) do
            result = call(fn -> Elara.resume_inputs(state.session) end)
            state = action(state, "resume_inputs", result)

            if result == :ok,
              do: %{state | terminal: nil},
              else: %{state | outcome: "resume_failed"}
          else
            state
          end

        wait(state)
    end
  end

  defp ask(state, prompt) do
    result = call(fn -> Elara.ask_async(state.session, prompt) end)
    state = action(state, "ask", result)

    case result do
      :ok -> state
      {:error, :busy} -> %{state | outcome: "busy"}
      _ -> %{state | outcome: "submission_failed"}
    end
  end

  defp refresh(state) do
    case call(fn -> Elara.snapshot(state.session) end) do
      %{snapshot: snapshot, incarnation: incarnation} ->
        inbox = snapshot["inbox"]

        metadata = %{
          provider: snapshot["provider_view"]["next_request"],
          context: inbox["context"]
        }

        state = %{state | inbox: inbox, metadata: metadata}
        key = {state.session, incarnation}
        state = if Map.has_key?(state.cursors, key), do: state, else: attach(state, key)
        owner = get_in(inbox, ["handoff", "delivery_owner"])

        cond do
          state.outcome ->
            state

          is_binary(owner) and owner != state.session and
              get_in(inbox, ["handoff", "stage"]) == "started" ->
            if Enum.any?(state.sessions, &(&1.id == owner)) do
              %{state | outcome: "ownership_cycle"}
            else
              refresh(%{state | session: owner, terminal: nil})
            end

          true ->
            state
        end

      error ->
        unavailable(state, error)
    end
  end

  defp attach(state, {id, incarnation} = key) do
    case call(fn -> Elara.attach(id, :observe, 0, incarnation) end) do
      {:ok, attached} ->
        state = %{
          state
          | sessions:
              state.sessions ++ [%{id: id, incarnation: incarnation, initial: state.metadata}],
            cursors: Map.put(state.cursors, key, 0)
        }

        Enum.reduce(attached.replay, state, fn {seq, event}, acc ->
          event(acc, key, seq, event)
        end)

      error ->
        unavailable(state, error)
    end
  end

  defp wait(%{outcome: outcome} = state) when not is_nil(outcome), do: finish(state)

  defp wait(state) do
    state = refresh(state)
    handoff = state.inbox["handoff"]

    cond do
      state.outcome ->
        finish(state)

      handoff && handoff["stage"] in ["failed", "stopped"] ->
        finish(%{state | outcome: "handoff_" <> handoff["stage"]})

      handoff ->
        receive_event(state)

      state.inbox["paused"] ->
        finish(%{state | outcome: "paused"})

      match?({:completed, _}, state.terminal) ->
        {:completed, text} = state.terminal

        if String.contains?(text || "", state.marker),
          do: finish(%{state | outcome: "complete"}),
          else: receive_event(%{state | terminal: nil})

      match?({:provider_error, _}, state.terminal) ->
        if pending?(state),
          do: receive_event(%{state | terminal: nil}),
          else: finish(%{state | outcome: "provider_error"})

      state.terminal != nil ->
        finish(%{state | outcome: "turn_failed"})

      true ->
        receive_event(state)
    end
  end

  defp receive_event(state) do
    remaining = state.deadline - now()

    if remaining <= 0 do
      finish(%{state | outcome: "driver_deadline"})
    else
      receive do
        {:elara_event, id, incarnation, seq, value} ->
          state = event(state, {id, incarnation}, seq, value)

          # Streaming deltas do not need another full transcript snapshot.
          if match?({:turn_ended, _}, value) or match?({:turn_ended, _, _}, value),
            do: wait(state),
            else: receive_event(state)
      after
        min(remaining, 100) -> wait(state)
      end
    end
  end

  defp event(state, {id, _} = key, seq, value) do
    previous = Map.get(state.cursors, key)

    if previous == nil or seq <= previous do
      state
    else
      gaps =
        if seq > previous + 1,
          do: state.gaps ++ [%{session: id, from: previous + 1, to: seq - 1}],
          else: state.gaps

      state = %{
        state
        | cursors: Map.put(state.cursors, key, seq),
          event_count: state.event_count + 1,
          gaps: gaps
      }

      case value do
        {:turn_started, _} when id == state.session -> %{state | terminal: nil}
        {:turn_ended, outcome} -> turn(state, id, outcome)
        {:turn_ended, outcome, :streamed} -> turn(state, id, outcome)
        _ -> state
      end
    end
  end

  defp turn(state, id, outcome) do
    public =
      case outcome do
        {:completed, text} -> %{outcome: "completed", text: text}
        {:provider_error, error} -> %{outcome: "provider_error", error: inspect(error)}
        other -> %{outcome: inspect(other)}
      end

    record = Map.merge(public, %{session: id, at_ms: now() - state.started})

    errors =
      if match?({:provider_error, _}, outcome), do: state.errors ++ [record], else: state.errors

    %{
      state
      | turns: state.turns ++ [record],
        errors: errors,
        terminal: if(id == state.session, do: outcome, else: state.terminal)
    }
  end

  defp pending?(state) do
    Enum.any?(state.inbox["entries"] || [], &(&1["state"] in ["accepted", "queued"])) or
      Enum.any?(state.pending_jobs, fn id ->
        ctx = %Elara.Tool.Ctx{
          session_id: state.session,
          cwd: Elara.cwd(state.session),
          tool_name: "test_job"
        }

        case Elara.TestJobs.run(%{"action" => "status", "job_id" => id}, ctx) do
          {:ok, json} -> JSON.decode!(json)["status"] == "running"
          _ -> false
        end
      end)
  end

  defp action(state, name, result),
    do: %{
      state
      | actions:
          state.actions ++ [%{action: name, session: state.session, result: inspect(result)}]
    }

  defp unavailable(state, error),
    do: %{
      state
      | outcome: "session_unavailable",
        errors: state.errors ++ [%{error: inspect(error)}]
    }

  defp finish(state) do
    Map.take(state, [
      :session,
      :outcome,
      :sessions,
      :turns,
      :errors,
      :actions,
      :gaps,
      :event_count
    ])
    |> Map.merge(%{final: state.metadata, duration_ms: now() - state.started})
  end

  defp call(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:session_call_exit, inspect(reason)}}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
