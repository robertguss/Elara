defmodule Elara.Benchmark.NoFaultFixtureTest do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.{Fixture, Manifest, Runner}

  @manifest_path Path.expand("../../fixtures/benchmark/exp003/manifest.json", __DIR__)

  defmodule NeutralFixtureAdapter do
    @behaviour Elara.Benchmark.Adapter

    @impl true
    def execute(task, cwd, %{kind: :no_fault}) do
      step = hd(task["plan"]["steps"])
      {:ok, %{"outcome" => execute_step(step, cwd)}}
    end

    defp execute_step(%{"operation_kind" => "write", "arguments" => args}, cwd) do
      target = Path.join(cwd, args["path"])

      cond do
        File.regular?(target) and target |> File.read!() |> sha256() == args["desired"]["sha256"] ->
          "ok"

        expected_write_state?(target, args["expected"]) ->
          File.mkdir_p!(Path.dirname(target))
          File.write!(target, args["desired"]["content"])
          "ok"

        true ->
          "error_conflict"
      end
    end

    defp execute_step(%{"operation_kind" => "patch", "arguments" => args}, cwd) do
      target = Path.join(cwd, args["path"])
      content = File.read!(target)

      cond do
        sha256(content) == args["postimage_sha256"] ->
          "ok"

        sha256(content) == args["preimage_sha256"] and
            length(:binary.matches(content, args["old_text"])) == 1 ->
          File.write!(
            target,
            String.replace(content, args["old_text"], args["new_text"], global: false)
          )

          "ok"

        true ->
          "error_conflict"
      end
    end

    defp execute_step(%{"operation_kind" => "shell", "arguments" => args}, cwd) do
      environment = Enum.map(args["environment"], fn {key, value} -> {key, value} end)

      {_output, status} =
        System.shell(args["command"],
          cd: Path.join(cwd, args["relative_cwd"]),
          env: environment,
          stderr_to_stdout: true
        )

      if status == 0, do: "ok", else: "error_exit_#{status}"
    end

    defp expected_write_state?(target, %{"state" => "absent"}), do: not File.exists?(target)

    defp expected_write_state?(target, %{"state" => "regular", "sha256" => digest}) do
      File.regular?(target) and target |> File.read!() |> sha256() == digest
    end

    defp sha256(value) do
      value
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end
  end

  setup do
    {:ok, manifest} = Manifest.load(@manifest_path)

    root =
      Path.join(System.tmp_dir!(), "elara-no-fault-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    %{manifest: manifest, root: root}
  end

  test "every selected task reaches its frozen no-fault outcome through a neutral adapter", %{
    manifest: manifest,
    root: root
  } do
    records =
      manifest.data["selection"]["selected_task_ids"]
      |> Enum.with_index(1)
      |> Enum.map(fn {task_id, order_index} ->
        run = %{
          "task_id" => task_id,
          "condition" => "receipts",
          "phase" => "measured",
          "run_index" => 1,
          "order_index" => order_index
        }

        assert {:ok, record} =
                 Runner.run_no_fault(manifest, run,
                   adapter: NeutralFixtureAdapter,
                   root: root
                 )

        record
      end)

    assert length(records) == 12
    assert Enum.all?(records, & &1["workspace_correct"])
    assert Enum.all?(records, & &1["outcome_correct"])

    assert Enum.map(records, &{&1["task_id"], &1["observed_outcome"]}) == [
             {"S03", "error_exit_7"},
             {"W03", "ok"},
             {"W07", "ok"},
             {"S02", "ok"},
             {"W08", "ok"},
             {"P08", "ok"},
             {"S04", "ok"},
             {"P04", "error_conflict"},
             {"W05", "ok"},
             {"P07", "ok"},
             {"P01", "ok"},
             {"S01", "ok"}
           ]
  end

  test "every reset is repeatable and removes contamination", %{manifest: manifest, root: root} do
    for task <- manifest.data["tasks"] do
      expected_digest = task["fixture"]["initial_workspace_sha256"]

      assert {:ok, ^expected_digest} = Fixture.reset(task, root)
      File.mkdir_p!(Path.join(root, "unexpected"))
      File.write!(Path.join(root, "unexpected/contamination.txt"), "bad")

      assert {:ok, ^expected_digest} = Fixture.reset(task, root)
      refute File.exists?(Path.join(root, "unexpected/contamination.txt"))
    end
  end

  test "reset refuses destructive roots", %{manifest: manifest} do
    {:ok, task} = Manifest.task(manifest, "W07")
    assert {:error, :unsafe_fixture_root} = Fixture.reset(task, "/")
  end
end
