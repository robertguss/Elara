defmodule Elara.Benchmark.Exp003V2Materializer do
  @moduledoc false

  alias Elara.Benchmark.Fixture

  @version "ER-3/FND-2-v2"
  @schema "elara.exp003.corpus.v2"
  @root "test/fixtures/benchmark/exp003-v2"
  @source_manifest "test/fixtures/benchmark/exp003/manifest.json"
  @source_dogfood "test/fixtures/benchmark/exp003/dogfood-plan.json"
  @manifest_path Path.join(@root, "manifest.json")
  @dogfood_path Path.join(@root, "dogfood-plan.json")
  @chain_hash "8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce"
  @round 6_426_976
  @randomness "102a5c96e0068d5a3bef46be242054307efb1dfd362c63c483c987f8d5319356"
  @frozen_commit "ff15e210f8ba9d62e439f2fe03dc8eb4b02f77c2"
  @token_fields ~w(module path value new_value sentinel preimage postimage)
  @shell_ids ~w(S01 S02 S03 S04)

  def run do
    source = read_json!(@source_manifest)
    dogfood = read_json!(@source_dogfood)
    beacon = verified_beacon!()
    seed = seed()
    candidates = candidates(source, seed)
    selected_ids = selected_ids(candidates)
    task_sources = Map.new(source["tasks"], &{&1["id"], &1})
    adapter_sources = Map.new(source["adapter_equivalence_fixtures"], &{&1["template_id"], &1})

    tasks =
      Enum.map(selected_ids, fn id ->
        build_task(id, candidates, task_sources, adapter_sources, source, seed)
      end)

    secondary_ids = Enum.take(selected_ids, 8)
    rows = rows(source, tasks, selected_ids, secondary_ids)

    adapters =
      Enum.map(source["adapter_equivalence_fixtures"], &retokenize_adapter(&1, source, seed))

    selection = selection(candidates, selected_ids, secondary_ids)

    manifest =
      source
      |> Map.put("schema", @schema)
      |> Map.put("preregistration_version", @version)
      |> Map.put("linear_issue", "ROB-843")
      |> Map.put("beacon", beacon)
      |> Map.put("seed", seed_record(seed))
      |> Map.put("candidate_frame", candidates)
      |> Map.put("selection", selection)
      |> Map.put("tasks", tasks)
      |> Map.put("fault_rows", rows)
      |> Map.put("adapter_equivalence_fixtures", adapters)
      |> Map.put("references", references())
      |> Map.put("exposure_statement", exposure_statement())
      |> Map.put("amendment_policy", amendment_policy())
      |> Map.put("materializer", %{
        "source" => "priv/benchmark/materialize_exp003_v2.exs",
        "sha256" => file_sha256!("priv/benchmark/materialize_exp003_v2.exs"),
        "source_template" => @source_manifest,
        "source_template_sha256" => file_sha256!(@source_manifest)
      })

    dogfood = dogfood(dogfood, seed)

    File.mkdir_p!(@root)
    File.write!(@manifest_path, Jason.encode!(manifest, pretty: true) <> "\n")
    File.write!(@dogfood_path, Jason.encode!(dogfood, pretty: true) <> "\n")

    IO.puts("manifest_sha256=#{file_sha256!(@manifest_path)}")
    IO.puts("dogfood_plan_sha256=#{file_sha256!(@dogfood_path)}")
    IO.puts("seed=#{Base.encode16(seed, case: :lower)}")
    IO.puts("tasks=#{Enum.join(selected_ids, ",")}")
    IO.puts("dogfood=#{Enum.join(dogfood["execution_order"], ",")}")
  end

  defp verified_beacon! do
    api = read_json!(Path.join(@root, "beacon/api.drand.sh.json"))
    cloudflare = read_json!(Path.join(@root, "beacon/drand.cloudflare.com.json"))
    verification = read_json!(Path.join(@root, "beacon/verification.json"))

    true = api == cloudflare
    true = api["round"] == @round
    true = api["randomness"] == @randomness
    true = sha256(Base.decode16!(api["signature"], case: :mixed)) == @randomness
    true = verification["verified"]

    verified =
      verification["results"]
      |> Enum.map(&Map.drop(&1, ["url"]))
      |> Enum.uniq()

    true = verified == [api]

    artifacts =
      Map.new(~w(api.drand.sh.json drand.cloudflare.com.json verification.json), fn name ->
        {name, file_sha256!(Path.join(@root, "beacon/#{name}"))}
      end)

    %{
      "chain_hash" => @chain_hash,
      "genesis_time" => 1_595_431_050,
      "period_seconds" => 30,
      "round_formula" => "ER-3/FND-2-v2 exact committed future round",
      "round" => @round,
      "nominal_time" => "2026-09-01T05:25:00Z",
      "randomness" => @randomness,
      "relay_response_paths" => ~w(beacon/api.drand.sh.json beacon/drand.cloudflare.com.json),
      "verification_path" => "beacon/verification.json",
      "official_client" => "drand-client@1.4.2",
      "signature_verified" => true,
      "artifact_sha256" => artifacts,
      "verification_script_path" => "beacon/verify.cjs",
      "verification_command" => "npm install --ignore-scripts && node verify.cjs"
    }
  end

  defp seed do
    sha256_binary(
      "elara:exp-003:er3:fnd-2:v2\0" <>
        @chain_hash <> ":#{@round}:" <> @randomness <> ":" <> @frozen_commit
    )
  end

  defp seed_record(seed) do
    %{
      "derivation" =>
        "SHA-256(\"elara:exp-003:er3:fnd-2:v2\\0\" || chain_hash || \":\" || decimal_round || \":\" || randomness_hex || \":\" || frozen_commit)",
      "frozen_commit" => @frozen_commit,
      "sha256" => Base.encode16(seed, case: :lower)
    }
  end

  defp candidates(source, seed) do
    Enum.map(source["candidate_frame"], fn candidate ->
      Map.put(candidate, "order_key", order_key(seed, candidate["id"]))
    end)
  end

  defp selected_ids(candidates) do
    typed =
      for operation <- ~w(write patch), fault <- ~w(F1 F2 F3 F4) do
        candidates
        |> Enum.filter(&(&1["operation_class"] == operation and &1["primary_fault"] == fault))
        |> Enum.min_by(& &1["order_key"])
        |> Map.fetch!("id")
      end

    (typed ++ @shell_ids)
    |> Enum.sort_by(&candidate!(candidates, &1)["order_key"])
  end

  defp selection(candidates, selected, secondary) do
    choices =
      for operation <- ~w(write patch), into: %{} do
        by_fault =
          for fault <- ~w(F1 F2 F3 F4), into: %{} do
            id =
              selected
              |> Enum.map(&candidate!(candidates, &1))
              |> Enum.find(&(&1["operation_class"] == operation and &1["primary_fault"] == fault))
              |> Map.fetch!("id")

            {fault, id}
          end

        {operation, by_fault}
      end

    %{
      "algorithm" =>
        "Universal: lowest order key per primary F1-F4 for write and patch; explicit all S01-S04; all selected primary rows plus secondary rows for eight lowest-key selected tasks",
      "non_amending_shell_interpretation" =>
        "Preserve table labels S01/S02/S03/S04 = F1/F2/F3/F2, select all four from explicit prose/count, and disclose absent shell primary F4; do not correct S04.",
      "selected_task_ids" => selected,
      "secondary_row_task_ids" => secondary,
      "candidate_order_keys" => Map.new(candidates, &{&1["id"], &1["order_key"]}),
      "stratum_choices" => Map.put(choices, "shell", @shell_ids),
      "shell_primary_distribution" => ~w(F1 F2 F3 F2),
      "task_count" => 12,
      "scored_row_count" => 20
    }
  end

  defp build_task(id, candidates, sources, adapter_sources, source, seed) do
    candidate = candidate!(candidates, id)

    task =
      cond do
        Map.has_key?(sources, id) -> retokenize_task(sources[id], source, seed)
        id == "W01" -> task_from_adapter(adapter_sources[id], candidate, source, seed)
        id in ~w(W02 P03 P05 P06) -> new_task(id, candidate, seed)
      end

    task
    |> Map.put("brief", candidate["brief"])
    |> Map.put("request", candidate["brief"])
    |> Map.put("order_key", candidate["order_key"])
    |> Map.put("primary_fault", candidate["primary_fault"])
    |> Map.put("secondary_fault", candidate["secondary_fault"])
    |> rehash_task()
  end

  defp retokenize_task(task, source, seed) do
    id = task["id"]

    task
    |> replace_tokens(token_replacements(source, seed, id))
    |> Map.put("generated_tokens", tokens(seed, id))
    |> Map.put("exposure_split", "held_out_relative_to_target_implementation")
    |> put_in(["fixture", "schema"], "elara.exp003.fixture.v2")
    |> put_in(["fixture", "fixture_ref"], "#{@manifest_path}#task-#{id}")
    |> put_in(["plan", "schema"], "elara.exp003.plan.v2")
  end

  defp task_from_adapter(adapter, candidate, source, seed) do
    transformed = retokenize_adapter(adapter, source, seed)
    id = candidate["id"]

    %{
      "id" => id,
      "operation_class" => candidate["operation_class"],
      "brief" => candidate["brief"],
      "request" => candidate["brief"],
      "order_key" => candidate["order_key"],
      "primary_fault" => candidate["primary_fault"],
      "secondary_fault" => candidate["secondary_fault"],
      "generated_tokens" => tokens(seed, id),
      "exposure_split" => "held_out_relative_to_target_implementation",
      "fixture" => Map.put(transformed["fixture"], "fixture_ref", "#{@manifest_path}#task-#{id}"),
      "plan" => transformed["plan"],
      "ground_truth" => ground_truth(1, 0, %{"expected_task_tool_call_count" => 1})
    }
  end

  defp retokenize_adapter(adapter, source, seed) do
    id = adapter["template_id"]

    adapter
    |> replace_tokens(token_replacements(source, seed, id))
    |> put_in(["fixture", "schema"], "elara.exp003.fixture.v2")
    |> put_in(["fixture", "fixture_ref"], "#{@manifest_path}#adapter-#{id}")
    |> put_in(["plan", "schema"], "elara.exp003.plan.v2")
    |> rehash_adapter()
  end

  defp new_task("W02", candidate, seed) do
    t = tokens(seed, "W02")
    path = "lib/generated_#{t["path"]}/corpus_case.ex"
    before = module_value(t, "pre_#{t["value"]}")
    after_value = "new_#{t["new_value"]}"
    after_content = module_value(t, after_value)
    initial = project_files(t, before, after_value)
    expected = replace_file(initial, path, after_content)

    step = write_step(path, before, after_content, "regular", 1)
    task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
  end

  defp new_task("P03", candidate, seed) do
    t = tokens(seed, "P03")
    path = "lib/generated_#{t["path"]}/corpus_case.ex"
    before = module_value(t, "pre_#{t["value"]}")
    after_value = "post_#{t["new_value"]}"
    after_content = module_value(t, after_value)
    initial = project_files(t, after_content, after_value)
    step = patch_step(path, before, after_content, "pre_#{t["value"]}", after_value, 0)
    task(candidate, t, initial, initial, [step], [], ground_truth(0, 0))
  end

  defp new_task("P05", candidate, seed) do
    t = Map.put(tokens(seed, "P05"), "concurrent", token(seed, "P05", "concurrent"))
    path = "lib/generated_#{t["path"]}/corpus_case.ex"
    before = module_with_note(t, "old_#{t["value"]}", "before_#{t["preimage"]}")
    post = module_with_note(t, "new_#{t["new_value"]}", "before_#{t["preimage"]}")
    concurrent = module_with_note(t, "old_#{t["value"]}", "concurrent_#{t["concurrent"]}")
    initial = project_files(t, before, "old_#{t["value"]}")
    expected = replace_file(initial, path, concurrent)

    change = %{
      "id" => "concurrent-same-file-edit",
      "kind" => "environment",
      "barrier" => "before_effect_dispatch",
      "path" => path,
      "content" => concurrent,
      "attributed_to_job" => false
    }

    step = patch_step(path, before, post, "old_#{t["value"]}", "new_#{t["new_value"]}", 0)
    step = Map.put(step, "expected_no_fault_outcome", "error_conflict")
    task(candidate, t, initial, expected, [step], [change], ground_truth(0, 1))
  end

  defp new_task("P06", candidate, seed) do
    t = tokens(seed, "P06")
    source_path = "lib/generated_#{t["path"]}/corpus_case.ex"
    test_path = "test/corpus_case_test.exs"
    before_source = module_value(t, "old_#{t["value"]}")
    after_source = module_value(t, "new_#{t["new_value"]}")
    before_test = test_content(t, "old_#{t["value"]}")
    after_test = test_content(t, "new_#{t["new_value"]}")

    initial = base_files() ++ [file(source_path, before_source), file(test_path, before_test)]
    expected = base_files() ++ [file(source_path, after_source), file(test_path, after_test)]

    effect =
      patch_step(
        source_path,
        before_source,
        after_source,
        "old_#{t["value"]}",
        "new_#{t["new_value"]}",
        1,
        "effect"
      )

    continuation =
      patch_step(
        test_path,
        before_test,
        after_test,
        "old_#{t["value"]}",
        "new_#{t["new_value"]}",
        1,
        "continuation"
      )

    truth =
      ground_truth(1, 0, %{
        "expected_task_tool_call_count" => 2,
        "expected_task_session_result_count" => 2,
        "fault_evidence_scope" => "effect job only",
        "expected_task_external_mutation_count" => 2
      })

    task(candidate, t, initial, expected, [effect, continuation], [], truth)
    |> put_in(["plan", "scripted_provider"], [
      provider_call("P06", "patch", 0, 1),
      provider_call("P06-continuation", "patch", 1, 2),
      %{"turn" => 3, "kind" => "assistant_text", "content" => "Task complete."}
    ])
    |> put_in(["plan", "continuation_policy"], %{
      "after_target_ok" => "execute continuation exactly once",
      "after_target_error" => "halt without continuation",
      "after_target_indeterminate" => "halt without retry or continuation",
      "fault_injection" => "effect only; continuation is never faulted",
      "parallelism" => "forbidden"
    })
  end

  defp task(candidate, tokens, initial, expected, steps, changes, truth) do
    id = candidate["id"]

    %{
      "id" => id,
      "operation_class" => candidate["operation_class"],
      "brief" => candidate["brief"],
      "request" => candidate["brief"],
      "order_key" => candidate["order_key"],
      "primary_fault" => candidate["primary_fault"],
      "secondary_fault" => candidate["secondary_fault"],
      "generated_tokens" => tokens,
      "exposure_split" => "held_out_relative_to_target_implementation",
      "fixture" => %{
        "schema" => "elara.exp003.fixture.v2",
        "digest_algorithm" =>
          "elara.workspace.v1 sorted path/mode/byte-length/content; excludes only declared transient artifacts",
        "initial_files" => initial,
        "expected_no_fault_files" => expected,
        "fixture_ref" => "#{@manifest_path}#task-#{id}"
      },
      "plan" => %{
        "schema" => "elara.exp003.plan.v2",
        "pre_operation_changes" => changes,
        "steps" => steps,
        "fault_target_step" => "effect",
        "scripted_provider" =>
          Enum.map(Enum.with_index(steps, 1), fn {step, turn} ->
            provider_call(id, step["operation_kind"], turn - 1, turn)
          end) ++
            [
              %{
                "turn" => length(steps) + 1,
                "kind" => "assistant_text",
                "content" => "Task complete."
              }
            ]
      },
      "ground_truth" => truth
    }
  end

  defp write_step(path, before, after_content, state, mutations) do
    expected =
      if state == "absent",
        do: %{"state" => "absent"},
        else: %{"state" => "regular", "sha256" => sha256(before)}

    declarations =
      if state == "absent",
        do: %{"expected_preimage_state" => "absent", "desired_postimage_content" => after_content},
        else: %{
          "expected_preimage_content" => before,
          "desired_postimage_content" => after_content
        }

    %{
      "id" => "effect",
      "operation_kind" => "write",
      "arguments" => %{
        "schema" => "elara.declarative_write.v1",
        "path" => path,
        "expected" => expected,
        "desired" => %{"content" => after_content, "sha256" => sha256(after_content)},
        "parent_policy" => "create",
        "replacement" => "same_directory_temp_rename"
      },
      "expected_no_fault_outcome" => "ok",
      "expected_job_external_mutation_count" => mutations,
      "expected_environmental_mutation_count" => 0,
      "frozen_declarations" => declarations
    }
  end

  defp patch_step(path, before, after_content, old_text, new_text, mutations, id \\ "effect") do
    %{
      "id" => id,
      "operation_kind" => "patch",
      "arguments" => %{
        "schema" => "elara.literal_patch.v1",
        "path" => path,
        "preimage_sha256" => sha256(before),
        "old_text" => old_text,
        "new_text" => new_text,
        "postimage_sha256" => sha256(after_content),
        "replacement" => "same_directory_temp_rename"
      },
      "expected_no_fault_outcome" => "ok",
      "expected_job_external_mutation_count" => mutations,
      "expected_environmental_mutation_count" => 0,
      "frozen_declarations" => %{
        "preimage_content" => before,
        "postimage_content" => after_content
      }
    }
  end

  defp provider_call(id, operation, step_index, turn) do
    %{
      "turn" => turn,
      "kind" => "tool_call",
      "tool_call_id" => "exp003-#{String.downcase(id)}",
      "operation_kind" => operation,
      "arguments_ref" => "plan.steps[#{step_index}].arguments"
    }
  end

  defp ground_truth(job_mutations, environmental_mutations, extra \\ %{}) do
    Map.merge(
      %{
        "source" =>
          "neutral adapter mutation hook plus exact fixture bytes; never subject-visible",
        "required_counts" =>
          ~w(admission_count callback_attempt_count external_mutation_count session_result_count),
        "expected_no_fault_job_external_mutation_count" => job_mutations,
        "expected_no_fault_environmental_mutation_count" => environmental_mutations,
        "evidence_identity" =>
          "fault target step -> tool call ID -> distinct durable job ID/digest"
      },
      extra
    )
  end

  defp rows(source, tasks, selected, secondary) do
    tasks_by_id = Map.new(tasks, &{&1["id"], &1})

    specs =
      Enum.map(selected, &{&1, tasks_by_id[&1]["primary_fault"], "primary"}) ++
        Enum.map(secondary, &{&1, tasks_by_id[&1]["secondary_fault"], "secondary"})

    specs
    |> Enum.with_index(1)
    |> Enum.map(fn {{task_id, fault, role}, index} ->
      task = tasks_by_id[task_id]

      template =
        Enum.find(source["fault_rows"], fn row ->
          row["fault_type"] == fault and row["operation_class"] == task["operation_class"]
        end) || Enum.find(source["fault_rows"], &(&1["fault_type"] == fault))

      target = task["plan"]["fault_target_step"]
      step = Enum.find(task["plan"]["steps"], &(&1["id"] == target))

      call =
        Enum.find(
          task["plan"]["scripted_provider"],
          &(&1["arguments_ref"] == step_ref(task, step))
        )

      template
      |> Map.put("row_id", "#{task_id}-#{fault}")
      |> Map.put("order_index", index)
      |> Map.put("task_id", task_id)
      |> Map.put("operation_class", task["operation_class"])
      |> Map.put("fault_role", role)
      |> Map.put(
        "observation_deadline_ms",
        if(task["operation_class"] == "shell", do: 5_000, else: 2_000)
      )
      |> Map.put("fault_target_step", target)
      |> Map.put("fault_target_tool_call_id", call["tool_call_id"])
      |> Map.put(
        "evidence_scope",
        "fault-target durable job only; task totals reported separately"
      )
    end)
  end

  defp step_ref(task, step) do
    index = Enum.find_index(task["plan"]["steps"], &(&1["id"] == step["id"]))
    "plan.steps[#{index}].arguments"
  end

  defp rehash_task(task) do
    task =
      update_in(task, ["plan", "steps"], &Enum.map(&1, fn step -> rehash_step(step, task) end))

    fixture = task["fixture"]

    task =
      task
      |> put_in(
        ["fixture", "initial_workspace_sha256"],
        Fixture.digest_files(fixture["initial_files"])
      )
      |> put_in(
        ["fixture", "expected_no_fault_workspace_sha256"],
        Fixture.digest_files(fixture["expected_no_fault_files"])
      )

    digest = Fixture.fixture_digest(task)

    task
    |> put_in(["fixture", "fixture_sha256"], digest)
    |> put_in(["fixture", "fixture_commit"], "sha256:" <> digest)
  end

  defp rehash_adapter(adapter) do
    fake = %{
      "id" => adapter["template_id"],
      "fixture" => adapter["fixture"],
      "plan" => adapter["plan"]
    }

    fake = rehash_task(fake)
    adapter |> Map.put("fixture", fake["fixture"]) |> Map.put("plan", fake["plan"])
  end

  defp rehash_step(%{"operation_kind" => "write"} = step, _task) do
    declarations = step["frozen_declarations"]
    desired = declarations["desired_postimage_content"]

    step
    |> put_in(["arguments", "desired", "content"], desired)
    |> put_in(["arguments", "desired", "sha256"], sha256(desired))
    |> then(fn updated ->
      case declarations do
        %{"expected_preimage_content" => before} ->
          put_in(updated, ["arguments", "expected", "sha256"], sha256(before))

        _other ->
          updated
      end
    end)
  end

  defp rehash_step(%{"operation_kind" => "patch"} = step, _task) do
    declarations = step["frozen_declarations"]

    step
    |> put_in(["arguments", "preimage_sha256"], sha256(declarations["preimage_content"]))
    |> put_in(["arguments", "postimage_sha256"], sha256(declarations["postimage_content"]))
  end

  defp rehash_step(%{"operation_kind" => "shell"} = step, task) do
    case get_in(step, ["arguments", "postcondition", "files"]) do
      files when is_list(files) ->
        expected = Map.new(task["fixture"]["expected_no_fault_files"], &{&1["path"], &1})

        updated =
          Enum.map(files, fn declaration ->
            Map.put(declaration, "sha256", sha256(expected[declaration["path"]]["content"]))
          end)

        put_in(step, ["arguments", "postcondition", "files"], updated)

      _other ->
        step
    end
  end

  defp token_replacements(source, seed, id) do
    old_seed = Base.decode16!(source["seed"]["sha256"], case: :mixed)
    old = tokens(old_seed, id)
    new = tokens(seed, id)

    Enum.flat_map(@token_fields, fn field ->
      [{old[field], new[field]}, {String.capitalize(old[field]), String.capitalize(new[field])}]
    end)
  end

  defp replace_tokens(value, replacements) when is_binary(value) do
    Enum.reduce(replacements, value, fn {old, new}, replaced ->
      String.replace(replaced, old, new)
    end)
  end

  defp replace_tokens(value, replacements) when is_list(value),
    do: Enum.map(value, &replace_tokens(&1, replacements))

  defp replace_tokens(value, replacements) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, replace_tokens(item, replacements)} end)

  defp replace_tokens(value, _replacements), do: value

  defp tokens(seed, id), do: Map.new(@token_fields, &{&1, token(seed, id, &1)})

  defp token(seed, id, field),
    do: sha256(seed <> <<0>> <> id <> <<0>> <> field) |> binary_part(0, 16)

  defp order_key(seed, id), do: sha256(seed <> <<0>> <> id)

  defp project_files(tokens, module_content, expected_value) do
    base_files() ++
      [
        file("lib/generated_#{tokens["path"]}/corpus_case.ex", module_content),
        file("test/corpus_case_test.exs", test_content(tokens, expected_value))
      ]
  end

  defp base_files do
    [
      file(
        "mix.exs",
        "defmodule CorpusFixture.MixProject do\n  use Mix.Project\n\n  def project, do: [app: :corpus_fixture, version: \"0.1.0\", elixir: \"~> 1.20\", deps: []]\nend\n"
      ),
      file("test/test_helper.exs", "ExUnit.start()\n")
    ]
  end

  defp module_value(tokens, value),
    do:
      "defmodule Corpus#{String.capitalize(tokens["module"])} do\n  def value, do: \"#{value}\"\nend\n"

  defp module_with_note(tokens, value, note) do
    "defmodule Corpus#{String.capitalize(tokens["module"])} do\n  def value, do: \"#{value}\"\n  def note, do: \"#{note}\"\nend\n"
  end

  defp test_content(tokens, expected_value) do
    "defmodule Corpus#{String.capitalize(tokens["module"])}Test do\n  use ExUnit.Case\n\n  test \"frozen outcome\" do\n    assert Corpus#{String.capitalize(tokens["module"])}.value() == \"#{expected_value}\"\n  end\nend\n"
  end

  defp file(path, content), do: %{"path" => path, "mode" => "0644", "content" => content}

  defp replace_file(files, path, content) do
    Enum.map(files, fn
      %{"path" => ^path} = entry -> Map.put(entry, "content", content)
      entry -> entry
    end)
  end

  defp dogfood(source, seed) do
    tasks =
      Enum.map(source["tasks"], fn task ->
        Map.put(task, "order_key", order_key(seed, task["id"]))
      end)

    order = tasks |> Enum.sort_by(& &1["order_key"]) |> Enum.map(& &1["id"])

    source
    |> Map.put("schema", "elara.exp003.dogfood-plan.v2")
    |> Map.put("preregistration_version", @version)
    |> Map.put("seed", %{
      "sha256" => Base.encode16(seed, case: :lower),
      "round" => @round,
      "order_key_formula" => "SHA-256(hex_decode(seed.sha256) || NUL || task_id)"
    })
    |> Map.put("execution_order", order)
    |> Map.put("tasks", tasks)
    |> put_in(
      ["source", "frozen_artifact"],
      "docs/experiments/003-effect-receipt-confirmatory-preregistration-v2.md"
    )
    |> put_in(["source", "linear_issue"], "ROB-843")
  end

  defp references do
    %{
      "preregistration" =>
        "docs/experiments/003-effect-receipt-confirmatory-preregistration-v2.md",
      "preserved_v1" => "docs/experiments/003-effect-receipt-confirmatory-preregistration.md",
      "gate_2" => "ROB-832",
      "materialization" => "ROB-843"
    }
  end

  defp exposure_statement do
    %{
      "target_fault_rows_executed" => 0,
      "external_fault_rows_executed" => 0,
      "dogfood_task_runs" => 0,
      "dogfood_fault_runs" => 0,
      "B_or_T_calculated" => false,
      "statement" =>
        "V2 materialization and no-fault construction only; no relevant fault output observed."
    }
  end

  defp amendment_policy do
    %{
      "version" => @version,
      "v1_preserved" => true,
      "fresh_future_round" => @round,
      "post_exposure_changes_require_new_version_seed_and_inputs" => true,
      "missing_or_inconsistent_rows_invalidate_instead_of_shrinking_denominator" => true
    }
  end

  defp candidate!(candidates, id), do: Enum.find(candidates, &(&1["id"] == id))
  defp read_json!(path), do: path |> File.read!() |> JSON.decode!()
  defp file_sha256!(path), do: path |> File.read!() |> sha256()
  defp sha256(value), do: value |> sha256_binary() |> Base.encode16(case: :lower)
  defp sha256_binary(value), do: :crypto.hash(:sha256, value)
end

Elara.Benchmark.Exp003V2Materializer.run()
