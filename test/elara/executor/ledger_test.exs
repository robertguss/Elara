defmodule Elara.Effect.ExecutorLedgerTest do
  use ExUnit.Case, async: false

  alias Elara.Effect.ExecutorLedger
  alias Elara.Effect.ExecutorLedger.Record

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-executor-ledger-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: Path.join(root, "executor.sqlite3")}
  end

  test "admission is durable, idempotent, and digest-bound", context do
    ledger = open_ledger(context.path)
    parent = self()

    hook = fn point ->
      send(parent, {:hook, point})
      :ok
    end

    assert ledger.configuration == %{
             journal_mode: "wal",
             schema_version: 1,
             synchronous: 2
           }

    assert {:ok, nil} = ExecutorLedger.query(ledger, "job-1")

    assert {:ok, :new, %Record{} = accepted} =
             ExecutorLedger.admit(ledger, "executor-1", "job-1", digest("a"), hook)

    assert_receive {:hook, :after_receipt_before_accept_commit}
    assert accepted.state == :accepted
    assert accepted.admission_count == 1
    assert accepted.callback_attempt_count == 0
    assert accepted.terminal_count == 0
    assert accepted.schema_version == 1
    assert accepted.result_digest_version == 1

    assert {:ok, :existing, ^accepted} =
             ExecutorLedger.admit(ledger, "executor-1", "job-1", digest("a"), hook)

    refute_receive {:hook, _point}

    assert {:error, :digest_conflict} =
             ExecutorLedger.admit(ledger, "executor-1", "job-1", digest("b"), hook)

    assert {:error, :wrong_executor} =
             ExecutorLedger.admit(ledger, "replacement", "job-1", digest("a"), hook)

    assert {:error, :invalid_operation_digest} =
             ExecutorLedger.admit(ledger, "executor-1", "job-2", "not-a-digest", hook)

    assert :ok = ExecutorLedger.close(ledger)

    reopened = open_ledger(context.path)
    assert {:ok, ^accepted} = ExecutorLedger.query(reopened, "job-1")
    assert :ok = ExecutorLedger.close(reopened)
  end

  test "callback attempt and terminal result commit as separate facts", context do
    ledger = open_ledger(context.path)

    assert {:ok, :new, accepted} =
             ExecutorLedger.admit(ledger, "executor-1", "job-1", digest("a"))

    assert ExecutorLedger.last_proven_fact(accepted) == :accepted

    assert {:ok, %Record{} = attempted} =
             ExecutorLedger.begin_attempt(ledger, "executor-1", "job-1", digest("a"))

    assert attempted.state == :accepted
    assert attempted.callback_attempt_count == 1
    assert attempted.terminal_count == 0
    assert attempted.result == nil
    assert ExecutorLedger.last_proven_fact(attempted) == :callback_invoked

    assert {:error, :callback_already_attempted} =
             ExecutorLedger.begin_attempt(ledger, "executor-1", "job-1", digest("a"))

    assert {:ok, %Record{} = completed} =
             ExecutorLedger.finish(
               ledger,
               "executor-1",
               "job-1",
               digest("a"),
               {:ok, "result"}
             )

    assert completed.state == :completed
    assert completed.result == {:ok, "result"}
    assert completed.terminal_count == 1
    assert byte_size(completed.result_digest) == 64
    assert ExecutorLedger.last_proven_fact(completed) == :completed

    assert {:error, :already_terminal} =
             ExecutorLedger.finish(
               ledger,
               "executor-1",
               "job-1",
               digest("a"),
               {:ok, "again"}
             )

    assert :ok = ExecutorLedger.close(ledger)

    reopened = open_ledger(context.path)
    assert {:ok, ^completed} = ExecutorLedger.query(reopened, "job-1")
    assert :ok = ExecutorLedger.close(reopened)
  end

  test "failed evidence is terminal and survives connection restart", context do
    ledger = open_ledger(context.path)

    assert {:ok, :new, _accepted} =
             ExecutorLedger.admit(ledger, "executor-1", "job-1", digest("a"))

    assert {:ok, _attempted} =
             ExecutorLedger.begin_attempt(ledger, "executor-1", "job-1", digest("a"))

    assert {:ok, %Record{} = failed} =
             ExecutorLedger.finish(
               ledger,
               "executor-1",
               "job-1",
               digest("a"),
               {:error, "failed"}
             )

    assert failed.state == :failed
    assert failed.result == {:error, "failed"}
    assert failed.admission_count == 1
    assert failed.callback_attempt_count == 1
    assert failed.terminal_count == 1
    assert ExecutorLedger.last_proven_fact(failed) == :failed

    assert :ok = ExecutorLedger.close(ledger)
    reopened = open_ledger(context.path)
    assert {:ok, ^failed} = ExecutorLedger.query(reopened, "job-1")
    assert :ok = ExecutorLedger.close(reopened)
  end

  test "accepted proof never authorizes another executor or an attempted callback", context do
    ledger = open_ledger(context.path)

    assert {:ok, :new, _accepted} =
             ExecutorLedger.admit(ledger, "executor-1", "job-1", digest("a"))

    assert {:error, :wrong_executor} =
             ExecutorLedger.begin_attempt(ledger, "replacement", "job-1", digest("a"))

    assert {:error, :digest_conflict} =
             ExecutorLedger.begin_attempt(ledger, "executor-1", "job-1", digest("b"))

    assert {:ok, attempted} =
             ExecutorLedger.begin_attempt(ledger, "executor-1", "job-1", digest("a"))

    assert ExecutorLedger.last_proven_fact(attempted) == :callback_invoked
    assert attempted.state == :accepted
    assert attempted.result == nil
    assert attempted.result_digest == nil

    assert :ok = ExecutorLedger.close(ledger)
    reopened = open_ledger(context.path)
    assert {:ok, ^attempted} = ExecutorLedger.query(reopened, "job-1")

    assert {:error, :callback_already_attempted} =
             ExecutorLedger.begin_attempt(reopened, "executor-1", "job-1", digest("a"))

    assert :ok = ExecutorLedger.close(reopened)
  end

  defp open_ledger(path) do
    {:ok, ledger} = ExecutorLedger.open(path)
    ledger
  end

  defp digest(character), do: String.duplicate(character, 64)
end
