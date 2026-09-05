defmodule Elara.InputQueueTest do
  use ExUnit.Case, async: false

  alias Elara.Message
  alias Elara.Message.ToolCall
  alias Elara.Provider.Error
  alias Elara.Session.Store
  alias Elara.Tool

  defmodule SlowTool do
    def run(%{"owner" => owner}, _ctx) do
      owner = String.to_existing_atom(owner)
      send(owner, {:tool_entered, self()})

      receive do
        :release -> {:ok, "actual success"}
      end
    end

    def sibling(%{"owner" => owner}, _ctx) do
      owner = String.to_existing_atom(owner)
      send(owner, :sibling_executed)
      {:ok, "unexpected"}
    end
  end

  defp assistant(text, calls \\ []) do
    {:ok, message} = Message.assistant(text, calls)
    message
  end

  defp session(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    {:ok, session} =
      Elara.start_session(provider: {Elara.Provider.Scripted, agent}, persist: false)

    session
  end

  defp attrs(id, text, kind \\ :normal) do
    %{id: id, sender_id: "test", kind: kind, user: Message.user(text)}
  end

  defp await_state(session, id, state, attempts \\ 100)
  defp await_state(_session, _id, _state, 0), do: flunk("input state did not converge")

  defp await_state(session, id, state, attempts) do
    case Elara.input_status(session, id) do
      {:ok, %{state: ^state} = entry} ->
        entry

      _ ->
        Process.sleep(10)
        await_state(session, id, state, attempts - 1)
    end
  end

  defp await_idle(session, attempts \\ 100)
  defp await_idle(_session, 0), do: flunk("session did not become idle")

  defp await_idle(session, attempts) do
    if Elara.status(session).phase == :idle do
      :ok
    else
      Process.sleep(10)
      await_idle(session, attempts - 1)
    end
  end

  defp stop(session) do
    {:ok, pid} = Elara.session_pid(session)
    GenServer.stop(pid)
  end

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])

    socket
  end

  defp send_json(socket, value), do: :gen_tcp.send(socket, Elara.Protocol.encode(value))

  defp recv_json(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    {:ok, value} = Elara.Protocol.decode(line)
    value
  end

  test "normal submissions execute FIFO and duplicate IDs are idempotent but conflicting payloads reject" do
    session =
      session([{:stream, [{:sleep, 50}], {:ok, assistant("one")}}, {:ok, assistant("two")}])

    assert {:ok, first} = Elara.submit_input(session, attrs("one", "first"))
    assert {:ok, duplicate} = Elara.submit_input(session, attrs("one", "first"))
    assert duplicate.id == first.id
    assert duplicate.created_at == first.created_at
    assert {:error, :submission_conflict} = Elara.submit_input(session, attrs("one", "different"))
    assert {:ok, _} = Elara.submit_input(session, attrs("two", "second"))
    await_state(session, "two", :consumed)

    assert Elara.materialized_view(session)["messages"]
           |> Enum.filter(&(&1["role"] == "user"))
           |> Enum.map(& &1["text"]) ==
             ["first", "second"]
  end

  test "queued input can be cancelled while consumed input cannot be rewritten" do
    session = session([{:stream, [{:sleep, 80}], {:ok, assistant("done")}}])
    {:ok, _} = Elara.submit_input(session, attrs("active", "active"))
    {:ok, _} = Elara.submit_input(session, attrs("queued", "queued"))
    assert {:ok, %{state: :cancelled}} = Elara.cancel_input(session, "queued")
    await_state(session, "active", :consumed)
    assert {:ok, %{state: :consumed}} = Elara.cancel_input(session, "active")
    refute Enum.any?(Elara.materialized_view(session)["messages"], &(&1["text"] == "queued"))
  end

  test "provider errors produce a failed durable receipt and do not redeliver" do
    error = %Error{kind: :bad_response, message: "provider broke"}
    session = session([{:error, error}])
    {:ok, _} = Elara.submit_input(session, attrs("failed", "once"))
    receipt = await_state(session, "failed", :failed)
    assert receipt.error =~ "provider broke"
    assert Enum.count(Elara.materialized_view(session)["messages"], &(&1["text"] == "once")) == 1
  end

  test "attached snapshots include inbox and inbox events have recorder causality" do
    session = session([{:stream, [{:sleep, 100}], {:ok, assistant("done")}}])
    {:ok, _} = Elara.submit_input(session, attrs("snapshot", "visible"))
    Process.sleep(10)
    {:ok, attached} = Elara.attach_v2(session, :observe)
    assert attached.snapshot["inbox"]["entries"] != []

    recording = Elara.recording(session)
    sequence = recording.event_causes |> Map.keys() |> Enum.max()

    assert {:ok, %{transition_id: %{recording_id: _, sequence: _}}} =
             Elara.FlightRecorder.why(recording, sequence)
  end

  test "persisted stop pauses queued work and restart fails the active receipt without duplicating its user" do
    root =
      Path.join(System.tmp_dir!(), "elara-queue-restart-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous = Application.get_env(:elara, :sessions_root)
    Application.put_env(:elara, :sessions_root, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:elara, :sessions_root, previous),
        else: Application.delete_env(:elara, :sessions_root)

      File.rm_rf!(root)
    end)

    {:ok, agent} =
      Agent.start_link(fn -> [{:stream, [{:sleep, 5_000}], {:ok, assistant("late")}}] end)

    {:ok, session} =
      Elara.start_session(provider: {Elara.Provider.Scripted, agent}, cwd: root, tools: [])

    {:ok, _} = Elara.submit_input(session, attrs("active", "active persisted"))
    await_state(session, "active", :consumed)
    {:ok, _} = Elara.submit_input(session, attrs("queued", "queued persisted"))
    {:ok, info} = Store.newest(root)
    stop(session)

    {:ok, disk} = Store.open(info.path, root)
    assert Enum.find(disk.inbox, &(&1.id == "queued")).state == :queued
    # Reproduce the durable state at the restart boundary: shutdown has released
    # the lock, the active receipt/user commit exists, and draining is paused.
    {:ok, disk} = Store.put_inbox(disk, disk.inbox, true, nil, "active")
    Store.release(disk)

    {:ok, resumed_agent} =
      Agent.start_link(fn -> [{:ok, assistant("drained")}, {:ok, assistant("ordinary")}] end)

    {:ok, resumed} =
      Elara.start_session(
        provider: {Elara.Provider.Scripted, resumed_agent},
        cwd: root,
        tools: [],
        resume: info.path
      )

    on_exit(fn -> if match?({:ok, _}, Elara.session_pid(resumed)), do: stop(resumed) end)
    assert await_state(resumed, "active", :failed).error == "session restarted"
    assert Elara.snapshot(resumed).snapshot["inbox"]["paused"]

    assert Enum.count(
             Elara.transcript(resumed),
             &match?(%Message.User{text: "active persisted"}, &1)
           ) == 1

    assert :ok = Elara.resume_inputs(resumed)
    await_state(resumed, "queued", :consumed)
    await_idle(resumed)
    assert {:ok, "ordinary"} = Elara.ask(resumed, "new ordinary")
    refute Elara.snapshot(resumed).snapshot["inbox"]["paused"]

    assert Enum.map(
             Enum.filter(Elara.transcript(resumed), &match?(%Message.User{}, &1)),
             & &1.text
           ) ==
             ["active persisted", "queued persisted", "new ordinary"]
  end

  test "steering waits for the active tool, suppresses siblings, drains priority FIFO, and clears steering" do
    Process.register(self(), :input_queue_test_owner)

    on_exit(fn ->
      if Process.whereis(:input_queue_test_owner), do: Process.unregister(:input_queue_test_owner)
    end)

    owner = "input_queue_test_owner"

    calls = [
      %ToolCall{id: "slow", name: "slow", args: {:ok, %{"owner" => owner}}},
      %ToolCall{id: "sibling", name: "sibling", args: {:ok, %{"owner" => owner}}}
    ]

    replies = [
      {:ok, assistant(nil, calls)},
      {:ok, assistant("steer one done")},
      {:ok, assistant("steer two done")},
      {:ok, assistant("normal done")},
      {:ok, assistant("after explicit interrupt")}
    ]

    {:ok, agent} = Agent.start_link(fn -> replies end)

    tools = [
      %Tool{name: "slow", description: "slow", parameters: %{}, run: {SlowTool, :run}},
      %Tool{name: "sibling", description: "sibling", parameters: %{}, run: {SlowTool, :sibling}}
    ]

    {:ok, session} =
      Elara.start_session(
        provider: {Elara.Provider.Scripted, agent},
        tools: tools,
        persist: false
      )

    {:ok, _} = Elara.submit_input(session, attrs("initial", "initial"))
    assert_receive {:tool_entered, tool_pid}, 1_000
    {:ok, _} = Elara.submit_input(session, attrs("normal", "normal", :normal))
    {:ok, _} = Elara.submit_input(session, attrs("steer-1", "steer one", :steer))
    {:ok, _} = Elara.submit_input(session, attrs("steer-2", "steer two", :steer))
    send(tool_pid, :release)
    await_state(session, "normal", :consumed)
    refute_receive :sibling_executed, 50

    results = Enum.filter(Elara.transcript(session), &match?(%Message.ToolResult{}, &1))
    assert Enum.any?(results, &match?(%Message.ToolResult{outcome: {:ok, "actual success"}}, &1))

    assert Enum.any?(
             results,
             &match?(
               %Message.ToolResult{
                 outcome: {:error, "not started: superseded by steering input"}
               },
               &1
             )
           )

    users =
      Enum.filter(Elara.transcript(session), &match?(%Message.User{}, &1)) |> Enum.map(& &1.text)

    assert users == ["initial", "steer one", "steer two", "normal"]

    Elara.interrupt(session)
    Process.sleep(20)
    assert {:ok, "after explicit interrupt"} = Elara.ask(session, "subsequent")
  end

  test "TCP input queue negotiation enforces observer writes and filters legacy inbox patches" do
    {:ok, session} =
      Elara.start_session(
        provider:
          {Elara.Provider.Scripted,
           elem(
             Agent.start_link(fn -> [{:stream, [{:sleep, 100}], {:ok, assistant("done")}}] end),
             1
           )},
        tools: [],
        persist: false
      )

    {:ok, server} =
      Elara.Server.start_link(
        port: 0,
        provider: {Elara.Provider.Scripted, elem(Agent.start_link(fn -> [] end), 1)}
      )

    controller = connect(Elara.Server.port(server))
    observer = connect(Elara.Server.port(server))
    legacy = connect(Elara.Server.port(server))

    attach = fn socket, mode, extensions ->
      send_json(socket, %{
        "version" => 2,
        "command" => "attach",
        "session_id" => session,
        "mode" => mode,
        "extensions" => extensions
      })

      recv_json(socket)
    end

    assert %{"snapshot" => %{"inbox" => _}} = attach.(controller, "control", ["input_queue_v1"])
    assert %{"snapshot" => %{"inbox" => _}} = attach.(observer, "observe", ["input_queue_v1"])
    legacy_attached = attach.(legacy, "observe", [])
    refute Map.has_key?(legacy_attached["snapshot"], "inbox")

    status = %{
      "version" => 2,
      "command" => "input_status",
      "extension" => "input_queue_v1",
      "submission_id" => "missing"
    }

    send_json(observer, status)
    assert %{"type" => "input_receipt", "command" => "input_status"} = recv_json(observer)

    send_json(
      observer,
      Map.merge(status, %{
        "command" => "submit_input",
        "sender_id" => "x",
        "kind" => "normal",
        "prompt" => "x",
        "references" => ["definitely-missing"]
      })
    )

    assert %{"type" => "input_receipt", "error" => "not_controller"} = recv_json(observer)

    send_json(
      controller,
      Map.merge(status, %{
        "command" => "submit_input",
        "sender_id" => "x",
        "kind" => "normal",
        "prompt" => "tcp",
        "references" => []
      })
    )

    assert %{"type" => "input_receipt"} = recv_json(controller)
    assert %{"type" => "patch", "seq" => seq1, "ops" => ops1} = recv_json(controller)
    assert Enum.any?(ops1, &(&1["op"] == "set_inbox"))
    assert %{"type" => "patch", "seq" => seq2, "ops" => ops2} = recv_json(legacy)
    assert seq2 == seq1
    refute Enum.any?(ops2, &(&1["op"] == "set_inbox"))
    refute JSON.encode!(Elara.snapshot(session)) =~ "base64"
    Enum.each([controller, observer, legacy], &:gen_tcp.close/1)
  end

  test "store rejects duplicate inbox IDs and cross-session headers and owns submitted file bytes" do
    root =
      Path.join(System.tmp_dir!(), "elara-queue-validation-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    store = %{Store.new(root) | path: Path.join(root, "queue.jsonl")}

    entry = %{
      id: "same",
      session_id: store.id,
      sender_id: "sender",
      kind: :normal,
      state: :queued,
      user: Message.user("owned"),
      created_at: 1,
      error: nil
    }

    {:ok, store} = Store.put_inbox(store, [entry], true)

    [header | rest] =
      File.read!(store.path) |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    duplicate =
      put_in(
        header,
        ["inbox", "entries"],
        header["inbox"]["entries"] ++ header["inbox"]["entries"]
      )

    File.write!(store.path, Enum.map_join([duplicate | rest], "\n", &JSON.encode!/1) <> "\n")
    assert {:error, :bad_header} = Store.open(store.path, root)

    foreign = put_in(header, ["inbox", "entries", Access.at(0), "sessionId"], "foreign")
    File.write!(store.path, Enum.map_join([foreign | rest], "\n", &JSON.encode!/1) <> "\n")
    assert {:error, :bad_header} = Store.open(store.path, root)

    File.write!(Path.join(root, "source.txt"), "original bytes")
    {:ok, user} = Elara.Attachment.prepare(root, "attached", ["source.txt"], [])
    immutable_store = %{Store.new(root) | path: Path.join(root, "immutable.jsonl")}
    immutable = %{entry | id: "immutable", user: user, session_id: immutable_store.id}

    {:ok, _} =
      Store.put_inbox(
        immutable_store,
        [immutable],
        true
      )

    File.write!(Path.join(root, "source.txt"), "changed bytes")
    {:ok, reopened} = Store.open(Path.join(root, "immutable.jsonl"), root)
    assert hd(hd(reopened.inbox).user.attachments)["content"] == "original bytes"
  end
end
