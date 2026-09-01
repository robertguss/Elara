defmodule Elara.Effect.OpaqueShellTest do
  use ExUnit.Case, async: false

  alias Elara.Effect.ControllerJournal
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Effect.Job
  alias Elara.Effect.OpaqueShell
  alias Elara.Effect.OpaqueShell.{Result, Workspace}
  alias Elara.Effect.TestExecutor

  @bound_ms 5_000
  @manifest_path Path.expand(
                   "../../../docs/experiments/004-real-mutations-er2-manifest.json",
                   __DIR__
                 )
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> JSON.decode!()
  @fixtures Map.new(@manifest["fixtures"], &{&1["id"], &1})
  @shell_rows @manifest["matrix"]
              |> Enum.filter(&(&1["operation"] == "shell"))
              |> Enum.map(& &1["id"])
              |> MapSet.new()
  @covered_shell_rows MapSet.new(
                        Enum.map(1..8, &"S-C#{&1}") ++
                          [
                            "S-SPAWN",
                            "S-EFFECT-LIVE",
                            "S-EXIT",
                            "S-NO-FAULT",
                            "S-NONZERO",
                            "S-SAME-DIGEST",
                            "S-CONFLICT-DIGEST",
                            "S-REPLACEMENT",
                            "S-LEDGER-ADAPTER",
                            "S-LEDGER-OPAQUE",
                            "S-TIMEOUT"
                          ]
                      )

  unless MapSet.equal?(@shell_rows, @covered_shell_rows) do
    raise "opaque shell tests do not cover the frozen shell matrix"
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "elara-er2-shell-#{System.unique_integer([:positive])}")

    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)
    {:ok, process_registry} = Agent.start(fn -> MapSet.new() end)

    context = %{
      root: root,
      cwd: cwd,
      primary: Path.join(cwd, "fixture/shell/primary.txt"),
      pid_path: Path.join(cwd, "fixture/shell/pid"),
      allow_effect: Path.join(cwd, "fixture/shell/allow-effect"),
      allow_exit: Path.join(cwd, "fixture/shell/allow-exit"),
      journal_path: Path.join(root, "controller.sqlite3"),
      executor_path: Path.join(root, "executor.sqlite3"),
      process_registry: process_registry
    }

    on_exit(fn ->
      context.process_registry
      |> Agent.get(& &1)
      |> terminate_fixture_processes()

      Agent.stop(context.process_registry)
      File.rm_rf!(root)
    end)

    context
  end

  test "S-NO-FAULT records a causal successful shell receipt", context do
    job = shell_job(context, "s_success")
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    counter = :atomics.new(1, [])

    assert_completed(
      OpaqueShell.execute(executor, journal, job, context.cwd, effect_opts(counter)),
      executor,
      job
    )

    assert :atomics.get(counter, 1) == 1
    assert File.read!(context.primary) == desired_content()
    close(executor, journal)
  end

  test "S-NONZERO retains a causal failed receipt after a real side effect", context do
    job = shell_job(context, "s_nonzero")
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    counter = :atomics.new(1, [])

    assert %Result{
             status: :terminal,
             outcome: {:error, message},
             workspace: %Workspace{state: :exact_postimage},
             causal: :failed,
             historical: :invoked,
             safe_action: :do_not_retry,
             executor_record: %Record{state: :failed}
           } = OpaqueShell.execute(executor, journal, job, context.cwd, effect_opts(counter))

    assert message =~ "exit_status=7"
    assert :atomics.get(counter, 1) == 1
    assert File.read!(context.primary) == desired_content()
    close(executor, journal)
  end

  test "a multi-resource failed command defeats a one-file adapter without changing causality",
       context do
    audit = Path.join(context.cwd, "fixture/shell/audit.txt")

    command =
      "mkdir -p fixture/shell; " <>
        "printf 'ER2-SHELL-DESIRED-V1\\n' > fixture/shell/primary.txt; " <>
        "printf 'external-resource\\n' >> fixture/shell/audit.txt; exit 9"

    arguments = fixture_arguments("s_success") |> Map.put("command", command)
    job = shell_job(context, arguments)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)

    assert %Result{
             outcome: {:error, _message},
             workspace: %Workspace{state: :exact_postimage},
             causal: :failed,
             safe_action: :do_not_retry
           } = OpaqueShell.execute(executor, journal, job, context.cwd)

    assert File.read!(context.primary) == desired_content()
    assert File.read!(audit) == "external-resource\n"
    close(executor, journal)
  end

  for cut <- 1..8 do
    test "S-C#{cut} executes the frozen shared crash schedule", context do
      run_shared_cut(unquote(cut), context)
    end
  end

  test "S-SPAWN reports an observed live shell before its declared effect", context do
    {job, journal, executor, task, pid} = start_lifecycle(context)
    assert process_state(pid) == :alive
    refute File.exists?(context.primary)

    kill_executor(executor)
    _initial = Task.await(task, @bound_ms)
    reopened = start_executor(context.executor_path)

    assert %Result{
             outcome: {:indeterminate, _message},
             workspace: %Workspace{state: :absent},
             process_lifetime: lifetime,
             causal: :unproven,
             historical: :invoked,
             safe_action: :manual_investigation,
             executor_record: %Record{callback_attempt_count: 1, terminal_count: 0}
           } =
             OpaqueShell.reconcile(reopened, journal, job, context.cwd,
               process_observer: process_observer(pid)
             )

    assert lifetime in [:alive, :terminated]
    refute File.exists?(context.primary)
    close(reopened, journal)
  end

  test "S-EFFECT-LIVE separates a satisfied adapter from a still-running shell", context do
    {job, journal, executor, task, pid} = start_lifecycle(context)
    File.touch!(context.allow_effect)
    await_file(context.primary)
    assert process_state(pid) == :alive

    kill_executor(executor)
    _initial = Task.await(task, @bound_ms)
    reopened = start_executor(context.executor_path)

    assert %Result{
             outcome: {:indeterminate, _message},
             workspace: %Workspace{state: :exact_postimage},
             process_lifetime: lifetime,
             causal: :unproven,
             historical: :invoked,
             safe_action: :postcondition_satisfied_no_retry
           } =
             OpaqueShell.reconcile(reopened, journal, job, context.cwd,
               process_observer: process_observer(pid)
             )

    assert lifetime in [:alive, :terminated]
    close(reopened, journal)
  end

  test "S-EXIT observes termination before callback return without inventing completion",
       context do
    parent = self()

    hook = fn
      :after_shell_exit_before_callback_return = point -> block(parent, :operation_hook, point)
      _point -> :ok
    end

    {job, journal, executor, task, pid} = start_lifecycle(context, operation_hook: hook)
    File.touch!(context.allow_effect)
    await_file(context.primary)
    File.touch!(context.allow_exit)

    assert_receive {:operation_hook, :after_shell_exit_before_callback_return, ^executor},
                   @bound_ms

    assert await_process_state(pid, :terminated) == :terminated

    kill_executor(executor)
    _initial = Task.await(task, @bound_ms)
    reopened = start_executor(context.executor_path)

    assert %Result{
             outcome: {:indeterminate, _message},
             workspace: %Workspace{state: :exact_postimage},
             process_lifetime: :terminated,
             causal: :unproven,
             historical: :invoked,
             safe_action: :postcondition_satisfied_no_retry
           } =
             OpaqueShell.reconcile(reopened, journal, job, context.cwd,
               process_observer: process_observer(pid)
             )

    close(reopened, journal)
  end

  test "S-TIMEOUT reports possible execution without blocking on the busy executor", context do
    {job, journal, executor, task, pid} = start_lifecycle(context, timeout: 300)
    File.touch!(context.allow_effect)
    await_file(context.primary)

    assert %Result{
             status: :terminal,
             outcome: {:indeterminate, message},
             workspace: %Workspace{state: :exact_postimage},
             process_lifetime: :alive,
             causal: :unproven,
             historical: :unknown,
             safe_action: :postcondition_satisfied_no_retry
           } = Task.await(task, @bound_ms)

    assert message =~ "completion_timeout"
    kill_executor(executor)
    reopened = start_executor(context.executor_path)

    assert %Result{
             outcome: {:indeterminate, _message},
             process_lifetime: lifetime,
             historical: :invoked,
             safe_action: :postcondition_satisfied_no_retry
           } =
             OpaqueShell.reconcile(reopened, journal, job, context.cwd,
               process_observer: process_observer(pid)
             )

    assert lifetime in [:alive, :terminated]
    close(reopened, journal)
  end

  test "S-SAME-DIGEST, S-CONFLICT-DIGEST, and S-REPLACEMENT preserve one owner", context do
    parent = self()

    sidecar_hook = fn
      :after_accept_observation_before_continue = point -> block(parent, :sidecar_hook, point)
      _point -> :ok
    end

    job = shell_job(context, "s_success")
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)

    task =
      Task.async(fn ->
        OpaqueShell.execute(executor, journal, job, context.cwd, sidecar_hook: sidecar_hook)
      end)

    assert_receive {:sidecar_hook, :after_accept_observation_before_continue, task_pid}, @bound_ms
    assert task_pid == task.pid
    assert {:accepted, accepted} = TestExecutor.query(executor, job.job_id)

    assert {:accepted, ^accepted} =
             TestExecutor.submit(executor, job.job_id, job.operation_digest, fn ->
               raise "same-digest shell replay invoked"
             end)

    changed_jobs = [
      shell_job(context, put_in(job.arguments["schema"], "elara.opaque_shell.v2")),
      shell_job(context, put_in(job.arguments["command"], "printf changed")),
      shell_job(context, put_in(job.arguments["relative_cwd"], "fixture")),
      shell_job(context, put_in(job.arguments["environment"]["LANG"], "C.UTF-8")),
      shell_job(context, put_in(job.arguments["timeout_ms"], 4_999)),
      shell_job(context, put_in(job.arguments["postcondition"], nil)),
      shell_job(context, job.arguments, workspace_id: "changed-workspace"),
      shell_job(context, job.arguments, allowed_capabilities: ["shell", "filesystem:write"])
    ]

    for changed <- changed_jobs do
      assert changed.job_id == job.job_id
      refute changed.operation_digest == job.operation_digest

      assert {:error, :digest_conflict} =
               TestExecutor.submit(executor, job.job_id, changed.operation_digest, fn ->
                 raise "conflicting shell callback invoked"
               end)
    end

    replacement = start_executor(context.executor_path, no_fault(), "executor-2")

    assert {:error, :wrong_executor} =
             TestExecutor.submit(replacement, job.job_id, job.operation_digest, fn ->
               raise "replacement shell callback invoked"
             end)

    assert :ok = TestExecutor.close(replacement)
    send(task.pid, {:continue, :after_accept_observation_before_continue})
    assert_completed(Task.await(task, @bound_ms), executor, job)
    close(executor, journal)
  end

  test "S-LEDGER-ADAPTER refines safe action without recreating causal completion", context do
    {job, journal, executor, task} = execute_until_primary(context, "s_success")
    kill_executor(executor)
    _initial = Task.await(task, @bound_ms)
    delete_executor_ledger(context.executor_path)

    assert %Result{
             outcome: {:indeterminate, _message},
             workspace: %Workspace{state: :exact_postimage},
             causal: :unproven,
             historical: :unknown,
             safe_action: :postcondition_satisfied_no_retry,
             executor_record: nil
           } = OpaqueShell.reconcile_unavailable(journal, job, context.cwd)

    assert :ok = ControllerJournal.close(journal)
  end

  test "S-LEDGER-OPAQUE remains manually indeterminate without a declared adapter", context do
    {job, journal, executor, task} = execute_until_primary(context, "s_success_no_adapter")
    kill_executor(executor)
    _initial = Task.await(task, @bound_ms)
    delete_executor_ledger(context.executor_path)

    assert %Result{
             outcome: {:indeterminate, _message},
             workspace: %Workspace{state: :not_applicable},
             causal: :unproven,
             historical: :unknown,
             safe_action: :manual_investigation,
             executor_record: nil
           } = OpaqueShell.reconcile_unavailable(journal, job, context.cwd)

    assert File.read!(context.primary) == desired_content()
    assert :ok = ControllerJournal.close(journal)
  end

  test "terminal controller evidence survives executor-ledger loss without rerun", context do
    job = shell_job(context, "s_success")
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    completed = OpaqueShell.execute(executor, journal, job, context.cwd)
    assert_completed(completed, executor, job)
    expected_outcome = completed.outcome
    assert :ok = TestExecutor.close(executor)
    delete_executor_ledger(context.executor_path)

    assert %Result{
             outcome: ^expected_outcome,
             causal: :completed,
             historical: :invoked,
             safe_action: :none,
             executor_record: nil,
             controller_record: %Record{state: :completed}
           } = OpaqueShell.reconcile_unavailable(journal, job, context.cwd)

    assert :ok = ControllerJournal.close(journal)
  end

  test "validation rejects malformed arguments, workspace paths, and authority", context do
    job = shell_job(context, "s_success")

    bad_postcondition_digest =
      update_in(job.arguments, ["postcondition", "files"], fn [file] ->
        [Map.put(file, "sha256", "bad")]
      end)

    invalid_jobs = [
      shell_job(context, put_in(job.arguments["schema"], "elara.opaque_shell.v2")),
      shell_job(context, put_in(job.arguments["command"], "")),
      shell_job(context, put_in(job.arguments["relative_cwd"], "../outside")),
      shell_job(context, put_in(job.arguments["environment"], %{"BAD=KEY" => "value"})),
      shell_job(context, put_in(job.arguments["timeout_ms"], 0)),
      shell_job(context, bad_postcondition_digest),
      shell_job(context, job.arguments, workspace_id: ""),
      shell_job(context, job.arguments, allowed_capabilities: [])
    ]

    for invalid <- invalid_jobs do
      assert {:error, _reason} = OpaqueShell.validate(invalid, context.cwd)
    end

    linked = Path.join(context.root, "linked-workspace")
    File.ln_s!(context.cwd, linked)
    assert {:error, :symlink_cwd_rejected} = OpaqueShell.validate(job, linked)
  end

  defp run_shared_cut(1, context) do
    job = shell_job(context, "s_success")
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
             workspace: %Workspace{state: :not_applicable},
             process_lifetime: :not_spawned,
             causal: :not_started,
             historical: :not_invoked,
             safe_action: :new_job_id_allowed
           } =
             OpaqueShell.reconcile_unavailable(reopened, job, context.cwd,
               process_observer: fn -> :not_spawned end
             )

    refute File.exists?(context.primary)
    assert :ok = ControllerJournal.close(reopened)
  end

  defp run_shared_cut(2, context) do
    job = shell_job(context, "s_success")
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
    assert_completed(OpaqueShell.reconcile(executor, reopened, job, context.cwd), executor, job)
    close(executor, reopened)
  end

  defp run_shared_cut(cut, context) when cut in 3..7 do
    job = shell_job(context, "s_success")
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
        OpaqueShell.execute(executor, journal, job, context.cwd, effect_opts(counter))
      end)

    assert_receive {:executor_hook, ^point, ^executor}, @bound_ms
    kill_executor(executor)
    _initial = Task.await(task, @bound_ms)
    reopened = start_executor(context.executor_path)
    result = OpaqueShell.reconcile(reopened, journal, job, context.cwd, effect_opts(counter))

    if cut == 6 do
      assert %Result{
               outcome: {:indeterminate, _message},
               workspace: %Workspace{state: :exact_postimage},
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

    close(reopened, journal)
  end

  defp run_shared_cut(8, context) do
    job = shell_job(context, "s_success")
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
        OpaqueShell.execute(
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
    assert_completed(OpaqueShell.reconcile(executor, journal, job, context.cwd), executor, job)
    assert :atomics.get(counter, 1) == 1
    close(executor, journal)
  end

  defp start_lifecycle(context, opts \\ []) do
    job = shell_job(context, "s_lifecycle")
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)
    process_observer = fn -> process_state_from_path(context.pid_path) end
    execute_opts = Keyword.put(opts, :process_observer, process_observer)

    task =
      Task.async(fn ->
        OpaqueShell.execute(executor, journal, job, context.cwd, execute_opts)
      end)

    pid = await_pid(context.pid_path)
    register_fixture_processes(context.process_registry, pid)
    {job, journal, executor, task, pid}
  end

  defp execute_until_primary(context, fixture_id) do
    parent = self()

    executor_hook = fn
      :after_external_mutation_before_completion_commit = point ->
        block(parent, :executor_hook, point)

      _point ->
        :ok
    end

    job = shell_job(context, fixture_id)
    journal = start_journal(context.journal_path)
    executor = start_executor(context.executor_path, executor_hook)
    assert {:ok, ^job} = ControllerJournal.commit_intent(journal, job)

    task = Task.async(fn -> OpaqueShell.execute(executor, journal, job, context.cwd) end)

    assert_receive {:executor_hook, :after_external_mutation_before_completion_commit, ^executor},
                   @bound_ms

    assert File.read!(context.primary) == desired_content()
    {job, journal, executor, task}
  end

  defp assert_completed(result, executor, job) do
    assert %Result{
             status: :terminal,
             outcome: {:ok, _message},
             workspace: %Workspace{state: :exact_postimage},
             causal: :completed,
             historical: :invoked,
             safe_action: :none,
             executor_record: %Record{} = completed
           } = result

    assert {:completed, ^completed} = TestExecutor.query(executor, job.job_id)
    assert completed.operation_digest == job.operation_digest

    assert {completed.admission_count, completed.callback_attempt_count, completed.terminal_count} ==
             {1, 1, 1}

    assert File.read!(Path.join(workspace_from_job(job), "fixture/shell/primary.txt")) ==
             desired_content()
  end

  defp shell_job(context, fixture_or_arguments, opts \\ []) do
    arguments =
      if is_binary(fixture_or_arguments),
        do: fixture_arguments(fixture_or_arguments),
        else: fixture_or_arguments

    Job.new(%{recording_id: "er2-shell", sequence: 1, effect_index: 0},
      operation_kind: :opaque_shell,
      tool_name: "opaque_shell",
      tool_version: "1",
      arguments: arguments,
      workspace_id: Keyword.get(opts, :workspace_id, "workspace:#{context.cwd}"),
      required_capabilities: ["shell"],
      allowed_capabilities: Keyword.get(opts, :allowed_capabilities, :all),
      placement: :local
    )
  end

  defp fixture_arguments(id) do
    fixture = @fixtures[id]
    success = @fixtures["s_success"]

    OpaqueShell.arguments(fixture["command"] || success["command"],
      relative_cwd: fixture["relative_cwd"],
      environment: fixture["environment"],
      timeout_ms: fixture["timeout_ms"],
      postcondition:
        cond do
          Map.has_key?(fixture, "postcondition") -> fixture["postcondition"]
          fixture["postcondition_ref"] -> success["postcondition"]
          true -> nil
        end
    )
  end

  defp desired_content, do: "ER2-SHELL-DESIRED-V1\n"

  defp workspace_from_job(job) do
    String.replace_prefix(job.workspace_id, "workspace:", "")
  end

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
    observer = fn :declared_postcondition_satisfied ->
      :atomics.add_get(counter, 1, 1)
      :ok
    end

    Keyword.put(opts, :effect_observer, observer)
  end

  defp process_observer(pid), do: fn -> process_state(pid) end

  defp process_state_from_path(path) do
    case read_pid(path) do
      {:ok, pid} -> process_state(pid)
      :error -> :not_spawned
    end
  end

  defp process_state(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        case Regex.run(~r/^\d+ \(.+\) ([A-Z]) /, stat) do
          [_, "Z"] -> :terminated
          [_, _state] -> :alive
          _unknown -> :unknown
        end

      {:error, :enoent} ->
        :terminated

      {:error, _reason} ->
        :unknown
    end
  end

  defp await_process_state(pid, expected) do
    await(fn -> process_state(pid) == expected end)
    process_state(pid)
  end

  defp await_pid(path) do
    await(fn -> match?({:ok, _pid}, read_pid(path)) end)
    {:ok, pid} = read_pid(path)
    pid
  end

  defp read_pid(path) do
    with {:ok, content} <- File.read(path),
         {pid, ""} <- content |> String.trim() |> Integer.parse() do
      {:ok, pid}
    else
      _unavailable -> :error
    end
  end

  defp await_file(path) do
    await(fn -> File.regular?(path) end)
    :ok
  end

  defp await(predicate) do
    deadline = System.monotonic_time(:millisecond) + @bound_ms
    do_await(predicate, deadline)
  end

  defp do_await(predicate, deadline) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition did not converge")

      true ->
        Process.sleep(10)
        do_await(predicate, deadline)
    end
  end

  defp register_fixture_processes(registry, root_pid) do
    await(fn -> process_tree(root_pid) != [] end)
    Agent.update(registry, &MapSet.union(&1, MapSet.new([root_pid | process_tree(root_pid)])))
  end

  defp process_tree(parent) do
    children =
      case System.cmd("pgrep", ["-P", Integer.to_string(parent)], stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split()
          |> Enum.map(&String.to_integer/1)

        {_output, _status} ->
          []
      end

    children ++ Enum.flat_map(children, &process_tree/1)
  end

  defp terminate_fixture_processes(pids) do
    for signal <- ["-TERM", "-KILL"] do
      for pid <- pids, fixture_process?(pid) do
        System.cmd("kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true)
      end

      Process.sleep(25)
    end
  end

  defp fixture_process?(pid) do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, command} -> String.contains?(command, "fixture/shell")
      {:error, _reason} -> false
    end
  end

  defp delete_executor_ledger(path) do
    File.rm_rf!(path)
    File.rm_rf!(path <> "-wal")
    File.rm_rf!(path <> "-shm")
  end

  defp shared_executor_point(3), do: :after_receipt_before_accept_commit
  defp shared_executor_point(4), do: :after_accept_commit_before_accept_reply
  defp shared_executor_point(5), do: :after_accept_reply_before_callback
  defp shared_executor_point(6), do: :after_external_mutation_before_completion_commit
  defp shared_executor_point(7), do: :after_completion_commit_before_completion_reply

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
