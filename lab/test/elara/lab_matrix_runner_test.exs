defmodule Elara.Lab.MatrixRunnerTest do
  use ExUnit.Case, async: false
  alias Elara.Lab.{Matrix, MatrixRunner, ProcessProbe, VM}

  setup do
    root =
      Path.join(System.tmp_dir!(), "elara-matrix-control-#{System.unique_integer([:positive])}")

    ebin = Path.join(root, "ebin")
    File.mkdir_p!(ebin)

    [{module, beam}] =
      Code.compile_string("""
      defmodule Elara.Lab.MatrixControlPeer do
        def run([root, _repo, _manifest, mode, _seed, _params]) do
          Elara.Lab.VM.write(root, "boot", %{os_pid: String.to_integer(System.pid()), phase: "preflight"})
          if mode == "finished" do
            Elara.Lab.VM.write(root, "finished", %{})
            System.halt(0)
          end
          Process.sleep(:infinity)
        end
      end
      """)

    File.write!(Path.join(ebin, Atom.to_string(module) <> ".beam"), beam)
    Code.prepend_path(ebin)
    {:ok, tracked} = Agent.start(fn -> [] end)

    on_exit(fn ->
      for owner <- Agent.get(tracked, & &1), Process.alive?(owner), do: VM.stop(owner)
      Agent.stop(tracked)
      Code.delete_path(ebin)
      :code.purge(module)
      :code.delete(module)
      File.rm_rf!(root)
    end)

    %{root: root, peer: module, track: fn owner -> Agent.update(tracked, &[owner | &1]) end}
  end

  test "timeout settles the actual owned VM and preserves the incomplete row", ctx do
    cell = %{hd(Matrix.plan(1, 42)) | scenario: "waiting"}
    row = Path.join(ctx.root, "row")

    result =
      MatrixRunner.execute(cell, "manifest.json", row,
        peer: ctx.peer,
        timeout: 1_000,
        repo: File.cwd!(),
        after_launch: ctx.track
      )

    assert result.error == "deadline"
    assert result.launch.port_owned
    assert result.outer.stopped
    assert result.outer.exit_status == 137
    assert result.outer.port_down
    assert ProcessProbe.stopped?(result.launch.os_pid)
    refute result.verdict.eligible
    assert result.verdict.stop
    assert File.exists?(Path.join(row, "boot.json"))
    assert VM.read(row, "record")["error"] == "deadline"
  end

  test "cleanup is registered before a fallible post-launch hook", ctx do
    row = Path.join(ctx.root, "row")

    result =
      MatrixRunner.execute(hd(Matrix.plan(1, 42)), "manifest.json", row,
        peer: ctx.peer,
        repo: File.cwd!(),
        after_launch: fn owner ->
          ctx.track.(owner)
          assert VM.wait(fn -> VM.read(row, "boot") end, 5_000)
          assert VM.snapshot(owner).port_owned
          raise "forced matrix control"
        end
      )

    assert result.error =~ "forced matrix control"
    assert result.outer.stopped
    assert ProcessProbe.stopped?(result.launch.os_pid)
    assert result.verdict.stop
    assert VM.read(row, "record")["outer"]["stopped"]
  end

  test "normal exit without causal evidence is retained and cannot count as a passing row", ctx do
    cell = %{hd(Matrix.plan(1, 42)) | scenario: "finished"}
    row = Path.join(ctx.root, "row")

    result = MatrixRunner.execute(cell, "manifest.json", row, peer: ctx.peer, repo: File.cwd!())

    assert result.error == nil
    assert result.outer.exit_status == 0
    assert result.outer.stopped
    assert result.verdict.stop
    refute result.verdict.passed
    assert result.report["matrix_peer"]["outer_cleanup_confirmed"]

    assert_raise File.Error, fn ->
      MatrixRunner.execute(cell, "manifest.json", row,
        peer: ctx.peer,
        repo: File.cwd!(),
        after_launch: ctx.track
      )
    end
  end
end
