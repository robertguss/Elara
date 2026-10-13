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
             schema_version: 4,
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
    assert accepted.schema_version == 4
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

  test "rejection fails only an unstarted job, retaining its receipt across reopen", context do
    ledger = open_ledger(context.path)
    {:ok, :new, _} = ExecutorLedger.admit(ledger, "owner", "unstarted", digest("a"))
    {:ok, :new, _} = ExecutorLedger.admit(ledger, "owner", "attempted", digest("b"))
    {:ok, attempted} = ExecutorLedger.begin_attempt(ledger, "owner", "attempted", digest("b"))

    assert {:error, :wrong_executor} =
             ExecutorLedger.reject(ledger, "other", "unstarted", digest("a"), "refused")

    assert {:error, :digest_conflict} =
             ExecutorLedger.reject(ledger, "owner", "unstarted", digest("c"), "refused")

    assert {:error, :callback_already_attempted} =
             ExecutorLedger.reject(ledger, "owner", "attempted", digest("b"), "refused")

    assert {:ok, ^attempted} = ExecutorLedger.query(ledger, "attempted")

    assert {:ok, %Record{state: :failed, callback_attempt_count: 0, terminal_count: 1} = refused} =
             ExecutorLedger.reject(ledger, "owner", "unstarted", digest("a"), "refused")

    assert refused.result == {:error, "refused"}

    assert {:error, :already_terminal} =
             ExecutorLedger.reject(ledger, "owner", "unstarted", digest("a"), "different")

    :ok = ExecutorLedger.close(ledger)
    reopened = open_ledger(context.path)
    assert {:ok, ^refused} = ExecutorLedger.query(reopened, "unstarted")
    assert {:ok, ^attempted} = ExecutorLedger.query(reopened, "attempted")
    :ok = ExecutorLedger.close(reopened)
  end

  defp digest(character), do: String.duplicate(character, 64)

  @v1_schema """
  CREATE TABLE executor_jobs (
    job_id TEXT PRIMARY KEY,
    operation_digest TEXT NOT NULL,
    executor_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('accepted', 'completed', 'failed')),
    admission_count INTEGER NOT NULL CHECK (admission_count = 1),
    callback_attempt_count INTEGER NOT NULL CHECK (callback_attempt_count IN (0, 1)),
    terminal_count INTEGER NOT NULL CHECK (terminal_count IN (0, 1)),
    result BLOB,
    result_digest TEXT,
    schema_version INTEGER NOT NULL,
    result_digest_version INTEGER NOT NULL,
    UNIQUE (job_id, operation_digest),
    CHECK (
      (state = 'accepted' AND terminal_count = 0 AND result IS NULL AND result_digest IS NULL) OR
      (state IN ('completed', 'failed') AND callback_attempt_count = 1 AND
        terminal_count = 1 AND result IS NOT NULL AND result_digest IS NOT NULL)
    )
  ) STRICT
  """

  for legacy_version <- [1, 2, 3] do
    @legacy_version legacy_version
    test "a schema #{@legacy_version} ledger migrates in place, preserving rows and digests",
         context do
      alias Exqlite.Sqlite3

      legacy_version = @legacy_version
      {:ok, db} = Sqlite3.open(context.path)

      schema =
        if legacy_version == 1,
          do: @v1_schema,
          else: String.replace(@v1_schema, "'failed'", "'failed', 'indeterminate'")

      :ok = Sqlite3.execute(db, schema)

      if legacy_version == 3,
        do:
          assert(
            :ok ==
              Sqlite3.execute(db, "ALTER TABLE executor_jobs ADD COLUMN attempt_incarnation TEXT")
          )

      rows = [
        {"job-accepted", "a", "accepted", 0, 0, nil},
        {"job-invoked", "b", "accepted", 1, 0, nil},
        {"job-done", "c", "completed", 1, 1, {:ok, "done"}},
        {"job-failed", "d", "failed", 1, 1, {:error, "no"}}
      ]

      for {job, seed, state, attempts, terminal, result} <- rows do
        {blob, result_digest} =
          if result,
            do: {{:blob, :erlang.term_to_binary(result, [:deterministic])}, v1_digest(result)},
            else: {nil, nil}

        {:ok, statement} =
          Sqlite3.prepare(
            db,
            "INSERT INTO executor_jobs (job_id, operation_digest, executor_id, state, admission_count, " <>
              "callback_attempt_count, terminal_count, result, result_digest, schema_version, result_digest_version) " <>
              "VALUES (?1, ?2, ?3, ?4, 1, ?5, ?6, ?7, ?8, #{legacy_version}, 1)"
          )

        :ok =
          Sqlite3.bind(statement, [
            job,
            digest(seed),
            "executor-1",
            state,
            attempts,
            terminal,
            blob,
            result_digest
          ])

        :done = Sqlite3.step(db, statement)
        :ok = Sqlite3.release(db, statement)
      end

      incarnation = if legacy_version == 3, do: "preserved-incarnation", else: nil

      if incarnation,
        do:
          assert(
            :ok ==
              Sqlite3.execute(
                db,
                "UPDATE executor_jobs SET attempt_incarnation = '#{incarnation}' WHERE callback_attempt_count = 1"
              )
          )

      :ok = Sqlite3.execute(db, "PRAGMA user_version=#{legacy_version}")
      :ok = Sqlite3.close(db)

      ledger = open_ledger(context.path)
      assert ledger.configuration.schema_version == 4

      assert {:ok, %Record{state: :completed, result: {:ok, "done"}} = done} =
               ExecutorLedger.query(ledger, "job-done")

      assert done.schema_version == legacy_version
      assert done.attempt_incarnation == incarnation
      assert done.result_digest == v1_digest({:ok, "done"})

      assert {:ok, %Record{state: :failed, result: {:error, "no"}}} =
               ExecutorLedger.query(ledger, "job-failed")

      assert {:ok, %Record{state: :accepted, callback_attempt_count: 0}} =
               ExecutorLedger.query(ledger, "job-accepted")

      # A legacy job in flight at migration can still end uncertain.
      assert {:ok,
              %Record{
                state: :indeterminate,
                schema_version: ^legacy_version,
                attempt_incarnation: ^incarnation
              }} =
               ExecutorLedger.finish(
                 ledger,
                 "executor-1",
                 "job-invoked",
                 digest("b"),
                 {:indeterminate, "lost"}
               )

      # New admissions use schema 4; the rebuilt table still enforces its constraints.
      assert {:ok, :new, %Record{schema_version: 4}} =
               ExecutorLedger.admit(ledger, "executor-1", "job-new", digest("e"))

      assert {:error, _constraint} =
               Sqlite3.execute(
                 ledger.db,
                 "UPDATE executor_jobs SET state = 'bogus' WHERE job_id = 'job-new'"
               )

      :ok = ExecutorLedger.close(ledger)

      reopened = open_ledger(context.path)

      assert {:ok, %Record{state: :indeterminate, result: {:indeterminate, "lost"}}} =
               ExecutorLedger.query(reopened, "job-invoked")

      {:ok, [[version]]} = pragma(reopened.db, "PRAGMA user_version")
      assert version == 4
      :ok = ExecutorLedger.close(reopened)
    end
  end

  test "malformed ownership evidence cannot terminalize an attempted job", context do
    owner = Elara.Effect.Ownership.writer()
    proof = owner |> Base.decode64!() |> :erlang.binary_to_term([:safe])

    malformed = [
      put_in(proof, ["vm", "os_pid"], "not-a-pid"),
      Map.update!(
        proof,
        "vm",
        &(Map.drop(&1, ["nonce", "node"]) |> Map.put("boot", "unsupported-boot"))
      ),
      Map.put(proof, "callback", "not-an-erlang-pid")
    ]

    for {proof, index} <- Enum.with_index(malformed) do
      ledger = open_ledger(context.path <> "-#{index}")
      incarnation = proof |> :erlang.term_to_binary() |> Base.encode64()
      assert {:ok, :new, _} = ExecutorLedger.admit(ledger, "executor-1", "job", digest("a"))

      assert {:ok, _} =
               ExecutorLedger.begin_attempt(ledger, "executor-1", "job", digest("a"), incarnation)

      assert {:error, {:effect_ownership_unknown, _}} = ExecutorLedger.claim_writer(ledger, owner)

      assert {:ok, %Record{state: :accepted, callback_attempt_count: 1, terminal_count: 0}} =
               ExecutorLedger.query(ledger, "job")

      :ok = ExecutorLedger.close(ledger)
    end
  end

  defp v1_digest(result) do
    {:elara_er1_result, 1, result}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp pragma(db, sql) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, sql)
    {:row, row} = Exqlite.Sqlite3.step(db, statement)
    :ok = Exqlite.Sqlite3.release(db, statement)
    {:ok, [row]}
  end
end
