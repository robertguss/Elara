defmodule Elara.ProtocolV2Test do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Elara.Attach.Projector
  alias Elara.Message
  alias Elara.Message.ToolCall
  alias Elara.Protocol
  alias Elara.Session.Core
  alias Elara.Tool

  defp asst(text, calls \\ []) do
    {:ok, assistant} = Message.assistant(text, calls)
    assistant
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        port,
        [:binary, packet: :line, packet_size: 16 * 1_024 * 1_024, active: false]
      )

    socket
  end

  defp send_json(socket, message), do: :gen_tcp.send(socket, Protocol.encode(message))

  defp recv_json(socket, timeout \\ 2_000) do
    {:ok, line} = recv_line(socket, timeout)
    {:ok, message} = Protocol.decode(line)
    message
  end

  defp recv_line(socket, timeout, line_buffer \\ {[], 0}) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, timeout)

    case Protocol.push_line(line_buffer, chunk) do
      {:ok, line} -> {:ok, line}
      {:more, line_buffer} -> recv_line(socket, timeout, line_buffer)
    end
  end

  defp attach_v2(socket, session, mode, cursor, incarnation) do
    :ok =
      send_json(socket, %{
        "version" => 2,
        "command" => "attach",
        "session_id" => session,
        "mode" => mode,
        "cursor" => cursor,
        "incarnation" => incarnation
      })

    recv_json(socket)
  end

  defp projector(%{
         "snapshot" => snapshot,
         "incarnation" => incarnation,
         "head" => head
       }) do
    Projector.new(snapshot, incarnation, head)
  end

  defp ingest_until(socket, projector, predicate) do
    message = recv_json(socket, 5_000)

    case message do
      %{"type" => "patch", "incarnation" => incarnation, "seq" => seq, "ops" => ops} ->
        assert {:applied, projector} = Projector.ingest_patch(projector, incarnation, seq, ops)

        if predicate.(projector) do
          projector
        else
          ingest_until(socket, projector, predicate)
        end

      %{"type" => type} when type in ["ok", "error", "status"] ->
        ingest_until(socket, projector, predicate)
    end
  end

  defp ingest_render_until_idle(socket, projector, events \\ [], output \\ []) do
    case recv_json(socket, 5_000) do
      %{"type" => "patch", "incarnation" => incarnation, "seq" => seq, "ops" => ops} ->
        assert {:applied, projector} = Projector.ingest_patch(projector, incarnation, seq, ops)
        assert {:ok, patch_events} = Protocol.patch_events(ops)
        output = [output, Enum.map(patch_events, &Elara.CLI.render/1)]
        events = events ++ patch_events

        if projector.view["turn"]["state"] == "idle" and
             Enum.any?(events, &match?({:turn_ended, _outcome}, &1)) do
          {projector, events, IO.iodata_to_binary(output)}
        else
          ingest_render_until_idle(socket, projector, events, output)
        end

      %{"type" => type} when type in ["ok", "error", "status"] ->
        ingest_render_until_idle(socket, projector, events, output)
    end
  end

  defp project_transition(core, view, seq, fact) do
    offset = length(core.history)
    previous_streaming = core.streaming
    {core, effects} = Core.step(core, fact)
    messages = Enum.drop(core.history, offset)

    context = %{
      message_offset: offset,
      messages: messages,
      supersedes:
        case {previous_streaming, core.streaming} do
          {%{id: id}, nil} -> id
          _other -> nil
        end
    }

    {view, seq} =
      Enum.reduce(effects, {view, seq}, fn
        {:emit, event}, {view, seq} ->
          ops = Protocol.patch_ops(event, core, context)
          assert {:ok, view} = Protocol.apply_patch(view, ops)
          assert view == Protocol.snapshot("property-session", "property-incarnation", core)
          {view, seq + 1}

        _effect, state ->
          state
      end)

    {core, view, seq}
  end

  test "cold v2 attach materializes history beyond the v1 replay window" do
    turns = 251

    {:ok, session} =
      Elara.start_session(
        provider: script(List.duplicate({:ok, asst("answer")}, turns)),
        tools: [],
        persist: false
      )

    for index <- 1..turns do
      assert {:ok, "answer"} = Elara.ask(session, "question #{index}")
    end

    assert %{event_head: head, event_retained: 1_000} = Elara.status(session)
    assert head > 1_000

    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]))
    socket = connect(Elara.Server.port(server))

    assert %{
             "type" => "attached",
             "version" => 2,
             "head" => ^head,
             "incarnation" => incarnation,
             "snapshot" => snapshot
           } = attach_v2(socket, session, "observe", 1, "stale-incarnation")

    assert snapshot["session"] == %{"id" => session, "incarnation" => incarnation}
    assert length(snapshot["messages"]) == turns * 2
    assert snapshot == Elara.materialized_view(session)
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 25)

    :ok = send_json(socket, %{"version" => 2, "command" => "resnapshot"})

    assert %{
             "type" => "snapshot",
             "version" => 2,
             "head" => ^head,
             "snapshot" => ^snapshot
           } = recv_json(socket)

    :gen_tcp.close(socket)
  end

  test "applying every v2 patch converges to the Core-derived materialized view" do
    call = %ToolCall{
      id: "projection-call",
      name: "bash",
      args: {:ok, %{"command" => "printf projected"}}
    }

    provider =
      script([
        {:ok, asst(nil, [call])},
        {:ok, asst("first complete")},
        {:ok, asst("second complete")}
      ])

    {:ok, session} = Elara.start_session(provider: provider, persist: false)
    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]))
    socket = connect(Elara.Server.port(server))
    attached = attach_v2(socket, session, "control", 0, nil)
    projector = projector(attached)

    {projector, previous_head} =
      Enum.reduce(["use a tool", "one more turn"], {projector, 0}, fn prompt,
                                                                      {projector, previous_head} ->
        :ok = send_json(socket, %{"version" => 2, "command" => "ask", "prompt" => prompt})
        assert %{"type" => "ok", "version" => 2} = recv_json(socket)

        projector =
          ingest_until(socket, projector, fn projector ->
            status = Elara.status(session)

            projector.view["turn"]["state"] == "idle" and
              projector.head > previous_head and projector.head == status.event_head
          end)

        assert projector.head > previous_head
        assert projector.view == Elara.materialized_view(session)
        {projector, projector.head}
      end)

    assert projector.head == Elara.status(session).event_head
    assert previous_head == projector.head
    :gen_tcp.close(socket)
  end

  test "every emitted sequence materializes its complete Core transition" do
    bash = Enum.find(Tool.builtins(), &(&1.name == "bash"))

    config = %Core.Config{
      system: "property test",
      tools: %{"bash" => bash},
      max_iterations: 4,
      max_tool_output_bytes: 1_024
    }

    core = Core.new(config)
    view = Protocol.snapshot("property-session", "property-incarnation", core)
    {core, view, seq} = project_transition(core, view, 1, {:ask, "exercise tools"})
    {:calling_provider, provider_ref, 1} = core.phase

    {core, view, seq} =
      project_transition(core, view, seq, {:provider_delta, provider_ref, "working "})

    {core, view, seq} =
      project_transition(core, view, seq, {:provider_delta, provider_ref, "now"})

    assert view["content_deltas"] == %{"assistant-1" => "working now"}

    calls = [
      %ToolCall{id: "valid", name: "bash", args: {:ok, %{"command" => "true"}}},
      %ToolCall{id: "malformed", name: "bash", args: {:malformed, "{"}},
      %ToolCall{id: "unknown", name: "missing", args: {:ok, %{}}}
    ]

    {core, view, seq} =
      project_transition(
        core,
        view,
        seq,
        {:provider_result, provider_ref, {:ok, asst("working now", calls)}}
      )

    assert view["content_deltas"] == %{}

    {:running_tool, tool_ref, %ToolCall{id: "valid"}, _remaining, 1} = core.phase
    {core, view, seq} = project_transition(core, view, seq, {:tool_result, tool_ref, {:ok, "ok"}})
    {:calling_provider, provider_ref, 2} = core.phase

    {core, view, seq} =
      project_transition(
        core,
        view,
        seq,
        {:provider_result, provider_ref, {:ok, asst("complete")}}
      )

    {core, view, seq} = project_transition(core, view, seq, {:ask, "interrupt all"})
    {:calling_provider, provider_ref, 1} = core.phase

    pending_calls = [
      %ToolCall{id: "first", name: "bash", args: {:ok, %{"command" => "sleep 1"}}},
      %ToolCall{id: "second", name: "bash", args: {:ok, %{"command" => "sleep 1"}}}
    ]

    {core, view, seq} =
      project_transition(
        core,
        view,
        seq,
        {:provider_result, provider_ref, {:ok, asst(nil, pending_calls)}}
      )

    {core, view, _seq} = project_transition(core, view, seq, :interrupt)
    assert core.phase == :idle
    assert view == Protocol.snapshot("property-session", "property-incarnation", core)
    assert Enum.all?(view["tool_calls"], &(&1["status"] in ["succeeded", "failed"]))
  end

  test "gap, incarnation change, and invalid patch request only one snapshot while pending" do
    {:ok, session} =
      Elara.start_session(provider: script([]), tools: [], persist: false)

    view = Elara.materialized_view(session)
    incarnation = view["session"]["incarnation"]
    projector = Projector.new(view, incarnation, 0)
    harmless = [%{"op" => "set_usage", "usage" => nil}]

    assert {:resnapshot, awaiting} =
             Projector.ingest_patch(projector, incarnation, 2, harmless)

    assert awaiting.awaiting_snapshot?
    assert {:ignored, ^awaiting} = Projector.ingest_patch(awaiting, incarnation, 3, harmless)

    projector = Projector.install_snapshot(awaiting, view, "new-incarnation", 7)

    assert {:resnapshot, changed} =
             Projector.ingest_patch(projector, incarnation, 8, harmless)

    assert {:ignored, ^changed} = Projector.ingest_patch(changed, incarnation, 9, harmless)

    projector = Projector.install_snapshot(changed, view, incarnation, 9)
    assert {:resnapshot, invalid} = Projector.ingest_patch(projector, incarnation, 10, [%{}])
    assert {:ignored, ^invalid} = Projector.ingest_patch(invalid, incarnation, 11, [%{}])
  end

  test "v1 event encoding remains explicit for streamed deltas and finals" do
    delta = {:content_delta, "assistant-1", "hel"}
    assistant = asst("hello")
    final = {:message_appended, assistant, :streamed}

    for event <- [delta, final] do
      encoded = Protocol.event(7, event)
      assert encoded["version"] == 1
      assert {:ok, ^event} = Protocol.decode_event(encoded["event"])
    end
  end

  test "mix elara.attach negotiates v2 and renders the current snapshot" do
    {:ok, session} =
      Elara.start_session(
        provider: script([{:ok, asst("already happened")}]),
        tools: [],
        persist: false
      )

    assert {:ok, "already happened"} = Elara.ask(session, "earlier")
    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]))

    output =
      capture_io("/quit\n", fn ->
        assert catch_exit(
                 Mix.Tasks.Elara.Attach.run([
                   session,
                   "--port",
                   Integer.to_string(Elara.Server.port(server))
                 ])
               ) == {:shutdown, 0}
      end)

    assert output =~ "already happened"
    assert output =~ "snapshot head 4"
  end

  test "v2 attach patches render each content delta before the superseding final" do
    {:ok, session} =
      Elara.start_session(
        provider:
          script([
            {:stream, ["hel", {:sleep, 50}, "lo"], {:ok, asst("hello")}}
          ]),
        tools: [],
        persist: false
      )

    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]))
    socket = connect(Elara.Server.port(server))
    projector = socket |> attach_v2(session, "control", 0, nil) |> projector()

    :ok = send_json(socket, %{"version" => 2, "command" => "ask", "prompt" => "stream"})
    assert %{"type" => "ok", "version" => 2} = recv_json(socket)

    {projector, events, output} = ingest_render_until_idle(socket, projector)

    assert Enum.filter(events, &match?({:content_delta, _, _}, &1)) == [
             {:content_delta, "assistant-1", "hel"},
             {:content_delta, "assistant-1", "lo"}
           ]

    assert output =~ "hello\n"
    refute output =~ "hello\nhello\n"
    assert projector.view["content_deltas"] == %{}
    assert projector.view == Elara.materialized_view(session)
    :gen_tcp.close(socket)
  end

  test "controller interrupt is visible to an observer and both projections converge" do
    call = %ToolCall{
      id: "interrupt-call",
      name: "bash",
      args: {:ok, %{"command" => "sleep 10"}}
    }

    {:ok, session} =
      Elara.start_session(provider: script([{:ok, asst(nil, [call])}]), persist: false)

    {:ok, server} = Elara.Server.start_link(port: 0, provider: script([]))
    port = Elara.Server.port(server)
    controller = connect(port)
    observer = connect(port)

    controller_projection =
      controller |> attach_v2(session, "control", 0, nil) |> projector()

    observer_projection = observer |> attach_v2(session, "observe", 0, nil) |> projector()

    :ok =
      send_json(controller, %{"version" => 2, "command" => "ask", "prompt" => "wait"})

    assert %{"type" => "ok"} = recv_json(controller)

    running? = fn projection ->
      Enum.any?(projection.view["tool_calls"], &(&1["status"] == "running")) and
        projection.head == Elara.status(session).event_head
    end

    controller_projection = ingest_until(controller, controller_projection, running?)
    observer_projection = ingest_until(observer, observer_projection, running?)

    :ok = send_json(observer, %{"version" => 2, "command" => "interrupt"})
    assert %{"type" => "error", "error" => "not_controller", "version" => 2} = recv_json(observer)

    :ok = send_json(controller, %{"version" => 2, "command" => "interrupt"})
    assert %{"type" => "ok", "version" => 2} = recv_json(controller)

    idle? = fn projection -> projection.view["turn"]["state"] == "idle" end
    controller_projection = ingest_until(controller, controller_projection, idle?)
    observer_projection = ingest_until(observer, observer_projection, idle?)

    assert controller_projection.view == observer_projection.view
    assert controller_projection.head == observer_projection.head
    assert controller_projection.view == Elara.materialized_view(session)
    assert Enum.any?(controller_projection.view["tool_calls"], &(&1["status"] == "failed"))

    :gen_tcp.close(controller)
    :gen_tcp.close(observer)
  end
end
