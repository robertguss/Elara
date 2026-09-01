defmodule Elara.Benchmark.DogfoodIsolationTest do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.Dogfood.{Isolation, Plan, Report}

  @path "test/fixtures/benchmark/exp003/dogfood-plan.json"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-dogfood-isolation-#{System.unique_integer([:positive])}"
      )

    source = Path.join(root, "source")
    runs = Path.join(root, "runs")

    {output, 0} =
      System.cmd("git", ["clone", "--no-local", "--no-hardlinks", File.cwd!(), source],
        stderr_to_stdout: true
      )

    assert output != ""
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root, source: source, runs: runs}
  end

  test "a disposable parent clone blocks push, strips environment, and read-only mounts shared source",
       context do
    assert {:ok, plan} = Plan.load(@path, repo_root: context.source)
    [task | _] = Plan.execution_tasks(plan)
    run_root = Path.join(context.runs, "guard-test")
    assert {:ok, isolation} = Isolation.prepare(context.source, task, run_root)

    assert {:ok, output} =
             Isolation.run(isolation, "sh", [
               "-eu",
               "-c",
               "test -z \"${ELARA_API_KEY+x}\"; test -z \"${XAI_API_KEY+x}\"; printf local > marker; ! git push; ! printf forbidden > \"$1/mix.exs\"",
               "sh",
               context.source
             ])

    assert output =~ "dogfood isolation: push disabled"
    assert output =~ "Read-only file system"
    assert File.read!(Path.join(isolation.workspace, "marker")) == "local"
    assert :ok = Isolation.verify_source_unchanged(isolation)

    File.write!(Path.join(context.source, "mix.exs"), "temporary disposable source change")
    assert {:error, :shared_source_changed} = Isolation.verify_source_unchanged(isolation)
    assert {:ok, _elapsed_ms} = Isolation.cleanup(isolation)
    refute File.exists?(run_root)
  end

  test "rejecting an unsafe isolation root never removes the source repository", context do
    assert {:ok, plan} = Plan.load(@path, repo_root: context.source)
    [task | _] = Plan.execution_tasks(plan)
    sentinel = Path.join(context.source, "mix.exs")
    original = File.read!(sentinel)

    assert {:error, :isolation_root_is_source} =
             Isolation.prepare(context.source, task, context.source)

    assert File.read!(sentinel) == original
    assert File.dir?(Path.join(context.source, ".git"))
  end

  test "the inert pilot runs no subject task and produces a valid cleanup report", context do
    assert {:ok, plan} = Plan.load(@path, repo_root: context.source)
    run_root = Path.join(context.runs, "pilot")

    assert {:ok, report} = Isolation.inert_pilot(plan, context.source, run_root)
    assert :ok = Report.validate(plan, report)
    assert report["pilot"]["real_task_runs"] == 0
    assert report["pilot"]["fault_runs"] == 0
    assert report["task_results"] == []
    refute File.exists?(run_root)
  end
end
