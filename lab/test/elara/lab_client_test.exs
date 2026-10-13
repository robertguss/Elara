defmodule Elara.Lab.ClientTest do
  use ExUnit.Case, async: true

  alias Elara.Lab.Client

  # A fake server: accepts one client, answers its attach, then relays test lines.
  defp start(opts \\ []) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    ledger = :ets.new(:ledger, [:ordered_set, :public])
    now = System.monotonic_time(:millisecond)
    shared = Client.shared(now - 10_000)

    client =
      Client.start(
        Keyword.merge(
          [
            owner: self(),
            sim_id: "u1c1",
            ledger: ledger,
            accounting: [
              sim_id: "u1c1",
              ttft_ms: 300,
              interval_ms: 20.0,
              answer_deltas: 5,
              window: {now - 60_000, now + 60_000}
            ],
            shared: shared,
            port: port,
            sample_ms: 10,
            guard_lag_ms: 60_000,
            bash_ms: 200,
            close_ms: 2_000,
            hold: false
          ],
          opts
        )
      )

    on_exit(fn -> Process.exit(client, :kill) end)
    test = self()
    spawn_link(fn -> send(test, {:attach, Client.attach(client, "session-1", 2_000)}) end)
    {:ok, socket} = :gen_tcp.accept(listen, 2_000)
    {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
    :ok = :gen_tcp.send(socket, JSON.encode!(%{"type" => "attached"}) <> "\n")
    assert_receive {:attach, :ok}

    %{
      client: client,
      socket: socket,
      ledger: ledger,
      shared: shared,
      request: JSON.decode!(request),
      now: now
    }
  end

  defp patch(ops), do: JSON.encode!(%{"type" => "patch", "seq" => 1, "ops" => ops}) <> "\n"

  defp delta(text),
    do: patch([%{"op" => "append_content_delta", "message_id" => "assistant-5", "text" => text}])

  test "the cutoff is written once: later cuts, sequential or concurrent, see the first" do
    shared = Client.shared(0)
    assert Client.cutoff(shared) == nil
    assert Client.cut(shared, -100) == -100
    assert Client.cut(shared, 200) == -100
    assert Client.cutoff(shared) == -100

    shared = Client.shared(0)

    cuts =
      1..50
      |> Task.async_stream(&Client.cut(shared, &1), max_concurrency: 50)
      |> Enum.map(&elem(&1, 1))

    assert [winner] = Enum.uniq(cuts)
    assert Client.cutoff(shared) == winner
  end

  test "the attach request observes with the five frozen extensions" do
    %{request: request} = start()

    assert %{"command" => "attach", "session_id" => "session-1", "mode" => "observe"} = request
    assert request["extensions"] == Client.extensions()
    assert length(Client.extensions()) == 5
  end

  test "bookkeeping never advances progress; an observed delta does" do
    %{client: client, socket: socket, ledger: ledger, shared: shared, now: now} = start()
    initial = Client.progress(shared)

    running = %{
      "op" => "set_tool_status",
      "id" => "c1",
      "status" => "running",
      "call" => %{"name" => "bash"}
    }

    :ok = :gen_tcp.send(socket, patch([running]))

    :ok =
      :gen_tcp.send(
        socket,
        patch([%{"op" => "set_tool_status", "id" => "c1", "status" => "succeeded"}])
      )

    :ok =
      :gen_tcp.send(socket, patch([%{"op" => "set_turn_state", "turn" => %{"state" => "idle"}}]))

    true = :ets.insert(ledger, {{"u1c1", 3}, now - 300, :answer, 0, :started})
    Process.sleep(60)
    assert Client.progress(shared) == initial

    :ok = :gen_tcp.send(socket, delta(String.pad_trailing("3:0", 20, ".")))
    Process.sleep(30)
    assert Client.progress(shared) > initial

    :ok = :gen_tcp.close(socket)
    Client.finish(client)
    assert_receive {:client_summary, ^client, "u1c1", summary}, 3_000
    assert summary.received == 1 and summary.close == :closed and summary.unattributed == 0
    assert :ets.select(ledger, [{{{"u1c1", :_}, :_, :_, :_, :_}, [], [true]}]) == []
  end

  test "a delta naming no ledger request is unattributed and does not advance progress" do
    %{client: client, socket: socket, shared: shared} = start()
    initial = Client.progress(shared)

    :ok = :gen_tcp.send(socket, delta(String.pad_trailing("9:0", 20, ".")))
    Process.sleep(30)
    assert Client.progress(shared) == initial

    :ok = :gen_tcp.close(socket)
    Client.finish(client)
    assert_receive {:client_summary, ^client, _, %{unattributed: 1, received: 0}}, 3_000
  end

  test "a held client reads nothing until it finishes, then drains to the close" do
    %{client: client, socket: socket, ledger: ledger, now: now} = start(hold: true)
    true = :ets.insert(ledger, {{"u1c1", 3}, now - 300, :answer, 2, :completed})

    for i <- 0..1, do: :ok = :gen_tcp.send(socket, delta(String.pad_trailing("3:#{i}", 20, ".")))
    :ok = :gen_tcp.close(socket)
    Process.sleep(50)
    refute_received {:client_summary, _, _, _}

    Client.finish(client)
    assert_receive {:client_summary, ^client, _, %{received: 2, close: :closed}}, 3_000
  end

  test "a provisional finish leaves the ledger rows for writers still running" do
    %{client: client, socket: socket, ledger: ledger, now: now} = start()
    true = :ets.insert(ledger, {{"u1c1", 3}, now - 300, :answer, 1, :started})
    :ok = :gen_tcp.close(socket)
    Client.finish(client, false)

    assert_receive {:client_summary, ^client, _, %{ledger_final: false, interrupted: 1}}, 3_000
    assert [_row] = :ets.lookup(ledger, {"u1c1", 3})
  end

  test "a client whose wire never closes reports a close timeout, never success" do
    %{client: client} = start(close_ms: 100)
    Client.finish(client)
    assert_receive {:client_summary, ^client, _, %{close: :close_timeout}}, 3_000
  end
end
