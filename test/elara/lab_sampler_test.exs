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

  test "coordinator mailbox is sampled without tripping the session mailbox guard" do
    owner = self()
    for i <- 1..5, do: send(owner, {:coordinator_backlog, i})

    sampler =
      Sampler.start(
        owner: owner,
        sample_ms: 10,
        listen: nil,
        server_port: nil,
        clients: :ets.new(:clients, [:public]),
        stub_os_pid: nil,
        guard_memory_bytes: 1,
        guard_mailbox: 1
      )

    assert_receive {:guard, :memory, _, _}, 1_000
    result = Sampler.stop(sampler)

    coordinator = result.mailboxes.baseline.coordinator
    assert Enum.any?(Map.keys(coordinator.counts), &(&1 >= 5))
    refute_received {:guard, :mailbox, _, _}

    for i <- 1..5, do: assert_receive({:coordinator_backlog, ^i})
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

  defp start_probed(target, extra \\ []) do
    Sampler.start(
      [
        owner: self(),
        sample_ms: 20,
        listen: nil,
        server_port: nil,
        clients: :ets.new(:clients, [:public]),
        stub_os_pid: nil,
        guard_memory_bytes: 1_000_000_000_000,
        guard_mailbox: 1_000_000,
        probe: true,
        probe_target: target
      ] ++ extra
    )
  end

  defp spin_until(at),
    do: if(System.monotonic_time(:millisecond) < at, do: spin_until(at), else: :ok)

  defp traced_target do
    test = self()

    spawn(fn ->
      receive do: (:go -> :ok)
      spin_until(System.monotonic_time(:millisecond) + 15)
      send(test, :spun)
      receive do: (:again -> :ok)
      receive do: (:never -> :ok)
    end)
  end

  test "with the probe on, a running trace times the target's on and off CPU, then is destroyed" do
    target = traced_target()
    on_exit(fn -> Process.exit(target, :kill) end)
    sampler = start_probed(target)

    send(target, :go)
    assert_receive :spun, 2_000
    spin_until(System.monotonic_time(:millisecond) + 5)
    send(target, :again)
    Process.sleep(40)
    result = Sampler.stop(sampler)

    buckets = result.running
    assert Enum.sum(Enum.map(buckets, & &1.running_us)) > 0
    assert Enum.sum(Enum.map(buckets, & &1.ins)) >= 1
    assert Enum.sum(for b <- buckets, {_mfa, us} <- b.off_us, do: us) > 0
    assert Enum.all?(buckets, &(is_integer(&1.start) and is_map(&1.outs)))
    assert result.probe != [] and Enum.all?(result.probe, &(is_integer(&1.t) and &1.phase))
    assert :trace.session_info(target) == []
  end

  test "a killed sampler's trace session is destroyed" do
    target = traced_target()
    on_exit(fn -> Process.exit(target, :kill) end)
    sampler = start_probed(target)
    assert :trace.session_info(target) != []

    Process.exit(sampler, :kill)
    wait_for(fn -> :trace.session_info(target) end, &(&1 == []))
  end

  test "with the probe off, the sampler reports no probe data and creates no trace session" do
    before = :trace.session_info(:all)

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

    Process.sleep(50)
    assert :trace.session_info(:all) == before
    result = Sampler.stop(sampler)

    refute Map.has_key?(result, :probe)
    refute Map.has_key?(result, :running)
    assert :trace.session_info(:all) == before
  end

  test "with the probe off, starting a sampler leaves nothing in the caller's mailbox" do
    {:message_queue_len, before} = Process.info(self(), :message_queue_len)

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

    refute_receive {_ref, :ready}, 100
    assert Process.info(self(), :message_queue_len) == {:message_queue_len, before}
    Sampler.stop(sampler)
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
