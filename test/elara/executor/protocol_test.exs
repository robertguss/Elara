defmodule Elara.Effect.TestExecutorProtocolTest do
  use ExUnit.Case, async: false

  alias Elara.Effect.ExecutorLedger
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Effect.TestExecutor

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
             TestExecutor.submit(executor, "job-1", digest("a"), operation)

    assert_receive {:hook, :after_receipt_before_accept_commit, ^executor}
    assert_receive {:hook, :after_accept_commit_before_accept_reply, ^executor}
    assert accepted.callback_attempt_count == 0
    assert {:accepted, ^accepted} = TestExecutor.query(executor, "job-1")

    assert :ok = TestExecutor.continue(executor, "job-1")
    assert_receive {:hook, :after_accept_reply_before_callback, ^executor}
    assert_receive :external_mutation
    assert_receive {:hook, :after_external_mutation_before_completion_commit, ^executor}
    assert_receive {:hook, :after_completion_commit_before_completion_reply, ^executor}

    assert_receive {:elara_test_executor, "executor-1", "job-1",
                    {:completed, %Record{} = completed}}

    assert completed.admission_count == 1
    assert completed.callback_attempt_count == 1
    assert completed.terminal_count == 1
    assert completed.result == {:ok, "result"}
    assert Agent.get(mutations, & &1) == 1
    assert {:completed, ^completed} = TestExecutor.query(executor, "job-1")
    assert :ok = TestExecutor.close(executor)
  end

  test "same identity replay and digest conflict never invoke the callback", context do
    {:ok, mutations} = Agent.start_link(fn -> 0 end)
    executor = start_executor(context.path)

    operation = fn ->
      Agent.update(mutations, &(&1 + 1))
      {:ok, "result"}
    end

    assert {:accepted, %Record{} = accepted} =
             TestExecutor.submit(executor, "job-1", digest("a"), operation)

    assert {:accepted, ^accepted} =
             TestExecutor.submit(executor, "job-1", digest("a"), fn ->
               Agent.update(mutations, &(&1 + 100))
               {:ok, "wrong"}
             end)

    assert {:accepted, ^accepted} = TestExecutor.query(executor, "job-1")

    assert {:error, :digest_conflict} =
             TestExecutor.submit(executor, "job-1", digest("b"), operation)

    assert Agent.get(mutations, & &1) == 0
    assert :ok = TestExecutor.continue(executor, "job-1")

    assert_receive {:elara_test_executor, "executor-1", "job-1",
                    {:completed, %Record{} = completed}}

    assert Agent.get(mutations, & &1) == 1

    assert {:completed, ^completed} =
             TestExecutor.submit(executor, "job-1", digest("a"), operation)

    assert {:completed, ^completed} = TestExecutor.query(executor, "job-1")

    assert {:error, :already_terminal} =
             TestExecutor.continue(executor, "job-1", digest("a"), operation)

    assert Agent.get(mutations, & &1) == 1
    assert :ok = TestExecutor.close(executor)
  end

  test "crash after receipt but before acceptance commit reopens as unknown", context do
    parent = self()

    hook = fn
      :after_receipt_before_accept_commit = point -> block(parent, point)
      _point -> :ok
    end

    executor = start_executor(context.path, hook)
    monitor = Process.monitor(executor)
    call_unlinked(fn -> TestExecutor.submit(executor, "job-1", digest("a"), ok_operation()) end)

    assert_receive {:hook, :after_receipt_before_accept_commit, ^executor}
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}
    assert_receive {:call_result, {:exit, _reason}}

    reopened = start_executor(context.path)
    assert :unknown = TestExecutor.query(reopened, "job-1")
    assert :ok = TestExecutor.close(reopened)
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
    call_unlinked(fn -> TestExecutor.submit(executor, "job-1", digest("a"), ok_operation()) end)

    assert_receive {:hook, :after_accept_commit_before_accept_reply, ^executor}
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}
    assert_receive {:call_result, {:exit, _reason}}

    reopened = start_executor(context.path)
    assert {:accepted, %Record{} = accepted} = TestExecutor.query(reopened, "job-1")
    assert accepted.admission_count == 1
    assert accepted.callback_attempt_count == 0
    assert accepted.terminal_count == 0
    assert :ok = TestExecutor.close(reopened)
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
             TestExecutor.submit(executor, "job-1", digest("a"), operation)

    assert :ok = TestExecutor.continue(executor, "job-1")
    assert_receive {:hook, :after_accept_reply_before_callback, ^executor}
    monitor = Process.monitor(executor)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}
    assert Agent.get(mutations, & &1) == 0

    reopened = start_executor(context.path)

    assert {:accepted, %Record{callback_attempt_count: 0}} =
             TestExecutor.query(reopened, "job-1")

    assert :ok = TestExecutor.continue(reopened, "job-1", digest("a"), operation)

    assert_receive {:elara_test_executor, "executor-1", "job-1",
                    {:completed, %Record{} = completed}}

    assert completed.admission_count == 1
    assert completed.callback_attempt_count == 1
    assert Agent.get(mutations, & &1) == 1
    assert :ok = TestExecutor.close(reopened)
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
    assert {:accepted, _accepted} = TestExecutor.submit(executor, "job-1", digest("a"), operation)
    assert :ok = TestExecutor.continue(executor, "job-1")

    assert_receive {:hook, :after_external_mutation_before_completion_commit, ^executor}
    assert Agent.get(mutations, & &1) == 1
    monitor = Process.monitor(executor)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}

    reopened = start_executor(context.path)
    assert {:accepted, %Record{} = attempted} = TestExecutor.query(reopened, "job-1")
    assert attempted.callback_attempt_count == 1
    assert attempted.terminal_count == 0
    assert attempted.result == nil
    assert ExecutorLedger.last_proven_fact(attempted) == :callback_invoked

    assert {:error, :callback_already_attempted} =
             TestExecutor.continue(reopened, "job-1", digest("a"), operation)

    refute_receive {:elara_test_executor, _, _, _}
    assert Agent.get(mutations, & &1) == 1
    assert :ok = TestExecutor.close(reopened)
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
    assert {:accepted, _accepted} = TestExecutor.submit(executor, "job-1", digest("a"), operation)
    assert :ok = TestExecutor.continue(executor, "job-1")

    assert_receive {:hook, :after_completion_commit_before_completion_reply, ^executor}
    assert Agent.get(mutations, & &1) == 1
    monitor = Process.monitor(executor)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}
    refute_receive {:elara_test_executor, _, _, _}

    reopened = start_executor(context.path)
    assert {:completed, %Record{} = completed} = TestExecutor.query(reopened, "job-1")
    assert completed.result == {:ok, "result"}
    assert completed.result_digest != nil
    assert completed.admission_count == 1
    assert completed.callback_attempt_count == 1
    assert completed.terminal_count == 1
    assert :ok = TestExecutor.close(reopened)
  end

  test "callback errors and crashes become durable failed evidence", context do
    executor = start_executor(context.path)

    assert {:accepted, _accepted} =
             TestExecutor.submit(executor, "job-error", digest("a"), fn -> {:error, "no"} end)

    assert :ok = TestExecutor.continue(executor, "job-error")

    assert_receive {:elara_test_executor, "executor-1", "job-error",
                    {:failed, %Record{} = failed}}

    assert failed.result == {:error, "no"}

    assert {:accepted, _accepted} =
             TestExecutor.submit(executor, "job-crash", digest("b"), fn -> raise "boom" end)

    assert :ok = TestExecutor.continue(executor, "job-crash")

    assert_receive {:elara_test_executor, "executor-1", "job-crash",
                    {:failed, %Record{} = crashed}}

    assert {:error, "callback crashed: boom"} = crashed.result
    assert :ok = TestExecutor.close(executor)
  end

  test "accepted jobs cannot fail over to a replacement executor identity", context do
    operation = ok_operation()
    original = start_executor(context.path)

    assert {:accepted, _accepted} =
             TestExecutor.submit(original, "job-1", digest("a"), operation)

    assert :ok = TestExecutor.close(original)
    replacement = start_executor(context.path, fn _point -> :ok end, "replacement")
    assert {:accepted, _accepted} = TestExecutor.query(replacement, "job-1")

    assert {:error, :wrong_executor} =
             TestExecutor.submit(replacement, "job-1", digest("a"), operation)

    assert {:error, :wrong_executor} =
             TestExecutor.continue(replacement, "job-1", digest("a"), operation)

    assert :ok = TestExecutor.close(replacement)
  end

  defp start_executor(path, hook \\ fn _point -> :ok end, id \\ "executor-1") do
    {:ok, executor} = TestExecutor.start_link(id: id, path: path, fault_hook: hook)
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
