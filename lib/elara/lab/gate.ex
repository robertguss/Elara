defmodule Elara.Lab.Gate do
  @moduledoc "One-shot lifecycle barriers and monitored timing evidence for lab fixtures."
  use GenServer

  alias Elara.Lab.Jobs

  def start_link, do: GenServer.start_link(__MODULE__, nil)

  def hold(gate, point, details \\ %{}),
    do: GenServer.call(gate, {:hold, point, details}, :infinity)

  def release(gate, point), do: GenServer.call(gate, {:release, point}, 1_000)
  def note(gate, point, details \\ %{}), do: GenServer.call(gate, {:note, point, details}, 1_000)
  def snapshot(gate), do: GenServer.call(gate, :snapshot, 1_000)
  def close(gate), do: GenServer.call(gate, :close, 1_000)
  def subscribe(gate, session), do: GenServer.call(gate, {:subscribe, session}, 1_000)

  def observe(gate, point, details \\ %{}),
    do: GenServer.call(gate, {:observe, point, details}, 1_000)

  def stop(gate) do
    events = close(gate)

    settled =
      events
      |> Enum.map(& &1.caller)
      |> Enum.filter(&is_pid/1)
      |> Enum.uniq()
      |> Enum.map(fn caller ->
        ref = Process.monitor(caller)
        Process.exit(caller, :kill)

        receive do
          {:DOWN, ^ref, :process, _, _} -> true
        after
          1_000 -> false
        end
      end)

    GenServer.stop(gate, :normal, 1_000)
    Enum.all?(settled) and not Process.alive?(gate)
  catch
    :exit, _ -> false
  end

  @impl true
  def init(_), do: {:ok, %{events: [], held: %{}, seen: MapSet.new(), closed: false}}

  @impl true
  def handle_call({kind, _point, _details}, _from, %{closed: true} = state)
      when kind in [:hold, :observe], do: {:reply, {:error, :closed}, state}

  def handle_call({:hold, point, details}, {caller, _tag} = from, state) do
    if MapSet.member?(state.seen, point) do
      {:reply, :skip, state}
    else
      installed = Jobs.now()
      ref = Process.monitor(caller)

      event = %{
        point: point,
        caller: caller,
        details: details,
        at: Jobs.now(),
        monitor_installed_at: installed,
        ref: ref,
        released_at: nil,
        down_at: nil,
        reason: nil
      }

      {:noreply,
       %{
         state
         | events: state.events ++ [event],
           seen: MapSet.put(state.seen, point),
           held: Map.put(state.held, point, from)
       }}
    end
  end

  def handle_call({:observe, point, details}, {caller, _tag}, state) do
    installed = Jobs.now()
    ref = Process.monitor(caller)

    event = %{
      point: point,
      caller: caller,
      details: details,
      at: Jobs.now(),
      monitor_installed_at: installed,
      ref: ref,
      released_at: nil,
      down_at: nil,
      reason: nil
    }

    {:reply, :ok, %{state | events: state.events ++ [event]}}
  end

  def handle_call({:release, point}, _from, state) do
    case Map.pop(state.held, point) do
      {nil, _} ->
        {:reply, {:error, :not_held}, state}

      {from, held} ->
        GenServer.reply(from, :ok)

        events =
          Enum.map(state.events, fn event ->
            if event.point == point, do: %{event | released_at: Jobs.now()}, else: event
          end)

        {:reply, :ok, %{state | held: held, events: events}}
    end
  end

  def handle_call({:note, point, details}, _from, state) do
    {:reply, :ok,
     %{
       state
       | events:
           state.events ++
             [
               %{point: point, caller: nil, details: details, at: Jobs.now()}
             ]
     }}
  end

  def handle_call(:snapshot, _from, state),
    do: {:reply, Enum.map(state.events, &Map.delete(&1, :ref)), state}

  def handle_call(:close, _from, state),
    do: {:reply, Enum.map(state.events, &Map.delete(&1, :ref)), %{state | closed: true}}

  def handle_call({:subscribe, session}, _from, state) do
    # subscribe/1 attaches its caller. The durable collector owns the
    # subscription, rather than a short-lived Deadline helper.
    result = Elara.subscribe(session)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:elara, session, event}, state) do
    if match?({:message_appended, %Elara.Message.User{}}, event) or
         match?({:turn_ended, _}, event) or match?({:turn_ended, _, _}, event) do
      witness = %{
        point: :public_event,
        caller: nil,
        details: %{session: session, event: event},
        at: Jobs.now()
      }

      {:noreply, %{state | events: state.events ++ [witness]}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    event = Enum.find(state.events, &(Map.get(&1, :ref) == ref))

    events =
      Enum.map(state.events, fn event ->
        if Map.get(event, :ref) == ref,
          do: %{event | down_at: Jobs.now(), reason: reason},
          else: event
      end)

    held = if event, do: Map.delete(state.held, event.point), else: state.held
    {:noreply, %{state | events: events, held: held}}
  end
end

defmodule Elara.Lab.GatedScripted do
  @moduledoc "Lab-only Scripted provider with a barrier on the first matching input."
  @behaviour Elara.Provider

  def chat(config, request), do: stream(config, request, fn _ -> :ok end)

  def stream(config, request, sink) do
    :ok = Elara.Lab.Gate.observe(config.gate, :provider_task)

    if List.last(request.messages) == config.input do
      Elara.Lab.Gate.hold(config.gate, :provider_ready)
    end

    case Elara.Provider.Scripted.stream(config.script, request, sink) do
      {:ok, answer, _script} -> {:ok, answer, config}
      {:error, error, _script} -> {:error, error, config}
    end
  end
end
