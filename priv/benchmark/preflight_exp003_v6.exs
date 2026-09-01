defmodule Elara.Benchmark.Exp003V6Preflight do
  @moduledoc false

  alias Elara.Benchmark.{Compatibility, Fixture, InternalConfirmatory}

  @source_manifest "test/fixtures/benchmark/exp003/manifest.json"
  @compatibility_path "docs/experiments/003-effect-receipt-v5-compatibility.json"
  @factory_source "priv/benchmark/materialize_exp003_v2.exs"
  @output_path "docs/experiments/003-effect-receipt-v6-preflight.json"
  @preflight_seed :crypto.hash(:sha256, "elara:exp-003:er3:v6:preflight:no-beacon\0")
  @faults ~w(F1 F2 F3 F4)

  @preserved_artifacts %{
    "docs/experiments/003-effect-receipt-confirmatory-preregistration.md" =>
      "6e63641df815677d3a8498ea5d5e6f3b897144436ede2bae32f5de6bb0369bb9",
    "docs/experiments/003-effect-receipt-confirmatory-preregistration-v2.md" =>
      "3ef325a4cc8c5856dd61fb11b2bb5ddff5e3b304edd4f6ef8f902ea33f21c89f",
    "docs/experiments/003-effect-receipt-confirmatory-preregistration-v3.md" =>
      "a196b651bbe07d28c295528e148e2b9770180ffdfdd4b918f2c28528cf2d2070",
    "docs/experiments/003-effect-receipt-confirmatory-preregistration-v4.md" =>
      "f63c0baf227991126afcf83b2f22d61f42289568d7c6b393ad23dfa859d5d863",
    "docs/experiments/003-effect-receipt-confirmatory-preregistration-v5.md" =>
      "ddaff6f6b1007245df75aaed700ec131428e723c168a812ae8faada9e906c224",
    "docs/experiments/003-effect-receipt-v5-compatibility.json" =>
      "256812afbb42f9c35f81a5c3a650dc59b34623acc88d48f44153033d01d8cfde",
    "docs/experiments/003-effect-receipt-v5-materialization-failure.md" =>
      "7dc27af1d7acdebd72a241af54961f99ed88d5ed7345b9efd25a99a1d8fe293a",
    "test/fixtures/benchmark/exp003/manifest.json" =>
      "a40fa18d3ea00eee5c6b8963055cff49ca7f94388f42325c793e0460be98a5b7",
    "test/fixtures/benchmark/exp003-v2/manifest.json" =>
      "f5fde3aead3a4ff2aaf9d6aee880d7da2b9a60619523f084cedcaa0943a5d1d9",
    "test/fixtures/benchmark/exp003-v3/manifest.json" =>
      "4129ae964daf35469499dc9506ace9fa89db0c9f00a20826dfc6790edd5b5491",
    "test/fixtures/benchmark/exp003-v4/manifest.json" =>
      "14cc3a57763f0ab48f4b68a70317916d09ff4bee64ba18d150480dd1315820a2",
    "test/fixtures/benchmark/exp003-v4/internal-confirmatory-qualification-failed.checkpoint.json" =>
      "e206f46325c420f5c664a0c185b223896e4a745ab598cc7091350769e5878a41",
    "test/fixtures/benchmark/exp003-v5/beacon/api.drand.sh.json" =>
      "24898a55a44ab5b9146cd6e745db0d0a688ebca8261695180bcc55015dd98a04",
    "test/fixtures/benchmark/exp003-v5/beacon/drand.cloudflare.com.json" =>
      "0ab8759a9caa6dabd507ae39d88bdc955ae935f63c21b8996a6436807ff0a60b",
    "test/fixtures/benchmark/exp003-v5/beacon/verification.json" =>
      "26656c573f96abceb9a3b55eb0e933313b352974e42757ec5c0e5bcb37d2c1d1"
  }

  def run(output_path \\ @output_path) do
    report = build_report()
    bytes = InternalConfirmatory.canonical_json(report)
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, bytes)

    IO.puts("preflight_sha256=#{sha256(bytes)}")
    IO.puts("candidate_count=#{report["summary"]["candidate_count"]}")
    IO.puts("assignment_count=#{report["summary"]["assignment_count"]}")
    :ok
  end

  def build_report do
    define_factory!()
    verify_preserved_artifacts!()

    {:ok, compatibility} = Compatibility.load(@compatibility_path)
    source = @source_manifest |> read_json!() |> compatible_source!(compatibility)

    tasks =
      apply(Elara.Benchmark.Exp003V6CandidateFactory, :construct_all, [source, @preflight_seed])

    profiles = Map.new(compatibility["candidates"], &{&1["id"], &1})

    expected_ids = source["candidate_frame"] |> Enum.map(& &1["id"]) |> Enum.sort()
    task_ids = tasks |> Enum.map(& &1["id"]) |> Enum.sort()
    true = length(tasks) == 20
    true = task_ids == expected_ids
    true = Enum.uniq(task_ids) == task_ids

    task_records = Enum.map(tasks, &validate_task!(&1, Map.fetch!(profiles, &1["id"])))

    assignments =
      Enum.flat_map(tasks, fn task ->
        profile = Map.fetch!(profiles, task["id"])

        [
          validate_assignment!(task, profile, profile["primary_fault"], "primary", compatibility),
          validate_assignment!(
            task,
            profile,
            profile["secondary_fault"],
            "secondary",
            compatibility
          )
        ]
      end)

    true = length(assignments) == 40

    %{
      "schema" => "elara.exp003.preflight.v6",
      "linear_issue" => "ROB-866",
      "purpose" =>
        "seed-independent exhaustive construction and semantic validation before any V6 beacon commitment",
      "preflight_seed" => %{
        "beacon_derived" => false,
        "domain" => "elara:exp-003:er3:v6:preflight:no-beacon\\0",
        "sha256" => Base.encode16(@preflight_seed, case: :lower)
      },
      "inputs" => %{
        "candidate_source" => @source_manifest,
        "candidate_source_sha256" => file_sha256!(@source_manifest),
        "compatibility" => @compatibility_path,
        "compatibility_sha256" => file_sha256!(@compatibility_path),
        "factory_template" => @factory_source,
        "factory_template_sha256" => file_sha256!(@factory_source),
        "preflight_source" => "priv/benchmark/preflight_exp003_v6.exs",
        "preflight_source_sha256" => file_sha256!("priv/benchmark/preflight_exp003_v6.exs")
      },
      "summary" => %{
        "candidate_count" => length(task_records),
        "candidate_ids" => expected_ids,
        "assignment_count" => length(assignments),
        "assignment_roles" => %{"primary" => 20, "secondary" => 20},
        "all_candidate_bytes_constructed" => true,
        "all_assignments_semantically_validated" => true,
        "sampling_or_selection_performed" => false
      },
      "tasks" => task_records,
      "assignments" => assignments,
      "preserved_artifact_sha256" => @preserved_artifacts,
      "exposure" => %{
        "future_beacon_committed" => false,
        "future_beacon_fetched" => false,
        "candidate_selection_performed" => false,
        "held_out_task_literals_generated" => false,
        "target_fault_rows" => 0,
        "target_timing_runs" => 0,
        "external_fault_rows" => 0,
        "dogfood_runs" => 0,
        "B_or_T_calculated" => false
      }
    }
  end

  defp define_factory! do
    unless Code.ensure_loaded?(Elara.Benchmark.Exp003V6CandidateFactory) do
      @factory_source
      |> File.read!()
      |> transform_factory()
      |> Code.eval_string([], file: @factory_source)
    end
  end

  defp transform_factory(source) do
    source
    |> String.replace(
      "Elara.Benchmark.Exp003V2Materializer",
      "Elara.Benchmark.Exp003V6CandidateFactory"
    )
    |> String.replace("ER-3/FND-2-v2", "ER-3/FND-2-v6-preflight")
    |> String.replace("elara.exp003.fixture.v2", "elara.exp003.fixture.v6")
    |> String.replace("elara.exp003.plan.v2", "elara.exp003.plan.v6")
    |> String.replace("test/fixtures/benchmark/exp003-v2", "test/fixtures/benchmark/exp003-v6")
    |> String.replace(
      "id in ~w(W02 P03 P05 P06) -> new_task(id, candidate, seed)",
      "id in ~w(W02 W04 W06 P02 P03 P05 P06) -> new_task(id, candidate, seed)"
    )
    |> String.replace(
      "  defp new_task(\"P03\", candidate, seed) do",
      additional_candidate_source() <> "\n\n  defp new_task(\"P03\", candidate, seed) do"
    )
    |> String.replace(
      "  defp verified_beacon! do",
      construct_all_source() <> "\n\n  defp verified_beacon! do"
    )
    |> String.replace("Elara.Benchmark.Exp003V6CandidateFactory.run()", "")
  end

  defp construct_all_source do
    ~S'''
      def construct_all(source, seed) do
        candidates = candidates(source, seed)
        task_sources = Map.new(source["tasks"], &{&1["id"], &1})
        adapter_sources = Map.new(source["adapter_equivalence_fixtures"], &{&1["template_id"], &1})

        Enum.map(candidates, fn candidate ->
          build_task(candidate["id"], candidates, task_sources, adapter_sources, source, seed)
        end)
      end
    '''
  end

  defp additional_candidate_source do
    ~S'''
      defp new_task("W04", candidate, seed) do
        t = tokens(seed, "W04")
        path = "lib/generated_#{t["path"]}/corpus_case.ex"
        before = module_value(t, "pre_#{t["value"]}")
        desired = module_value(t, "post_#{t["new_value"]}")
        conflict_value = "conflict_#{t["sentinel"]}"
        conflict = module_value(t, conflict_value)
        initial = project_files(t, conflict, conflict_value)

        step = write_step(path, before, desired, "regular", 0)
        step = Map.put(step, "expected_no_fault_outcome", "error_conflict")
        task(candidate, t, initial, initial, [step], [], ground_truth(0, 0))
      end

      defp new_task("W06", candidate, seed) do
        t = tokens(seed, "W06")
        path = "lib/generated_#{t["path"]}/corpus_case.ex"
        before = module_value(t, "pre_#{t["value"]}")
        test = "defmodule Corpus#{String.capitalize(t["module"])}Test do\n  use ExUnit.Case\n\n  test \"frozen outcome\" do\n    assert File.read!(\"#{path}\") == \"\"\n  end\nend\n"
        initial = base_files() ++ [file(path, before), file("test/corpus_case_test.exs", test)]
        expected = base_files() ++ [file(path, ""), file("test/corpus_case_test.exs", test)]
        step = write_step(path, before, "", "regular", 1)
        task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
      end

      defp new_task("P02", candidate, seed) do
        t = tokens(seed, "P02")
        path = "lib/generated_#{t["path"]}/corpus_case.ex"
        old_text = "old_#{t["value"]}"
        new_text = "new_#{t["new_value"]}"
        before = "defmodule Corpus#{String.capitalize(t["module"])} do\r\n  def value, do: \"#{old_text}\"\r\n  def untouched, do: \"#{t["sentinel"]}\"\r\nend\r\n"
        after_content = String.replace(before, old_text, new_text, global: false)
        initial = project_files(t, before, new_text)
        expected = replace_file(initial, path, after_content)
        step = patch_step(path, before, after_content, old_text, new_text, 1)
        task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
      end
    '''
  end

  defp compatible_source!(source, compatibility) do
    profiles = Map.new(compatibility["candidates"], &{&1["id"], &1})

    candidates =
      Enum.map(source["candidate_frame"], fn candidate ->
        profile = Map.fetch!(profiles, candidate["id"])
        true = profile["class"] == candidate["operation_class"]

        candidate
        |> Map.put("primary_fault", profile["primary_fault"])
        |> Map.put("secondary_fault", profile["secondary_fault"])
      end)

    true = Enum.sort(Map.keys(profiles)) == Enum.sort(Enum.map(candidates, & &1["id"]))
    Map.put(source, "candidate_frame", candidates)
  end

  defp validate_task!(task, profile) do
    true = task["id"] == profile["id"]
    true = task["operation_class"] == profile["class"]
    true = task["primary_fault"] == profile["primary_fault"]
    true = task["secondary_fault"] == profile["secondary_fault"]
    true = length(task["plan"]["steps"]) == profile["step_count"]

    true =
      Enum.all?(task["plan"]["steps"], &(&1["operation_kind"] == profile["class"]))

    target = target_step!(task)
    changes = task["plan"]["pre_operation_changes"]
    true = target["expected_job_external_mutation_count"] == profile["fault_target_job_mutations"]
    true = length(changes) == profile["environmental_mutations_before_dispatch"]

    true =
      task["ground_truth"]["expected_no_fault_job_external_mutation_count"] ==
        profile["fault_target_job_mutations"]

    true =
      task["ground_truth"]["expected_no_fault_environmental_mutation_count"] == length(changes)

    true =
      profile["complete_task_requires_live_continuation"] ==
        length(task["plan"]["steps"]) > 1

    initial = task["fixture"]["initial_files"]
    pre_effect = apply_environment(initial, changes)
    target_files = fault_target_files(pre_effect, target, task)
    complete = execute_no_fault!(task, pre_effect)
    expected = task["fixture"]["expected_no_fault_files"]

    true =
      Fixture.digest_files(complete) == Fixture.digest_files(expected) ||
        raise("#{task["id"]}: executable no-fault workspace does not match ground truth")

    fixture = task["fixture"]
    true = fixture["initial_workspace_sha256"] == Fixture.digest_files(initial)
    true = fixture["expected_no_fault_workspace_sha256"] == Fixture.digest_files(expected)
    true = fixture["fixture_sha256"] == Fixture.fixture_digest(task)

    p02 = if task["id"] == "P02", do: validate_p02!(task), else: nil

    %{
      "id" => task["id"],
      "operation_class" => task["operation_class"],
      "fixture_sha256" => fixture["fixture_sha256"],
      "step_count" => length(task["plan"]["steps"]),
      "fault_target_job_mutations" => target["expected_job_external_mutation_count"],
      "environmental_mutations_before_dispatch" => length(changes),
      "complete_task_requires_live_continuation" =>
        profile["complete_task_requires_live_continuation"],
      "workspace_sha256" => %{
        "initial_reset_workspace" => Fixture.digest_files(initial),
        "pre_effect_workspace" => Fixture.digest_files(pre_effect),
        "fault_target_postcondition" => Fixture.digest_files(target_files),
        "complete_task_workspace" => Fixture.digest_files(complete)
      },
      "p02_crlf_exact_edit" => p02
    }
  end

  defp validate_p02!(task) do
    step = target_step!(task)
    before = step["frozen_declarations"]["preimage_content"]
    after_content = step["frozen_declarations"]["postimage_content"]
    old_text = step["arguments"]["old_text"]
    new_text = step["arguments"]["new_text"]
    [{offset, old_size}] = :binary.matches(before, old_text)

    true = String.contains?(before, "\r\n")
    false = String.contains?(String.replace(before, "\r\n", ""), "\n")
    false = String.contains?(String.replace(after_content, "\r\n", ""), "\n")
    true = :binary.replace(before, old_text, new_text) == after_content

    prefix = binary_part(before, 0, offset)
    suffix = binary_part(before, offset + old_size, byte_size(before) - offset - old_size)
    true = after_content == prefix <> new_text <> suffix

    %{
      "unique_match_count" => 1,
      "crlf_only" => true,
      "unrelated_prefix_sha256" => sha256(prefix),
      "unrelated_suffix_sha256" => sha256(suffix),
      "preimage_sha256" => sha256(before),
      "postimage_sha256" => sha256(after_content)
    }
  end

  defp validate_assignment!(task, profile, fault, role, compatibility) do
    true = fault in @faults
    contract = compatibility["fault_contracts"][fault]
    workspace = workspace_contract(task)
    target_mutations = target_step!(task)["expected_job_external_mutation_count"]

    mutations_at_barrier =
      case contract["job_mutations_at_barrier"] do
        "task_defined" -> target_mutations
        count -> count
      end

    if fault == "F3", do: true = target_mutations == 1
    if fault in ~w(F1 F2), do: true = mutations_at_barrier == 0

    barrier_workspace = contract["barrier_workspace"]
    true = is_binary(workspace[barrier_workspace])

    convergence =
      get_in(profile, ["workspace_overrides", fault]) || contract["converged_workspace"]

    for condition <- ~w(baseline receipts) do
      true = is_binary(workspace[convergence[condition]])
    end

    causal = contract["causal_terminal_evidence_expected_to_survive"]
    true = Enum.sort(Map.keys(causal)) == ~w(baseline receipts)
    true = Enum.all?(Map.values(causal), &is_boolean/1)

    %{
      "id" => "#{task["id"]}-#{role}",
      "task_id" => task["id"],
      "role" => role,
      "fault" => fault,
      "job_mutations_at_barrier" => mutations_at_barrier,
      "barrier_workspace" => barrier_workspace,
      "barrier_workspace_sha256" => workspace[barrier_workspace],
      "converged_workspace_by_condition" => convergence,
      "converged_workspace_sha256_by_condition" =>
        Map.new(convergence, fn {condition, name} -> {condition, workspace[name]} end),
      "causal_terminal_evidence_expected_to_survive" => causal
    }
  end

  defp workspace_contract(task) do
    initial = task["fixture"]["initial_files"]
    pre_effect = apply_environment(initial, task["plan"]["pre_operation_changes"])
    target = fault_target_files(pre_effect, target_step!(task), task)

    %{
      "initial_reset_workspace" => Fixture.digest_files(initial),
      "pre_effect_workspace" => Fixture.digest_files(pre_effect),
      "fault_target_postcondition" => Fixture.digest_files(target),
      "complete_task_workspace" =>
        Fixture.digest_files(task["fixture"]["expected_no_fault_files"])
    }
  end

  defp fault_target_files(files, step, task) do
    if step["expected_job_external_mutation_count"] == 0 do
      files
    else
      apply_successful_step(files, step, task)
    end
  end

  defp execute_no_fault!(task, files) do
    Enum.reduce_while(task["plan"]["steps"], files, fn step, current ->
      case step["expected_no_fault_outcome"] do
        "ok" ->
          {:cont, apply_successful_step(current, step, task)}

        "error_conflict" ->
          true = validate_conflict!(current, step)
          {:halt, current}

        "error_exit_" <> _status ->
          {:halt, apply_successful_step(current, step, task)}
      end
    end)
  end

  defp apply_successful_step(files, %{"operation_kind" => "write"} = step, _task) do
    arguments = step["arguments"]

    if file_digest(files, arguments["path"]) == arguments["desired"]["sha256"] do
      files
    else
      validate_write_precondition!(files, arguments)
      upsert_file(files, arguments["path"], arguments["desired"]["content"])
    end
  end

  defp apply_successful_step(files, %{"operation_kind" => "patch"} = step, task) do
    arguments = step["arguments"]
    before = file_content!(files, arguments["path"])

    if sha256(before) == arguments["postimage_sha256"] do
      files
    else
      true =
        sha256(before) == arguments["preimage_sha256"] ||
          raise("#{task["id"]}: patch preimage digest does not match")

      true =
        length(:binary.matches(before, arguments["old_text"])) == 1 ||
          raise("#{task["id"]}: patch old_text is not unique")

      after_content = :binary.replace(before, arguments["old_text"], arguments["new_text"])

      true =
        sha256(after_content) == arguments["postimage_sha256"] ||
          raise("#{task["id"]}: patch postimage digest does not match")

      upsert_file(files, arguments["path"], after_content)
    end
  end

  defp apply_successful_step(_files, %{"operation_kind" => "shell"}, task) do
    task["fixture"]["expected_no_fault_files"]
  end

  defp validate_conflict!(files, %{"operation_kind" => "write"} = step) do
    arguments = step["arguments"]
    false = write_precondition?(files, arguments)
    true
  end

  defp validate_conflict!(files, %{"operation_kind" => "patch"} = step) do
    arguments = step["arguments"]
    before = file_content!(files, arguments["path"])

    false =
      sha256(before) == arguments["preimage_sha256"] and
        length(:binary.matches(before, arguments["old_text"])) == 1

    true
  end

  defp validate_write_precondition!(files, arguments) do
    true = write_precondition?(files, arguments)
  end

  defp write_precondition?(files, %{"path" => path, "expected" => %{"state" => "absent"}}) do
    not Enum.any?(files, &(&1["path"] == path))
  end

  defp write_precondition?(files, %{
         "path" => path,
         "expected" => %{"state" => "regular", "sha256" => expected}
       }) do
    Enum.any?(files, &(&1["path"] == path and sha256(&1["content"]) == expected))
  end

  defp apply_environment(files, changes) do
    Enum.reduce(changes, files, fn change, current ->
      upsert_file(current, change["path"], change["content"])
    end)
  end

  defp upsert_file(files, path, content) do
    if Enum.any?(files, &(&1["path"] == path)) do
      Enum.map(files, fn
        %{"path" => ^path} = file -> Map.put(file, "content", content)
        file -> file
      end)
    else
      files ++ [%{"path" => path, "mode" => "0644", "content" => content}]
    end
  end

  defp file_content!(files, path),
    do: Enum.find_value(files, &(&1["path"] == path && &1["content"]))

  defp file_digest(files, path) do
    case Enum.find(files, &(&1["path"] == path)) do
      nil -> nil
      file -> sha256(file["content"])
    end
  end

  defp target_step!(task) do
    target = task["plan"]["fault_target_step"]
    Enum.find(task["plan"]["steps"], &(&1["id"] == target))
  end

  defp verify_preserved_artifacts! do
    Enum.each(@preserved_artifacts, fn {path, expected} ->
      true = file_sha256!(path) == expected
    end)
  end

  defp read_json!(path), do: path |> File.read!() |> JSON.decode!()
  defp file_sha256!(path), do: path |> File.read!() |> sha256()
  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end

unless Process.get(:elara_exp003_v6_preflight_no_run) do
  Elara.Benchmark.Exp003V6Preflight.run()
end
