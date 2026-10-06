defmodule Elara.Lab.MatrixPeer do
  @moduledoc "No-compile disposable lab peer; source/build preflight precedes application admission."
  alias Elara.Lab.{Artifacts, ProcessProbe, VM}

  def run([root, repo, manifest_path, scenario, seed, params]) do
    File.cd!(repo)
    tmp = Path.join(root, "tmp")
    File.mkdir_p!(tmp)
    System.put_env("TMPDIR", tmp)
    manifest = manifest_path |> File.read!() |> JSON.decode!()
    verification = Artifacts.verify(manifest["artifacts"])
    source = manifest["artifacts"]["source"]

    boot = %{
      os_pid: String.to_integer(System.pid()),
      phase: "preflight",
      artifacts_verified: verification.verified,
      source: source
    }

    VM.write(root, "boot", boot)

    unless verification.verified and source["dirty"] == false and
             source["commit"] == manifest["commit"] do
      VM.write(root, "rejected", %{reason: "source_or_artifacts", verification: verification})
      System.halt(1)
    end

    :ok = Application.load(:elara)
    Application.put_env(:elara, :sessions_root, Path.join(root, "controller-sessions"))
    Application.put_env(:elara, :skills_home, Path.join(root, "home"))
    Application.put_env(:elara, :max_restarts, 3)
    VM.write(root, "boot", Map.put(boot, :phase, "starting"))
    {:ok, _} = Application.ensure_all_started(:elara)
    {:ok, {flags, _}} = :sys.get_state(Elara.Supervisor) |> Tuple.to_list() |> List.last()
    %{available: true, jobs: 0, os_pid: stub} = Elara.Exec.status()

    peer = %{
      max_restarts: flags.intensity,
      period: flags.period,
      artifacts_verified: true,
      os_pid: boot.os_pid,
      stub: stub
    }

    VM.write(root, "boot", Map.merge(boot, Map.merge(peer, %{phase: "ready"})))

    true =
      peer.max_restarts == 3 and peer.period == 5 and :erlang.system_info(:schedulers_online) == 2

    {:ok, [row]} =
      Elara.Lab.run(scenario, seed: String.to_integer(seed), params: JSON.decode!(params))

    VM.write(root, "observed", Map.put(row, :matrix_peer, peer))
    %{available: true, jobs: 0, os_pid: final_stub} = Elara.Exec.status()
    stubs = Enum.uniq([stub, final_stub])
    peer = Map.put(peer, :stubs, stubs)
    VM.write(root, "boot", Map.merge(boot, Map.merge(peer, %{phase: "ready"})))
    :ok = Application.stop(:elara)
    true = VM.wait(fn -> Enum.all?(stubs, &ProcessProbe.stopped?/1) end, 5_000) == true
    final_verification = Artifacts.verify(manifest["artifacts"])
    peer = Map.put(peer, :artifacts_verified, final_verification.verified)
    VM.write(root, "finished", Map.put(row, :matrix_peer, peer))
    System.halt(0)
  end
end
