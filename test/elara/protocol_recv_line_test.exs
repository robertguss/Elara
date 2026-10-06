defmodule Elara.ProtocolRecvLineTest do
  use ExUnit.Case, async: true

  alias Elara.Protocol

  # A connected pair of passive line-mode sockets with a small receive buffer,
  # so long lines arrive in pieces.
  defp pair do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, buffer: 256])
    {:ok, port} = :inet.port(listen)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    {:ok, server} = :gen_tcp.accept(listen)
    :gen_tcp.close(listen)

    on_exit(fn ->
      :gen_tcp.close(server)
      :gen_tcp.close(client)
    end)

    {server, client}
  end

  test "reassembles a line longer than the receive buffer" do
    {server, client} = pair()
    line = String.duplicate("x", 50_000) <> "\n"

    for chunk <- for(<<c::binary-size(1_000) <- binary_part(line, 0, 50_000)>>, do: c) do
      :ok = :gen_tcp.send(client, chunk)
    end

    :ok = :gen_tcp.send(client, "\n")
    assert {:ok, ^line} = Protocol.recv_line(server, 5_000)
  end

  test "an incomplete line times out at the deadline" do
    {server, client} = pair()
    :ok = :gen_tcp.send(client, String.duplicate("y", 2_000))

    started = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = Protocol.recv_line(server, 200)
    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "sustained fragments do not renew the overall receive deadline" do
    {server, client} = pair()
    owner = self()

    {sender, sender_ref} =
      spawn_monitor(fn ->
        deadline = System.monotonic_time(:millisecond) + 3_000
        send_fragments(client, owner, deadline)
      end)

    on_exit(fn ->
      ref = Process.monitor(sender)
      Process.exit(sender, :kill)
      assert_receive {:DOWN, ^ref, :process, ^sender, _}, 1_000
    end)

    assert_receive {:fragment_sent, _at}, 1_000
    started = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = Protocol.recv_line(server, 200)
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert {:ok, [recv_cnt: count]} = :inet.getstat(server, [:recv_cnt])
    assert count > 1
    assert Process.alive?(sender)
    assert_receive {:fragment_sent, at} when at >= started + 200, 1_000

    Process.exit(sender, :kill)
    assert_receive {:DOWN, ^sender_ref, :process, ^sender, :killed}, 1_000
  end

  test "already buffered fragments cannot carry a partial line past the deadline" do
    {server, client} = pair()
    :ok = :gen_tcp.send(client, String.duplicate("b", 8_000) <> "\n")
    assert {:ok, first} = :gen_tcp.recv(server, 0, 1_000)
    refute String.ends_with?(first, "\n")

    assert {:error, :timeout} = Protocol.recv_line(server, 0)
  end

  defp send_fragments(socket, owner, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      :ok = :gen_tcp.send(socket, String.duplicate("f", 256))
      send(owner, {:fragment_sent, System.monotonic_time(:millisecond)})
      Process.sleep(10)
      send_fragments(socket, owner, deadline)
    end
  end

  test "a line over the protocol limit is rejected" do
    {server, client} = pair()
    chunk = String.duplicate("z", 1_048_576)

    sender =
      Task.async(fn ->
        for _ <- 1..17, do: :gen_tcp.send(client, chunk)
      end)

    assert {:error, :message_too_large} = Protocol.recv_line(server, 10_000)
    :gen_tcp.close(server)
    Task.await(sender, 10_000)
  end
end
