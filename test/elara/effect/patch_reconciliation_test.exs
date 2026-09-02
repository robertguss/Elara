defmodule Elara.Effect.PatchReconciliationTest do
  use ExUnit.Case, async: false

  alias Elara.Effect.ControllerJournal
  alias Elara.Effect.ControllerJournal.Observation, as: ControllerObservation
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Effect.Job
  alias Elara.Effect.LiteralPatch
  alias Elara.Effect.LiteralPatch.{Observation, Result}
  alias Elara.Effect.TestExecutor

  @bound_ms 2_000
  @manifest_path Path.expand("../../fixtures/effect/reconciliation.json", __DIR__)
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> JSON.decode!()
  @fixtures Map.new(@manifest["fixtures"], &{&1["id"], &1})

  setup do
    root =
      Path.join(System.tmp_dir!(), "elara-er2-patch-#{System.unique_integer([:positive])}")

    cwd = Path.join(root, "workspace")
    File.mkdir_p!(Path.join(cwd, "fixture/patch"))
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      cwd: cwd,
      target: Path.join(cwd, "fixture/patch/target.txt"),
      journal_path: Path.join(root, "controller.sqlite3"),
      executor_path: Path.join(root, "executor.sqlite3")
    }
  end

  test "P-NO-FAULT applies one unique literal replacement through a causal receipt", context do
    File.write!(context.target, preimage())
    job = patch_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    counter = :atomics.new(1, [])

    result = LiteralPatch.execute(executor, journal, job, context.cwd, effect_opts(counter))

    assert_completed(result, executor, job)
    assert :atomics.get(counter, 1) == 1
    assert File.read!(context.target) == postimage()
    close(executor, journal)
  end

  test "P-ALREADY proves the postcondition without applying the patch again", context do
    File.write!(context.target, postimage())
    job = patch_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    counter = :atomics.new(1, [])
    before = File.stat!(context.target)

    result = LiteralPatch.execute(executor, journal, job, context.cwd, effect_opts(counter))

    assert_completed(result, executor, job)
    assert {:ok, message} = result.outcome
    assert message =~ "postcondition_satisfied"
    assert :atomics.get(counter, 1) == 0
    after_stat = File.stat!(context.target)

    assert {after_stat.inode, after_stat.size, after_stat.mtime} ==
             {before.inode, before.size, before.mtime}

    close(executor, journal)
  end

  test "P-CONFLICT rejects an incompatible preimage without overwriting it", context do
    File.write!(context.target, conflict_content())
    job = patch_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)

    assert %Result{
             outcome: {:error, message},
             workspace: %Observation{state: :conflict},
             causal: :failed,
             historical: :invoked,
             safe_action: :report_conflict
           } = LiteralPatch.execute(executor, journal, job, context.cwd)

    assert message =~ "literal patch conflict"
    assert File.read!(context.target) == conflict_content()
    close(executor, journal)
  end

  test "P-MULTIPLE rejects a non-unique literal without mutating the exact preimage", context do
    fixture = @fixtures["p_multiple"]
    initial = fixture["preimage"]["content"]
    File.write!(context.target, initial)
    job = patch_job(context, patch_arguments(fixture))
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    counter = :atomics.new(1, [])

    assert %Result{
             outcome: {:error, message},
             workspace: %Observation{state: :expected_preimage},
             causal: :failed,
             safe_action: :report_rejection
           } = LiteralPatch.execute(executor, journal, job, context.cwd, effect_opts(counter))

    assert message =~ "old_text_match_count"
    assert File.read!(context.target) == initial
    assert :atomics.get(counter, 1) == 0
    close(executor, journal)
  end

  test "P-NON-FILE rejects a directory without mutation", context do
    File.mkdir!(context.target)
    job = patch_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)

    assert %Result{
             outcome: {:error, _message},
             workspace: %Observation{state: :non_file},
             causal: :failed,
             safe_action: :report_rejection
           } = LiteralPatch.execute(executor, journal, job, context.cwd)

    assert File.dir?(context.target)
    close(executor, journal)
  end

  test "P-SYMLINK rejects a link without touching its target", context do
    outside = Path.join(context.root, "outside.txt")
    File.write!(outside, "outside")
    File.ln_s!(outside, context.target)
    job = patch_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)

    assert %Result{
             outcome: {:error, _message},
             workspace: %Observation{state: :symlink_rejected},
             causal: :failed,
             safe_action: :report_rejection
           } = LiteralPatch.execute(executor, journal, job, context.cwd)

    assert File.read!(outside) == "outside"
    close(executor, journal)
  end

  test "missing targets and concurrent unrelated edits remain unchanged", context do
    for initial <- [:missing, "alpha\nOLD\nomega\nconcurrent\n"] do
      reset_storage(context)
      if initial != :missing, do: File.write!(context.target, initial)
      job = patch_job(context)
      journal = start_journal(context.journal_path)
      executor = start_executor(context.executor_path)
      assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)

      assert %Result{outcome: {:error, _message}, causal: :failed} =
               LiteralPatch.execute(executor, journal, job, context.cwd)

      assert current_content(context.target) == initial
      close(executor, journal)
    end
  end

  test "protocol validation rejects malformed identity, arguments, path, and authority",
       context do
    job = patch_job(context)

    invalid_jobs = [
      patch_job(context, put_in(job.arguments["schema"], "elara.literal_patch.v2")),
      patch_job(context, put_in(job.arguments["path"], "../outside.txt")),
      patch_job(context, put_in(job.arguments["preimage_sha256"], "invalid")),
      patch_job(context, put_in(job.arguments["old_text"], "")),
      patch_job(context, put_in(job.arguments["postimage_sha256"], "invalid")),
      patch_job(context, put_in(job.arguments["replacement"], "global")),
      patch_job(context, job.arguments, workspace_id: ""),
      patch_job(context, job.arguments, allowed_capabilities: [])
    ]

    for invalid <- invalid_jobs do
      assert {:error, _reason} = LiteralPatch.validate(invalid, context.cwd)
    end
  end

  test "computed-postimage mismatch and a concurrent pre-rename edit cannot overwrite", context do
    File.write!(context.target, preimage())

    bad_arguments =
      put_in(
        patch_arguments(@fixtures["p_unique"])["postimage_sha256"],
        String.duplicate("a", 64)
      )

    bad_job = patch_job(context, bad_arguments)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^bad_job} = ControllerJournal.commit_intent(journal, bad_job)

    assert %Result{outcome: {:error, message}, causal: :failed} =
             LiteralPatch.execute(executor, journal, bad_job, context.cwd)

    assert message =~ "postimage_digest_mismatch"
    assert File.read!(context.target) == preimage()
    close(executor, journal)

    reset_storage(context)
    File.write!(context.target, preimage())
    job = patch_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)

    hook = fn
      :after_temp_complete_before_rename ->
        File.write!(context.target, conflict_content())
        :ok

      _point ->
        :ok
    end

    assert %Result{
             outcome: {:error, _message},
             workspace: %Observation{state: :conflict},
             causal: :failed,
             safe_action: :report_conflict
           } = LiteralPatch.execute(executor, journal, job, context.cwd, operation_hook: hook)

    assert File.read!(context.target) == conflict_content()
    assert temp_files(context) == []
    close(executor, journal)
  end

  for cut <- 1..8 do
    @tag repeated_cross_class: cut in [2, 5, 6, 7]
    test "P-C#{cut} executes the frozen shared crash schedule", context do
      run_shared_cut(unquote(cut), context)
    end
  end

  test "P-T1 crash after precondition leaves the exact preimage and forbids retry", context do
    run_typed_cut(:after_typed_precondition_before_temp_create, :manual_investigation, 0, context)
  end

  @tag repeated_cross_class: true
  test "P-T2 crash after temp completion permits only bound-temp cleanup", context do
    result =
      run_typed_cut(
        :after_temp_complete_before_rename,
        :cleanup_bound_temp_only_no_retry,
        1,
        context
      )

    [temp] = temp_files(context)
    File.rm!(temp)
    assert File.read!(context.target) == preimage()
    assert result.safe_action == :cleanup_bound_temp_only_no_retry
  end

  @tag repeated_cross_class: true
  test "P-SAME-DIGEST, P-CONFLICT-DIGEST, and P-REPLACEMENT preserve one owner", context do
    File.write!(context.target, preimage())
    parent = self()

    sidecar_hook = fn
      :after_accept_observation_before_continue = point -> block(parent, :sidecar_hook, point)
      _point -> :ok
    end

    job = patch_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)

    task =
      Task.async(fn ->
        LiteralPatch.execute(executor, journal, job, context.cwd, sidecar_hook: sidecar_hook)
      end)

    assert_receive {:sidecar_hook, :after_accept_observation_before_continue, task_pid}, @bound_ms
    assert task_pid == task.pid
    assert {:accepted, accepted} = TestExecutor.query(executor, job.job_id)

    assert {:accepted, ^accepted} =
             TestExecutor.submit(executor, job.job_id, job.operation_digest, fn ->
               raise "same-digest replay invoked callback"
             end)

    changed_jobs = [
      patch_job(context, put_in(job.arguments["schema"], "elara.literal_patch.v2")),
      patch_job(context, put_in(job.arguments["path"], "fixture/patch/other.txt")),
      patch_job(context, put_in(job.arguments["preimage_sha256"], String.duplicate("a", 64))),
      patch_job(context, put_in(job.arguments["old_text"], "DIFFERENT")),
      patch_job(context, put_in(job.arguments["new_text"], "DIFFERENT")),
      patch_job(context, put_in(job.arguments["postimage_sha256"], String.duplicate("b", 64))),
      patch_job(context, put_in(job.arguments["replacement"], "global")),
      patch_job(context, job.arguments, workspace_id: "changed-workspace"),
      patch_job(context, job.arguments, allowed_capabilities: ["filesystem:write", "shell"])
    ]

    for changed <- changed_jobs do
      assert changed.job_id == job.job_id
      refute changed.operation_digest == job.operation_digest

      assert {:error, :digest_conflict} =
               TestExecutor.submit(executor, job.job_id, changed.operation_digest, fn ->
                 raise "conflicting-digest callback invoked"
               end)
    end

    replacement = start_executor(context.executor_path, no_fault(), "executor-2")

    assert {:error, :wrong_executor} =
             TestExecutor.submit(replacement, job.job_id, job.operation_digest, fn ->
               raise "replacement-owner callback invoked"
             end)

    assert :ok = TestExecutor.close(replacement)
    send(task.pid, {:continue, :after_accept_observation_before_continue})
    assert_completed(Task.await(task, @bound_ms), executor, job)
    close(executor, journal)
  end

  @tag repeated_cross_class: true
  test "P-LEDGER-LOSS distinguishes a satisfied postcondition from causal completion", context do
    {job, journal, counter, initial_task} = execute_until_primary(context)
    assert File.read!(context.target) == postimage()
    assert :atomics.get(counter, 1) == 1

    kill_executor(initial_task.executor)
    assert %Result{status: :awaiting_executor} = Task.await(initial_task.task, @bound_ms)
    delete_executor_ledger(context.executor_path)

    assert %Result{
             status: :terminal,
             outcome: {:indeterminate, message},
             workspace: %Observation{state: :exact_postimage},
             causal: :unproven,
             historical: :unknown,
             safe_action: :postcondition_satisfied_no_retry,
             executor_record: nil
           } = LiteralPatch.reconcile_unavailable(journal, job, context.cwd)

    assert message =~ "executor_evidence=unavailable"
    assert File.read!(context.target) == postimage()
    assert :atomics.get(counter, 1) == 1
    assert :ok = ControllerJournal.close(journal)
  end

  @tag repeated_cross_class: true
  test "P-STALE refreshes a desired observation before reporting a concurrent conflict",
       context do
    {job, journal, counter, initial_task} = execute_until_primary(context)
    kill_executor(initial_task.executor)
    assert %Result{status: :awaiting_executor} = Task.await(initial_task.task, @bound_ms)
    delete_executor_ledger(context.executor_path)

    hook = fn :after_postcondition_observation_before_action ->
      File.write!(context.target, conflict_content())
      :ok
    end

    assert %Result{
             outcome: {:indeterminate, _message},
             workspace: %Observation{state: :conflict},
             causal: :unproven,
             safe_action: :refresh_then_report_conflict,
             executor_record: nil
           } =
             LiteralPatch.reconcile_unavailable(journal, job, context.cwd, reconcile_hook: hook)

    assert File.read!(context.target) == conflict_content()
    assert :atomics.get(counter, 1) == 1
    assert :ok = ControllerJournal.close(journal)
  end

  test "a controller-copied terminal patch receipt remains causal after ledger loss", context do
    File.write!(context.target, preimage())
    job = patch_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    completed = LiteralPatch.execute(executor, journal, job, context.cwd)
    assert_completed(completed, executor, job)
    expected_outcome = completed.outcome
    assert :ok = TestExecutor.close(executor)
    delete_executor_ledger(context.executor_path)

    assert %Result{
             outcome: ^expected_outcome,
             workspace: %Observation{state: :exact_postimage},
             causal: :completed,
             historical: :invoked,
             safe_action: :none,
             executor_record: nil,
             controller_record: %Record{state: :completed}
           } = LiteralPatch.reconcile_unavailable(journal, job, context.cwd)

    assert :ok = ControllerJournal.close(journal)
  end

  test "replacement exposes only exact preimage or postimage bytes", context do
    large_preimage = "prefix\nOLD\n" <> String.duplicate("z", 1_000_000)
    large_postimage = String.replace(large_preimage, "OLD", "NEW", global: false)
    File.write!(context.target, large_preimage)

    job =
      patch_job(context, LiteralPatch.arguments(relative_path(), large_preimage, "OLD", "NEW"))

    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    sampler = start_sampler(context.target, large_preimage)

    assert_completed(
      LiteralPatch.execute(executor, journal, job, context.cwd),
      executor,
      job,
      large_postimage
    )

    send(sampler, :stop)
    assert_receive {:sampled_images, images}, @bound_ms
    assert MapSet.subset?(images, MapSet.new([large_preimage, large_postimage]))
    assert File.read!(context.target) == large_postimage
    close(executor, journal)
  end

  defp run_shared_cut(1, context) do
    File.write!(context.target, preimage())
    job = patch_job(context)
    parent = self()

    hook = fn
      :before_intent_commit = point -> block(parent, :controller_hook, point)
      _point -> :ok
    end

    journal = start_journal(context.journal_path)
    commit = commit_unlinked(journal, job, hook)
    assert_receive {:controller_hook, :before_intent_commit, ^journal}, @bound_ms
    kill_process(journal)
    assert_receive {^commit, {:exit, _reason}}, @bound_ms
    reopened = start_journal(context.journal_path)

    assert %Result{
             causal: :not_started,
             historical: :not_invoked,
             safe_action: :new_job_id_allowed
           } = LiteralPatch.reconcile_unavailable(reopened, job, context.cwd)

    assert File.read!(context.target) == preimage()
    assert :ok = ControllerJournal.close(reopened)
  end

  defp run_shared_cut(2, context) do
    File.write!(context.target, preimage())
    job = patch_job(context)
    parent = self()

    hook = fn
      :after_intent_commit_before_dispatch = point -> block(parent, :controller_hook, point)
      _point -> :ok
    end

    journal = start_journal(context.journal_path)
    commit = commit_unlinked(journal, job, hook)
    assert_receive {:controller_hook, :after_intent_commit_before_dispatch, ^journal}, @bound_ms
    kill_process(journal)
    assert_receive {^commit, {:exit, _reason}}, @bound_ms
    reopened = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)

    assert_completed(LiteralPatch.reconcile(executor, reopened, job, context.cwd), executor, job)
    close(executor, reopened)
  end

  defp run_shared_cut(cut, context) when cut in 3..7 do
    File.write!(context.target, preimage())
    job = patch_job(context)
    parent = self()
    point = shared_executor_point(cut)

    executor_hook = fn
      ^point -> block(parent, :executor_hook, point)
      _point -> :ok
    end

    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path, executor_hook)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    counter = :atomics.new(1, [])

    task =
      Task.async(fn ->
        LiteralPatch.execute(executor, journal, job, context.cwd, effect_opts(counter))
      end)

    assert_receive {:executor_hook, ^point, ^executor}, @bound_ms
    kill_executor(executor)
    _initial = Task.await(task, @bound_ms)
    reopened = start_executor(context.executor_path)
    result = LiteralPatch.reconcile(reopened, journal, job, context.cwd, effect_opts(counter))

    if cut == 6 do
      assert %Result{
               status: :terminal,
               outcome: {:indeterminate, _message},
               workspace: %Observation{state: :exact_postimage},
               causal: :unproven,
               historical: :invoked,
               safe_action: :postcondition_satisfied_no_retry,
               executor_record: %Record{callback_attempt_count: 1, terminal_count: 0}
             } = result

      assert :atomics.get(counter, 1) == 1
    else
      assert_completed(result, reopened, job)
      assert :atomics.get(counter, 1) == 1
    end

    assert File.read!(context.target) == postimage()
    close(reopened, journal)
  end

  defp run_shared_cut(8, context) do
    File.write!(context.target, preimage())
    job = patch_job(context)
    parent = self()

    sidecar_hook = fn
      :after_completion_reply_before_session_result_persist = point ->
        block(parent, :sidecar_hook, point)

      _point ->
        :ok
    end

    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    counter = :atomics.new(1, [])

    task =
      Task.async(fn ->
        LiteralPatch.execute(
          executor,
          journal,
          job,
          context.cwd,
          effect_opts(counter, sidecar_hook: sidecar_hook)
        )
      end)

    assert_receive {:sidecar_hook, :after_completion_reply_before_session_result_persist,
                    task_pid},
                   @bound_ms

    assert task_pid == task.pid
    Task.shutdown(task, :brutal_kill)
    assert_completed(LiteralPatch.reconcile(executor, journal, job, context.cwd), executor, job)
    assert :atomics.get(counter, 1) == 1
    close(executor, journal)
  end

  defp run_typed_cut(point, safe_action, temp_count, context) do
    File.write!(context.target, preimage())
    parent = self()

    operation_hook = fn
      ^point -> block(parent, :operation_hook, point)
      _point -> :ok
    end

    job = patch_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    counter = :atomics.new(1, [])

    task =
      Task.async(fn ->
        LiteralPatch.execute(
          executor,
          journal,
          job,
          context.cwd,
          effect_opts(counter, operation_hook: operation_hook)
        )
      end)

    assert_receive {:operation_hook, ^point, ^executor}, @bound_ms
    kill_executor(executor)
    _initial = Task.await(task, @bound_ms)
    reopened = start_executor(context.executor_path)

    assert %Result{
             status: :terminal,
             outcome: {:indeterminate, _message},
             workspace: %Observation{state: :expected_preimage},
             causal: :unproven,
             historical: :invoked,
             safe_action: ^safe_action,
             executor_record: %Record{callback_attempt_count: 1, terminal_count: 0}
           } = result = LiteralPatch.reconcile(reopened, journal, job, context.cwd)

    assert File.read!(context.target) == preimage()
    assert :atomics.get(counter, 1) == 0
    assert length(temp_files(context)) == temp_count
    close(reopened, journal)
    result
  end

  defp execute_until_primary(context) do
    File.write!(context.target, preimage())
    parent = self()

    executor_hook = fn
      :after_external_mutation_before_completion_commit = point ->
        block(parent, :executor_hook, point)

      _point ->
        :ok
    end

    job = patch_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path, executor_hook)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    counter = :atomics.new(1, [])

    task =
      Task.async(fn ->
        LiteralPatch.execute(executor, journal, job, context.cwd, effect_opts(counter))
      end)

    assert_receive {:executor_hook, :after_external_mutation_before_completion_commit, ^executor},
                   @bound_ms

    assert {:ok, %ControllerObservation{executor_record: %Record{callback_attempt_count: 0}}} =
             ControllerJournal.observation(journal, job.job_id)

    {job, journal, counter, %{task: task, executor: executor}}
  end

  defp assert_completed(result, executor, job, expected_bytes \\ postimage()) do
    assert %Result{
             status: :terminal,
             outcome: {:ok, _message},
             workspace: %Observation{state: :exact_postimage},
             causal: :completed,
             historical: :invoked,
             safe_action: :none,
             executor_record: %Record{} = completed
           } = result

    assert {:completed, ^completed} = TestExecutor.query(executor, job.job_id)
    assert completed.operation_digest == job.operation_digest

    assert {completed.admission_count, completed.callback_attempt_count, completed.terminal_count} ==
             {1, 1, 1}

    assert result.workspace.sha256 == LiteralPatch.sha256(expected_bytes)
  end

  defp patch_job(context, arguments \\ nil, opts \\ []) do
    arguments = arguments || patch_arguments(@fixtures["p_unique"])

    Job.new(%{recording_id: "er2-patch", sequence: 1, effect_index: 0},
      operation_kind: :literal_patch,
      tool_name: "literal_patch",
      tool_version: "1",
      arguments: arguments,
      workspace_id: Keyword.get(opts, :workspace_id, "workspace:#{context.cwd}"),
      required_capabilities: ["filesystem:write"],
      allowed_capabilities: Keyword.get(opts, :allowed_capabilities, :all),
      placement: :local
    )
  end

  defp patch_arguments(fixture) do
    %{
      "schema" => LiteralPatch.schema(),
      "path" => fixture["path"],
      "preimage_sha256" => fixture["preimage"]["sha256"],
      "old_text" => fixture["old_text"],
      "new_text" => fixture["new_text"],
      "postimage_sha256" => fixture["postimage"]["sha256"],
      "replacement" => "same_directory_temp_rename"
    }
  end

  defp relative_path, do: @fixtures["p_unique"]["path"]
  defp preimage, do: @fixtures["p_unique"]["preimage"]["content"]
  defp postimage, do: @fixtures["p_unique"]["postimage"]["content"]
  defp conflict_content, do: @fixtures["p_conflict"]["initial"]["content"]

  defp start_executor(path, hook \\ nil, id \\ "executor-1") do
    {:ok, executor} =
      TestExecutor.start_link(id: id, path: path, fault_hook: hook || no_fault())

    Process.unlink(executor)
    executor
  end

  defp start_journal(path) do
    {:ok, journal} = ControllerJournal.start_link(path: path)
    Process.unlink(journal)
    journal
  end

  defp effect_opts(counter, opts \\ []) do
    observer = fn :primary_target_committed ->
      :atomics.add_get(counter, 1, 1)
      :ok
    end

    Keyword.put(opts, :effect_observer, observer)
  end

  defp reset_storage(context) do
    File.rm_rf!(context.target)
    delete_executor_ledger(context.executor_path)
    File.rm_rf!(context.journal_path)
    File.rm_rf!(context.journal_path <> "-wal")
    File.rm_rf!(context.journal_path <> "-shm")
  end

  defp delete_executor_ledger(path) do
    File.rm_rf!(path)
    File.rm_rf!(path <> "-wal")
    File.rm_rf!(path <> "-shm")
  end

  defp temp_files(context) do
    context.target
    |> Path.dirname()
    |> File.ls!()
    |> Enum.filter(&(String.starts_with?(&1, ".elara-") and String.ends_with?(&1, ".tmp")))
    |> Enum.map(&Path.join(Path.dirname(context.target), &1))
  end

  defp current_content(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, :enoent} -> :missing
    end
  end

  defp shared_executor_point(3), do: :after_receipt_before_accept_commit
  defp shared_executor_point(4), do: :after_accept_commit_before_accept_reply
  defp shared_executor_point(5), do: :after_accept_reply_before_callback
  defp shared_executor_point(6), do: :after_external_mutation_before_completion_commit
  defp shared_executor_point(7), do: :after_completion_commit_before_completion_reply

  defp start_sampler(path, expected) do
    parent = self()
    spawn(fn -> sample(path, MapSet.new([expected]), parent) end)
  end

  defp sample(path, images, parent) do
    images =
      case File.read(path) do
        {:ok, content} -> MapSet.put(images, content)
        {:error, :enoent} -> MapSet.put(images, :absent)
      end

    receive do
      :stop -> send(parent, {:sampled_images, MapSet.put(images, File.read!(path))})
    after
      0 -> sample(path, images, parent)
    end
  end

  defp commit_unlinked(journal, job, hook) do
    ref = make_ref()
    parent = self()

    spawn(fn ->
      result =
        try do
          ControllerJournal.commit_intent(journal, job, hook)
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {ref, result})
    end)

    ref
  end

  defp block(parent, tag, point) do
    send(parent, {tag, point, self()})

    receive do
      {:continue, ^point} -> :ok
    end
  end

  defp kill_executor(executor), do: kill_process(executor)

  defp kill_process(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, @bound_ms
  end

  defp close(executor, journal) do
    assert :ok = TestExecutor.close(executor)
    assert :ok = ControllerJournal.close(journal)
  end

  defp no_fault, do: fn _point -> :ok end
end
