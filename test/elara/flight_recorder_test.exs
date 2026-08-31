defmodule Elara.FlightRecorderTest do
  use ExUnit.Case, async: false

  alias Elara.FlightRecorder
  alias Elara.Message
  alias Elara.Message.ToolCall
  alias Elara.Session.Core
  alias Elara.Tool

  defmodule NotifyTool do
    def run(_arguments, context) do
      send(Process.whereis(:flight_recorder_test), {:tool_executed, context.cwd})
      {:ok, "tool output"}
    end
  end

  setup do
    Process.register(self(), :flight_recorder_test)

    on_exit(fn ->
      if Process.whereis(:flight_recorder_test), do: Process.unregister(:flight_recorder_test)
    end)

    :ok
  end

  defp asst(text, calls \\ []) do
    {:ok, assistant} = Message.assistant(text, calls)
    assistant
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp tool do
    %Tool{
      name: "recorded",
      description: "recorded tool",
      parameters: %{"type" => "object", "properties" => %{}},
      run: {NotifyTool, :run}
    }
  end

  test "records causal transitions and replays without provider or tool effects" do
    provider =
      script([
        {:ok, asst(nil, [%ToolCall{id: "call-1", name: "recorded", args: {:ok, %{}}}])},
        {:ok, asst("done")}
      ])

    {:ok, session} =
      Elara.start_session(provider: provider, tools: [tool()], persist: false)

    assert {:ok, "done"} = Elara.ask(session, "go")
    assert_receive {:tool_executed, _}

    recording = Elara.recording(session)
    assert length(recording.segments) == 1
    assert length(recording.transitions) == 4

    refute_receive {:tool_executed, _}

    assert {:ok, %FlightRecorder.Report{status: :match, transitions: 4}} =
             Elara.replay(recording)

    refute_receive {:tool_executed, _}

    assert {:ok, explanation} = Elara.why(session)
    assert explanation.fact.kind == :provider_result
    assert Enum.map(explanation.chain, & &1.transition_id.sequence) == [1, 2, 3, 4]
  end

  test "detects core behavior changes and supports transition fault injection" do
    {:ok, session} =
      Elara.start_session(
        provider: script([{:ok, asst("answer")}]),
        tools: [],
        persist: false
      )

    assert {:ok, "answer"} = Elara.ask(session, "question")
    recording = Elara.recording(session)

    changed_step = fn state, fact ->
      {next, effects} = Core.step(state, fact)
      {next, Enum.reject(effects, &match?({:emit, {:turn_started, _}}, &1))}
    end

    assert {:ok, %FlightRecorder.Report{status: :diverged, divergence: divergence}} =
             Elara.replay(recording, step: changed_step)

    assert divergence.id.sequence == 1
    assert divergence.field == :effects

    injection = %{2 => {:replace, :interrupt}}

    assert {:ok, %FlightRecorder.Report{status: :injected, observations: observations}} =
             Elara.replay(recording, inject: injection)

    assert length(observations) == 2
  end

  test "persistent recordings retain event causes and distinguish incomplete transitions" do
    cwd = Path.join(System.tmp_dir!(), "elara-flight-#{System.unique_integer([:positive])}")

    {:ok, session} =
      Elara.start_session(
        provider: script([{:ok, asst("answer")}]),
        tools: [],
        cwd: cwd
      )

    assert {:ok, "answer"} = Elara.ask(session, "question")
    path = Elara.status(session).recording_path
    assert File.exists?(path)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

    assert {:ok, %FlightRecorder.Recording{transitions: [_, _]} = recording} =
             FlightRecorder.load(path)

    assert {:ok, %{transition_id: %{sequence: 2}}} =
             FlightRecorder.why(recording, {:transition, 2})

    head = Elara.status(session).event_head

    assert {:ok, %{transition_id: %{sequence: 2}}} = FlightRecorder.why(recording, head)
    assert {:ok, %{transition_id: %{sequence: 2}}} = FlightRecorder.why(recording, :latest)

    truncated = path <> ".truncated"
    binary = File.read!(path)
    File.write!(truncated, binary <> <<0, 0, 0, 20, 1, 2, 3>>)

    assert {:ok, %FlightRecorder.Recording{transitions: [_, _]}} =
             FlightRecorder.load(truncated)

    incomplete_path = path <> ".incomplete"

    begin = %{
      type: :transition_begin,
      id: %{recording_id: recording.header.recording_id, sequence: 3}
    }

    frame = :erlang.term_to_binary(begin, [:deterministic])
    File.write!(incomplete_path, binary <> <<byte_size(frame)::unsigned-big-32>> <> frame)

    assert {:ok, %FlightRecorder.Recording{incomplete: [^begin]} = incomplete} =
             FlightRecorder.load(incomplete_path)

    assert {:error, {:incomplete_recording, [%{sequence: 3}]}} = Elara.replay(incomplete)
  end
end
