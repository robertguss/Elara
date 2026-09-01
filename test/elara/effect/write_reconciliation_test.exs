defmodule Elara.Effect.WriteReconciliationTest do
  use ExUnit.Case, async: false

  alias Elara.Effect.ControllerJournal
  alias Elara.Effect.ControllerJournal.Observation, as: ControllerObservation
  alias Elara.Effect.DeclarativeWrite
  alias Elara.Effect.DeclarativeWrite.{Observation, Result}
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Effect.Job
  alias Elara.Effect.TestExecutor

  @bound_ms 2_000
  @manifest_path Path.expand(
                   "../../../docs/experiments/004-real-mutations-er2-manifest.json",
                   __DIR__
                 )
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> JSON.decode!()
  @fixtures Map.new(@manifest["fixtures"], &{&1["id"], &1})
  @write_rows @manifest["matrix"]
              |> Enum.filter(&(&1["operation"] == "write"))
              |> Enum.map(& &1["id"])
              |> MapSet.new()
  @covered_write_rows MapSet.new(
                        Enum.map(1..8, &"W-C#{&1}") ++
                          [
                            "W-T1",
                            "W-T2",
                            "W-NO-FAULT",
                            "W-ALREADY",
                            "W-CONFLICT",
                            "W-NON-FILE",
                            "W-SYMLINK",
                            "W-SAME-DIGEST",
                            "W-CONFLICT-DIGEST",
                            "W-REPLACEMENT",
                            "W-LEDGER-LOSS",
                            "W-STALE"
                          ]
                      )

  unless MapSet.equal?(@write_rows, @covered_write_rows) do
    raise "write reconciliation tests do not cover the frozen write matrix"
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "elara-er2-write-#{System.unique_integer([:positive])}")

    cwd = Path.join(root, "workspace")
    File.mkdir_p!(Path.join(cwd, "fixture/write"))
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      cwd: cwd,
      target: Path.join(cwd, "fixture/write/target.txt"),
      journal_path: Path.join(root, "controller.sqlite3"),
      executor_path: Path.join(root, "executor.sqlite3")
    }
  end

  test "W-NO-FAULT writes an absent target once through a causal terminal receipt", context do
    job = write_job(context, fixture_arguments("w_absent"))
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    counter = :atomics.new(1, [])

    started = now_ms()
    result = DeclarativeWrite.execute(executor, journal, job, context.cwd, effect_opts(counter))

    assert_completed(result, executor, job, desired_content())
    assert :atomics.get(counter, 1) == 1
    assert elapsed_ms(started) <= @bound_ms

    close(executor, journal)
  end

  test "parent creation remains inside the workspace and participates in the atomic write",
       context do
    path = "new/deep/target.txt"
    arguments = DeclarativeWrite.arguments(path, :absent, desired_content())
    job = write_job(context, arguments)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)

    assert_completed(
      DeclarativeWrite.execute(executor, journal, job, context.cwd),
      executor,
      job
    )

    assert File.read!(Path.join(context.cwd, path)) == desired_content()
    close(executor, journal)
  end

  test "W-ALREADY records causal completion without rewriting exact desired bytes", context do
    File.write!(context.target, desired_content())
    job = write_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    counter = :atomics.new(1, [])
    before = File.stat!(context.target)

    result = DeclarativeWrite.execute(executor, journal, job, context.cwd, effect_opts(counter))

    assert_completed(result, executor, job, desired_content())
    assert {:ok, message} = result.outcome
    assert message =~ "postcondition_satisfied"
    assert message =~ "no_write=true"
    assert :atomics.get(counter, 1) == 0
    after_stat = File.stat!(context.target)

    assert {after_stat.inode, after_stat.size, after_stat.mtime} ==
             {before.inode, before.size, before.mtime}

    close(executor, journal)
  end

  test "W-CONFLICT and partial or missing preimages are structured failures without overwrite",
       context do
    for {initial, expected_state} <- [
          {conflict_content(), :conflict},
          {"ER2-WRITE-PARTIAL", :conflict},
          {:missing, :absent}
        ] do
      reset_storage(context)
      if initial != :missing, do: File.write!(context.target, initial)
      job = write_job(context)
      journal = start_journal(context.journal_path)
      executor = start_executor(context.executor_path)
      assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
      counter = :atomics.new(1, [])

      assert %Result{
               status: :terminal,
               outcome: {:error, message},
               workspace: %Observation{state: ^expected_state},
               causal: :failed,
               historical: :invoked,
               safe_action: safe_action
             } =
               DeclarativeWrite.execute(executor, journal, job, context.cwd, effect_opts(counter))

      assert message =~ "declarative write"
      assert safe_action in [:report_conflict, :report_rejection]
      assert :atomics.get(counter, 1) == 0
      assert current_content(context.target) == initial
      close(executor, journal)
    end
  end

  test "W-NON-FILE and W-SYMLINK reject structured path states without touching the target",
       context do
    outside = Path.join(context.root, "outside.txt")
    File.write!(outside, "outside")

    for {kind, expected_state} <- [directory: :non_file, symlink: :symlink_rejected] do
      reset_storage(context)

      case kind do
        :directory -> File.mkdir!(context.target)
        :symlink -> File.ln_s!(outside, context.target)
      end

      job = write_job(context)
      journal = start_journal(context.journal_path)
      executor = start_executor(context.executor_path)
      assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)

      assert %Result{
               outcome: {:error, _message},
               workspace: %Observation{state: ^expected_state},
               causal: :failed,
               safe_action: :report_rejection
             } = DeclarativeWrite.execute(executor, journal, job, context.cwd)

      if kind == :symlink, do: assert(File.read!(outside) == "outside")
      close(executor, journal)
    end

    reset_storage(context)
    outside_dir = Path.join(context.root, "outside-dir")
    File.mkdir!(outside_dir)
    File.ln_s!(outside_dir, Path.join(context.cwd, "linked-parent"))
    arguments = DeclarativeWrite.arguments("linked-parent/target.txt", :absent, desired_content())
    job = write_job(context, arguments)

    assert {:ok, %Observation{state: :symlink_rejected}} =
             DeclarativeWrite.observe(job, context.cwd)

    assert {:error, message} = DeclarativeWrite.run(job, context.cwd)
    assert message =~ "symlink_rejected"
    refute File.exists?(Path.join(outside_dir, "target.txt"))
  end

  test "unreadable targets and noncanonical paths are unavailable or rejected before mutation",
       context do
    File.write!(context.target, expected_content())
    File.chmod!(context.target, 0o000)
    job = write_job(context)

    assert {:ok, %Observation{state: :unavailable}} =
             DeclarativeWrite.observe(job, context.cwd)

    File.chmod!(context.target, 0o600)

    for path <- ["../outside.txt", "/tmp/outside.txt", "fixture//write/target.txt", "bad\0path"] do
      args = DeclarativeWrite.arguments(path, {:regular, expected_digest()}, desired_content())

      assert {:error, :path_outside_workspace} =
               DeclarativeWrite.validate(write_job(context, args), context.cwd)
    end
  end

  for cut <- 1..8 do
    @tag repeated_cross_class: cut in [2, 5, 6, 7]
    test "W-C#{cut} executes the frozen shared crash schedule", context do
      run_shared_cut(unquote(cut), context)
    end
  end

  test "W-T1 crash after precondition leaves the exact preimage and forbids reinvocation",
       context do
    run_typed_cut(:after_typed_precondition_before_temp_create, :manual_investigation, 0, context)
  end

  @tag repeated_cross_class: true
  test "W-T2 crash after temp completion leaves one bound temp and permits cleanup only",
       context do
    result =
      run_typed_cut(
        :after_temp_complete_before_rename,
        :cleanup_bound_temp_only_no_retry,
        1,
        context
      )

    [temp] = temp_files(context)
    File.rm!(temp)
    assert File.read!(context.target) == expected_content()
    assert result.safe_action == :cleanup_bound_temp_only_no_retry
  end

  @tag repeated_cross_class: true
  test "identity controls admit once and reject changed digest fields and replacement owner",
       context do
    File.write!(context.target, expected_content())
    parent = self()

    sidecar_hook = fn
      :after_accept_observation_before_continue = point -> block(parent, :sidecar_hook, point)
      _point -> :ok
    end

    job = write_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)

    task =
      Task.async(fn ->
        DeclarativeWrite.execute(executor, journal, job, context.cwd, sidecar_hook: sidecar_hook)
      end)

    assert_receive {:sidecar_hook, :after_accept_observation_before_continue, task_pid}, @bound_ms
    assert task_pid == task.pid
    assert {:accepted, accepted} = TestExecutor.query(executor, job.job_id)

    assert {:accepted, ^accepted} =
             TestExecutor.submit(executor, job.job_id, job.operation_digest, fn ->
               raise "same-digest replay invoked callback"
             end)

    changed_jobs = [
      write_job(context, put_in(job.arguments["schema"], "elara.declarative_write.v2")),
      write_job(context, put_in(job.arguments["path"], "fixture/write/other.txt")),
      write_job(context, put_in(job.arguments["expected"]["sha256"], String.duplicate("a", 64))),
      write_job(context, put_in(job.arguments["desired"]["content"], "changed")),
      write_job(context, put_in(job.arguments["desired"]["sha256"], String.duplicate("b", 64))),
      write_job(context, put_in(job.arguments["parent_policy"], "parents_must_exist")),
      write_job(context, put_in(job.arguments["replacement"], "direct_write")),
      write_job(context, job.arguments, workspace_id: "changed-workspace"),
      write_job(context, job.arguments, allowed_capabilities: ["filesystem:write", "shell"])
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
    assert_completed(Task.await(task, @bound_ms), executor, job, desired_content())
    close(executor, journal)
  end

  @tag repeated_cross_class: true
  test "W-LEDGER-LOSS reports exact desired state without recreating causal completion",
       context do
    {job, journal, counter, initial_task, _accepted} = execute_until_primary(context)
    assert File.read!(context.target) == desired_content()
    assert :atomics.get(counter, 1) == 1

    kill_executor(initial_task.executor)
    assert %Result{status: :awaiting_executor} = Task.await(initial_task.task, @bound_ms)
    delete_executor_ledger(context.executor_path)

    result = DeclarativeWrite.reconcile_unavailable(journal, job, context.cwd)

    assert %Result{
             status: :terminal,
             outcome: {:indeterminate, message},
             workspace: %Observation{state: :exact_postimage},
             causal: :unproven,
             historical: :unknown,
             safe_action: :postcondition_satisfied_no_retry,
             executor_record: nil
           } = result

    assert message =~ "executor_evidence=unavailable"
    assert message =~ "causal=unproven"
    assert File.read!(context.target) == desired_content()
    assert :atomics.get(counter, 1) == 1
    assert :ok = ControllerJournal.close(journal)
  end

  @tag repeated_cross_class: true
  test "W-STALE refreshes desired state before action and reports a concurrent conflict",
       context do
    {job, journal, counter, initial_task, _accepted} = execute_until_primary(context)
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
             DeclarativeWrite.reconcile_unavailable(journal, job, context.cwd,
               reconcile_hook: hook
             )

    assert File.read!(context.target) == conflict_content()
    assert :atomics.get(counter, 1) == 1
    assert :ok = ControllerJournal.close(journal)
  end

  test "a controller-copied terminal receipt remains causal after executor-ledger loss",
       context do
    File.write!(context.target, expected_content())
    job = write_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    completed = DeclarativeWrite.execute(executor, journal, job, context.cwd)
    assert_completed(completed, executor, job)
    assert %Record{state: :completed} = completed.executor_record
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
           } = DeclarativeWrite.reconcile_unavailable(journal, job, context.cwd)

    assert :ok = ControllerJournal.close(journal)
  end

  test "same-directory replacement exposes only exact preimage or postimage", context do
    File.write!(context.target, expected_content())
    job = write_job(context, nil, content: String.duplicate("z", 1_000_000))
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    desired = job.arguments["desired"]["content"]
    sampler = start_sampler(context.target, expected_content())

    assert_completed(
      DeclarativeWrite.execute(executor, journal, job, context.cwd),
      executor,
      job,
      desired
    )

    send(sampler, :stop)
    assert_receive {:sampled_images, images}, @bound_ms
    assert MapSet.subset?(images, MapSet.new([expected_content(), desired]))
    assert File.read!(context.target) == desired
    close(executor, journal)
  end

  defp run_shared_cut(1, context) do
    File.write!(context.target, expected_content())
    job = write_job(context)
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
           } = DeclarativeWrite.reconcile_unavailable(reopened, job, context.cwd)

    assert File.read!(context.target) == expected_content()
    assert :ok = ControllerJournal.close(reopened)
  end

  defp run_shared_cut(2, context) do
    File.write!(context.target, expected_content())
    job = write_job(context)
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

    assert_completed(
      DeclarativeWrite.reconcile(executor, reopened, job, context.cwd),
      executor,
      job
    )

    close(executor, reopened)
  end

  defp run_shared_cut(cut, context) when cut in 3..7 do
    File.write!(context.target, expected_content())
    job = write_job(context)
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
        DeclarativeWrite.execute(executor, journal, job, context.cwd, effect_opts(counter))
      end)

    assert_receive {:executor_hook, ^point, ^executor}, @bound_ms
    kill_executor(executor)
    _initial = Task.await(task, @bound_ms)

    reopened = start_executor(context.executor_path)
    result = DeclarativeWrite.reconcile(reopened, journal, job, context.cwd, effect_opts(counter))

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

    assert File.read!(context.target) == desired_content()
    close(reopened, journal)
  end

  defp run_shared_cut(8, context) do
    File.write!(context.target, expected_content())
    job = write_job(context)
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
        DeclarativeWrite.execute(
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

    assert_completed(
      DeclarativeWrite.reconcile(executor, journal, job, context.cwd),
      executor,
      job
    )

    assert :atomics.get(counter, 1) == 1
    close(executor, journal)
  end

  defp run_typed_cut(point, safe_action, temp_count, context) do
    File.write!(context.target, expected_content())
    parent = self()

    operation_hook = fn
      ^point -> block(parent, :operation_hook, point)
      _point -> :ok
    end

    job = write_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    counter = :atomics.new(1, [])

    task =
      Task.async(fn ->
        DeclarativeWrite.execute(
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
           } = result = DeclarativeWrite.reconcile(reopened, journal, job, context.cwd)

    assert File.read!(context.target) == expected_content()
    assert :atomics.get(counter, 1) == 0
    assert length(temp_files(context)) == temp_count
    close(reopened, journal)
    result
  end

  defp execute_until_primary(context) do
    File.write!(context.target, expected_content())
    parent = self()

    executor_hook = fn
      :after_external_mutation_before_completion_commit = point ->
        block(parent, :executor_hook, point)

      _point ->
        :ok
    end

    job = write_job(context)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path, executor_hook)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    counter = :atomics.new(1, [])

    task =
      Task.async(fn ->
        DeclarativeWrite.execute(executor, journal, job, context.cwd, effect_opts(counter))
      end)

    assert_receive {:executor_hook, :after_external_mutation_before_completion_commit, ^executor},
                   @bound_ms

    assert {:ok, %ControllerObservation{executor_record: %Record{callback_attempt_count: 0}}} =
             ControllerJournal.observation(journal, job.job_id)

    {job, journal, counter, %{task: task, executor: executor}, :accepted}
  end

  defp assert_completed(result, executor, job, expected_bytes \\ desired_content()) do
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

    assert result.workspace.sha256 == DeclarativeWrite.sha256(expected_bytes)
  end

  defp write_job(context, arguments \\ nil, opts \\ []) do
    content = Keyword.get(opts, :content, desired_content())

    arguments =
      arguments ||
        DeclarativeWrite.arguments(
          "fixture/write/target.txt",
          {:regular, expected_digest()},
          content
        )

    Job.new(%{recording_id: "er2-write", sequence: 1, effect_index: 0},
      operation_kind: :declarative_write,
      tool_name: "declarative_write",
      tool_version: "1",
      arguments: arguments,
      workspace_id: Keyword.get(opts, :workspace_id, "workspace:#{context.cwd}"),
      required_capabilities: ["filesystem:write"],
      allowed_capabilities: Keyword.get(opts, :allowed_capabilities, :all),
      placement: :local
    )
  end

  defp fixture_arguments("w_absent") do
    fixture = @fixtures["w_absent"]
    DeclarativeWrite.arguments(fixture["path"], :absent, fixture["desired"]["content"])
  end

  defp expected_content, do: @fixtures["w_replace"]["expected"]["content"]
  defp expected_digest, do: @fixtures["w_replace"]["expected"]["sha256"]
  defp desired_content, do: @fixtures["w_replace"]["desired"]["content"]
  defp conflict_content, do: @fixtures["w_conflict"]["initial"]["content"]

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
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp elapsed_ms(started), do: System.monotonic_time(:millisecond) - started
end
