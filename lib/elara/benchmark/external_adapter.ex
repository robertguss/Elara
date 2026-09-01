defmodule Elara.Benchmark.ExternalAdapter do
  @moduledoc false

  @behaviour Elara.Benchmark.Adapter

  alias Elara.Benchmark.{Fixture, Manifest}

  @lemon_commit "b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39"
  @lemon_repository "https://github.com/z80dev/lemon"
  @runner_path "priv/benchmark/lemon_target_runner.exs"
  @adapter_path "lib/elara/benchmark/external_adapter.ex"
  @neutral_runner_path "lib/elara/benchmark/runner.ex"
  @config_key {__MODULE__, :config}
  @fixture_ids ~w(adapter-w01 adapter-p01 adapter-s02)

  @source_refs %{
    "F1" => [
      "https://github.com/z80dev/lemon/blob/#{@lemon_commit}/apps/coding_agent/lib/coding_agent/session/persistence.ex#L11-L40",
      "https://github.com/z80dev/lemon/blob/#{@lemon_commit}/apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex#L547-L576"
    ],
    "F2" => [
      "https://github.com/z80dev/lemon/blob/#{@lemon_commit}/apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex#L547-L576",
      "https://github.com/z80dev/lemon/blob/#{@lemon_commit}/apps/coding_agent/lib/coding_agent/session/event_handler.ex#L86-L105"
    ],
    "F3" => [
      "https://github.com/z80dev/lemon/blob/#{@lemon_commit}/apps/coding_agent/lib/coding_agent/tools/write.ex#L223-L253",
      "https://github.com/z80dev/lemon/blob/#{@lemon_commit}/apps/coding_agent/lib/coding_agent/tools/edit.ex#L165-L203",
      "https://github.com/z80dev/lemon/blob/#{@lemon_commit}/apps/coding_agent/lib/coding_agent/bash_executor.ex#L75-L135",
      "https://github.com/z80dev/lemon/blob/#{@lemon_commit}/apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex#L627-L631",
      "https://github.com/z80dev/lemon/blob/#{@lemon_commit}/apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex#L672-L696"
    ],
    "F4" => [
      "https://github.com/z80dev/lemon/blob/#{@lemon_commit}/apps/coding_agent/lib/coding_agent/session/event_handler.ex#L62-L66",
      "https://github.com/z80dev/lemon/blob/#{@lemon_commit}/apps/coding_agent/lib/coding_agent/session/event_handler.ex#L108-L126"
    ]
  }

  @reasons %{
    "F1" =>
      "Lemon records session messages in process state but has no durable intent record before " <>
        "executor dispatch and no synchronous external gate at that boundary.",
    "F2" =>
      "Lemon emits tool_execution_start before starting the task, but session delivery is an " <>
        "asynchronous observation and cannot stop execution before the callback without replacing " <>
        "or wrapping the native tool.",
    "F3" =>
      "Write and edit have a source-ordered interval after filesystem mutation and before their " <>
        "result returns, but expose no synchronous gate there; shell mutation count is defined by " <>
        "the opaque workload rather than a runtime mutation boundary.",
    "F4" =>
      "Lemon exposes terminal lifecycle events and persists messages, but has no synchronous " <>
        "controller-observed barrier between terminal delivery and session persistence."
  }

  @spec comparator_commit() :: String.t()
  def comparator_commit, do: @lemon_commit

  @spec prepare(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare(repo_root, state_root, lemon_root)
      when is_binary(repo_root) and is_binary(state_root) and is_binary(lemon_root) do
    repo_root = Path.expand(repo_root)
    state_root = Path.expand(state_root)
    lemon_root = Path.expand(lemon_root)

    with :ok <- validate_state_root(repo_root, state_root),
         :ok <- File.mkdir_p(state_root),
         :ok <- verify_support_files(repo_root),
         {:ok, @lemon_commit} <- git(lemon_root, ["rev-parse", "HEAD"]),
         {:ok, ""} <- git(lemon_root, ["status", "--porcelain=v1"]),
         :ok <- verify_lemon_files(lemon_root) do
      {:ok,
       %{
         repo_root: repo_root,
         state_root: state_root,
         lemon_root: lemon_root,
         runner_path: Path.join(repo_root, @runner_path),
         evidence_sink: nil
       }}
    else
      {:ok, actual} -> {:error, {:lemon_checkout_mismatch, @lemon_commit, actual}}
      {:error, _reason} = error -> error
    end
  end

  @spec prepare(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare(repo_root, state_root) do
    case System.get_env("LEMON_SOURCE_ROOT") do
      root when is_binary(root) and root != "" -> prepare(repo_root, state_root, root)
      _other -> {:error, :lemon_source_root_not_configured}
    end
  end

  @spec mapping(map()) :: {:ok, map()} | {:error, term()}
  def mapping(%{"plan" => %{"steps" => [step], "scripted_provider" => [call, final]}}) do
    with {:ok, tool_name, tool_arguments, constraints} <- map_step(step),
         "tool_call" <- call["kind"],
         ^tool_name <- tool_name(call["operation_kind"]),
         tool_call_id when is_binary(tool_call_id) <- call["tool_call_id"],
         "assistant_text" <- final["kind"],
         final_text when is_binary(final_text) <- final["content"] do
      {:ok,
       %{
         "operation_kind" => step["operation_kind"],
         "tool_name" => tool_name,
         "tool_call_id" => tool_call_id,
         "tool_arguments" => tool_arguments,
         "execution_constraints" => constraints,
         "final_assistant_text" => final_text
       }}
    else
      value -> {:error, {:invalid_frozen_plan, value}}
    end
  end

  def mapping(_task), do: {:error, :invalid_frozen_plan}

  @impl true
  def execute(_task, _cwd, %{kind: :fault}), do: {:error, :fault_execution_forbidden}

  def execute(task, cwd, %{kind: :no_fault}) do
    with {:ok, config} <- fetch_config(),
         {:ok, mapped} <- mapping(task),
         {:ok, observation} <- run_target(config, task, mapped, cwd) do
      deliver_observation(config.evidence_sink, observation)
      {:ok, %{"outcome" => observation["observed_outcome"]}}
    end
  end

  def execute(_task, _cwd, context), do: {:error, {:unsupported_context, context}}

  @spec prove_no_fault(Manifest.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def prove_no_fault(%Manifest{} = manifest, config, workspace_root)
      when is_map(config) and is_binary(workspace_root) do
    reference = make_ref()
    parent = self()
    config = %{config | evidence_sink: &send(parent, {reference, &1})}

    result =
      with_config(config, fn ->
        Enum.reduce_while(@fixture_ids, {:ok, []}, fn fixture_id, {:ok, entries} ->
          with {:ok, task} <- Manifest.adapter_fixture(manifest, fixture_id),
               {:ok, initial_digest} <- Fixture.reset(task, workspace_root),
               {:ok, adapter_evidence} <- execute(task, workspace_root, %{kind: :no_fault}),
               {:ok, final_digest} <- Fixture.digest_directory(workspace_root),
               {:ok, observation} <- receive_observation(reference) do
            entry =
              build_task_entry(task, initial_digest, final_digest, adapter_evidence, observation)

            {:cont, {:ok, [entry | entries]}}
          else
            {:error, reason} -> {:halt, {:error, {fixture_id, reason}}}
          end
        end)
      end)

    with {:ok, entries} <- result do
      build_report(manifest, config, Enum.reverse(entries))
    end
  end

  defp with_config(config, fun) do
    previous = Process.get(@config_key)
    Process.put(@config_key, config)

    try do
      fun.()
    after
      if previous, do: Process.put(@config_key, previous), else: Process.delete(@config_key)
    end
  end

  defp run_target(config, task, mapped, cwd) do
    run_root = Path.join([config.state_root, "runs", task["id"]])
    request_path = Path.join(run_root, "request.json")
    output_path = Path.join(run_root, "output.json")

    request = %{
      "schema" => "elara.exp003.external-adapter-request.v1",
      "task_id" => task["id"],
      "prompt" => "Execute the frozen no-fault fixture operation.",
      "workspace_root" => Path.expand(cwd),
      "lemon_workspace_root" => Path.join(run_root, "lemon-workspace"),
      "mapping" => mapped
    }

    with {:ok, _removed} <- File.rm_rf(run_root),
         :ok <- File.mkdir_p(run_root),
         :ok <- File.write(request_path, JSON.encode!(request)),
         {:ok, _process_output} <- execute_target(config, request_path, output_path),
         {:ok, encoded} <- File.read(output_path),
         {:ok, %{"status" => "ok"} = observation} <- JSON.decode(encoded) do
      {:ok, observation}
    else
      {:ok, decoded} -> {:error, {:lemon_reported_error, decoded}}
      {:error, reason} -> {:error, {:lemon_output_failed, reason}}
    end
  end

  defp execute_target(config, request_path, output_path) do
    result =
      System.cmd(
        "mix",
        ["run", "--no-compile", config.runner_path, "--", request_path, output_path],
        cd: config.lemon_root,
        env: lemon_env(),
        stderr_to_stdout: true
      )

    case result do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:lemon_run_failed, status, output}}
    end
  end

  defp build_task_entry(task, initial_digest, final_digest, adapter_evidence, observation) do
    expected_outcome =
      task["plan"]["steps"] |> List.last() |> Map.fetch!("expected_no_fault_outcome")

    expected_digest = task["fixture"]["expected_no_fault_workspace_sha256"]

    correct? =
      initial_digest == task["fixture"]["initial_workspace_sha256"] and
        final_digest == expected_digest and adapter_evidence["outcome"] == expected_outcome and
        observation["provider_plan_consumed"] and observation["stream_call_count"] == 2 and
        observation["tool_execution_start_count"] == 1 and
        observation["tool_execution_end_count"] == 1 and
        observation["tool_error"] == false and observation["agent_end_count"] == 1

    %{
      "fixture_id" => task["id"],
      "template_id" => task["template_id"],
      "operation_class" => task["operation_class"],
      "fixture_commit" => task["fixture"]["fixture_commit"],
      "mapping" => unwrap_mapping(task),
      "initial_workspace_sha256" => initial_digest,
      "expected_workspace_sha256" => expected_digest,
      "final_workspace_sha256" => final_digest,
      "expected_outcome" => expected_outcome,
      "observed_outcome" => adapter_evidence["outcome"],
      "native_observation" => Map.drop(observation, ["status", "schema", "task_id"]),
      "classification" => if(correct?, do: "equivalent", else: "non_equivalent")
    }
  end

  defp build_report(manifest, config, tasks) do
    comparability = Enum.map(manifest.data["fault_rows"], &classify_row/1)
    classes = tasks |> Enum.map(& &1["operation_class"]) |> Enum.uniq()

    equivalent_classes =
      tasks
      |> Enum.filter(&(&1["classification"] == "equivalent"))
      |> Enum.map(& &1["operation_class"])
      |> Enum.uniq()

    comparable_rows = Enum.count(comparability, &(&1["classification"] == "comparable"))

    comparable_fault_types =
      comparability
      |> Enum.filter(&(&1["classification"] == "comparable"))
      |> Enum.map(& &1["fault_type"])
      |> Enum.uniq()

    report = %{
      "schema" => "elara.exp003.external-adapter-equivalence.v1",
      "manifest_sha256" => manifest.sha256,
      "comparator" => %{
        "name" => "Lemon",
        "repository" => @lemon_repository,
        "commit" => @lemon_commit,
        "checkout_clean" => true,
        "source_materialization" =>
          "pre-existing checkout verified by exact HEAD and clean status"
      },
      "runtime" => hd(tasks)["native_observation"]["runtime"],
      "configuration" => configuration_report(),
      "comparator_checks" => comparator_checks(),
      "adapter" => %{
        "source" => @adapter_path,
        "sha256" => file_sha256!(config.repo_root, @adapter_path),
        "target_runner_source" => @runner_path,
        "target_runner_sha256" => file_sha256!(config.repo_root, @runner_path),
        "neutral_runner_source" => @neutral_runner_path,
        "neutral_runner_sha256" => file_sha256!(config.repo_root, @neutral_runner_path)
      },
      "tasks" => tasks,
      "summary" => %{
        "fixture_count" => length(tasks),
        "included_operation_classes" => classes,
        "equivalent" => Enum.count(tasks, &(&1["classification"] == "equivalent")),
        "non_equivalent" => Enum.count(tasks, &(&1["classification"] == "non_equivalent")),
        "adapter_failure" => 0
      },
      "native_hook_inventory" => hook_inventory(),
      "fault_comparability" => comparability,
      "comparability_floor" => %{
        "required_no_fault_equivalent_classes" => classes,
        "observed_no_fault_equivalent_classes" => equivalent_classes,
        "minimum_equivalent_fault_rows" => 3,
        "observed_equivalent_fault_rows" => comparable_rows,
        "minimum_equivalent_fault_types" => 2,
        "observed_equivalent_fault_types" => comparable_fault_types,
        "status" => "below_floor",
        "required_later_outcome" => "Insufficient comparability"
      },
      "exposure" => %{
        "lemon_fault_rows_executed" => 0,
        "target_fault_rows_executed" => 0,
        "B_or_T_calculated" => false,
        "fault_execution" => "forbidden",
        "statement" =>
          "Only the three unscored development adapter fixtures ran no-fault. All 20 fault " <>
            "rows were classified from pinned source before any Lemon or target fault outcome."
      },
      "limitations" => [
        "No-fault semantic equivalence does not establish fault-boundary equivalence.",
        "Native lifecycle events are asynchronous observations, not externally controlled barriers.",
        "Workspace postconditions do not prove causal job completion.",
        "The external comparison cannot proceed as confirmatory evidence because the frozen floor is not met."
      ]
    }

    if length(tasks) == 3 and length(comparability) == 20 do
      {:ok, report}
    else
      {:error, :incomplete_external_equivalence_evidence}
    end
  end

  defp classify_row(row) do
    fault_type = row["fault_type"]

    %{
      "row_id" => row["row_id"],
      "task_id" => row["task_id"],
      "operation_class" => row["operation_class"],
      "fault_type" => fault_type,
      "barrier_id" => row["barrier_id"],
      "classification" => "non_comparable",
      "adapter_failure" => false,
      "reason" => Map.fetch!(@reasons, fault_type),
      "source_refs" => Map.fetch!(@source_refs, fault_type)
    }
  end

  defp hook_inventory do
    %{
      "tool_execution_start" => %{
        "native" => true,
        "behavior" => "asynchronous session event emitted before the native task callback starts",
        "behavior_neutral_use" => "observation and count only",
        "fault_gate" => false,
        "source_refs" => Map.fetch!(@source_refs, "F2")
      },
      "tool_execution_end" => %{
        "native" => true,
        "behavior" =>
          "asynchronous session event emitted after the native callback result returns",
        "behavior_neutral_use" => "observation and count only",
        "fault_gate" => false,
        "source_refs" => Map.fetch!(@source_refs, "F3")
      },
      "message_persistence_and_agent_end" => %{
        "native" => true,
        "behavior" => "session message persistence and terminal lifecycle notification",
        "behavior_neutral_use" => "observation and count only",
        "fault_gate" => false,
        "source_refs" => Map.fetch!(@source_refs, "F4")
      },
      "adapter_added_hooks" => []
    }
  end

  defp configuration_report do
    %{
      "model" => "deterministic LemonAi mock-shaped model; no provider or network",
      "stream_fn" =>
        "supported CodingAgent.Session stream_fn; exactly one tool-call turn then Task complete.",
      "tools" => %{
        "write" => %{"format" => false, "diagnostics" => false},
        "edit" => %{"match" => "exact and unique", "diagnostics" => false},
        "bash" => %{"pty" => false, "timeout_ms" => 5_000, "stderr" => "merged"}
      },
      "session" => %{
        "register" => false,
        "compaction" => false,
        "retry" => false,
        "extensions" => [],
        "python_repl" => false
      },
      "workspace" =>
        "fresh exact fixture reset per run; Lemon workspace outside fixture workspace",
      "environment" => %{"LANG" => "C", "LC_ALL" => "C", "MIX_ENV" => "test"}
    }
  end

  defp comparator_checks do
    %{
      "git_pin_and_clean_checkout" => "passed",
      "mix_format_check" => "passed",
      "mix_compile" => "passed_with_upstream_warnings",
      "mix_compile_warnings_as_errors" => %{
        "status" => "failed",
        "qualification" =>
          "Pinned Lemon emits existing compiler and type warnings. The comparator was not " <>
            "modified or the warnings suppressed."
      },
      "focused_native_tests" => %{
        "status" => "passed",
        "result" => "253 passed",
        "scope" =>
          "CodingAgent agent loop, write, edit, edit edge cases, bash tool, and bash executor"
      },
      "full_umbrella_test" => %{
        "status" => "not_green_or_complete_in_orb",
        "qualification" =>
          "The inherited-environment run exposed unrelated provider-config failures. A clean " <>
            "environment run exposed existing stale-doc, CLI backup, automation, LSP, and web " <>
            "guard failures, then was interrupted by the orb executor SIGTERM before the final " <>
            "umbrella summary. No comparator source was changed."
      }
    }
  end

  defp map_step(%{"operation_kind" => "write", "arguments" => args}) do
    with "elara.declarative_write.v1" <- args["schema"],
         path when is_binary(path) <- args["path"],
         content when is_binary(content) <- get_in(args, ["desired", "content"]) do
      {:ok, "write",
       %{"path" => path, "content" => content, "format" => false, "diagnostics" => false},
       %{"source_schema" => args["schema"], "format" => false, "diagnostics" => false}}
    else
      value -> {:error, {:invalid_write_plan, value}}
    end
  end

  defp map_step(%{"operation_kind" => "patch", "arguments" => args}) do
    with "elara.literal_patch.v1" <- args["schema"],
         path when is_binary(path) <- args["path"],
         old_text when is_binary(old_text) <- args["old_text"],
         new_text when is_binary(new_text) <- args["new_text"] do
      {:ok, "edit",
       %{"path" => path, "old_text" => old_text, "new_text" => new_text, "diagnostics" => false},
       %{
         "source_schema" => args["schema"],
         "match" => "exact_unique",
         "fuzzy_fallback_used" => false,
         "diagnostics" => false
       }}
    else
      value -> {:error, {:invalid_patch_plan, value}}
    end
  end

  defp map_step(%{"operation_kind" => "shell", "arguments" => args}) do
    with "elara.opaque_shell.v1" <- args["schema"],
         command when is_binary(command) <- args["command"],
         "." <- args["relative_cwd"],
         %{"LANG" => "C", "LC_ALL" => "C"} <- args["environment"],
         timeout when is_integer(timeout) and timeout > 0 <- args["timeout_ms"] do
      {:ok, "bash", %{"command" => command, "pty" => false},
       %{
         "source_schema" => args["schema"],
         "relative_cwd" => ".",
         "environment" => args["environment"],
         "timeout_ms" => timeout,
         "pty" => false,
         "stderr" => "merged"
       }}
    else
      value -> {:error, {:invalid_shell_plan, value}}
    end
  end

  defp map_step(step), do: {:error, {:unsupported_step, step}}

  defp tool_name("write"), do: "write"
  defp tool_name("patch"), do: "edit"
  defp tool_name("shell"), do: "bash"
  defp tool_name(_kind), do: nil

  defp unwrap_mapping(task) do
    {:ok, mapping} = mapping(task)
    mapping
  end

  defp receive_observation(reference) do
    receive do
      {^reference, observation} -> {:ok, observation}
    after
      1_000 -> {:error, :adapter_observation_missing}
    end
  end

  defp fetch_config do
    case Process.get(@config_key) do
      config when is_map(config) -> {:ok, config}
      _other -> {:error, :adapter_not_configured}
    end
  end

  defp deliver_observation(nil, _observation), do: :ok
  defp deliver_observation(sink, observation) when is_function(sink, 1), do: sink.(observation)

  defp verify_support_files(repo_root) do
    verify_files(repo_root, [@runner_path, @adapter_path, @neutral_runner_path])
  end

  defp verify_lemon_files(lemon_root) do
    verify_files(lemon_root, [
      "mix.exs",
      "apps/coding_agent/lib/coding_agent/session.ex",
      "apps/coding_agent/lib/coding_agent/tools/write.ex",
      "apps/coding_agent/lib/coding_agent/tools/edit.ex",
      "apps/coding_agent/lib/coding_agent/tools/bash.ex"
    ])
  end

  defp verify_files(root, paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      if File.regular?(Path.join(root, path)),
        do: {:cont, :ok},
        else: {:halt, {:error, {:support_file_missing, path}}}
    end)
  end

  defp validate_state_root(repo_root, state_root) do
    cond do
      state_root in ["/", repo_root] -> {:error, :unsafe_state_root}
      String.starts_with?(repo_root <> "/", state_root <> "/") -> {:error, :unsafe_state_root}
      true -> :ok
    end
  end

  defp git(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_failed, args, status, output}}
    end
  end

  defp lemon_env do
    [{"LANG", "C"}, {"LC_ALL", "C"}, {"MIX_ENV", "test"}]
  end

  defp file_sha256!(root, relative), do: root |> Path.join(relative) |> File.read!() |> sha256()

  defp sha256(value) do
    value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
