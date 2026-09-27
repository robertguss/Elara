defmodule Elara.LabTest do
  use ExUnit.Case, async: false

  defmodule Checked do
    @behaviour Elara.Lab
    @impl true
    def run(%{seed: seed, dir: dir}) do
      File.write!(Path.join(dir, "evidence"), "kept")
      send(Process.whereis(:lab_test), {:dir, seed, dir})
      %{checks: %{even_seed: rem(seed, 2) == 0, always: true}, cleanup_confirmed: seed != 5}
    end
  end

  # A run with unconfirmed cleanup (or a raise) leaves its sessions root bound.
  setup do
    previous = Map.new([:sessions_root, :skills_home], &{&1, Application.get_env(:elara, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:elara, key, value) end)
    end)
  end

  @params %{"sessions" => "2", "turns" => "3", "rate_limited_pct" => "20", "ttft_ms" => "5"}

  test "a seed reproduces the scenario's choices and a different seed changes them" do
    {:ok, [first]} = Elara.Lab.run("smoke", seed: 11, params: @params)
    {:ok, [again]} = Elara.Lab.run("smoke", seed: 11, params: @params)
    {:ok, [other]} = Elara.Lab.run("smoke", seed: 12, params: @params)

    assert first.choices_digest == again.choices_digest
    refute first.choices_digest == other.choices_digest
    assert first.completed_turns + first.failed_turns == 6
    assert %{count: count, p50: _, p95: _, p99: _} = first.latency_ms
    assert count > 0
  end

  test "repetitions use consecutive seeds and isolated state roots" do
    home = Application.fetch_env!(:elara, :sessions_root)
    {:ok, results} = Elara.Lab.run("smoke", seed: 3, n: 2, params: @params)

    assert Enum.map(results, & &1.seed) == [3, 4]
    assert Application.fetch_env!(:elara, :sessions_root) == home

    summary = Elara.Lab.summarize(results)
    assert summary.repetitions == 2
    assert length(summary.choices_digests) == 2
  end

  test "results are written as one JSON line per repetition" do
    root = Path.join(System.tmp_dir!(), "lab-results-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, results} = Elara.Lab.run("smoke", seed: 5, n: 2, params: @params)

    path = Elara.Lab.write_results(root, results)
    lines = path |> File.read!() |> String.split("\n", trim: true)

    assert [%{"seed" => 5, "scenario" => "smoke"}, %{"seed" => 6}] =
             Enum.map(lines, &JSON.decode!/1)
  end

  test "real mode refuses a request cap below one request per turn, before any network use" do
    params = %{"sessions" => "2", "turns" => "2"}

    assert_raise RuntimeError, ~r/below one request per turn/, fn ->
      Elara.Lab.run("smoke", seed: 1, provider: :real, max_requests: 3, params: params)
    end

    assert_raise RuntimeError, ~r/requires --max-requests/, fn ->
      Elara.Lab.run("smoke", seed: 1, provider: :real, params: params)
    end
  end

  test "unknown scenarios are rejected with the known list" do
    assert {:error,
            {:unknown_scenario, "nope",
             ["concurrency", "concurrent_jobs", "provider_fault", "session_crash", "smoke"]}} =
             Elara.Lab.run("nope", seed: 1)
  end

  test "failed checks keep evidence; unconfirmed cleanup keeps the root bound and stops" do
    Process.register(self(), :lab_test)
    root = Application.fetch_env!(:elara, :sessions_root)
    {:ok, results} = Elara.Lab.run(Checked, seed: 2, n: 5)

    assert Enum.map(results, & &1.seed) == [2, 3, 4, 5]
    assert Enum.map(results, &Elara.Lab.failed_checks/1) == [[], [:even_seed], [], [:even_seed]]
    dirs = for seed <- 2..5, do: receive(do: ({:dir, ^seed, dir} -> dir))
    refute_received {:dir, 6, _}
    [passed, failed, _, unsettled] = dirs
    pid = System.pid()

    assert Enum.all?(
             dirs,
             &(Path.basename(&1) =~ ~r/^elara-lab-checked-\d+-#{pid}-[0-9a-f]{16}$/)
           )

    assert length(Enum.uniq(dirs)) == 4
    on_exit(fn -> Enum.each(dirs, &File.rm_rf!/1) end)

    refute File.exists?(passed)
    assert File.read!(Path.join(failed, "evidence")) == "kept"
    assert Enum.at(results, 1).evidence_dir == failed
    assert List.last(results).retained_dir == unsettled
    assert Application.fetch_env!(:elara, :sessions_root) == Path.join(unsettled, "sessions")
    refute root == Path.join(unsettled, "sessions")

    summary = Elara.Lab.summarize(results)
    assert summary.failed_checks == %{even_seed: 2}
    assert summary.retained_dirs == [unsettled]
    assert summary.evidence_dirs == [failed]
  end

  # A GenServer a test can block inside a callback.
  defmodule Blocker do
    use GenServer, restart: :temporary
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    @impl true
    def init(nil), do: {:ok, nil}
    @impl true
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}

    def handle_call({:block, test}, _from, state) do
      send(test, {:blocked, self()})
      receive(do: (:unblock -> :ok))
      {:reply, :ok, state}
    end
  end

  # Test-supervised, so ExUnit stops it even while blocked or suspended.
  defp start_blocker(id), do: start_supervised!(Supervisor.child_spec(Blocker, id: id))

  defp sys_state(pid) do
    {:status, ^pid, _module, [_pdict, state | _]} = :sys.get_status(pid)
    state
  end

  defp await_sys_state(pid, state, tries \\ 200) do
    cond do
      sys_state(pid) == state ->
        :ok

      tries == 0 ->
        flunk("#{inspect(pid)} never became #{state}")

      true ->
        Process.sleep(10)
        await_sys_state(pid, state, tries - 1)
    end
  end

  # Stages a completion the transport has not accepted, under the run's root.
  defmodule HoldsTransport do
    @behaviour Elara.Lab
    @impl true
    def run(%{dir: dir}) do
      completions = Path.join([dir, "sessions", "_thread_messages", "completions"])
      File.mkdir_p!(completions)

      File.write!(
        Path.join(completions, "held.json"),
        JSON.encode!(%{
          "sender" => "held-sender",
          "recipient" => "held-recipient",
          "id" => "held-id",
          "text" => "held text",
          "evidence" => nil
        })
      )

      :ok = Elara.Lab.hold(Elara.Threads.Communication, 5_000)
      %{checks: %{}, cleanup_confirmed: true}
    end
  end

  defp restored_messages(root) do
    for path <- Path.wildcard(Path.join([root, "_thread_messages", "*.json"])),
        File.read!(path) =~ "held-sender",
        do: path
  end

  test "a held actor stays suspended until the root and the directory are final" do
    restored = Application.fetch_env!(:elara, :sessions_root)
    transport = Process.whereis(Elara.Threads.Communication)
    on_exit(fn -> if sys_state(transport) == :suspended, do: :sys.resume(transport) end)
    test = self()

    before_release = fn dir ->
      send(test, {:checked, dir})
      assert Application.fetch_env!(:elara, :sessions_root) == restored
      refute File.exists?(dir)
      assert sys_state(transport) == :suspended
      send(transport, :deliver)
      assert {:messages, messages} = Process.info(transport, :messages)
      assert :deliver in messages
    end

    {:ok, [result]} = Elara.Lab.run(HoldsTransport, seed: 1, before_release: before_release)
    assert_received {:checked, _dir}
    refute Map.has_key?(result, :retained_dir)
    assert sys_state(transport) == :running
    # A round trip follows the queued tick, which ran under the restored root.
    :sys.get_state(transport)
    assert restored_messages(restored) == []
  end

  defmodule HoldsThenRaises do
    @behaviour Elara.Lab
    @impl true
    def run(_context) do
      :ok = Elara.Lab.hold(Process.get(:lab_held), 5_000)
      raise "scenario failed after holding"
    end
  end

  test "a held actor is released on the raise path" do
    blocker = start_blocker(:blocker)
    Process.put(:lab_held, blocker)
    test = self()

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert_raise RuntimeError, fn ->
        Elara.Lab.run(HoldsThenRaises, seed: 1, before_release: &send(test, {:dir, &1}))
      end
    end)

    assert_received {:dir, dir}
    on_exit(fn -> File.rm_rf!(dir) end)
    assert sys_state(blocker) == :running
    assert GenServer.call(blocker, :ping) == :pong
  end

  defmodule HoldsTwo do
    @behaviour Elara.Lab
    @impl true
    def run(_context) do
      [first, second] = Process.get(:lab_held)
      :ok = Elara.Lab.hold(first, 5_000)
      :ok = Elara.Lab.hold(second, 5_000)
      ref = Process.monitor(first)
      Process.exit(first, :kill)
      receive(do: ({:DOWN, ^ref, _, _, _} -> :ok))
      %{checks: %{}, cleanup_confirmed: true}
    end
  end

  test "every held actor is released even when an earlier release fails" do
    first = start_blocker(:first)
    second = start_blocker(:second)
    Process.put(:lab_held, [first, second])
    {:ok, [_result]} = Elara.Lab.run(HoldsTwo, seed: 1)
    assert sys_state(second) == :running
    assert GenServer.call(second, :ping) == :pong
  end

  test "holding an unregistered name or a dead pid reports an error" do
    assert {:error, :noproc} = Elara.Lab.hold(:no_such_lab_process, 100)
    {pid, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert {:error, _reason} = Elara.Lab.hold(pid, 100)
  end

  # A suspend that times out while the target is busy still takes effect later.
  defmodule HoldsLate do
    @behaviour Elara.Lab
    @impl true
    def run(_context) do
      blocker = Process.get(:lab_held)
      test = self()
      spawn(fn -> GenServer.call(blocker, {:block, test}, :infinity) end)
      receive(do: ({:blocked, ^blocker} -> :ok))
      {:error, {:timeout, _}} = Elara.Lab.hold(blocker, 100)
      send(blocker, :unblock)
      %{checks: %{}, cleanup_confirmed: true}
    end
  end

  test "a hold that times out and takes effect later is still released" do
    blocker = start_blocker(:blocker)
    Process.put(:lab_held, blocker)
    test = self()

    before_release = fn _dir ->
      await_sys_state(blocker, :suspended)
      send(test, :was_suspended)
    end

    {:ok, [_result]} = Elara.Lab.run(HoldsLate, seed: 1, before_release: before_release)
    assert_received :was_suspended
    assert sys_state(blocker) == :running
    assert GenServer.call(blocker, :ping) == :pong
  end

  test "a choice log digests choices per id in request order" do
    log = Elara.Lab.choice_log()

    for {id, n, c} <- [{"a", 1, :x}, {"b", 1, :y}, {"a", 2, :z}],
        do: send(log, {:lab_choice, id, n, c})

    assert Elara.Lab.choices_digest(log) == Elara.Lab.digest(%{"a" => [:x, :z], "b" => [:y]})
  end

  defmodule Precomputed do
    @behaviour Elara.Lab
    @impl true
    def run(%{seed: seed}),
      do: %{latency_ms: %{count: 3, p50: seed, p95: :infinity, p99: :infinity, max: :infinity}}
  end

  test "a scenario's precomputed latency map passes through; spreads skip infinity" do
    {:ok, results} = Elara.Lab.run(Precomputed, seed: 4, n: 2)
    assert [%{latency_ms: %{p50: 4, p95: :infinity}}, %{latency_ms: %{p50: 5}}] = results

    summary = Elara.Lab.summarize(results)
    assert summary.latency_p50_ms == %{min: 4, mean: 4.5, max: 5}
    assert summary.latency_p95_ms == %{min: nil, mean: nil, max: nil, infinite: 2}
  end

  test "host metadata names the machine, runtime and commit" do
    host = Elara.Lab.host()
    assert host.logical_cpus > 0 and host.schedulers > 0
    assert is_binary(host.otp) and is_binary(host.elixir)
    assert Map.has_key?(host, :dirty) and (is_binary(host.commit) or is_nil(host.commit))
  end

  test "percentiles use nearest rank" do
    assert %{count: 100, p50: 50, p95: 95, p99: 99, max: 100} =
             Elara.Lab.percentiles(Enum.to_list(1..100))

    assert Elara.Lab.percentiles([]) == nil
  end
end
