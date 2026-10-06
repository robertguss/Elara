defmodule Elara.Lab.MatrixRunner do
  @moduledoc "Bounded frozen-code matrix launch; retained rows never substitute outcome for causal evidence."
  alias Elara.Lab.{Artifacts, Matrix, MatrixPeer, ProcessProbe, VM}

  def registration(repo, qualification_root, measurement_root) do
    artifacts = Artifacts.snapshot(Path.expand(repo))

    %{
      schema: 1,
      commit: artifacts.source.commit,
      repo: Path.expand(repo),
      artifacts: artifacts,
      timeout_ms: 60_000,
      qualification: %{root: Path.expand(qualification_root), cells: Matrix.plan(1, 1_084_900)},
      measurement: %{root: Path.expand(measurement_root), cells: Matrix.plan(50, 1_085_000)}
    }
  end

  def cli([manifest, mode]) when mode in ["qualification", "measurement"] do
    summary = run(manifest, mode)
    IO.puts(JSON.encode!(summary))
    System.halt(if(summary.completed, do: 0, else: 1))
  end

  def run(manifest_path, mode) when mode in ["qualification", "measurement"] do
    manifest_path = Path.expand(manifest_path)
    bytes = File.read!(manifest_path)
    manifest = JSON.decode!(bytes)

    expected =
      if mode == "measurement", do: Matrix.plan(50, 1_085_000), else: Matrix.plan(1, 1_084_900)

    true = manifest["schema"] == 1 and manifest["timeout_ms"] == 60_000
    true = manifest[mode]["cells"] == json(expected)
    true = manifest["artifacts"]["source"] == %{"commit" => manifest["commit"], "dirty" => false}
    true = Artifacts.verify(manifest["artifacts"]).verified
    root = manifest[mode]["root"]
    File.mkdir_p!(Path.dirname(root))
    File.mkdir!(root)
    frozen_manifest = Path.join(root, "registration.json")
    File.write!(frozen_manifest, bytes, [:sync])

    results =
      Enum.reduce_while(expected, [], fn cell, results ->
        row_root = Path.join(root, String.pad_leading(to_string(cell.index), 4, "0"))

        result =
          execute(cell, frozen_manifest, row_root,
            repo: manifest["repo"],
            commit: manifest["commit"]
          )

        IO.puts(
          JSON.encode!(%{index: cell.index, case_id: cell.case_id, verdict: result.verdict})
        )

        next = [result | results]
        if result.verdict.stop, do: {:halt, next}, else: {:cont, next}
      end)
      |> Enum.reverse()

    summary = summarize(results, length(expected))
    VM.write(root, "summary", summary)
    summary
  end

  # The lower-level entry permits disposable fixture peers and short deadlines in controls.
  # Registered runs above always use MatrixPeer and the fixed 60-second bound.
  def execute(cell, manifest_path, root, opts \\ []) do
    File.mkdir!(root)
    repo = Keyword.fetch!(opts, :repo)
    peer = Keyword.get(opts, :peer, MatrixPeer)
    started = System.monotonic_time(:millisecond)

    case VM.start(root, "matrix", peer, [
           root,
           repo,
           manifest_path,
           cell.scenario,
           to_string(cell.seed),
           JSON.encode!(cell.params)
         ]) do
      {:ok, owner} ->
        execute_owned(owner, cell, root, opts, started)

      {:error, reason} ->
        result = %{
          cell: cell,
          launch: %{},
          boot: nil,
          outer: %{stopped: false},
          error: inspect({:launch_failed, reason}),
          report: nil,
          elapsed_ms: System.monotonic_time(:millisecond) - started,
          verdict: Matrix.judge(nil, cell, Keyword.get(opts, :commit))
        }

        VM.write(root, "record", result)
        result
    end
  end

  defp execute_owned(owner, cell, root, opts, started) do
    key = {__MODULE__, make_ref()}
    Process.put(key, %{})

    outcome =
      try do
        launch = VM.snapshot(owner) |> Map.take([:os_pid, :port_owned])
        Process.put(key, %{launch: launch})
        Keyword.get(opts, :after_launch, fn _ -> :ok end).(owner)
        deadline = started + Keyword.get(opts, :timeout, 60_000)
        wait_result(owner, root, deadline)
      rescue
        error -> %{report: VM.read(root, "observed"), error: Exception.message(error)}
      catch
        kind, reason -> %{report: VM.read(root, "observed"), error: inspect({kind, reason})}
      after
        state = Process.get(key)

        outer =
          try do
            VM.stop(owner) |> Map.take([:os_pid, :exit_status, :port_down, :stopped, :error])
          catch
            kind, reason -> %{stopped: false, error: inspect({kind, reason})}
          end

        Process.put(key, Map.put(state, :outer, outer))
      end

    state = Process.delete(key)
    launch = Map.get(state, :launch, %{})
    boot = VM.read(root, "boot")
    outer = state.outer
    cleanup = outer.stopped and boot_stopped?(boot, launch)
    report = annotate(outcome.report, boot, launch, outer, cleanup, outcome.error == nil)
    verdict = Matrix.judge(report, cell, Keyword.get(opts, :commit))

    result = %{
      cell: cell,
      launch: launch,
      boot: boot,
      outer: outer,
      error: outcome.error,
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      report: report,
      verdict: verdict
    }

    VM.write(root, "record", result)
    result
  end

  def summarize(results, expected) do
    groups = Enum.group_by(results, & &1.cell.case_id)

    %{
      expected: expected,
      recorded: length(results),
      completed: length(results) == expected and Enum.all?(results, &(not &1.verdict.stop)),
      eligible: Enum.count(results, & &1.verdict.eligible),
      passed: Enum.count(results, & &1.verdict.passed),
      outcome_failures: Enum.count(results, &(&1.verdict.eligible and not &1.verdict.passed)),
      ineligible: Enum.count(results, &(not &1.verdict.eligible)),
      unconfirmed_cleanup: Enum.count(results, &(not &1.verdict.cleanup_confirmed)),
      cases:
        Map.new(groups, fn {name, rows} ->
          {name,
           %{
             recorded: length(rows),
             eligible: Enum.count(rows, & &1.verdict.eligible),
             passed: Enum.count(rows, & &1.verdict.passed),
             recovery_ms: timings(rows, "recovery_ms"),
             backlog_ms: timings(rows, "backlog_ms"),
             failed_checks:
               rows |> Enum.flat_map(& &1.verdict.failed_checks) |> Enum.frequencies()
           }}
        end)
    }
  end

  defp timings(rows, key) do
    samples =
      for row <- rows, row.verdict.eligible, value = row.report[key], is_number(value), do: value

    Elara.Lab.percentiles(samples)
  end

  defp wait_result(owner, root, deadline) do
    cond do
      report = VM.read(root, "finished") ->
        VM.wait(fn -> VM.snapshot(owner).port_down end, 5_000)
        %{report: report, error: nil}

      rejected = VM.read(root, "rejected") ->
        %{report: nil, error: inspect(rejected)}

      VM.snapshot(owner).port_down ->
        %{report: VM.read(root, "observed"), error: "peer_exited_without_finished_row"}

      System.monotonic_time(:millisecond) >= deadline ->
        %{report: VM.read(root, "observed"), error: "deadline"}

      true ->
        Process.sleep(10)
        wait_result(owner, root, deadline)
    end
  end

  defp annotate(report, boot, launch, outer, cleanup, finished) when is_map(report) do
    peer = if is_map(report["matrix_peer"]), do: report["matrix_peer"], else: %{}

    matched =
      finished and is_map(boot) and boot["phase"] == "ready" and boot["os_pid"] == launch[:os_pid] and
        boot["artifacts_verified"] == true and
        peer["os_pid"] == launch[:os_pid] and launch[:port_owned] == true and
        outer[:exit_status] == 0

    peer =
      peer
      |> Map.put("outer_cleanup_confirmed", cleanup)
      |> Map.put("outer_launcher_verified", matched)

    Map.put(report, "matrix_peer", peer)
  end

  defp annotate(report, _boot, _launch, _outer, _cleanup, _finished), do: report

  defp boot_stopped?(%{"os_pid" => pid, "phase" => "preflight"}, %{os_pid: pid}), do: true

  defp boot_stopped?(%{"os_pid" => pid, "phase" => "ready", "stub" => stub, "stubs" => stubs}, %{
         os_pid: pid
       })
       when is_list(stubs) and stubs != [] do
    stub in stubs and Enum.all?(stubs, &(is_integer(&1) and &1 > 0)) and
      VM.wait(fn -> Enum.all?(stubs, &ProcessProbe.stopped?/1) end, 5_000) == true
  end

  defp boot_stopped?(_boot, _launch), do: false
  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end
