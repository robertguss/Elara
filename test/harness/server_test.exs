defmodule Harness.ServerTest do
  use ExUnit.Case, async: false

  alias Harness.Message
  alias Harness.Message.ToolCall
  alias Harness.Protocol

  defp asst(text, calls \\ []) do
    {:ok, assistant} = Message.assistant(text, calls)
    assistant
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Harness.Provider.Scripted, agent}
  end

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])

    socket
  end

  defp send_json(socket, message), do: :gen_tcp.send(socket, Protocol.encode(message))

  defp recv_json(socket, timeout \\ 2_000) do
    {:ok, line} = :gen_tcp.recv(socket, 0, timeout)
    {:ok, message} = Protocol.decode(line)
    message
  end

  defp attach(socket, session, mode, cursor, incarnation) do
    :ok =
      send_json(socket, %{
        "version" => Protocol.version(),
        "command" => "attach",
        "session_id" => session,
        "mode" => mode,
        "cursor" => cursor,
        "incarnation" => incarnation
      })

    recv_json(socket)
  end

  test "stable IDs resolve to live sessions while PID compatibility remains" do
    {:ok, session} =
      Harness.start_session(provider: script([{:ok, asst("hello")}]), tools: [], persist: false)

    assert is_binary(session)
    assert {:ok, pid} = Harness.session_pid(session)
    assert {:ok, ^pid} = Harness.session_pid(pid)
    assert {:ok, "hello"} = Harness.ask(session, "hi")
    assert Harness.transcript(pid) == Harness.transcript(session)
  end

  test "client detaches during a tool, replays exactly once, and observers cannot control" do
    call = %ToolCall{
      id: "slow-1",
      name: "bash",
      args: {:ok, %{"command" => "sleep 0.2; printf finished"}}
    }

    provider = script([{:ok, asst(nil, [call])}, {:ok, asst("continued")}])
    {:ok, server} = Harness.Server.start_link(port: 0, provider: provider)
    port = Harness.Server.port(server)

    controller = connect(port)

    :ok =
      send_json(controller, %{
        "version" => Protocol.version(),
        "command" => "create",
        "mode" => "control",
        "cwd" => File.cwd!()
      })

    %{
      "type" => "attached",
      "session_id" => session,
      "incarnation" => incarnation,
      "head" => 0
    } = recv_json(controller)

    :ok =
      send_json(controller, %{
        "version" => Protocol.version(),
        "command" => "ask",
        "prompt" => "run it"
      })

    assert %{"type" => "ok"} = recv_json(controller)
    assert %{"type" => "event", "seq" => 1} = recv_json(controller)
    assert %{"type" => "event", "seq" => 2} = recv_json(controller)

    assert %{"type" => "event", "seq" => 3, "event" => %{"kind" => "message_appended"}} =
             recv_json(controller)

    assert %{"type" => "event", "seq" => 4, "event" => %{"kind" => "tool_started"}} =
             recv_json(controller)

    :ok = :gen_tcp.close(controller)
    {:ok, session_pid} = Harness.session_pid(session)
    assert Process.alive?(session_pid)

    Process.sleep(50)
    observer = connect(port)

    assert %{"type" => "attached", "mode" => "observe"} =
             attach(observer, session, "observe", 4, incarnation)

    :ok =
      send_json(observer, %{
        "version" => Protocol.version(),
        "command" => "ask",
        "prompt" => "not allowed"
      })

    assert %{"type" => "error", "error" => "not_controller"} = recv_json(observer)

    replayed = Enum.map(5..7, fn seq -> {seq, recv_json(observer, 3_000)} end)

    assert Enum.map(replayed, &elem(&1, 0)) == [5, 6, 7]

    assert Enum.map(replayed, fn {seq, event} -> {seq, event["seq"]} end) ==
             [{5, 5}, {6, 6}, {7, 7}]

    assert {7, %{"event" => %{"kind" => "turn_ended"}}} = List.last(replayed)

    second_observer = connect(port)

    assert %{"type" => "attached", "mode" => "observe"} =
             attach(second_observer, session, "observe", 7, incarnation)

    :ok = :gen_tcp.close(observer)
    :ok = :gen_tcp.close(second_observer)
  end

  test "cursor and controller validation reject ambiguous replay" do
    {:ok, session} =
      Harness.start_session(provider: script([{:ok, asst("done")}]), tools: [], persist: false)

    assert {:ok, first} = Harness.attach(session, :control)

    assert {:error, :control_taken} =
             Task.async(fn -> Harness.attach(session, :control) end) |> Task.await()

    assert {:error, :invalid_cursor} = Harness.attach(session, :observe, 1, first.incarnation)
    assert {:error, :stale_incarnation} = Harness.attach(session, :observe, 0, "old")
  end
end
