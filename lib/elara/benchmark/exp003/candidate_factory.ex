defmodule Elara.Benchmark.Exp003.CandidateFactory do
  @moduledoc false

  alias Elara.Benchmark.{ElaraAdapter, Fixture}

  @token_fields ~w(module path value new_value sentinel preimage postimage)
  @candidate_ids for(
                   class <- ~w(P W),
                   n <- 1..8,
                   do: class <> String.pad_leading(Integer.to_string(n), 2, "0")
                 ) ++
                   for(n <- 1..4, do: "S" <> String.pad_leading(Integer.to_string(n), 2, "0"))
  @blueprints Map.new(@candidate_ids, fn id ->
                operation =
                  case id do
                    "P" <> _ -> "patch"
                    "W" <> _ -> "write"
                    "S" <> _ -> "shell"
                  end

                {id, %{operation_class: operation, step_count: if(id == "P06", do: 2, else: 1)}}
              end)
  @blueprint_seed :binary.copy(<<0>>, 32)
  @blueprint_shape_sha256 "e5a84961d3a00dc0ddc3dbc627baa8f48346a75ae5f51b0d9891b58075f15e2d"

  @spec compatible_source!(map(), map()) :: map()
  def compatible_source!(source, compatibility) do
    profiles = Map.new(compatibility["candidates"], &{&1["id"], &1})

    candidates =
      Enum.map(source["candidate_frame"], fn candidate ->
        profile = Map.fetch!(profiles, candidate["id"])

        require!(profile["class"] == candidate["operation_class"], {
          :operation_class_mismatch,
          candidate["id"]
        })

        candidate
        |> Map.put("primary_fault", profile["primary_fault"])
        |> Map.put("secondary_fault", profile["secondary_fault"])
      end)

    require!(
      Enum.sort(Map.keys(profiles)) == Enum.sort(Enum.map(candidates, & &1["id"])),
      :candidate_profile_mismatch
    )

    Map.put(source, "candidate_frame", candidates)
  end

  @spec validate_blueprints!(map(), map()) :: :ok
  def validate_blueprints!(source, compatibility) do
    profiles = Map.new(compatibility["candidates"], &{&1["id"], &1})
    candidates = Map.new(source["candidate_frame"], &{&1["id"], &1})

    require!(Enum.sort(Map.keys(candidates)) == Enum.sort(@candidate_ids), :blueprint_frame)
    require!(Enum.sort(Map.keys(profiles)) == Enum.sort(@candidate_ids), :blueprint_profiles)

    Enum.each(@blueprints, fn {id, blueprint} ->
      candidate = Map.fetch!(candidates, id)
      profile = Map.fetch!(profiles, id)
      require!(candidate["operation_class"] == blueprint.operation_class, {:blueprint_class, id})
      require!(profile["class"] == blueprint.operation_class, {:blueprint_profile_class, id})
      require!(profile["step_count"] == blueprint.step_count, {:blueprint_steps, id})
    end)

    tasks = blueprint_tasks(source)

    Enum.each(tasks, fn task ->
      require!(
        Fixture.fixture_digest(task) == task["fixture"]["fixture_sha256"],
        {:blueprint_fixture, task["id"]}
      )

      {:ok, mapping} = ElaraAdapter.mapping(task)

      require!(
        length(mapping["tool_calls"]) == @blueprints[task["id"]].step_count,
        {:blueprint_mapping, task["id"]}
      )
    end)

    require!(
      blueprint_shape_sha256(tasks) == @blueprint_shape_sha256,
      :blueprint_structural_shape
    )

    :ok
  end

  @doc false
  @spec blueprint_shape_digest(map()) :: String.t()
  def blueprint_shape_digest(source), do: source |> blueprint_tasks() |> blueprint_shape_sha256()

  @spec construct_all(map(), binary(), keyword()) :: [map()]
  def construct_all(source, seed, opts \\ [])
      when is_map(source) and is_binary(seed) and byte_size(seed) == 32 do
    fixture_schema = Keyword.fetch!(opts, :fixture_schema)
    plan_schema = Keyword.fetch!(opts, :plan_schema)
    fixture_ref = Keyword.fetch!(opts, :fixture_ref)
    exposure_split = Keyword.fetch!(opts, :exposure_split)

    candidates = candidates(source, seed)

    tasks =
      Enum.map(candidates, fn candidate ->
        candidate["id"]
        |> new_task(candidate, seed)
        |> put_versioned_identity(fixture_schema, plan_schema, fixture_ref, exposure_split)
        |> rehash_task()
      end)

    ids = Enum.map(tasks, & &1["id"])
    require!(length(tasks) == 20, {:candidate_count, length(tasks)})
    require!(Enum.sort(ids) == Enum.sort(@candidate_ids), {:candidate_frame, ids})
    require!(Enum.uniq(ids) == ids, :duplicate_candidate)
    tasks
  end

  @spec order_key(binary(), String.t()) :: String.t()
  def order_key(seed, id), do: sha256(seed <> <<0>> <> id)

  defp candidates(source, seed) do
    Enum.map(source["candidate_frame"], fn candidate ->
      Map.put(candidate, "order_key", order_key(seed, candidate["id"]))
    end)
  end

  defp blueprint_tasks(source) do
    construct_all(source, @blueprint_seed,
      fixture_schema: "elara.exp003.fixture.v8-blueprint",
      plan_schema: "elara.exp003.plan.v8-blueprint",
      fixture_ref: &"blueprint://#{&1}",
      exposure_split: "pre_beacon_structural_blueprint"
    )
  end

  defp blueprint_shape_sha256(tasks) do
    tasks
    |> Enum.map(fn task ->
      {:ok, mapping} = ElaraAdapter.mapping(task)
      %{"task" => structural_shape(task), "mapping" => structural_shape(mapping)}
    end)
    |> canonical_json()
    |> sha256()
  end

  defp structural_shape(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, structural_shape(item)} end)

  defp structural_shape(value) when is_list(value), do: Enum.map(value, &structural_shape/1)
  defp structural_shape(value) when is_binary(value), do: "string"
  defp structural_shape(value) when is_integer(value), do: "integer"
  defp structural_shape(value) when is_float(value), do: "float"
  defp structural_shape(value) when is_boolean(value), do: "boolean"
  defp structural_shape(nil), do: "null"

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, item} ->
      JSON.encode!(key) <> ":" <> canonical_json(item)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(value) when is_list(value) do
    value |> Enum.map_join(",", &canonical_json/1) |> then(&("[" <> &1 <> "]"))
  end

  defp canonical_json(value), do: JSON.encode!(value)

  defp new_task("W01", candidate, seed) do
    t = tokens(seed, "W01")
    source_path = generated_path(t)
    target_path = "lib/nested_#{t["path"]}/created.ex"
    root_module = root_module(t)
    desired = module_value(t, t["value"])

    initial =
      [
        mix_file(),
        file(source_path, root_module),
        test_helper(),
        file("test/corpus_case_test.exs", true_test(t))
      ]

    expected = initial ++ [file(target_path, desired)]
    step = write_step(target_path, "", desired, "absent", 1)
    task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
  end

  defp new_task("W02", candidate, seed) do
    t = tokens(seed, "W02")
    path = generated_path(t)
    before = module_value(t, "pre_#{t["value"]}")
    after_value = "new_#{t["new_value"]}"
    after_content = module_value(t, after_value)
    initial = project_files(t, before, after_value)
    expected = replace_file(initial, path, after_content)
    step = write_step(path, before, after_content, "regular", 1)
    task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
  end

  defp new_task("W03", candidate, seed) do
    t = tokens(seed, "W03")
    path = generated_path(t)
    before = module_value(t, "pre_#{t["value"]}")
    desired = module_value(t, t["value"])
    initial = project_files(t, desired, t["value"])
    step = write_step(path, before, desired, "regular", 0)
    task(candidate, t, initial, initial, [step], [], ground_truth(0, 0))
  end

  defp new_task("W04", candidate, seed) do
    t = tokens(seed, "W04")
    path = generated_path(t)
    before = module_value(t, "pre_#{t["value"]}")
    desired = module_value(t, "post_#{t["new_value"]}")
    conflict_value = "conflict_#{t["sentinel"]}"
    conflict = module_value(t, conflict_value)
    initial = project_files(t, conflict, conflict_value)

    step =
      path
      |> write_step(before, desired, "regular", 0)
      |> Map.put("expected_no_fault_outcome", "error_conflict")

    task(candidate, t, initial, initial, [step], [], ground_truth(0, 0))
  end

  defp new_task("W05", candidate, seed) do
    t = tokens(seed, "W05")
    path = generated_path(t)
    desired = module_value(t, t["value"])
    initial = project_files(t, "", t["value"])
    expected = replace_file(initial, path, desired)
    step = write_step(path, "", desired, "regular", 1)
    task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
  end

  defp new_task("W06", candidate, seed) do
    t = tokens(seed, "W06")
    path = generated_path(t)
    before = module_value(t, "pre_#{t["value"]}")

    test =
      "defmodule Corpus#{t["module"]}Test do\n  use ExUnit.Case\n\n  test \"frozen outcome\" do\n    assert File.read!(\"#{path}\") == \"\"\n  end\nend\n"

    initial = [
      mix_file(),
      file(path, before),
      test_helper(),
      file("test/corpus_case_test.exs", test)
    ]

    expected = [
      mix_file(),
      file(path, ""),
      test_helper(),
      file("test/corpus_case_test.exs", test)
    ]

    step = write_step(path, before, "", "regular", 1)
    task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
  end

  defp new_task("W07", candidate, seed) do
    t = tokens(seed, "W07")
    source_path = generated_path(t)
    target_path = "lib/nested_#{t["path"]}/created.ex"
    sibling = file("lib/sibling_0d8b13dc01301460.txt", "sibling_3bb1a5bad2e7088f\n")
    desired = module_value(t, t["value"])

    initial =
      [
        mix_file(),
        file(source_path, root_module(t)),
        test_helper(),
        file("test/corpus_case_test.exs", true_test(t)),
        sibling
      ]

    expected = initial ++ [file(target_path, desired)]
    step = write_step(target_path, "", desired, "absent", 1)
    task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
  end

  defp new_task("W08", candidate, seed) do
    t = tokens(seed, "W08")
    path = generated_path(t)
    before = module_value(t, "pre_#{t["value"]}")
    desired = module_value(t, t["new_value"])
    unrelated_path = "notes/unrelated.txt"
    unrelated_before = "before_2df882afbb1672c7\n"
    unrelated_after = "after_8d052f9f229553eb\n"

    initial = project_files(t, before, t["new_value"]) ++ [file(unrelated_path, unrelated_before)]

    expected =
      initial
      |> replace_file(path, desired)
      |> replace_file(unrelated_path, unrelated_after)

    change = %{
      "id" => "concurrent-unrelated-write",
      "kind" => "environment",
      "barrier" => "before_effect_dispatch",
      "path" => unrelated_path,
      "content" => unrelated_after,
      "attributed_to_job" => false
    }

    step =
      path
      |> write_step(before, desired, "regular", 1)
      |> Map.put("expected_environmental_mutation_count", 1)

    task(candidate, t, initial, expected, [step], [change], ground_truth(1, 1))
  end

  defp new_task("P01", candidate, seed) do
    t = tokens(seed, "P01")
    path = generated_path(t)
    old_text = "old_#{t["value"]}"
    new_text = "new_#{t["new_value"]}"
    before = module_value(t, old_text)
    after_content = module_value(t, new_text)
    initial = project_files(t, before, new_text)
    expected = replace_file(initial, path, after_content)
    step = patch_step(path, before, after_content, old_text, new_text, 1)
    task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
  end

  defp new_task("P02", candidate, seed) do
    t = tokens(seed, "P02")
    path = generated_path(t)
    old_text = "old_#{t["value"]}"
    new_text = "new_#{t["new_value"]}"

    before =
      "defmodule Corpus#{t["module"]} do\r\n  def value, do: \"#{old_text}\"\r\n  def untouched, do: \"#{t["sentinel"]}\"\r\nend\r\n"

    after_content =
      "defmodule Corpus#{t["module"]} do\r\n  def value, do: \"#{new_text}\"\r\n  def untouched, do: \"#{t["sentinel"]}\"\r\nend\r\n"

    initial = project_files(t, before, new_text)
    expected = replace_file(initial, path, after_content)
    step = patch_step(path, before, after_content, old_text, new_text, 1)
    task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
  end

  defp new_task("P03", candidate, seed) do
    t = tokens(seed, "P03")
    path = generated_path(t)
    before = module_value(t, "pre_#{t["value"]}")
    after_value = "post_#{t["new_value"]}"
    after_content = module_value(t, after_value)
    initial = project_files(t, after_content, after_value)
    step = patch_step(path, before, after_content, "pre_#{t["value"]}", after_value, 0)
    task(candidate, t, initial, initial, [step], [], ground_truth(0, 0))
  end

  defp new_task("P04", candidate, seed) do
    t = tokens(seed, "P04")
    path = generated_path(t)
    before = module_value(t, "pre_#{t["value"]}")
    after_content = module_value(t, "post_#{t["new_value"]}")
    conflict_value = "conflict_4afa6ff627d8dedf"
    conflict = module_value(t, conflict_value)
    initial = project_files(t, conflict, conflict_value)
    initial = replace_file(initial, "test/corpus_case_test.exs", true_test(t))

    step =
      path
      |> patch_step(before, after_content, "pre_#{t["value"]}", "post_#{t["new_value"]}", 0)
      |> Map.put("expected_no_fault_outcome", "error_conflict")

    task(candidate, t, initial, initial, [step], [], ground_truth(0, 0))
  end

  defp new_task("P05", candidate, seed) do
    t = tokens(seed, "P05")
    concurrent_token = token(seed, "P05", "concurrent")
    path = generated_path(t)
    before = module_with_note(t, "old_#{t["value"]}", "before_#{t["preimage"]}")
    post = module_with_note(t, "new_#{t["new_value"]}", "before_#{t["preimage"]}")
    concurrent = module_with_note(t, "old_#{t["value"]}", "concurrent_#{concurrent_token}")
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

    step =
      path
      |> patch_step(before, post, "old_#{t["value"]}", "new_#{t["new_value"]}", 0)
      |> Map.put("expected_no_fault_outcome", "error_conflict")

    task(candidate, t, initial, expected, [step], [change], ground_truth(0, 1))
  end

  defp new_task("P06", candidate, seed) do
    t = tokens(seed, "P06")
    source_path = generated_path(t)
    test_path = "test/corpus_case_test.exs"
    before_source = module_value(t, "old_#{t["value"]}")
    after_source = module_value(t, "new_#{t["new_value"]}")
    before_test = test_content(t, "old_#{t["value"]}")
    after_test = test_content(t, "new_#{t["new_value"]}")

    initial = [
      mix_file(),
      file(source_path, before_source),
      test_helper(),
      file(test_path, before_test)
    ]

    expected =
      [mix_file(), file(source_path, after_source), test_helper(), file(test_path, after_test)]

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
      "after_target_error" => "halt without continuation",
      "after_target_indeterminate" => "halt without retry or continuation",
      "after_target_ok_live_controller" => "execute continuation exactly once",
      "after_target_ok_recovered_controller" =>
        "do not invent model-loop continuation; report partial task workspace",
      "fault_injection" => "effect only; continuation is never faulted",
      "parallelism" => "forbidden"
    })
  end

  defp new_task("P07", candidate, seed) do
    t = tokens(seed, "P07")
    path = generated_path(t)
    old_text = "  def value, do: \"#{t["value"]}\""
    new_text = "  def helper, do: \"#{t["new_value"]}\"\n  def value, do: helper()"
    before = module_value(t, t["value"])

    after_content =
      "defmodule Corpus#{t["module"]} do\n#{new_text}\nend\n"

    initial = project_files(t, before, t["new_value"])
    expected = replace_file(initial, path, after_content)
    step = patch_step(path, before, after_content, old_text, new_text, 1)
    task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
  end

  defp new_task("P08", candidate, seed) do
    t = tokens(seed, "P08")
    path = generated_path(t)
    old_text = "  def value, do: legacy()\n  def legacy, do: \"#{t["value"]}\""
    new_text = "  def value, do: \"#{t["new_value"]}\""

    before =
      "defmodule Corpus#{t["module"]} do\n#{old_text}\nend\n"

    after_content =
      "defmodule Corpus#{t["module"]} do\n#{new_text}\nend\n"

    initial = project_files(t, before, t["new_value"])
    expected = replace_file(initial, path, after_content)
    step = patch_step(path, before, after_content, old_text, new_text, 1)
    task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
  end

  defp new_task("S01", candidate, seed) do
    t = tokens(seed, "S01")
    records = "header\nrecord_#{t["value"]}\n"
    sentinel = "sentinel_#{t["sentinel"]}\n"
    initial = project_files(t, module_value(t, t["value"]), t["value"])
    initial = initial ++ [file("data/records.log", "header\n")]
    expected = initial ++ [file("data/sentinel.txt", sentinel)]
    expected = replace_file(expected, "data/records.log", records)

    command =
      "mkdir -p data; printf '%s\\n' 'record_#{t["value"]}' >> data/records.log; " <>
        "printf '%s\\n' 'sentinel_#{t["sentinel"]}' > data/sentinel.txt"

    step = shell_step(command, ~w(data/records.log data/sentinel.txt), "ok")
    task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
  end

  defp new_task("S02", candidate, seed) do
    t = tokens(seed, "S02")
    initial = project_files(t, module_value(t, t["value"]), t["value"])

    expected =
      initial ++
        [
          file("data/first.txt", "first_#{t["value"]}\n"),
          file("data/second.txt", "second_#{t["new_value"]}\n")
        ]

    command =
      "mkdir -p data; printf '%s\\n' 'first_#{t["value"]}' > data/first.txt; " <>
        "printf '%s\\n' 'second_#{t["new_value"]}' > data/second.txt"

    step = shell_step(command, ~w(data/first.txt data/second.txt), "ok")
    task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
  end

  defp new_task("S03", candidate, seed) do
    t = tokens(seed, "S03")
    initial = project_files(t, module_value(t, t["value"]), t["value"])
    expected = initial ++ [file("data/effect.txt", "effect_#{t["value"]}\n")]

    command =
      "mkdir -p data; printf '%s\\n' 'effect_#{t["value"]}' > data/effect.txt; exit 7"

    step = shell_step(command, ["data/effect.txt"], "error_exit_7")
    task(candidate, t, initial, expected, [step], [], ground_truth(1, 0))
  end

  defp new_task("S04", candidate, seed) do
    t = tokens(seed, "S04")
    initial = project_files(t, module_value(t, t["value"]), t["value"])

    step =
      shell_step("MIX_ENV=test mix test", [], "ok")
      |> Map.put("expected_undeclared_artifacts", ["_build/"])
      |> Map.put("semantic_workspace_digest_excludes", ["_build/", "deps/", ".elara/"])

    task(candidate, t, initial, initial, [step], [], ground_truth(1, 0))
  end

  defp task(candidate, generated_tokens, initial, expected, steps, changes, truth) do
    id = candidate["id"]

    %{
      "id" => id,
      "operation_class" => candidate["operation_class"],
      "brief" => candidate["brief"],
      "request" => candidate["brief"],
      "order_key" => candidate["order_key"],
      "primary_fault" => candidate["primary_fault"],
      "secondary_fault" => candidate["secondary_fault"],
      "generated_tokens" => generated_tokens,
      "fixture" => %{
        "digest_algorithm" =>
          "elara.workspace.v1 sorted path/mode/byte-length/content; excludes only declared transient artifacts",
        "initial_files" => initial,
        "expected_no_fault_files" => expected
      },
      "plan" => %{
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

  defp put_versioned_identity(task, fixture_schema, plan_schema, fixture_ref, exposure_split) do
    id = task["id"]

    task
    |> Map.put("exposure_split", exposure_split)
    |> put_in(["fixture", "schema"], fixture_schema)
    |> put_in(["fixture", "fixture_ref"], fixture_ref.(id))
    |> put_in(["plan", "schema"], plan_schema)
  end

  defp write_step(path, before, after_content, state, mutations) do
    expected =
      if state == "absent",
        do: %{"state" => "absent"},
        else: %{"state" => "regular", "sha256" => sha256(before)}

    declarations =
      if state == "absent" do
        %{"expected_preimage_state" => "absent", "desired_postimage_content" => after_content}
      else
        %{"expected_preimage_content" => before, "desired_postimage_content" => after_content}
      end

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

  defp shell_step(command, postcondition_paths, outcome) do
    postcondition =
      case postcondition_paths do
        [] -> nil
        paths -> %{"kind" => "files_sha256", "files" => Enum.map(paths, &%{"path" => &1})}
      end

    %{
      "id" => "effect",
      "operation_kind" => "shell",
      "arguments" => %{
        "schema" => "elara.opaque_shell.v1",
        "command" => command,
        "relative_cwd" => ".",
        "environment" => %{"LANG" => "C", "LC_ALL" => "C"},
        "timeout_ms" => 5_000,
        "postcondition" => postcondition
      },
      "expected_no_fault_outcome" => outcome,
      "expected_job_external_mutation_count" => 1,
      "expected_environmental_mutation_count" => 0
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
        "expected_no_fault_environmental_mutation_count" => environmental_mutations
      },
      extra
    )
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

  defp tokens(seed, id), do: Map.new(@token_fields, &{&1, token(seed, id, &1)})

  defp token(seed, id, field),
    do: sha256(seed <> <<0>> <> id <> <<0>> <> field) |> binary_part(0, 16)

  defp project_files(generated_tokens, module_content, expected_value) do
    [
      mix_file(),
      file(generated_path(generated_tokens), module_content),
      test_helper(),
      file("test/corpus_case_test.exs", test_content(generated_tokens, expected_value))
    ]
  end

  defp mix_file,
    do:
      file(
        "mix.exs",
        "defmodule CorpusFixture.MixProject do\n  use Mix.Project\n\n  def project, do: [app: :corpus_fixture, version: \"0.1.0\", elixir: \"~> 1.20\", deps: []]\nend\n"
      )

  defp test_helper, do: file("test/test_helper.exs", "ExUnit.start()\n")

  defp generated_path(generated_tokens),
    do: "lib/generated_#{generated_tokens["path"]}/corpus_case.ex"

  defp module_value(generated_tokens, value),
    do: "defmodule Corpus#{generated_tokens["module"]} do\n  def value, do: \"#{value}\"\nend\n"

  defp module_with_note(generated_tokens, value, note) do
    "defmodule Corpus#{generated_tokens["module"]} do\n  def value, do: \"#{value}\"\n  def note, do: \"#{note}\"\nend\n"
  end

  defp root_module(generated_tokens) do
    "defmodule Corpus#{generated_tokens["module"]}Root do\n  def ready?, do: true\nend\n"
  end

  defp true_test(generated_tokens) do
    "defmodule Corpus#{generated_tokens["module"]}Test do\n  use ExUnit.Case\n\n  test \"frozen outcome\" do\n    assert true\n  end\nend\n"
  end

  defp test_content(generated_tokens, expected_value) do
    "defmodule Corpus#{generated_tokens["module"]}Test do\n  use ExUnit.Case\n\n  test \"frozen outcome\" do\n    assert Corpus#{generated_tokens["module"]}.value() == \"#{expected_value}\"\n  end\nend\n"
  end

  defp file(path, content), do: %{"path" => path, "mode" => "0644", "content" => content}

  defp replace_file(files, path, content) do
    Enum.map(files, fn
      %{"path" => ^path} = entry -> Map.put(entry, "content", content)
      entry -> entry
    end)
  end

  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp require!(true, _reason), do: :ok

  defp require!(false, reason),
    do: raise(ArgumentError, "invalid EXP-003 candidate source: #{inspect(reason)}")
end
