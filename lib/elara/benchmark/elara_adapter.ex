defmodule Elara.Benchmark.ElaraAdapter do
  @moduledoc false

  @behaviour Elara.Benchmark.Adapter

  alias Elara.Benchmark.{Manifest, Runner}

  @baseline_commit "23e603550253c69846795b13cc2f2670f1122e21"
  @receipts_commit "9ff416f2c22327c5ef38edcd52a9e89108fbc726"
  @runner_path "priv/benchmark/elara_target_runner.exs"
  @adapter_path "lib/elara/benchmark/elara_adapter.ex"
  @neutral_runner_path "lib/elara/benchmark/runner.ex"
  @config_key {__MODULE__, :config}
  @conditions ~w(baseline receipts)

  @spec target_commits() :: %{String.t() => String.t()}
  def target_commits do
    %{"baseline" => @baseline_commit, "receipts" => @receipts_commit}
  end

  @spec prepare(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare(repo_root, state_root) when is_binary(repo_root) and is_binary(state_root) do
    repo_root = Path.expand(repo_root)
    state_root = Path.expand(state_root)

    with :ok <- validate_state_root(repo_root, state_root),
         :ok <- File.mkdir_p(state_root),
         :ok <- verify_support_files(repo_root),
         {:ok, targets} <- prepare_targets(repo_root, state_root) do
      {:ok,
       %{
         repo_root: repo_root,
         state_root: state_root,
         runner_path: Path.join(repo_root, @runner_path),
         targets: targets,
         evidence_sink: nil
       }}
    end
  end

  @spec with_config(map(), (-> result)) :: result when result: var
  def with_config(config, fun) when is_map(config) and is_function(fun, 0) do
    previous = Process.get(@config_key)
    Process.put(@config_key, config)

    try do
      fun.()
    after
      if previous, do: Process.put(@config_key, previous), else: Process.delete(@config_key)
    end
  end

  @spec mapping(map()) :: {:ok, map()} | {:error, term()}
  def mapping(%{"plan" => %{"steps" => [step], "scripted_provider" => [call, final]}}) do
    with {:ok, tool_name, tool_arguments, constraints} <- map_step(step),
         "tool_call" <- call["kind"],
         ^tool_name <- tool_name(call["operation_kind"]),
         "assistant_text" <- final["kind"],
         tool_call_id when is_binary(tool_call_id) <- call["tool_call_id"],
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

  def execute(task, cwd, %{kind: :no_fault, condition: condition} = context)
      when condition in @conditions do
    with {:ok, config} <- fetch_config(),
         {:ok, target} <- fetch_target(config, condition),
         {:ok, mapped} <- mapping(task),
         {:ok, observation} <- run_target(config, target, task, mapped, cwd, context) do
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
    sink = fn evidence -> send(parent, {reference, evidence}) end
    config = %{config | evidence_sink: sink}

    runs =
      manifest.data["selection"]["selected_task_ids"]
      |> Enum.flat_map(fn task_id ->
        Enum.map(@conditions, &%{"task_id" => task_id, "condition" => &1})
      end)
      |> Enum.with_index(1)

    result =
      with_config(config, fn ->
        Enum.reduce_while(runs, {:ok, []}, fn {run, order_index}, {:ok, entries} ->
          run =
            Map.merge(run, %{
              "phase" => "measured",
              "run_index" => 1,
              "order_index" => order_index
            })

          case Runner.run_no_fault(manifest, run, adapter: __MODULE__, root: workspace_root) do
            {:ok, record} ->
              receive do
                {^reference, observation} ->
                  entry = %{"record" => record, "observation" => observation}
                  {:cont, {:ok, [entry | entries]}}
              after
                1_000 -> {:halt, {:error, {:adapter_observation_missing, run}}}
              end

            {:error, reason} ->
              {:halt, {:error, {run, reason}}}
          end
        end)
      end)

    with {:ok, entries} <- result do
      build_report(manifest, config, Enum.reverse(entries))
    end
  end

  defp prepare_targets(repo_root, state_root) do
    Enum.reduce_while(target_commits(), {:ok, %{}}, fn {condition, commit}, {:ok, targets} ->
      case prepare_target(repo_root, state_root, condition, commit) do
        {:ok, target} -> {:cont, {:ok, Map.put(targets, condition, target)}}
        {:error, reason} -> {:halt, {:error, {condition, reason}}}
      end
    end)
  end

  defp prepare_target(repo_root, state_root, condition, commit) do
    source_root = Path.join([state_root, "targets", condition, "source"])
    build_root = Path.join([state_root, "targets", condition, "build"])

    with {:ok, ^commit} <- git(repo_root, ["rev-parse", "#{commit}^{commit}"]),
         :ok <- replace_with_archive(repo_root, commit, source_root),
         :ok <- File.mkdir_p(build_root),
         :ok <- compile_target(repo_root, source_root, build_root) do
      {:ok,
       %{
         condition: condition,
         commit: commit,
         source_root: source_root,
         build_root: build_root
       }}
    else
      {:ok, actual} -> {:error, {:commit_mismatch, commit, actual}}
      {:error, _reason} = error -> error
    end
  end

  defp replace_with_archive(repo_root, commit, source_root) do
    with {:ok, _removed} <- File.rm_rf(source_root),
         :ok <- File.mkdir_p(source_root),
         {:ok, archive} <- git_archive(repo_root, commit),
         :ok <- extract_archive(archive, source_root) do
      :ok
    end
  end

  defp compile_target(repo_root, source_root, build_root) do
    {output, status} =
      System.cmd("mix", ["compile", "--warnings-as-errors"],
        cd: source_root,
        env: target_env(repo_root, build_root),
        stderr_to_stdout: true
      )

    if status == 0, do: :ok, else: {:error, {:target_compile_failed, status, output}}
  end

  defp run_target(config, target, task, mapped, cwd, context) do
    run_root = run_root(config.state_root, task["id"], context)
    request_path = Path.join(run_root, "request.json")
    output_path = Path.join(run_root, "output.json")

    request = %{
      "schema" => "elara.exp003.internal-adapter-request.v1",
      "condition" => target.condition,
      "target_commit" => target.commit,
      "workspace_root" => Path.expand(cwd),
      "controller_journal_path" => Path.join(run_root, "controller.sqlite3"),
      "executor_ledger_path" => Path.join(run_root, "executor.sqlite3"),
      "task_id" => task["id"],
      "prompt" => task["request"],
      "mapping" => mapped,
      "tool_timeout_ms" => 5_000
    }

    with {:ok, _removed} <- File.rm_rf(run_root),
         :ok <- File.mkdir_p(run_root),
         :ok <- File.write(request_path, JSON.encode!(request)),
         {:ok, process_output} <-
           execute_target(config, target, request_path, output_path),
         {:ok, observation} <- decode_target_output(output_path) do
      {:ok, Map.put(observation, "process_output_sha256", sha256(process_output))}
    end
  end

  defp execute_target(config, target, request_path, output_path) do
    result =
      System.cmd(
        "mix",
        [
          "run",
          "--no-compile",
          config.runner_path,
          "--",
          request_path,
          output_path
        ],
        cd: target.source_root,
        env: target_env(config.repo_root, target.build_root),
        stderr_to_stdout: true
      )

    case result do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:target_run_failed, status, output}}
    end
  end

  defp decode_target_output(output_path) do
    with {:ok, encoded} <- File.read(output_path),
         {:ok, decoded} <- JSON.decode(encoded) do
      case decoded do
        %{"status" => "ok"} = observation -> {:ok, observation}
        %{"status" => "error"} = error -> {:error, {:target_reported_error, error}}
        other -> {:error, {:invalid_target_output, other}}
      end
    else
      {:error, reason} -> {:error, {:target_output_failed, reason}}
    end
  end

  defp build_report(manifest, config, entries) do
    grouped = Enum.group_by(entries, & &1["record"]["task_id"])

    tasks =
      Enum.map(manifest.data["selection"]["selected_task_ids"], fn task_id ->
        task = manifest.tasks[task_id]
        by_condition = Map.new(grouped[task_id], &{&1["record"]["condition"], &1})
        baseline = semantic_evidence(by_condition["baseline"])
        receipts = semantic_evidence(by_condition["receipts"])

        %{
          "task_id" => task_id,
          "operation_class" => task["operation_class"],
          "fixture_commit" => task["fixture"]["fixture_commit"],
          "mapping" => unwrap_mapping(task),
          "expected_outcome" => expected_outcome(task),
          "expected_workspace_sha256" => task["fixture"]["expected_no_fault_workspace_sha256"],
          "baseline" => baseline,
          "receipts" => receipts,
          "classification" => classify(task, baseline, receipts)
        }
      end)

    eligible_task_ids =
      tasks
      |> Enum.filter(&(&1["classification"] == "equivalent"))
      |> Enum.map(& &1["task_id"])
      |> MapSet.new()

    denominator =
      manifest.data["fault_rows"]
      |> Enum.filter(&MapSet.member?(eligible_task_ids, &1["task_id"]))
      |> Enum.map(& &1["row_id"])

    report = %{
      "schema" => "elara.exp003.internal-adapter-equivalence.v1",
      "manifest_sha256" => manifest.sha256,
      "targets" => target_report(config.targets),
      "runtime" => hd(entries)["observation"]["runtime"],
      "configuration" => configuration_report(),
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
        "task_count" => length(tasks),
        "equivalent" => Enum.count(tasks, &(&1["classification"] == "equivalent")),
        "non_equivalent" => Enum.count(tasks, &(&1["classification"] == "non_equivalent")),
        "adapter_failure" => 0
      },
      "internal_paired_denominator" => %{
        "status" => if(length(denominator) == 20, do: "eligible", else: "ineligible"),
        "row_count" => length(denominator),
        "row_ids" => denominator
      },
      "hook_disclosure" => hook_disclosure(),
      "shell_timeout_qualification" =>
        "The plan's unaccelerated timeout_ms=5000 is represented by session " <>
          "tool_timeout_ms=5000. Neither pinned builtin consumes the plan argument directly, " <>
          "and ER-2 did not prove production enforcement of that exact timeout. The receipt " <>
          "sidecar also has its pinned 1000 ms recovery wait. No timeout claim is made here.",
      "tool_result_payload_qualification" =>
        "Equivalence uses the frozen outcome category and workspace digest. Opaque shell output " <>
          "bodies are not compared because commands such as mix test may emit nondeterministic " <>
          "metadata; result kind, transcript shape, and exact plan consumption are compared.",
      "exposure" => %{
        "fault_rows_executed" => 0,
        "B_or_T_calculated" => false,
        "adapter_fault_execution" => "forbidden",
        "statement" =>
          "Only one no-fault execution per selected task and pinned target was run. No fault " <>
            "barrier, recovery score, target tuning, Lemon run, or dogfood run was executed."
      },
      "limitations" => [
        "OS-process and filesystem isolation are behavior-neutral adapter boundaries, not recovery mechanisms.",
        "No-fault equivalence does not prove fault behavior or timing equivalence.",
        "Workspace postconditions do not prove causal job completion.",
        "The receipt target uses the research-only Elara.Effect.TestExecutor."
      ]
    }

    if length(entries) == 24, do: {:ok, report}, else: {:error, :incomplete_equivalence_evidence}
  end

  defp semantic_evidence(%{"record" => record, "observation" => observation}) do
    %{
      "target_commit" => observation["target_commit"],
      "initial_workspace_sha256" => record["initial_workspace_sha256"],
      "final_workspace_sha256" => record["final_workspace_sha256"],
      "workspace_correct" => record["workspace_correct"],
      "observed_outcome" => record["observed_outcome"],
      "outcome_correct" => record["outcome_correct"],
      "provider_plan_consumed" => observation["provider_plan_consumed"],
      "provider_call_count" => observation["provider_call_count"],
      "tool_call_count" => observation["tool_call_count"],
      "session_result_count" => observation["session_result_count"],
      "session_result" => observation["session_result"],
      "session_idle" => observation["session_idle"],
      "transcript_shape" => observation["transcript_shape"],
      "tool_result_kind" => observation["tool_result_kind"],
      "hooks_observed" => observation["hooks_observed"],
      "receipt_evidence" => observation["receipt_evidence"]
    }
  end

  defp classify(task, baseline, receipts) do
    expected = expected_outcome(task)
    expected_shape = ~w(user assistant_tool_call tool_result assistant_text)

    common? =
      Enum.all?([baseline, receipts], fn evidence ->
        evidence["workspace_correct"] and evidence["outcome_correct"] and
          evidence["observed_outcome"] == expected and evidence["provider_plan_consumed"] and
          evidence["provider_call_count"] == 2 and evidence["tool_call_count"] == 1 and
          evidence["session_result_count"] == 1 and evidence["session_result"] == "Task complete." and
          evidence["session_idle"] and evidence["transcript_shape"] == expected_shape
      end)

    receipt? =
      receipts["receipt_evidence"]["admission_count"] == 1 and
        receipts["receipt_evidence"]["callback_attempt_count"] == 1 and
        receipts["receipt_evidence"]["terminal_count"] == 1 and
        receipts["receipt_evidence"]["result_persisted"] and
        receipts["receipt_evidence"]["identity_consistent"]

    baseline? = baseline["receipt_evidence"] == "not_applicable"

    if common? and receipt? and baseline?, do: "equivalent", else: "non_equivalent"
  end

  defp configuration_report do
    %{
      "provider" => "Elara.Provider.Scripted: exactly one tool-call turn then Task complete.",
      "persist" => false,
      "plugins" => [],
      "tools" => ~w(read write edit bash),
      "tool_timeout_ms" => 5_000,
      "workspace" =>
        "fresh exact fixture reset per run; state and SQLite storage outside workspace",
      "environment" => %{
        "LANG" => "C",
        "LC_ALL" => "C",
        "HEX_OFFLINE" => "1",
        "MIX_ENV" => "test for target; frozen shell commands control their own MIX_ENV"
      },
      "baseline_effect_executor" => "not_applicable",
      "receipts_effect_executor" =>
        "isolated Elara.Effect.TestExecutor with one SQLite ledger per task/condition/run",
      "receipts_controller_journal" => "one isolated SQLite journal per task/condition/run",
      "authority" => %{"allowed_capabilities" => "all", "placement" => "local router"}
    }
  end

  defp hook_disclosure do
    %{
      "behavior" =>
        "No-op native target hooks append point names to an isolated Agent. They do not pause, " <>
          "crash, retry, replace an executor, add evidence to the target, or alter recovery.",
      "baseline" => "not_applicable",
      "receipts_expected_order" => ~w(
        before_intent_commit
        after_intent_commit_before_dispatch
        after_receipt_before_accept_commit
        after_accept_commit_before_accept_reply
        after_accept_observation_before_continue
        after_accept_reply_before_callback
        after_external_mutation_before_completion_commit
        after_completion_commit_before_completion_reply
        after_completion_reply_before_session_result_persist
      )
    }
  end

  defp target_report(targets) do
    Map.new(@conditions, fn condition ->
      target = targets[condition]

      {condition,
       %{
         "commit" => target.commit,
         "source_materialization" => "git archive of exact commit",
         "execution_boundary" => "separate OS BEAM with isolated MIX_BUILD_PATH"
       }}
    end)
  end

  defp map_step(%{"operation_kind" => "write", "arguments" => args}) do
    with "elara.declarative_write.v1" <- args["schema"],
         path when is_binary(path) <- args["path"],
         content when is_binary(content) <- get_in(args, ["desired", "content"]) do
      {:ok, "write", %{"path" => path, "content" => content},
       %{"source_schema" => args["schema"]}}
    else
      value -> {:error, {:invalid_write_plan, value}}
    end
  end

  defp map_step(%{"operation_kind" => "patch", "arguments" => args}) do
    with "elara.literal_patch.v1" <- args["schema"],
         path when is_binary(path) <- args["path"],
         old_text when is_binary(old_text) <- args["old_text"],
         new_text when is_binary(new_text) <- args["new_text"] do
      {:ok, "edit", %{"path" => path, "old_text" => old_text, "new_text" => new_text},
       %{"source_schema" => args["schema"]}}
    else
      value -> {:error, {:invalid_patch_plan, value}}
    end
  end

  defp map_step(%{"operation_kind" => "shell", "arguments" => args}) do
    with "elara.opaque_shell.v1" <- args["schema"],
         command when is_binary(command) <- args["command"],
         relative_cwd when is_binary(relative_cwd) <- args["relative_cwd"],
         environment when is_map(environment) <- args["environment"],
         timeout when is_integer(timeout) and timeout > 0 <- args["timeout_ms"] do
      {:ok, "bash", %{"command" => command},
       %{
         "source_schema" => args["schema"],
         "relative_cwd" => relative_cwd,
         "environment" => environment,
         "requested_timeout_ms" => timeout
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

  defp expected_outcome(task) do
    task["plan"]["steps"] |> List.last() |> Map.fetch!("expected_no_fault_outcome")
  end

  defp unwrap_mapping(task) do
    {:ok, mapping} = mapping(task)
    mapping
  end

  defp fetch_config do
    case Process.get(@config_key) do
      config when is_map(config) -> {:ok, config}
      _other -> {:error, :adapter_not_configured}
    end
  end

  defp fetch_target(config, condition) do
    case get_in(config, [:targets, condition]) do
      target when is_map(target) -> {:ok, target}
      _other -> {:error, {:target_not_prepared, condition}}
    end
  end

  defp deliver_observation(nil, _observation), do: :ok
  defp deliver_observation(sink, observation) when is_function(sink, 1), do: sink.(observation)

  defp run_root(state_root, task_id, context) do
    phase = context |> Map.get(:phase, "direct") |> to_string()
    index = context |> Map.get(:run_index, 1) |> to_string()

    Path.join([
      state_root,
      "runs",
      String.downcase(task_id),
      context.condition,
      phase,
      index
    ])
  end

  defp target_env(repo_root, build_root) do
    [
      {"HEX_OFFLINE", "1"},
      {"LANG", "C"},
      {"LC_ALL", "C"},
      {"MIX_BUILD_PATH", build_root},
      {"MIX_DEPS_PATH", Path.join(repo_root, "deps")},
      {"MIX_ENV", "test"}
    ]
  end

  defp verify_support_files(repo_root) do
    Enum.reduce_while([@runner_path, @adapter_path, @neutral_runner_path], :ok, fn relative,
                                                                                   :ok ->
      if File.regular?(Path.join(repo_root, relative)) do
        {:cont, :ok}
      else
        {:halt, {:error, {:support_file_missing, relative}}}
      end
    end)
  end

  defp validate_state_root(repo_root, state_root) do
    cond do
      state_root in ["/", repo_root] -> {:error, :unsafe_state_root}
      String.starts_with?(repo_root <> "/", state_root <> "/") -> {:error, :unsafe_state_root}
      true -> :ok
    end
  end

  defp git(repo_root, args) do
    case System.cmd("git", args, cd: repo_root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_failed, args, status, output}}
    end
  end

  defp git_archive(repo_root, commit) do
    case System.cmd("git", ["archive", "--format=tar", commit], cd: repo_root) do
      {archive, 0} -> {:ok, archive}
      {output, status} -> {:error, {:git_archive_failed, status, output}}
    end
  end

  defp extract_archive(archive, source_root) do
    case :erl_tar.extract(
           {:binary, archive},
           [{:cwd, String.to_charlist(source_root)}]
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:archive_extract_failed, reason}}
    end
  end

  defp file_sha256!(root, relative), do: root |> Path.join(relative) |> File.read!() |> sha256()

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
