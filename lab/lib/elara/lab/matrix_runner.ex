defmodule Elara.Lab.MatrixRunner do
  @moduledoc "Bounded frozen-code matrix launch; retained rows never substitute outcome for causal evidence."
  alias Elara.Lab.{Matrix, MatrixPeer, ProcessProbe, VM}

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
end
