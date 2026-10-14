defmodule Elara.FlightRecorderTest do
  use ExUnit.Case, async: false

  alias Elara.FlightRecorder
  alias Elara.FlightRecorder.ContextCensus
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

  @tag :tmp_dir
  test "pre-retry recordings are explicitly unsupported, not falsely divergent", %{tmp_dir: tmp} do
    for result <- [
          {:ok, asst("done")},
          {:error, %Elara.Provider.Error{kind: :http, status: 503, message: "overloaded"}}
        ] do
      {:ok, session} =
        Elara.start_session(
          provider: script([result]),
          tools: [],
          persist: false,
          provider_retry: Elara.Provider.Retry.disabled()
        )

      Elara.ask(session, "go")
      recording = Elara.recording(session)
      assert recording.header.format_version == 3
      assert {:ok, %FlightRecorder.Report{status: :match}} = Elara.replay(recording)

      legacy = %{recording | header: %{recording.header | format_version: 1}}
      assert {:error, {:unsupported_format, 1, message}} = Elara.replay(legacy)
      assert message =~ "pre-retry build at daa06f281368d0a532721695c6a656ec12ec14a5"
    end

    path = Path.join(tmp, "legacy.flight")
    bytes = "ELARA-FLIGHT\0" <> <<1::unsigned-big-32>>
    File.write!(path, bytes)
    assert {:error, {:unsupported_format, 1, message}} = FlightRecorder.load(path)
    assert message =~ "format 1 is unsupported"
    assert File.read!(path) == bytes
  end

  test "format 2 recordings replay with their original hash domain" do
    path = Path.expand("../fixtures/flight-v2.flight", __DIR__)
    original = File.read!(path)
    assert {:ok, recording} = FlightRecorder.load(path)
    assert recording.header.format_version == 2

    assert {:ok, %FlightRecorder.Report{status: :match, transitions: 5}} =
             FlightRecorder.replay(recording)

    assert File.read!(path) == original
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

  test "stream deltas replay while the persisted final state matches a non-streamed turn" do
    root =
      Path.join(System.tmp_dir!(), "elara-stream-replay-#{System.unique_integer([:positive])}")

    {:ok, streamed} =
      Elara.start_session(
        provider: script([{:stream, ["ans", "wer"], {:ok, asst("answer")}}]),
        tools: [],
        cwd: Path.join(root, "streamed")
      )

    {:ok, plain} =
      Elara.start_session(
        provider: script([{:ok, asst("answer")}]),
        tools: [],
        cwd: Path.join(root, "plain")
      )

    assert {:ok, "answer"} = Elara.ask(streamed, "question")
    assert {:ok, "answer"} = Elara.ask(plain, "question")
    assert Elara.transcript(streamed) == Elara.transcript(plain)

    assert {:ok, recording} =
             streamed |> Elara.status() |> Map.fetch!(:recording_path) |> FlightRecorder.load()

    assert length(recording.transitions) == 4

    assert Enum.map(recording.transitions, & &1.fact.kind) == [
             :ask,
             :provider_delta,
             :provider_delta,
             :provider_result
           ]

    assert {:ok, %FlightRecorder.Report{status: :match, transitions: 4}} =
             Elara.replay(recording)
  end

  test "provider-private assistant state is excluded from recording and replay" do
    provider_state = %{
      "openai_codex" => %{
        "output" => [
          %{
            "type" => "reasoning",
            "id" => "rs_1",
            "summary" => [],
            "encrypted_content" => "encrypted"
          }
        ]
      }
    }

    {:ok, assistant} = Message.assistant("answer", [], provider_state)

    assistant =
      %{
        assistant
        | response_model: "gpt-4.1",
          usage: %{"input_tokens" => 10, "cached_input_tokens" => 4, "output_tokens" => 3}
      }
      |> Elara.Provider.Billing.stamp("openai")

    {:ok, session} =
      Elara.start_session(provider: script([{:ok, assistant}]), tools: [], persist: false)

    assert {:ok, "answer"} = Elara.ask(session, "question")
    recording = Elara.recording(session)

    refute get_in(List.last(recording.transitions), [:fact, :message, :provider_state])
    refute inspect(recording) =~ "encrypted_content"

    assert {:ok, %FlightRecorder.Report{status: :match, final_state: replayed}} =
             Elara.replay(recording)

    assert List.last(replayed.history).provider_state == nil
    assert List.last(replayed.history).billing_receipt == assistant.billing_receipt

    assert Elara.Provider.Visibility.view(replayed)["usage"]["cost"]["estimated_usd_nanos"] ==
             38_000
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

    # Silent state changes must still diverge, not just a changed effect list.
    for change <- [
          fn next -> %{next | config: %{next.config | system: "different system"}} end,
          fn next -> %{next | history: [%Message.User{text: "different history"}]} end,
          fn next -> %{next | read_only: not next.read_only} end
        ] do
      changed_state = fn state, fact ->
        {next, effects} = Core.step(state, fact)
        {change.(next), effects}
      end

      assert {:ok, %FlightRecorder.Report{status: :diverged, divergence: %{field: :post}}} =
               Elara.replay(recording, step: changed_state)
    end

    injection = %{2 => {:replace, :interrupt}}

    assert {:ok, %FlightRecorder.Report{status: :injected, observations: observations}} =
             Elara.replay(recording, inject: injection)

    assert length(observations) == 2
  end

  test "context observations retain live accounting, causal IDs and file coverage" do
    cwd =
      Path.join(System.tmp_dir!(), "elara-context-flight-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(cwd) end)
    provider = script([{:ok, asst("answer")}])

    {:ok, session} =
      Elara.start_session(
        provider: provider,
        cwd: cwd,
        tools: [],
        plugins: [],
        context_limit: 200_000,
        seed_history: [
          %Message.User{
            text: "context",
            agent_source: %{"sender" => "sender", "message_id" => "message"}
          }
        ]
      )

    {:ok, pid} = Elara.session_pid(session)
    :sys.suspend(elem(provider, 1))
    assert :ok = Elara.ask_async(session, "question")
    shell = :sys.get_state(pid)
    budget = Elara.Session.Context.budget(shell.core, 200_000)
    recording = Elara.recording(session)
    assert [decision] = recording.context_decisions
    assert decision.branch == :attempt_dispatch
    assert decision.limit == 200_000
    assert decision.estimate_tokens == budget["estimate_tokens"]

    assert decision.reserves == %{
             "output" => 20_000,
             "handoff" => 0,
             "tools" => 0,
             "uncertainty" => 0
           }

    assert decision.frozen == false

    transition =
      Enum.find(recording.transitions, &(&1.id == Map.delete(decision.effect, :effect_index)))

    assert Enum.find(transition.effects, &(&1.index == decision.effect.effect_index)).value.kind ==
             :call_provider

    # Normalized history loses provenance; capture must use live accounting.
    stripped = %{
      shell.core
      | history:
          Enum.map(shell.core.history, fn
            %Message.User{} = user -> %{user | agent_source: nil}
            message -> message
          end)
    }

    assert decision.estimate_tokens >
             Elara.Session.Context.budget(stripped, 200_000)["estimate_tokens"]

    path = Elara.status(session).recording_path
    assert {:ok, loaded} = FlightRecorder.load(path)
    assert loaded.context_decisions == recording.context_decisions

    assert {:ok, %{segments: [%{status: :match, compared: 1}]}} =
             ContextCensus.compare(path, 200_000)

    assert {:ok, %{segments: [%{status: :diverged, compared: 1}]}} =
             ContextCensus.compare(path, 1)

    # The final frame is the durably written observation; a partial frame must
    # not turn the already-recorded call_provider effect into a match.
    binary = File.read!(path)
    truncated = path <> ".context-truncated"
    File.write!(truncated, binary_part(binary, 0, byte_size(binary) - 1))

    assert {:ok,
            %{
              segments: [
                %{status: :unknown, compared: 0, unknown: %{reason: :missing_observation}}
              ]
            }} =
             ContextCensus.compare(truncated, 200_000)

    :sys.resume(elem(provider, 1))
    GenServer.stop(pid)
  end

  test "context capture keeps resolved catalog/default budgets, reported usage and images" do
    for {settings, override, limit} <- [
          {nil, nil, 128_000},
          {%{"model" => "gpt-5.5", "effort" => "low"}, nil, 272_000},
          {%{"model" => "gpt-5.5", "effort" => "low"}, 100_000, 100_000}
        ] do
      core =
        Core.new(
          %Core.Config{
            system: "",
            tools: %{},
            provider_settings: settings,
            max_tool_output_bytes: 1024
          },
          [
            %Message.Assistant{
              text: "small",
              usage: %{"input_tokens" => 90_000, "output_tokens" => 123},
              provider_state: %{"secret" => "never record"}
            }
          ]
        )

      recorder = FlightRecorder.new(core, "test", "incarnation", nil)

      user = %Message.User{
        text: "image",
        attachments: [%{"kind" => "image", "name" => "fixture", "base64" => "private"}]
      }

      {recorder, begin} = FlightRecorder.begin_transition(recorder, core, {:ask_input, user})
      {core, effects} = Core.step(core, {:ask_input, user})
      {recorder, transition} = FlightRecorder.complete_transition(recorder, begin, core, effects)
      index = Enum.find_index(effects, &match?({:call_provider, _, _}, &1))
      effect = Map.put(transition.id, :effect_index, index)
      budget = Elara.Session.Context.budget(core, override)
      assert budget["limit"] == limit
      assert budget["reserves"]["output"] == div(limit, 10)
      assert budget["reserves"]["uncertainty"] == 0
      # 90,123 reported tokens + image reserve + public encoded user bytes.
      assert budget["estimate_tokens"] > 122_891
      branch = if budget["handoff_required"], do: :attempt_handoff, else: :attempt_dispatch

      # Simulate an intervening recorded fact: observation must reference the
      # original effect, not the recorder's most recent transition.
      {recorder, nested} =
        FlightRecorder.begin_transition(recorder, core, {:provider_delta, 1, ""})

      {recorder, _} = FlightRecorder.complete_transition(recorder, nested, core, [])
      recorder = FlightRecorder.context_decision(recorder, effect, budget, false, branch)
      recording = FlightRecorder.snapshot(recorder)
      assert [decision] = recording.context_decisions
      assert decision.effect.sequence == 1
      assert recorder.sequence == 2
      assert decision.estimate_tokens == budget["estimate_tokens"]
      assert decision.reserves == budget["reserves"]
      refute inspect(recording) =~ "never record"
      refute inspect(recording) =~ "private"
      assert {:ok, %{segments: [%{status: :match}]}} = ContextCensus.compare(recording, limit)
    end
  end

  test "fresh VM can plain-load and replay every context branch without Session or Census" do
    root = Path.join(System.tmp_dir!(), "elara-flight-vm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    paths =
      for branch <- [:attempt_dispatch, :attempt_handoff, :interrupt_frozen] do
        core = Core.new(%Core.Config{system: "", tools: %{}})

        recorder =
          FlightRecorder.new(core, "fixture", "#{branch}", Path.join(root, "session.jsonl"))

        {recorder, begin} = FlightRecorder.begin_transition(recorder, core, {:ask, "go"})
        {core, effects} = Core.step(core, {:ask, "go"})

        {recorder, transition} =
          FlightRecorder.complete_transition(recorder, begin, core, effects)

        index = Enum.find_index(effects, &match?({:call_provider, _, _}, &1))

        budget = %{
          "limit" => 100,
          "estimate_tokens" => if(branch == :attempt_handoff, do: 100, else: 10),
          "reserves" => %{"output" => 2, "handoff" => 3, "tools" => 5, "uncertainty" => 7}
        }

        recorder =
          FlightRecorder.context_decision(
            recorder,
            Map.put(transition.id, :effect_index, index),
            budget,
            branch == :interrupt_frozen,
            branch
          )

        facts = [
          {:provider_result, 1,
           {:error, %Elara.Provider.Error{kind: :http, status: 503, message: "overloaded"}}},
          {:retry_elapsed, 2},
          {:provider_result, 3, {:ok, asst("recovered")}}
        ]

        {recorder, _core} =
          Enum.reduce(facts, {recorder, core}, fn fact, {recorder, core} ->
            {recorder, begin} = FlightRecorder.begin_transition(recorder, core, fact)
            {core, effects} = Core.step(core, fact)
            {recorder, _} = FlightRecorder.complete_transition(recorder, begin, core, effects)
            {recorder, core}
          end)

        :ok = FlightRecorder.close(recorder)
        FlightRecorder.path(recorder)
      end

    code = """
    Code.ensure_loaded!(Elara.FlightRecorder)
    false = :code.is_loaded(Elara.Session)
    false = :code.is_loaded(Elara.FlightRecorder.ContextCensus)
    for path <- System.argv() do
      {:ok, recording} = Elara.FlightRecorder.load(path)
      {:ok, %{status: :match}} = Elara.FlightRecorder.replay(recording)
      IO.puts(Atom.to_string(hd(recording.context_decisions).branch))
    end
    false = :code.is_loaded(Elara.Session)
    false = :code.is_loaded(Elara.FlightRecorder.ContextCensus)
    """

    beams = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))

    args =
      ["--erl", "+S 2:2"] ++ Enum.flat_map(beams, &["-pa", &1]) ++ ["-e", code, "--"] ++ paths

    {output, status} = System.cmd(System.find_executable("elixir"), args, stderr_to_stdout: true)
    assert status == 0, output

    assert String.split(String.trim(output), "\n") == [
             "attempt_dispatch",
             "attempt_handoff",
             "interrupt_frozen"
           ]
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
