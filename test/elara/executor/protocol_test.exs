defmodule Elara.Effect.ExecutorProtocolTest do
  use ExUnit.Case, async: false

  alias Elara.Effect.ExecutorLedger
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Effect.Executor

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-test-executor-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: Path.join(root, "executor.sqlite3")}
  end

  test "no-fault protocol orders acceptance, one callback, terminal commit, and replies",
       context do
    parent = self()
    {:ok, mutations} = Agent.start_link(fn -> 0 end)
    hook = reporting_hook(parent)
    executor = start_executor(context.path, hook)

    operation = fn ->
      Agent.update(mutations, &(&1 + 1))
      send(parent, :external_mutation)
      {:ok, "result"}
    end

    assert {:accepted, %Record{} = accepted} =
             Executor.submit(executor, "job-1", digest("a"), operation)

    assert_receive {:hook, :after_receipt_before_accept_commit, ^executor}
    assert_receive {:hook, :after_accept_commit_before_accept_reply, ^executor}
    assert accepted.callback_attempt_count == 0
    assert {:accepted, ^accepted} = Executor.query(executor, "job-1")

    assert :ok = Executor.continue(executor, "job-1")
    assert_receive {:hook, :after_accept_reply_before_callback, ^executor}
    assert_receive :external_mutation
    assert_receive {:hook, :after_external_mutation_before_completion_commit, ^executor}
    assert_receive {:hook, :after_completion_commit_before_completion_reply, ^executor}

    assert_receive {:elara_effect_executor, "executor-1", "job-1",
                    {:completed, %Record{} = completed}}

    assert completed.admission_count == 1
    assert completed.callback_attempt_count == 1
    assert completed.terminal_count == 1
    assert completed.result == {:ok, "result"}
    assert Agent.get(mutations, & &1) == 1
    assert {:completed, ^completed} = Executor.query(executor, "job-1")
    assert :ok = Executor.close(executor)
  end

  test "same identity replay and digest conflict never invoke the callback", context do
    {:ok, mutations} = Agent.start_link(fn -> 0 end)
    executor = start_executor(context.path)

    operation = fn ->
      Agent.update(mutations, &(&1 + 1))
      {:ok, "result"}
    end

    assert {:accepted, %Record{} = accepted} =
             Executor.submit(executor, "job-1", digest("a"), operation)

    assert {:accepted, ^accepted} =
             Executor.submit(executor, "job-1", digest("a"), fn ->
               Agent.update(mutations, &(&1 + 100))
               {:ok, "wrong"}
             end)

    assert {:accepted, ^accepted} = Executor.query(executor, "job-1")

    assert {:error, :digest_conflict} =
             Executor.submit(executor, "job-1", digest("b"), operation)

    assert Agent.get(mutations, & &1) == 0
    assert :ok = Executor.continue(executor, "job-1")

    assert_receive {:elara_effect_executor, "executor-1", "job-1",
                    {:completed, %Record{} = completed}}

    assert Agent.get(mutations, & &1) == 1

    assert {:completed, ^completed} =
             Executor.submit(executor, "job-1", digest("a"), operation)

    assert {:completed, ^completed} = Executor.query(executor, "job-1")

    assert {:error, :already_terminal} =
             Executor.continue(executor, "job-1", digest("a"), operation)

    assert Agent.get(mutations, & &1) == 1
    assert :ok = Executor.close(executor)
  end

  test "crash after receipt but before acceptance commit reopens as unknown", context do
    parent = self()

    hook = fn
      :after_receipt_before_accept_commit = point -> block(parent, point)
      _point -> :ok
    end

    executor = start_executor(context.path, hook)
    monitor = Process.monitor(executor)
    call_unlinked(fn -> Executor.submit(executor, "job-1", digest("a"), ok_operation()) end)

    assert_receive {:hook, :after_receipt_before_accept_commit, ^executor}
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}
    assert_receive {:call_result, {:exit, _reason}}

    reopened = start_executor(context.path)
    assert :unknown = Executor.query(reopened, "job-1")
    assert :ok = Executor.close(reopened)
  end

  test "crash after acceptance commit but before its reply preserves accepted zero-attempt proof",
       context do
    parent = self()

    hook = fn
      :after_accept_commit_before_accept_reply = point -> block(parent, point)
      _point -> :ok
    end

    executor = start_executor(context.path, hook)
    monitor = Process.monitor(executor)
    call_unlinked(fn -> Executor.submit(executor, "job-1", digest("a"), ok_operation()) end)

    assert_receive {:hook, :after_accept_commit_before_accept_reply, ^executor}
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}
    assert_receive {:call_result, {:exit, _reason}}

    reopened = start_executor(context.path)
    assert {:accepted, %Record{} = accepted} = Executor.query(reopened, "job-1")
    assert accepted.admission_count == 1
    assert accepted.callback_attempt_count == 0
    assert accepted.terminal_count == 0
    assert :ok = Executor.close(reopened)
  end

  test "crash after acceptance reply permits one explicit same-owner continue", context do
    parent = self()
    {:ok, mutations} = Agent.start_link(fn -> 0 end)

    hook = fn
      :after_accept_reply_before_callback = point -> block(parent, point)
      _point -> :ok
    end

    operation = counted_operation(mutations)
    executor = start_executor(context.path, hook)

    assert {:accepted, _accepted} =
             Executor.submit(executor, "job-1", digest("a"), operation)

    assert :ok = Executor.continue(executor, "job-1")
    assert_receive {:hook, :after_accept_reply_before_callback, ^executor}
    monitor = Process.monitor(executor)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}
    assert Agent.get(mutations, & &1) == 0

    holder =
      spawn(fn ->
        {:ok, lock} =
          Elara.Effect.Ownership.acquire(context.path <> ".writer.lock", :exclusive)

        send(parent, :writer_lock_held)

        receive do
          :release -> :ok = Elara.Effect.Ownership.release(lock)
        end
      end)

    on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)
    assert_receive :writer_lock_held, 5_000

    spawn(fn ->
      Process.sleep(500)
      send(holder, :release)
    end)

    reopened = start_executor(context.path)

    assert {:accepted, %Record{callback_attempt_count: 0}} =
             Executor.query(reopened, "job-1")

    assert :ok = Executor.continue(reopened, "job-1", digest("a"), operation)

    assert_receive {:elara_effect_executor, "executor-1", "job-1",
                    {:completed, %Record{} = completed}}

    assert completed.admission_count == 1
    assert completed.callback_attempt_count == 1
    assert Agent.get(mutations, & &1) == 1
    assert :ok = Executor.close(reopened)
  end

  test "crash after external mutation preserves attempt proof and forbids reinvocation",
       context do
    parent = self()
    {:ok, mutations} = Agent.start_link(fn -> 0 end)

    hook = fn
      :after_external_mutation_before_completion_commit = point -> block(parent, point)
      _point -> :ok
    end

    operation = counted_operation(mutations)
    executor = start_executor(context.path, hook)
    assert {:accepted, _accepted} = Executor.submit(executor, "job-1", digest("a"), operation)
    assert :ok = Executor.continue(executor, "job-1")

    assert_receive {:hook, :after_external_mutation_before_completion_commit, ^executor}
    assert Agent.get(mutations, & &1) == 1
    monitor = Process.monitor(executor)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}

    reopened = start_executor(context.path)
    assert {:indeterminate, %Record{} = attempted} = Executor.query(reopened, "job-1")
    assert attempted.callback_attempt_count == 1
    assert attempted.terminal_count == 1
    assert {:indeterminate, reason} = attempted.result
    assert reason =~ "orphaned at startup"
    assert reason =~ "last_known_incarnation="
    assert reason =~ "VM OS PID=#{System.pid()}"
    assert reason =~ "attempt_count=1"
    assert ExecutorLedger.last_proven_fact(attempted) == :indeterminate

    assert {:error, :already_terminal} =
             Executor.continue(reopened, "job-1", digest("a"), operation)

    refute_receive {:elara_effect_executor, _, _, _}
    assert Agent.get(mutations, & &1) == 1
    assert :ok = Executor.close(reopened)
  end

  test "crash after terminal commit loses only completion reply", context do
    parent = self()
    {:ok, mutations} = Agent.start_link(fn -> 0 end)

    hook = fn
      :after_completion_commit_before_completion_reply = point -> block(parent, point)
      _point -> :ok
    end

    operation = counted_operation(mutations)
    executor = start_executor(context.path, hook)
    assert {:accepted, _accepted} = Executor.submit(executor, "job-1", digest("a"), operation)
    assert :ok = Executor.continue(executor, "job-1")

    assert_receive {:hook, :after_completion_commit_before_completion_reply, ^executor}
    assert Agent.get(mutations, & &1) == 1
    monitor = Process.monitor(executor)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}
    refute_receive {:elara_effect_executor, _, _, _}

    reopened = start_executor(context.path)
    assert {:completed, %Record{} = completed} = Executor.query(reopened, "job-1")
    assert completed.result == {:ok, "result"}
    assert completed.result_digest != nil
    assert completed.admission_count == 1
    assert completed.callback_attempt_count == 1
    assert completed.terminal_count == 1
    assert :ok = Executor.close(reopened)
  end

  test "callback errors are failed; uncertain results and crashes are indeterminate",
       context do
    executor = start_executor(context.path)

    assert {:accepted, _accepted} =
             Executor.submit(executor, "job-error", digest("a"), fn -> {:error, "no"} end)

    assert :ok = Executor.continue(executor, "job-error")

    assert_receive {:elara_effect_executor, "executor-1", "job-error",
                    {:failed, %Record{} = failed}}

    assert failed.result == {:error, "no"}

    uncertain = fn -> {:indeterminate, "killed mid-run"} end

    assert {:accepted, _accepted} =
             Executor.submit(executor, "job-maybe", digest("c"), uncertain)

    assert :ok = Executor.continue(executor, "job-maybe")

    assert_receive {:elara_effect_executor, "executor-1", "job-maybe",
                    {:indeterminate, %Record{} = maybe}}

    assert maybe.result == {:indeterminate, "killed mid-run"}
    assert maybe.terminal_count == 1
    assert ExecutorLedger.last_proven_fact(maybe) == :indeterminate
    assert {:indeterminate, ^maybe} = Executor.query(executor, "job-maybe")

    assert {:accepted, _accepted} =
             Executor.submit(executor, "job-crash", digest("b"), fn -> raise "boom" end)

    assert :ok = Executor.continue(executor, "job-crash")

    # The callback started, so a crash leaves its mutation unknown.
    assert_receive {:elara_effect_executor, "executor-1", "job-crash",
                    {:indeterminate, %Record{} = crashed}}

    assert {:indeterminate, "callback crashed: boom; " <> _} = crashed.result

    # A terminal indeterminate job is never invoked again.
    assert {:error, :already_terminal} =
             Elara.Effect.Executor.continue(executor, "job-crash", digest("b"), fn ->
               flunk("a terminal job must not be invoked again")
             end)

    assert :ok = Executor.close(executor)
  end

  test "accepted jobs cannot fail over to a replacement executor identity", context do
    operation = ok_operation()
    original = start_executor(context.path)

    assert {:accepted, _accepted} =
             Executor.submit(original, "job-1", digest("a"), operation)

    assert :ok = Executor.close(original)
    replacement = start_executor(context.path, fn _point -> :ok end, "replacement")
    assert {:accepted, _accepted} = Executor.query(replacement, "job-1")

    assert {:error, :wrong_executor} =
             Executor.submit(replacement, "job-1", digest("a"), operation)

    assert {:error, :wrong_executor} =
             Executor.continue(replacement, "job-1", digest("a"), operation)

    assert :ok = Executor.close(replacement)
  end

  test "callback worker loss records uncertainty without killing the writer or replaying",
       context do
    parent = self()
    {:ok, mutations} = Agent.start_link(fn -> 0 end)
    executor = owned_executor(context.path)

    operation = fn ->
      Agent.update(mutations, &(&1 + 1))
      send(parent, {:callback_worker, self()})

      receive do
        :release -> {:ok, "result"}
      end
    end

    assert {:accepted, _} = Executor.submit(executor, "lost-worker", digest("a"), operation)
    assert :ok = Executor.continue(executor, "lost-worker")
    assert_receive {:callback_worker, worker}, 5_000
    on_exit(fn -> stop_owned_process(worker) end)
    ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 5_000

    assert_receive {:elara_effect_executor, "executor-1", "lost-worker",
                    {:indeterminate, %Record{} = record}},
                   5_000

    assert Process.alive?(executor)
    refute worker == executor
    assert {:indeterminate, "callback worker lost:" <> _} = record.result
    assert record.admission_count == 1
    assert record.callback_attempt_count == 1
    assert record.terminal_count == 1
    assert record.result_digest != nil
    assert {:indeterminate, ^record} = Executor.query(executor, "lost-worker")

    assert {:indeterminate, ^record} =
             Executor.submit(executor, "lost-worker", digest("a"), operation)

    assert {:error, :already_terminal} =
             Executor.continue(executor, "lost-worker", digest("a"), operation)

    assert Agent.get(mutations, & &1) == 1
    refute_receive {:callback_worker, _}
    assert {:accepted, _} = Executor.submit(executor, "next-job", digest("b"), ok_operation())
    assert :ok = Executor.continue(executor, "next-job")

    assert_receive {:elara_effect_executor, "executor-1", "next-job", {:completed, _}},
                   5_000
  end

  test "writer loss kills its callback and startup records uncertainty without replay", context do
    parent = self()
    executor = owned_executor(context.path)

    operation = fn ->
      send(parent, {:callback_worker, self()})

      receive do
        :release -> {:ok, "result"}
      end
    end

    assert {:accepted, _} = Executor.submit(executor, "lost-writer", digest("a"), operation)
    assert :ok = Executor.continue(executor, "lost-writer")
    assert_receive {:callback_worker, worker}, 5_000
    on_exit(fn -> stop_owned_process(worker) end)
    refute worker == executor
    writer_ref = Process.monitor(executor)
    worker_ref = Process.monitor(worker)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^writer_ref, :process, ^executor, :killed}, 5_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 5_000
    refute_receive {:elara_effect_executor, _, "lost-writer", _}

    reopened = owned_executor(context.path)

    assert {:indeterminate, %Record{callback_attempt_count: 1, terminal_count: 1}} =
             Executor.query(reopened, "lost-writer")

    assert {:error, :already_terminal} =
             Executor.continue(reopened, "lost-writer", digest("a"), operation)

    refute_receive {:callback_worker, _}
  end

  test "a surviving callback hold prevents startup from declaring an orphan", context do
    parent = self()
    executor = owned_executor(context.path)

    operation = fn ->
      Process.flag(:trap_exit, true)
      send(parent, {:held_callback, self()})

      receive do
        :release -> {:ok, "done"}
      end
    end

    assert {:accepted, _} = Executor.submit(executor, "held", digest("a"), operation)
    assert :ok = Executor.continue(executor, "held")
    assert_receive {:held_callback, worker}, 5_000
    on_exit(fn -> stop_owned_process(worker) end)
    writer_ref = Process.monitor(executor)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^writer_ref, :process, ^executor, :killed}, 5_000

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(parent, {:blocked_start, Executor.start_link(id: "executor-1", path: context.path)})
    end)

    assert_receive {:blocked_start, {:error, :locked}}, 5_000
    assert Process.alive?(worker)
    {:ok, ledger} = ExecutorLedger.open(context.path)

    assert {:ok, %Record{state: :accepted, callback_attempt_count: 1, terminal_count: 0}} =
             ExecutorLedger.query(ledger, "held")

    :ok = ExecutorLedger.close(ledger)

    callback_port =
      Enum.find(Port.list(), fn port -> Port.info(port, :connected) == {:connected, worker} end)

    assert is_port(callback_port)
    Port.close(callback_port)
    assert Process.alive?(worker)

    # Wait for the external holder to exit, not for the callback to die. The
    # durable PID proof must still refuse even when flock is now obtainable.
    lock_path = context.path <> ".callbacks.lock"

    Enum.reduce_while(1..100, nil, fn _, _ ->
      case System.cmd("flock", ["-n", "-x", lock_path, "true"]) do
        {_, 0} ->
          {:halt, :ok}

        _ ->
          Process.sleep(10)
          {:cont, nil}
      end
    end)

    assert {_, 0} = System.cmd("flock", ["-n", "-x", lock_path, "true"])

    blocked =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        Executor.start_link(id: "executor-1", path: context.path)
      end)

    assert {:error, {:effect_owner_alive, message}} = Task.await(blocked)
    assert message =~ "VM OS PID="
    assert message =~ "stop it first"

    worker_ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 5_000
    reopened = owned_executor(context.path)

    assert {:indeterminate, %Record{callback_attempt_count: 1, terminal_count: 1}} =
             Executor.query(reopened, "held")
  end

  test "ledger symlink aliases cannot take over a live callback", context do
    executor = owned_executor(context.path)
    parent = self()

    operation = fn ->
      send(parent, :alias_callback_running)

      receive do
        :release -> {:ok, "done"}
      end
    end

    assert {:accepted, _} = Executor.submit(executor, "alias", digest("a"), operation)
    assert :ok = Executor.continue(executor, "alias")
    assert_receive :alias_callback_running, 5_000

    file_alias = context.path <> ".alias"
    dir_alias = Path.dirname(context.path) <> "-alias"
    File.ln_s!(context.path, file_alias)
    File.ln_s!(Path.dirname(context.path), dir_alias)
    on_exit(fn -> File.rm(dir_alias) end)

    for alias_path <- [file_alias, Path.join(dir_alias, Path.basename(context.path))] do
      blocked =
        Task.async(fn ->
          Process.flag(:trap_exit, true)
          Executor.start_link(id: "executor-1", path: alias_path)
        end)

      assert {:error, :locked} = Task.await(blocked)
    end
  end

  defp owned_executor(path) do
    executor = start_executor(path)
    on_exit(fn -> stop_owned_process(executor) end)
    executor
  end

  defp stop_owned_process(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  defp start_executor(path, hook \\ fn _point -> :ok end, id \\ "executor-1") do
    {:ok, executor} = Executor.start_link(id: id, path: path, fault_hook: hook)
    Process.unlink(executor)
    executor
  end

  defp reporting_hook(parent) do
    fn point ->
      send(parent, {:hook, point, self()})
      :ok
    end
  end

  defp block(parent, point) do
    send(parent, {:hook, point, self()})

    receive do
      {:continue, ^point} -> :ok
    end
  end

  defp call_unlinked(fun) do
    parent = self()

    spawn(fn ->
      result =
        try do
          fun.()
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {:call_result, result})
    end)
  end

  defp counted_operation(counter) do
    fn ->
      Agent.update(counter, &(&1 + 1))
      {:ok, "result"}
    end
  end

  defp ok_operation, do: fn -> {:ok, "result"} end
  defp digest(character), do: String.duplicate(character, 64)
end
