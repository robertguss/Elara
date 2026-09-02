alias Elara.Benchmark.{ElaraAdapter, Manifest}
alias Elara.Benchmark.Exp003.Materializer

defmodule Elara.Benchmark.Exp003.V8Preflight do
  @moduledoc false

  @schema "elara.exp003.pre-beacon-qualification.v8"
  @version "ER-3/FND-2-v8-development"
  @output_files ~w(
    beacon/verified.json
    dogfood-plan.json
    external-adapter-equivalence.json
    manifest.json
    materialization-receipt.json
  )

  def run(
        protocol_path,
        protocol_sha256,
        beacon_path,
        beacon_sha256,
        work_root,
        output_path
      ) do
    work_root = Path.expand(work_root)
    output_path = Path.expand(output_path)
    assert_absent!(work_root, "work root")
    assert_absent!(output_path, "report output")
    true = File.dir?(Path.dirname(work_root))
    true = File.dir?(Path.dirname(output_path))
    File.mkdir!(work_root)

    first_root = Path.join(work_root, "materialization-a")
    second_root = Path.join(work_root, "materialization-b")

    run_materializer!([
      protocol_path,
      protocol_sha256,
      beacon_path,
      beacon_sha256,
      first_root
    ])

    {:ok, _second} =
      Materializer.run(
        File.cwd!(),
        protocol_path,
        protocol_sha256,
        beacon_path,
        beacon_sha256,
        second_root
      )

    true =
      Enum.all?(
        @output_files,
        &(File.read!(Path.join(first_root, &1)) == File.read!(Path.join(second_root, &1)))
      )

    receipt_path = Path.join(first_root, "materialization-receipt.json")
    receipt_sha256 = file_sha256!(receipt_path)
    qualification_path = Path.join(work_root, "qualification.json")

    run_command!([
      "qualify",
      protocol_path,
      protocol_sha256,
      receipt_path,
      receipt_sha256,
      Path.join(work_root, "qualification-state"),
      Path.join(work_root, "qualification-workspace"),
      qualification_path
    ])

    qualification = read_json!(qualification_path)
    replay_path = Path.join(work_root, "replay.json")

    run_command!([
      "replay",
      protocol_path,
      protocol_sha256,
      receipt_path,
      receipt_sha256,
      qualification_path,
      replay_path
    ])

    replay = read_json!(replay_path)
    manifest_path = Path.join(first_root, "manifest.json")
    {:ok, loaded_manifest} = Manifest.load(manifest_path)
    authorization_probe = authorization_probe(loaded_manifest)

    protocol = read_json!(protocol_path)
    receipt = read_json!(receipt_path)
    manifest = read_json!(manifest_path)

    report =
      report(
        protocol,
        protocol_sha256,
        beacon_sha256,
        receipt,
        manifest,
        qualification,
        replay,
        authorization_probe
      )

    bytes = Materializer.canonical_json(report)
    File.write!(output_path, bytes, [:exclusive])

    IO.puts("pre_beacon_report_sha256=#{sha256(bytes)}")
    IO.puts("candidate_construction_count=#{report["summary"]["candidate_construction_count"]}")
    IO.puts("qualification_status=#{report["command_stack"]["score"]["status"]}")
    :ok
  end

  defp report(
         protocol,
         protocol_sha256,
         beacon_sha256,
         receipt,
         manifest,
         qualification,
         replay,
         authorization_probe
       ) do
    rows =
      Enum.map(manifest["fault_rows"], fn row ->
        Map.take(
          row,
          ~w(row_id order_index task_id operation_class fault_type fault_role fault_target_step fault_target_tool_call_id)
        )
      end)

    qualification_score =
      Map.take(qualification["score"], ~w(schema valid status errors safety_disqualifiers))

    %{
      "schema" => @schema,
      "preregistration_version" => @version,
      "purpose" =>
        "deterministic development qualification of the explicit materializer and complete command stack before any V8 future-beacon commitment",
      "reproduction_command" =>
        "mix run priv/benchmark/preflight_exp003_v8.exs -- <protocol> <protocol-sha256> <development-beacon> <beacon-sha256> <absent-work-root> <absent-report.json>",
      "inputs" => %{
        "protocol_path" => protocol["path"],
        "protocol_sha256" => protocol_sha256,
        "development_beacon_path" => "test/fixtures/benchmark/exp003-v8-development/beacon.json",
        "development_beacon_sha256" => beacon_sha256,
        "semantics" => protocol["inputs"]
      },
      "source_identities" => protocol["source_identities"],
      "summary" => %{
        "candidate_source_count" => 20,
        "candidate_construction_count" => receipt["candidate_construction_count"],
        "eligible_candidate_count" => receipt["eligible_candidate_count"],
        "selected_task_count" => receipt["selected_task_count"],
        "selected_row_count" => receipt["selected_row_count"],
        "materialization_count" => 2,
        "byte_identical_materializations" => true,
        "qualification_fault_run_count" =>
          get_in(qualification, ["execution", "fault_run_count"]),
        "qualification_no_fault_run_count" =>
          get_in(qualification, ["execution", "no_fault_run_count"]),
        "qualification_checkpoint_event_count" =>
          get_in(qualification, ["execution", "checkpoint_event_count"]),
        "qualification_status" => get_in(qualification, ["score", "status"]),
        "replay_status" => replay["status"]
      },
      "materialization" => %{
        "output_sha256" => receipt["outputs"],
        "receipt_sha256" => sha256(Materializer.canonical_json(receipt)),
        "candidate_construction_proofs" => receipt["candidate_construction_proofs"],
        "eligible_candidate_ids" => receipt["eligible_candidate_ids"],
        "selected_task_ids" => receipt["selected_task_ids"],
        "secondary_row_task_ids" => receipt["secondary_row_task_ids"],
        "selected_development_rows" => rows,
        "byte_identity_scope" => @output_files
      },
      "command_stack" => %{
        "commands" => get_in(protocol, ["command_stack", "commands"]),
        "exact_cli_entrypoints_exercised" => [
          "mix run priv/benchmark/preflight_exp003_v8.exs",
          "mix run priv/benchmark/materialize_exp003_v8.exs",
          "mix run priv/benchmark/run_exp003_v8.exs -- qualify",
          "mix run priv/benchmark/run_exp003_v8.exs -- replay"
        ],
        "source_paths" => get_in(protocol, ["command_stack", "source_paths"]),
        "target_commits" => get_in(protocol, ["command_stack", "target_commits"]),
        "authorization_probe" => authorization_probe,
        "score" => qualification_score,
        "replay" => Map.take(replay, ~w(schema valid status errors safety_disqualifiers)),
        "all_no_fault_correct" => get_in(qualification, ["diagnostics", "all_no_fault_correct"]),
        "harness_error_count" => get_in(qualification, ["diagnostics", "harness_error_count"]),
        "safety_disqualifier_count" =>
          get_in(qualification, ["diagnostics", "safety_disqualifier_count"]),
        "checkpoint_policy" => get_in(qualification, ["configuration", "checkpoint_policy"]),
        "failure_policy" => get_in(qualification, ["configuration", "failure_policy"])
      },
      "exposure" => receipt["exposure"],
      "limitations" => [
        "All materialization and command runs use fixed non-confirmatory development entropy.",
        "The development score proves stack coherence only; it is not V8 B/T evidence.",
        "No future beacon is selected, committed, fetched, or inferable from this report.",
        "No external comparator or dogfood task is executed."
      ]
    }
  end

  defp authorization_probe(manifest) do
    {:ok, authorized} = ElaraAdapter.authorize_confirmatory(%{}, manifest, manifest.sha256)

    wrong_digest_manifest = %{manifest | sha256: String.duplicate("0", 64)}

    {:error, :confirmatory_manifest_not_frozen} =
      ElaraAdapter.authorize_confirmatory(%{}, wrong_digest_manifest, manifest.sha256)

    row = manifest.rows |> Map.values() |> Enum.min_by(& &1["row_id"])
    task = Map.fetch!(manifest.tasks, row["task_id"])
    authorization = authorized.fault_authorization

    true = ElaraAdapter.confirmatory_binding_matches?(task, row, authorization)

    false =
      ElaraAdapter.confirmatory_binding_matches?(
        Map.put(task, "brief", "tampered task"),
        row,
        authorization
      )

    false =
      ElaraAdapter.confirmatory_binding_matches?(
        task,
        Map.put(row, "barrier_id", "tampered-row"),
        authorization
      )

    %{
      "correct_manifest_digest_accepted" => true,
      "wrong_manifest_digest_rejected" => true,
      "exact_task_and_row_binding_accepted" => true,
      "wrong_task_rejected" => true,
      "wrong_row_rejected" => true,
      "fault_execution_attempted" => false,
      "held_out_data_used" => false
    }
  end

  defp run_command!(arguments) do
    {output, status} =
      System.cmd("mix", ["run", "priv/benchmark/run_exp003_v8.exs", "--" | arguments],
        cd: File.cwd!(),
        stderr_to_stdout: true
      )

    if status != 0 do
      raise "V8 command entrypoint failed (status #{status}): #{output}"
    end

    true = output =~ "EXP-003 V8 command complete; score=Pass"
    :ok
  end

  defp run_materializer!(arguments) do
    {output, status} =
      System.cmd(
        "mix",
        ["run", "priv/benchmark/materialize_exp003_v8.exs", "--" | arguments],
        cd: File.cwd!(),
        stderr_to_stdout: true
      )

    if status != 0 do
      raise "V8 materialization entrypoint failed (status #{status}): #{output}"
    end

    true = output =~ "manifest_sha256="
    true = output =~ "receipt_sha256="
    :ok
  end

  defp assert_absent!(path, label) do
    if File.exists?(path), do: raise("#{label} must be absent: #{path}")
  end

  defp read_json!(path), do: path |> File.read!() |> JSON.decode!()
  defp file_sha256!(path), do: path |> File.read!() |> sha256()
  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end

args =
  case System.argv() do
    ["--" | rest] -> rest
    rest -> rest
  end

case args do
  [protocol, protocol_sha256, beacon, beacon_sha256, work_root, output] ->
    Elara.Benchmark.Exp003.V8Preflight.run(
      protocol,
      protocol_sha256,
      beacon,
      beacon_sha256,
      work_root,
      output
    )

  _other ->
    raise "usage: mix run priv/benchmark/preflight_exp003_v8.exs -- " <>
            "<protocol.json> <protocol-sha256> <development-beacon.json> " <>
            "<beacon-sha256> <absent-work-root> <absent-report.json>"
end
