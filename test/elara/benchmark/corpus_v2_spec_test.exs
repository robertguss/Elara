defmodule Elara.Benchmark.CorpusV2SpecTest do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.{Fixture, Manifest, Runner}
  alias Elara.Benchmark.Dogfood.Plan

  @manifest_path Path.expand("../../fixtures/benchmark/exp003-v2/manifest.json", __DIR__)
  @dogfood_path Path.expand("../../fixtures/benchmark/exp003-v2/dogfood-plan.json", __DIR__)
  @fixture_root Path.dirname(@manifest_path)
  @seed "4823a4f6cbb157900953ce8eebccb1a867f1f6d3ec579adc9842cbcf29648a12"
  @selected ~w(W02 S04 P06 S03 P03 P05 W01 W03 P07 S01 S02 W07)
  @dogfood ~w(D04 D12 D02 D03 D07 D01 D06 D05 D11 D10 D08 D09)

  defmodule NeutralAdapter do
    @behaviour Elara.Benchmark.Adapter

    @impl true
    def execute(task, cwd, %{kind: :no_fault}) do
      outcome =
        Enum.reduce_while(task["plan"]["steps"], "ok", fn step, _outcome ->
          case execute_step(step, cwd) do
            "ok" -> {:cont, "ok"}
            other -> {:halt, other}
          end
        end)

      {:ok, %{"outcome" => outcome}}
    end

    defp execute_step(%{"operation_kind" => "write", "arguments" => args}, cwd) do
      target = Path.join(cwd, args["path"])

      cond do
        File.regular?(target) and sha256(File.read!(target)) == args["desired"]["sha256"] ->
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
      {_output, status} =
        System.shell(args["command"],
          cd: Path.join(cwd, args["relative_cwd"]),
          env: Map.to_list(args["environment"]),
          stderr_to_stdout: true
        )

      if status == 0, do: "ok", else: "error_exit_#{status}"
    end

    defp expected_write_state?(target, %{"state" => "absent"}), do: not File.exists?(target)

    defp expected_write_state?(target, %{"state" => "regular", "sha256" => digest}),
      do: File.regular?(target) and sha256(File.read!(target)) == digest

    defp sha256(value),
      do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  setup_all do
    {:ok, manifest} = Manifest.load(@manifest_path)
    {:ok, dogfood} = Plan.load(@dogfood_path)
    %{manifest: manifest, dogfood: dogfood}
  end

  test "the verified future beacon deterministically selects fresh v2 inputs", %{
    manifest: manifest
  } do
    data = manifest.data
    beacon = data["beacon"]
    seed = Base.decode16!(@seed, case: :mixed)

    assert data["schema"] == "elara.exp003.corpus.v2"
    assert data["preregistration_version"] == "ER-3/FND-2-v2"
    assert beacon["round"] == 6_426_976
    assert beacon["nominal_time"] == "2026-09-01T05:25:00Z"

    assert beacon["randomness"] ==
             "102a5c96e0068d5a3bef46be242054307efb1dfd362c63c483c987f8d5319356"

    assert data["seed"]["sha256"] == @seed

    material =
      "elara:exp-003:er3:fnd-2:v2\0" <>
        beacon["chain_hash"] <>
        ":#{beacon["round"]}:#{beacon["randomness"]}:#{data["seed"]["frozen_commit"]}"

    assert sha256(material) == @seed

    for candidate <- data["candidate_frame"] do
      assert candidate["order_key"] == sha256(seed <> <<0>> <> candidate["id"])
    end

    assert data["selection"]["selected_task_ids"] == @selected
    assert data["selection"]["secondary_row_task_ids"] == Enum.take(@selected, 8)
    assert Enum.map(data["tasks"], & &1["id"]) == @selected
    assert Enum.map(data["fault_rows"], & &1["order_index"]) == Enum.to_list(1..20)
    assert length(Enum.uniq_by(data["fault_rows"], & &1["row_id"])) == 20

    assert data["exposure_statement"] == %{
             "target_fault_rows_executed" => 0,
             "external_fault_rows_executed" => 0,
             "dogfood_task_runs" => 0,
             "dogfood_fault_runs" => 0,
             "B_or_T_calculated" => false,
             "statement" =>
               "V2 materialization and no-fault construction only; no relevant fault output observed."
           }

    assert data["materializer"]["sha256"] ==
             file_sha256("priv/benchmark/materialize_exp003_v2.exs")

    assert data["materializer"]["source_template_sha256"] ==
             file_sha256("test/fixtures/benchmark/exp003/manifest.json")
  end

  test "both relays and the official client preserve the committed beacon", %{manifest: manifest} do
    [api_path, cloudflare_path] = manifest.data["beacon"]["relay_response_paths"]
    api = read_fixture(api_path)
    cloudflare = read_fixture(cloudflare_path)
    verification = read_fixture(manifest.data["beacon"]["verification_path"])

    assert api == cloudflare
    assert verification["verified"]
    assert verification["client"] == "drand-client@1.4.2"
    assert Enum.map(verification["results"], &Map.drop(&1, ["url"])) == [api, api]
    assert sha256(Base.decode16!(api["signature"], case: :mixed)) == api["randomness"]

    for {filename, expected} <- manifest.data["beacon"]["artifact_sha256"] do
      assert file_sha256(Path.join(@fixture_root, "beacon/#{filename}")) == expected
    end
  end

  test "all generated values, fixtures, rows, and plans are version-aligned", %{
    manifest: manifest
  } do
    seed = Base.decode16!(@seed, case: :mixed)

    for task <- manifest.data["tasks"] do
      assert task["fixture"]["schema"] == "elara.exp003.fixture.v2"
      assert task["plan"]["schema"] == "elara.exp003.plan.v2"
      assert task["fixture"]["fixture_commit"] == "sha256:" <> task["fixture"]["fixture_sha256"]

      assert task["fixture"]["initial_workspace_sha256"] ==
               Fixture.digest_files(task["fixture"]["initial_files"])

      assert task["fixture"]["expected_no_fault_workspace_sha256"] ==
               Fixture.digest_files(task["fixture"]["expected_no_fault_files"])

      for {field, value} <- task["generated_tokens"] do
        assert value == token(seed, task["id"], field)
        refute String.contains?(task["request"], value)
      end

      target = task["plan"]["fault_target_step"]
      assert Enum.count(task["plan"]["steps"], &(&1["id"] == target)) == 1

      call =
        Enum.find(
          task["plan"]["scripted_provider"],
          &(&1["arguments_ref"] == "plan.steps[0].arguments")
        )

      assert call["tool_call_id"] == "exp003-#{String.downcase(task["id"])}"
    end

    for row <- manifest.data["fault_rows"] do
      assert row["fault_target_step"] == "effect"
      assert row["fault_target_tool_call_id"] == "exp003-#{String.downcase(row["task_id"])}"
      assert row["evidence_scope"] =~ "fault-target durable job only"
    end
  end

  test "P06 freezes two serial jobs and one unambiguous fault target", %{manifest: manifest} do
    {:ok, task} = Manifest.task(manifest, "P06")
    [effect, continuation] = task["plan"]["steps"]

    assert effect["id"] == "effect"
    assert continuation["id"] == "continuation"
    assert effect["arguments"]["path"] != continuation["arguments"]["path"]
    assert task["plan"]["fault_target_step"] == "effect"
    assert task["plan"]["continuation_policy"]["fault_injection"] =~ "effect only"
    assert task["plan"]["continuation_policy"]["parallelism"] == "forbidden"
    assert task["ground_truth"]["fault_evidence_scope"] == "effect job only"
    assert task["ground_truth"]["expected_task_tool_call_count"] == 2
    assert task["ground_truth"]["expected_task_external_mutation_count"] == 2

    assert Enum.map(task["plan"]["scripted_provider"], & &1["kind"]) ==
             ~w(tool_call tool_call assistant_text)
  end

  test "every selected task reaches its no-fault outcome from an exact reset", %{
    manifest: manifest
  } do
    root = temporary_root("no-fault")

    records =
      @selected
      |> Enum.with_index(1)
      |> Enum.map(fn {task_id, index} ->
        run = %{
          "task_id" => task_id,
          "condition" => "receipts",
          "phase" => "measured",
          "run_index" => 1,
          "order_index" => index
        }

        assert {:ok, record} =
                 Runner.run_no_fault(manifest, run, adapter: NeutralAdapter, root: root)

        record
      end)

    assert length(records) == 12
    assert Enum.all?(records, & &1["workspace_correct"])
    assert Enum.all?(records, & &1["outcome_correct"])
  end

  @tag timeout: 120_000
  test "every expected workspace is an offline passing Mix project", %{manifest: manifest} do
    root = temporary_root("expected")

    for task <- manifest.data["tasks"] do
      cwd = Path.join(root, String.downcase(task["id"]))
      assert {:ok, _digest} = Fixture.reset(task, cwd, :expected_no_fault)

      {output, status} =
        System.cmd("mix", ["test"],
          cd: cwd,
          env: [{"HEX_OFFLINE", "1"}, {"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert status == 0, "#{task["id"]} expected fixture failed offline:\n#{output}"
      assert output =~ "Result: 1 passed"
    end
  end

  test "the versioned dogfood plan preserves membership and derives a fresh order", %{
    dogfood: dogfood
  } do
    assert dogfood.data["schema"] == "elara.exp003.dogfood-plan.v2"
    assert dogfood.data["preregistration_version"] == "ER-3/FND-2-v2"
    assert dogfood.data["seed"]["sha256"] == @seed
    assert dogfood.data["seed"]["round"] == 6_426_976
    assert dogfood.data["execution_order"] == @dogfood

    assert Enum.map(dogfood.data["tasks"], & &1["id"]) ==
             Enum.map(1..12, &"D#{String.pad_leading("#{&1}", 2, "0")}")

    assert dogfood.data["denominators"] == %{"P" => 12, "I" => 10, "C" => 2}
    assert dogfood.data["exposure"]["dogfood_task_runs"] == 0
    assert dogfood.data["exposure"]["dogfood_fault_runs"] == 0
  end

  defp temporary_root(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-exp003-v2-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp read_fixture(path),
    do: path |> then(&Path.join(@fixture_root, &1)) |> File.read!() |> JSON.decode!()

  defp file_sha256(path), do: path |> Path.expand(File.cwd!()) |> File.read!() |> sha256()

  defp token(seed, id, field),
    do: sha256(seed <> <<0>> <> id <> <<0>> <> field) |> binary_part(0, 16)

  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
