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
