defmodule Elara.Effect.CrashMatrixTest do
  use ExUnit.Case, async: false

  alias Elara.Effect.ControllerJournal
  alias Elara.Effect.ControllerJournal.Observation
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Effect.Job
  alias Elara.Effect.TestExecutor
  alias Elara.Message
  alias Elara.Message.{ToolCall, ToolResult}
  alias Elara.Session.Store
  alias Elara.Tool
  alias Elara.Tool.Ctx
  alias Exqlite.Sqlite3

  @bound_ms 1_000
  @manifest_path Path.expand(
                   "../../../docs/experiments/003-effect-receipt-er1-v3-manifest.json",
                   __DIR__
                 )
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> JSON.decode!()
  @fixtures Map.new(@manifest["cases"], &{&1["id"], &1})

  defmodule MarkerTool do
    def run(
          %{"fixture_variant" => variant, "path" => path, "token" => token},
          %Ctx{job_id: job_id, operation_digest: operation_digest}
        )
        when is_binary(job_id) and is_binary(operation_digest) do
      marker = %{
        "fixture_variant" => variant,
        "job_id" => job_id,
        "operation_digest" => operation_digest,
        "token" => token
      }

      File.write!(path, JSON.encode!(marker) <> "\n", [:append])
      {:ok, "marker #{token} committed"}
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "elara-er1-v3-#{System.unique_integer([:positive])}")

    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      cwd: cwd,
      marker_path: Path.join(cwd, "marker.jsonl"),
      journal_path: Path.join(root, "controller.sqlite3"),
      executor_path: Path.join(root, "executor.sqlite3")
    }
  end

  test "row 1: crash before controller intent commit classifies not_started without execution",
       context do
    parent = self()

    controller_hook = fn
      :before_intent_commit = point -> block(parent, :controller_hook, point)
      _point -> :ok
    end

    executor = start_executor(context.executor_path)
    fixture = fixture("v3_row_1")
    call = marker_call(context.marker_path, fixture)

    session =
      start_marker_session(
        context,
        executor,
        script([{:ok, assistant(nil, [call])}]),
        controller_hook
      )

    call_ask_unlinked(session)

    assert_receive {:controller_hook, :before_intent_commit, _journal}, @bound_ms
    store_path = newest_store_path(context.cwd)
    kill_session(session)

    started = now_ms()
    recovered = start_marker_session(context, executor, script([]), no_fault(), store_path)
    elapsed = elapsed_ms(started)

    assert [] = controller_jobs(context.journal_path)
    assert {0, 0, 0} = executor_totals(context.executor_path)
    assert [] = marker_records(context.marker_path)

    results = tool_results(recovered)
    assert [%ToolResult{outcome: {:error, message}}] = results
    assert message =~ "not_started"
    assert message =~ "action=do_not_reconcile_or_auto_retry"

    assert_manifest_counts(fixture, %{
      controller_intent_count: 0,
      executor_admission_count: 0,
      executor_callback_attempt_count: 0,
      external_mutation_count: 0,
      executor_terminal_result_count: 0,
      session_tool_result_count: length(results)
    })

    assert elapsed <= @bound_ms

    stop_session(recovered)
    assert :ok = TestExecutor.close(executor)
  end

  test "row 2: crash after intent commit recovers unknown with one same-identity submit",
       context do
    parent = self()

    controller_hook = fn
      :after_intent_commit_before_dispatch = point -> block(parent, :controller_hook, point)
      _point -> :ok
    end

    executor = start_executor(context.executor_path)
    fixture = fixture("v3_row_2")
    call = marker_call(context.marker_path, fixture)

    session =
      start_marker_session(
        context,
        executor,
        script([{:ok, assistant(nil, [call])}]),
        controller_hook
      )

    call_ask_unlinked(session)

    assert_receive {:controller_hook, :after_intent_commit_before_dispatch, _journal}, @bound_ms
    store_path = newest_store_path(context.cwd)
    {job, nil} = controller_evidence(context.journal_path)
    assert :unknown = TestExecutor.query(executor, job.job_id)
    assert [] = marker_records(context.marker_path)
    kill_session(session)

    started = now_ms()
    recovered = start_marker_session(context, executor, script([]), no_fault(), store_path)
    elapsed = elapsed_ms(started)

    assert_success(recovered, executor, context, job, fixture)
    assert elapsed <= @bound_ms

    stop_session(recovered)
    assert :ok = TestExecutor.close(executor)
  end

  test "row 3: crash after receipt rolls back acceptance and resubmits on the reopened owner",
       context do
    parent = self()

    executor_hook = fn
      :after_receipt_before_accept_commit = point -> block(parent, :executor_hook, point)
      _point -> :ok
    end

    executor = start_executor(context.executor_path, executor_hook)
    fixture = fixture("v3_row_3")
    call = marker_call(context.marker_path, fixture)
    session = live_marker_session(context, executor, call)
    call_ask_unlinked(session)

    assert_receive {:executor_hook, :after_receipt_before_accept_commit, ^executor}, @bound_ms
    {job, nil} = controller_evidence(context.journal_path)
    assert [] = marker_records(context.marker_path)
    kill_executor(executor)

    started = now_ms()
    reopened = start_executor(context.executor_path)
    assert :unknown = TestExecutor.query(reopened, job.job_id)
    assert :ok = Elara.replace_effect_executor(session, reopened)
    assert_receive {:ask_result, {:ok, "done"}}, @bound_ms
    elapsed = elapsed_ms(started)

    assert_success(session, reopened, context, job, fixture)
    assert elapsed <= @bound_ms

    stop_session(session)
    assert :ok = TestExecutor.close(reopened)
  end

  test "row 4: crash after acceptance commit continues accepted zero-attempt work once",
       context do
    parent = self()

    executor_hook = fn
      :after_accept_commit_before_accept_reply = point -> block(parent, :executor_hook, point)
      _point -> :ok
    end

    executor = start_executor(context.executor_path, executor_hook)
    fixture = fixture("v3_row_4")
    call = marker_call(context.marker_path, fixture)
    session = live_marker_session(context, executor, call)
    call_ask_unlinked(session)

    assert_receive {:executor_hook, :after_accept_commit_before_accept_reply, ^executor},
                   @bound_ms

    {job, nil} = controller_evidence(context.journal_path)
    assert [] = marker_records(context.marker_path)
    kill_executor(executor)

    started = now_ms()
    reopened = start_executor(context.executor_path)

    assert {:accepted, %Record{admission_count: 1, callback_attempt_count: 0}} =
             TestExecutor.query(reopened, job.job_id)

    assert :ok = Elara.replace_effect_executor(session, reopened)
    assert_receive {:ask_result, {:ok, "done"}}, @bound_ms
    elapsed = elapsed_ms(started)

    assert_success(session, reopened, context, job, fixture)
    assert elapsed <= @bound_ms

    stop_session(session)
    assert :ok = TestExecutor.close(reopened)
  end

  test "row 5: crash after accepted observation continues only on the same owner", context do
    parent = self()

    executor_hook = fn
      :after_accept_reply_before_callback = point -> block(parent, :executor_hook, point)
      _point -> :ok
    end

    executor = start_executor(context.executor_path, executor_hook)
    fixture = fixture("v3_row_5")
    call = marker_call(context.marker_path, fixture)
    session = live_marker_session(context, executor, call)
    call_ask_unlinked(session)

    assert_receive {:executor_hook, :after_accept_reply_before_callback, ^executor}, @bound_ms

    {job, %Observation{executor_record: %Record{state: :accepted} = accepted}} =
      controller_evidence(context.journal_path)

    assert accepted.callback_attempt_count == 0
    assert [] = marker_records(context.marker_path)
    kill_executor(executor)

    started = now_ms()
    reopened = start_executor(context.executor_path)
    assert {:accepted, ^accepted} = TestExecutor.query(reopened, job.job_id)
    assert :ok = Elara.replace_effect_executor(session, reopened)
    assert_receive {:ask_result, {:ok, "done"}}, @bound_ms
    elapsed = elapsed_ms(started)

    assert_success(session, reopened, context, job, fixture)
    assert elapsed <= @bound_ms

    stop_session(session)
    assert :ok = TestExecutor.close(reopened)
  end

  test "row 6: crash after external mutation reports indeterminate and never reinvokes",
       context do
    parent = self()

    executor_hook = fn
      :after_external_mutation_before_completion_commit = point ->
        block(parent, :executor_hook, point)

      _point ->
        :ok
    end

    executor = start_executor(context.executor_path, executor_hook)
    fixture = fixture("v3_row_6")
    call = marker_call(context.marker_path, fixture)
    session = live_marker_session(context, executor, call)
    call_ask_unlinked(session)

    assert_receive {:executor_hook, :after_external_mutation_before_completion_commit, ^executor},
                   @bound_ms

    {job, %Observation{executor_record: %Record{state: :accepted}}} =
      controller_evidence(context.journal_path)

    assert [marker] = marker_records(context.marker_path)
    assert_marker(marker, job, fixture)
    kill_executor(executor)

    started = now_ms()
    reopened = start_executor(context.executor_path)

    assert {:accepted, %Record{callback_attempt_count: 1, terminal_count: 0}} =
             TestExecutor.query(reopened, job.job_id)

    assert :ok = Elara.replace_effect_executor(session, reopened)
    assert_receive {:ask_result, {:ok, "done"}}, @bound_ms
    elapsed = elapsed_ms(started)

    assert {:accepted,
            %Record{
              admission_count: 1,
              callback_attempt_count: 1,
              terminal_count: 0
            } = attempted} = TestExecutor.query(reopened, job.job_id)

    assert {1, 1, 0} = executor_totals(context.executor_path)
    assert [^marker] = marker_records(context.marker_path)

    results = tool_results(session)
    assert [%ToolResult{outcome: {:indeterminate, message}}] = results
    assert message =~ "last_proven=callback_invoked"
    assert message =~ "missing=completed_or_failed"
    assert message =~ "action=do_not_retry_or_fail_over"

    assert_manifest_counts(fixture, %{
      controller_intent_count: 1,
      executor_admission_count: attempted.admission_count,
      executor_callback_attempt_count: attempted.callback_attempt_count,
      external_mutation_count: length(marker_records(context.marker_path)),
      executor_terminal_result_count: attempted.terminal_count,
      session_tool_result_count: length(results)
    })

    assert %Observation{executor_record: ^attempted, result_persisted?: true} =
             observation(context.journal_path, job.job_id)

    assert elapsed <= @bound_ms

    stop_session(session)
    assert :ok = TestExecutor.close(reopened)
  end

  test "row 7: crash after completion commit recovers the causal terminal result without callback",
       context do
    parent = self()

    executor_hook = fn
      :after_completion_commit_before_completion_reply = point ->
        block(parent, :executor_hook, point)

      _point ->
        :ok
    end

    executor = start_executor(context.executor_path, executor_hook)
    fixture = fixture("v3_row_7")
    call = marker_call(context.marker_path, fixture)
    session = live_marker_session(context, executor, call)
    call_ask_unlinked(session)

    assert_receive {:executor_hook, :after_completion_commit_before_completion_reply, ^executor},
                   @bound_ms

    {job, %Observation{executor_record: %Record{state: :accepted}}} =
      controller_evidence(context.journal_path)

    assert [_marker] = marker_records(context.marker_path)
    kill_executor(executor)

    started = now_ms()
    reopened = start_executor(context.executor_path)
    assert {:completed, completed} = TestExecutor.query(reopened, job.job_id)
    assert :ok = Elara.replace_effect_executor(session, reopened)
    assert_receive {:ask_result, {:ok, "done"}}, @bound_ms
    elapsed = elapsed_ms(started)

    assert_success(session, reopened, context, job, fixture, completed)
    assert elapsed <= @bound_ms

    stop_session(session)
    assert :ok = TestExecutor.close(reopened)
  end

  test "row 8: crash after terminal observation persists one result before transcript repair",
       context do
    parent = self()

    controller_hook = fn
      :after_completion_reply_before_session_result_persist = point ->
        block(parent, :controller_hook, point)

      _point ->
        :ok
    end

    executor = start_executor(context.executor_path)
    fixture = fixture("v3_row_8")
    call = marker_call(context.marker_path, fixture)

    session =
      start_marker_session(
        context,
        executor,
        script([{:ok, assistant(nil, [call])}]),
        controller_hook
      )

    call_ask_unlinked(session)

    assert_receive {:controller_hook, :after_completion_reply_before_session_result_persist,
                    task},
                   @bound_ms

    store_path = newest_store_path(context.cwd)

    {job, %Observation{executor_record: %Record{state: :completed}, result_persisted?: false}} =
      controller_evidence(context.journal_path)

    assert [] = tool_results(session)
    assert [_marker] = marker_records(context.marker_path)
    kill_session(session)
    send(task, {:continue, :after_completion_reply_before_session_result_persist})

    started = now_ms()
    recovered = start_marker_session(context, executor, script([]), no_fault(), store_path)
    elapsed = elapsed_ms(started)

    assert_success(recovered, executor, context, job, fixture)

    refute Enum.any?(
             tool_results(recovered),
             &match?(%ToolResult{outcome: {:error, "interrupted"}}, &1)
           )

    assert elapsed <= @bound_ms

    stop_session(recovered)
    assert :ok = TestExecutor.close(executor)
  end

  test "control: no fault produces one intent, admission, attempt, mutation, and result",
       context do
    executor = start_executor(context.executor_path)
    fixture = fixture("v3_control_no_fault")
    call = marker_call(context.marker_path, fixture)
    session = live_marker_session(context, executor, call)

    started = now_ms()
    assert {:ok, "done"} = Elara.ask(session, "run marker")
    elapsed = elapsed_ms(started)

    {job, _observation} = controller_evidence(context.journal_path)
    assert_success(session, executor, context, job, fixture)
    assert elapsed <= @bound_ms

    stop_session(session)
    assert :ok = TestExecutor.close(executor)
  end

  test "control: same ID and digest replay preserves accepted and terminal evidence", context do
    parent = self()

    controller_hook = fn
      :after_accept_observation_before_continue = point ->
        block(parent, :controller_hook, point)

      _point ->
        :ok
    end

    executor = start_executor(context.executor_path)
    fixture = fixture("v3_control_same_digest")
    call = marker_call(context.marker_path, fixture)
    session = start_marker_session(context, executor, live_script(call), controller_hook)
    call_ask_unlinked(session)

    assert_receive {:controller_hook, :after_accept_observation_before_continue, task}, @bound_ms
    {job, %Observation{executor_record: accepted}} = controller_evidence(context.journal_path)
    assert accepted.state == :accepted
    assert accepted.callback_attempt_count == 0

    started = now_ms()

    assert {:accepted, ^accepted} =
             TestExecutor.submit(executor, job.job_id, job.operation_digest, fn ->
               raise "same-digest accepted replay invoked callback"
             end)

    assert {:accepted, ^accepted} = TestExecutor.query(executor, job.job_id)
    assert elapsed_ms(started) <= @bound_ms
    assert {1, 0, 0} = executor_totals(context.executor_path)
    assert [] = marker_records(context.marker_path)
    assert [] = tool_results(session)

    send(task, {:continue, :after_accept_observation_before_continue})
    assert_receive {:ask_result, {:ok, "done"}}, @bound_ms

    assert {:completed, completed} = TestExecutor.query(executor, job.job_id)

    started = now_ms()

    assert {:completed, ^completed} =
             TestExecutor.submit(executor, job.job_id, job.operation_digest, fn ->
               raise "same-digest terminal replay invoked callback"
             end)

    assert {:completed, ^completed} = TestExecutor.query(executor, job.job_id)
    assert elapsed_ms(started) <= @bound_ms
    assert_success(session, executor, context, job, fixture, completed)

    stop_session(session)
    assert :ok = TestExecutor.close(executor)
  end

  test "control: same ID with conflicting digest is rejected before mutation", context do
    parent = self()

    controller_hook = fn
      :after_accept_observation_before_continue = point ->
        block(parent, :controller_hook, point)

      _point ->
        :ok
    end

    executor = start_executor(context.executor_path)
    fixture = fixture("v3_control_conflicting_digest")
    call = marker_call(context.marker_path, fixture)
    session = start_marker_session(context, executor, live_script(call), controller_hook)
    call_ask_unlinked(session)

    assert_receive {:controller_hook, :after_accept_observation_before_continue, task}, @bound_ms
    {job, %Observation{executor_record: accepted}} = controller_evidence(context.journal_path)
    conflicting_job = conflicting_job(job, fixture)
    assert conflicting_job.job_id == job.job_id
    refute conflicting_job.operation_digest == job.operation_digest
    started = now_ms()

    assert {:error, :digest_conflict} =
             TestExecutor.submit(executor, job.job_id, conflicting_job.operation_digest, fn ->
               raise "conflicting digest invoked callback"
             end)

    assert {:accepted, ^accepted} = TestExecutor.query(executor, job.job_id)
    assert elapsed_ms(started) <= @bound_ms
    assert {1, 0, 0} = executor_totals(context.executor_path)
    assert [] = marker_records(context.marker_path)

    send(task, {:continue, :after_accept_observation_before_continue})
    assert_receive {:ask_result, {:ok, "done"}}, @bound_ms
    assert_success(session, executor, context, job, fixture)

    stop_session(session)
    assert :ok = TestExecutor.close(executor)
  end

  defp assert_success(session, executor, context, job, fixture, expected_record \\ nil) do
    token = fixture["token"]
    assert {:completed, %Record{} = completed} = TestExecutor.query(executor, job.job_id)
    if expected_record, do: assert(completed == expected_record)

    assert completed.operation_digest == job.operation_digest
    assert completed.admission_count == 1
    assert completed.callback_attempt_count == 1
    assert completed.terminal_count == 1
    assert {1, 1, 1} = executor_totals(context.executor_path)

    assert [marker] = marker_records(context.marker_path)
    assert_marker(marker, job, fixture)

    results = tool_results(session)

    assert [%ToolResult{outcome: {:ok, "marker " <> ^token <> " committed"}}] = results

    assert %Observation{executor_record: ^completed, result_persisted?: true} =
             observation(context.journal_path, job.job_id)

    assert_manifest_counts(fixture, %{
      controller_intent_count: 1,
      executor_admission_count: completed.admission_count,
      executor_callback_attempt_count: completed.callback_attempt_count,
      external_mutation_count: 1,
      executor_terminal_result_count: completed.terminal_count,
      session_tool_result_count: length(results)
    })
  end

  defp assert_marker(marker, job, fixture) do
    assert marker["job_id"] == job.job_id
    assert marker["operation_digest"] == job.operation_digest
    assert marker["token"] == fixture["token"]
    assert marker["fixture_variant"] == fixture["variant"]
  end

  defp assert_manifest_counts(fixture, observed) do
    expected =
      Map.new(fixture["expected_counts"], fn {key, value} ->
        {String.to_existing_atom(key), value}
      end)

    assert observed == expected
  end

  defp live_marker_session(context, executor, call) do
    start_marker_session(context, executor, live_script(call))
  end

  defp live_script(call) do
    script([{:ok, assistant(nil, [call])}, {:ok, assistant("done")}])
  end

  defp start_marker_session(
         context,
         executor,
         provider,
         fault_hook \\ nil,
         resume \\ nil
       ) do
    opts = [
      provider: provider,
      tools: [marker_tool()],
      plugins: [],
      cwd: context.cwd,
      effect_executor: executor,
      effect_journal_path: context.journal_path,
      effect_fault_hook: fault_hook || no_fault()
    ]

    opts = if resume, do: Keyword.put(opts, :resume, resume), else: opts
    {:ok, session} = Elara.start_session(opts)
    session
  end

  defp marker_tool do
    %Tool{
      name: "marker",
      version: "1",
      description: "append a non-deduplicating ER-1 marker",
      parameters: %{"type" => "object"},
      capabilities: ["filesystem:write"],
      mutating: true,
      placement: :local,
      run: {MarkerTool, :run}
    }
  end

  defp marker_call(path, fixture) do
    %ToolCall{
      id: "marker-call-#{fixture["id"]}",
      name: "marker",
      args:
        {:ok,
         %{
           "fixture_variant" => fixture["variant"],
           "path" => path,
           "token" => fixture["token"]
         }}
    }
  end

  defp fixture(id), do: Map.fetch!(@fixtures, id)

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp assistant(text, calls \\ []) do
    {:ok, assistant} = Message.assistant(text, calls)
    assistant
  end

  defp start_executor(path, hook \\ nil) do
    {:ok, executor} =
      TestExecutor.start_link(id: "executor-1", path: path, fault_hook: hook || no_fault())

    Process.unlink(executor)
    executor
  end

  defp start_journal(path) do
    {:ok, journal} = ControllerJournal.start_link(path: path)
    Process.unlink(journal)
    journal
  end

  defp controller_jobs(path) do
    journal = start_journal(path)
    assert {:ok, jobs} = ControllerJournal.all(journal)
    assert :ok = ControllerJournal.close(journal)
    jobs
  end

  defp controller_evidence(path) do
    journal = start_journal(path)
    assert {:ok, [job]} = ControllerJournal.all(journal)
    assert {:ok, observation} = ControllerJournal.observation(journal, job.job_id)
    assert :ok = ControllerJournal.close(journal)
    {job, observation}
  end

  defp observation(path, job_id) do
    journal = start_journal(path)
    assert {:ok, observation} = ControllerJournal.observation(journal, job_id)
    assert :ok = ControllerJournal.close(journal)
    observation
  end

  defp executor_totals(path) do
    {:ok, db} = Sqlite3.open(path)

    {:ok, statement} =
      Sqlite3.prepare(
        db,
        "SELECT COALESCE(SUM(admission_count), 0), " <>
          "COALESCE(SUM(callback_attempt_count), 0), " <>
          "COALESCE(SUM(terminal_count), 0) FROM executor_jobs"
      )

    assert {:row, [admissions, attempts, terminals]} = Sqlite3.step(db, statement)
    assert :ok = Sqlite3.release(db, statement)
    assert :ok = Sqlite3.close(db)
    {admissions, attempts, terminals}
  end

  defp marker_records(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)

      {:error, :enoent} ->
        []
    end
  end

  defp tool_results(session) do
    Enum.filter(Elara.transcript(session), &is_struct(&1, ToolResult))
  end

  defp newest_store_path(cwd) do
    {:ok, info} = Store.newest(cwd)
    info.path
  end

  defp block(parent, tag, point) do
    send(parent, {tag, point, self()})

    receive do
      {:continue, ^point} -> :ok
    end
  end

  defp call_ask_unlinked(session) do
    parent = self()

    spawn(fn ->
      result =
        try do
          Elara.ask(session, "run marker")
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {:ask_result, result})
    end)
  end

  defp kill_session(session) do
    {:ok, pid} = Elara.session_pid(session)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, @bound_ms
  end

  defp kill_executor(executor) do
    monitor = Process.monitor(executor)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}, @bound_ms
  end

  defp stop_session(session) do
    {:ok, pid} = Elara.session_pid(session)
    GenServer.stop(pid)
  end

  defp conflicting_job(job, fixture) do
    args =
      Map.update!(job.arguments, "fixture_variant", fn variant ->
        Map.put(variant, "conflict_nonce", fixture["variant"]["nonce"] <> "-conflict")
      end)

    Job.new(job.effect_id,
      operation_kind: job.operation_kind,
      tool_call_id: job.tool_call_id,
      tool_name: job.tool_name,
      tool_version: job.tool_version,
      arguments: args,
      workspace_id: job.workspace_id,
      required_capabilities: job.required_capabilities,
      allowed_capabilities: job.authority_scope.allowed_capabilities,
      placement: job.authority_scope.placement,
      marker_schema_version: job.marker_schema_version
    )
  end

  defp no_fault, do: fn _point -> :ok end
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp elapsed_ms(started), do: now_ms() - started
end
