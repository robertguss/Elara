defmodule Elara.Lab.SamplerTest do
  use ExUnit.Case, async: false

  alias Elara.Lab.Sampler

  test "connection discovery finds exactly the server's connection owners" do
    {:ok, server} = Elara.Server.start(port: 0)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    port = Elara.Server.port(server)
    listen = :sys.get_state(server).listen
    assert is_port(listen)

    # An unrelated listening socket and two raw clients of the server.
    {:ok, other} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    clients = for _ <- 1..2, do: elem(:gen_tcp.connect({127, 0, 0, 1}, port, [:binary]), 1)
    on_exit(fn -> Enum.each([other | clients], &:gen_tcp.close/1) end)

    owners = wait_for(fn -> Sampler.connections(listen, port) end, &(length(&1) == 2))

    peers =
      for pid <- owners,
          socket <- Port.list(),
          Port.info(socket, :connected) == {:connected, pid},
          {:ok, peer} = :inet.peername(socket),
          do: peer

    assert Enum.sort(peers) == Enum.sort(for c <- clients, do: elem(:inet.sockname(c), 1))
    refute self() in owners
    refute server in owners
  end

  test "discovery is unavailable, not empty, without a port-backed listener" do
    assert Sampler.connections(:not_a_port, 4048) == nil
  end

  test "an unreadable stub RSS is unavailable, not zero" do
    assert Sampler.stub_rss(nil) == nil
    assert Sampler.stub_rss(999_999_999) == nil

    assert is_integer(Sampler.stub_rss(String.to_integer(System.pid()))) and
             Sampler.stub_rss(String.to_integer(System.pid())) > 0
  end

  test "mailbox and memory samples accumulate; the memory guard reports once" do
    sampler =
      Sampler.start(
        owner: self(),
        sample_ms: 20,
        listen: nil,
        server_port: nil,
        clients: :ets.new(:clients, [:public]),
        stub_os_pid: nil,
        guard_memory_bytes: 1,
        guard_mailbox: 1_000_000
      )

    assert_receive {:guard, :memory, _at, total} when total > 1, 1_000
    Process.sleep(100)
    refute_received {:guard, :memory, _, _}
    result = Sampler.stop(sampler)
    assert length(result.samples) >= 3
    assert Enum.all?(result.samples, &(is_integer(&1.total) and &1.stub_rss == nil))
    assert result.mailboxes.baseline.connection.unavailable == length(result.samples)
    assert result.mailboxes.baseline.exec.unavailable == 0
  end

  test "samples and mailboxes are phased; a cutoff ends the window early" do
    sampler =
      Sampler.start(
        owner: self(),
        sample_ms: 10,
        listen: nil,
        server_port: nil,
        clients: :ets.new(:clients, [:public]),
        stub_os_pid: nil,
        guard_memory_bytes: 1_000_000_000_000,
        guard_mailbox: 1_000_000
      )

    Process.sleep(40)
    t0 = System.monotonic_time(:millisecond)
    shared = Elara.Lab.Client.shared(t0)
    Sampler.load(sampler, t0, t0 + 50, t0 + 10_000, shared)
    Process.sleep(150)
    cutoff = Elara.Lab.Client.cut(shared, System.monotonic_time(:millisecond))
    Process.sleep(60)
    result = Sampler.stop(sampler)

    by_phase = Enum.group_by(result.samples, & &1.phase)
    assert Enum.all?([:baseline, :warmup, :window, :after], &Map.has_key?(by_phase, &1))
    assert Enum.all?(by_phase.window, &(&1.t >= t0 + 50 and &1.t < cutoff))
    assert Enum.all?(by_phase.after, &(&1.t >= cutoff))

    for {phase, samples} <- by_phase do
      exec = result.mailboxes[phase].exec
      assert Enum.sum(Map.values(exec.counts)) + exec.unavailable == length(samples)
    end
  end

  defp wait_for(fun, done?, tries \\ 50) do
    value = fun.()

    cond do
      done?.(value) -> value
      tries == 0 -> flunk("condition not reached: #{inspect(value)}")
      true -> Process.sleep(20) && wait_for(fun, done?, tries - 1)
    end
  end
end
