defmodule Elara.Effect.ExecutorLedger do
  @moduledoc false

  alias Exqlite.Sqlite3

  @schema_version 1
  @result_digest_version 1

  defmodule Record do
    @moduledoc false

    @enforce_keys [
      :job_id,
      :operation_digest,
      :executor_id,
      :state,
      :admission_count,
      :callback_attempt_count,
      :terminal_count,
      :schema_version,
      :result_digest_version
    ]
    defstruct [
      :job_id,
      :operation_digest,
      :executor_id,
      :state,
      :result,
      :result_digest,
      :admission_count,
      :callback_attempt_count,
      :terminal_count,
      :schema_version,
      :result_digest_version
    ]

    @type t :: %__MODULE__{
            job_id: String.t(),
            operation_digest: String.t(),
            executor_id: String.t(),
            state: :accepted | :completed | :failed,
            result: {:ok | :error, term()} | nil,
            result_digest: String.t() | nil,
            admission_count: 1,
            callback_attempt_count: 0 | 1,
            terminal_count: 0 | 1,
            schema_version: pos_integer(),
            result_digest_version: pos_integer()
          }
  end

  @enforce_keys [:db, :path, :configuration]
  defstruct [:db, :path, :configuration]

  @type t :: %__MODULE__{
          db: Sqlite3.db(),
          path: String.t(),
          configuration: map()
        }

  @type fault_hook :: (atom() -> :ok)

  @spec open(String.t()) :: {:ok, t()} | {:error, term()}
  def open(path) when is_binary(path) do
    path = Path.expand(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, db} <- Sqlite3.open(path) do
      case initialize(db) do
        {:ok, configuration} ->
          :ok = File.chmod(path, 0o600)
          {:ok, %__MODULE__{db: db, path: path, configuration: configuration}}

        {:error, reason} ->
          Sqlite3.close(db)
          {:error, reason}
      end
    end
  end

  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{db: db}), do: Sqlite3.close(db)

  @spec admit(t(), String.t(), String.t(), String.t(), fault_hook()) ::
          {:ok, :new | :existing, Record.t()} | {:error, term()}
  def admit(ledger, executor_id, job_id, operation_digest, fault_hook \\ &no_fault/1)
      when is_binary(executor_id) and executor_id != "" and is_binary(job_id) and job_id != "" and
             is_binary(operation_digest) do
    if valid_digest?(operation_digest) do
      transaction(ledger, fn ->
        case select_one(ledger, job_id) do
          {:ok, nil} ->
            record = %Record{
              job_id: job_id,
              operation_digest: operation_digest,
              executor_id: executor_id,
              state: :accepted,
              admission_count: 1,
              callback_attempt_count: 0,
              terminal_count: 0,
              schema_version: @schema_version,
              result_digest_version: @result_digest_version
            }

            with :ok <- insert(ledger, record),
                 :ok <- invoke_hook(fault_hook, :after_receipt_before_accept_commit) do
              {:ok, {:new, record}}
            end

          {:ok, %Record{operation_digest: ^operation_digest, executor_id: ^executor_id} = record} ->
            {:ok, {:existing, record}}

          {:ok, %Record{operation_digest: ^operation_digest}} ->
            {:error, :wrong_executor}

          {:ok, %Record{}} ->
            {:error, :digest_conflict}

          {:error, _reason} = error ->
            error
        end
      end)
      |> case do
        {:ok, {kind, record}} -> {:ok, kind, record}
        error -> error
      end
    else
      {:error, :invalid_operation_digest}
    end
  end

  @spec query(t(), String.t()) :: {:ok, Record.t() | nil} | {:error, term()}
  def query(%__MODULE__{} = ledger, job_id) when is_binary(job_id) do
    select_one(ledger, job_id)
  end

  @spec begin_attempt(t(), String.t(), String.t(), String.t()) ::
          {:ok, Record.t()} | {:error, term()}
  def begin_attempt(ledger, executor_id, job_id, operation_digest) do
    transaction(ledger, fn ->
      with {:ok, %Record{} = record} <- require_record(ledger, job_id),
           :ok <- require_digest(record, operation_digest),
           :ok <- require_owner(record, executor_id),
           :ok <- require_attemptable(record),
           :ok <- update_attempt_count(ledger, job_id),
           {:ok, %Record{} = updated} <- select_one(ledger, job_id) do
        {:ok, updated}
      end
    end)
  end

  @spec finish(t(), String.t(), String.t(), String.t(), {:ok | :error, term()}) ::
          {:ok, Record.t()} | {:error, term()}
  def finish(ledger, executor_id, job_id, operation_digest, {kind, _payload} = result)
      when kind in [:ok, :error] do
    transaction(ledger, fn ->
      with {:ok, %Record{} = record} <- require_record(ledger, job_id),
           :ok <- require_digest(record, operation_digest),
           :ok <- require_owner(record, executor_id),
           :ok <- require_finishable(record),
           :ok <- update_terminal(ledger, job_id, result),
           {:ok, %Record{} = updated} <- select_one(ledger, job_id) do
        {:ok, updated}
      end
    end)
  end

  @spec last_proven_fact(Record.t()) :: :accepted | :callback_invoked | :completed | :failed
  def last_proven_fact(%Record{state: :accepted, callback_attempt_count: 0}), do: :accepted

  def last_proven_fact(%Record{state: :accepted, callback_attempt_count: 1}),
    do: :callback_invoked

  def last_proven_fact(%Record{state: state}) when state in [:completed, :failed], do: state

  defp initialize(db) do
    with :ok <- Sqlite3.execute(db, "PRAGMA journal_mode=WAL"),
         :ok <- Sqlite3.execute(db, "PRAGMA synchronous=FULL"),
         :ok <- Sqlite3.execute(db, "PRAGMA busy_timeout=1000"),
         {:ok, version} <- scalar(db, "PRAGMA user_version"),
         :ok <- initialize_schema(db, version),
         {:ok, journal_mode} <- scalar(db, "PRAGMA journal_mode"),
         {:ok, synchronous} <- scalar(db, "PRAGMA synchronous") do
      {:ok,
       %{
         journal_mode: journal_mode,
         synchronous: synchronous,
         schema_version: @schema_version
       }}
    end
  end

  defp initialize_schema(db, 0) do
    with :ok <- Sqlite3.execute(db, schema_sql()),
         :ok <- Sqlite3.execute(db, "PRAGMA user_version=#{@schema_version}") do
      :ok
    end
  end

  defp initialize_schema(db, @schema_version), do: Sqlite3.execute(db, schema_sql())
  defp initialize_schema(_db, version), do: {:error, {:unsupported_schema_version, version}}

  defp schema_sql do
    """
    CREATE TABLE IF NOT EXISTS executor_jobs (
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
  end

  defp insert(ledger, record) do
    sql = """
    INSERT INTO executor_jobs (
      job_id, operation_digest, executor_id, state, admission_count,
      callback_attempt_count, terminal_count, result, result_digest,
      schema_version, result_digest_version
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
    """

    values = [
      record.job_id,
      record.operation_digest,
      record.executor_id,
      Atom.to_string(record.state),
      record.admission_count,
      record.callback_attempt_count,
      record.terminal_count,
      nil,
      nil,
      record.schema_version,
      record.result_digest_version
    ]

    execute_statement(ledger, sql, values)
  end

  defp update_attempt_count(ledger, job_id) do
    sql = """
    UPDATE executor_jobs
    SET callback_attempt_count = 1
    WHERE job_id = ?1 AND state = 'accepted' AND callback_attempt_count = 0
    """

    execute_one_change(ledger, sql, [job_id])
  end

  defp update_terminal(ledger, job_id, {kind, _payload} = result) do
    state = if kind == :ok, do: "completed", else: "failed"

    sql = """
    UPDATE executor_jobs
    SET state = ?1, terminal_count = 1, result = ?2, result_digest = ?3
    WHERE job_id = ?4 AND state = 'accepted' AND callback_attempt_count = 1
    """

    values = [state, {:blob, encode(result)}, result_digest(result), job_id]
    execute_one_change(ledger, sql, values)
  end

  defp select_one(ledger, job_id) do
    sql = """
    SELECT job_id, operation_digest, executor_id, state, admission_count,
           callback_attempt_count, terminal_count, result, result_digest,
           schema_version, result_digest_version
    FROM executor_jobs
    WHERE job_id = ?1
    """

    with_statement(ledger, sql, fn statement ->
      with :ok <- Sqlite3.bind(statement, [job_id]) do
        case Sqlite3.step(ledger.db, statement) do
          {:row, row} -> decode_row(row)
          :done -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  defp decode_row([
         job_id,
         operation_digest,
         executor_id,
         state,
         admission_count,
         callback_attempt_count,
         terminal_count,
         result_binary,
         stored_result_digest,
         schema_version,
         result_digest_version
       ]) do
    with {:ok, state} <- decode_state(state),
         {:ok, result} <- decode_result(state, result_binary, stored_result_digest),
         true <-
           valid_record_values?(
             job_id,
             operation_digest,
             executor_id,
             state,
             result,
             admission_count,
             callback_attempt_count,
             terminal_count
           ),
         true <- schema_version == @schema_version,
         true <- result_digest_version == @result_digest_version do
      {:ok,
       %Record{
         job_id: job_id,
         operation_digest: operation_digest,
         executor_id: executor_id,
         state: state,
         result: result,
         result_digest: stored_result_digest,
         admission_count: admission_count,
         callback_attempt_count: callback_attempt_count,
         terminal_count: terminal_count,
         schema_version: schema_version,
         result_digest_version: result_digest_version
       }}
    else
      _ -> {:error, :invalid_executor_record}
    end
  rescue
    ArgumentError -> {:error, :invalid_executor_record}
  end

  defp decode_row(_row), do: {:error, :invalid_executor_record}

  defp decode_state("accepted"), do: {:ok, :accepted}
  defp decode_state("completed"), do: {:ok, :completed}
  defp decode_state("failed"), do: {:ok, :failed}
  defp decode_state(_state), do: {:error, :invalid_executor_record}

  defp decode_result(:accepted, nil, nil), do: {:ok, nil}

  defp decode_result(state, result_binary, stored_digest) when state in [:completed, :failed] do
    result = decode(result_binary)

    if result_digest(result) == stored_digest do
      {:ok, result}
    else
      {:error, :invalid_executor_record}
    end
  end

  defp decode_result(_state, _result_binary, _stored_digest),
    do: {:error, :invalid_executor_record}

  defp valid_record_values?(
         job_id,
         operation_digest,
         executor_id,
         state,
         result,
         1,
         callback_attempt_count,
         terminal_count
       )
       when is_binary(job_id) and job_id != "" and is_binary(executor_id) and executor_id != "" and
              callback_attempt_count in [0, 1] and terminal_count in [0, 1] do
    valid_digest?(operation_digest) and
      valid_state_values?(state, result, callback_attempt_count, terminal_count)
  end

  defp valid_record_values?(
         _job_id,
         _operation_digest,
         _executor_id,
         _state,
         _result,
         _admission_count,
         _callback_attempt_count,
         _terminal_count
       ),
       do: false

  defp valid_state_values?(:accepted, nil, callback_attempt_count, 0)
       when callback_attempt_count in [0, 1],
       do: true

  defp valid_state_values?(:completed, {:ok, _payload}, 1, 1), do: true
  defp valid_state_values?(:failed, {:error, _payload}, 1, 1), do: true
  defp valid_state_values?(_state, _result, _callback_attempt_count, _terminal_count), do: false

  defp require_record(ledger, job_id) do
    case select_one(ledger, job_id) do
      {:ok, nil} -> {:error, :unknown_job}
      other -> other
    end
  end

  defp require_digest(%Record{operation_digest: digest}, digest), do: :ok
  defp require_digest(%Record{}, _digest), do: {:error, :digest_conflict}

  defp require_owner(%Record{executor_id: executor_id}, executor_id), do: :ok
  defp require_owner(%Record{}, _executor_id), do: {:error, :wrong_executor}

  defp require_attemptable(%Record{state: :accepted, callback_attempt_count: 0}), do: :ok
  defp require_attemptable(%Record{state: :accepted}), do: {:error, :callback_already_attempted}
  defp require_attemptable(%Record{}), do: {:error, :already_terminal}

  defp require_finishable(%Record{state: :accepted, callback_attempt_count: 1}), do: :ok
  defp require_finishable(%Record{state: :accepted}), do: {:error, :callback_not_attempted}
  defp require_finishable(%Record{}), do: {:error, :already_terminal}

  defp transaction(ledger, fun) do
    with :ok <- Sqlite3.execute(ledger.db, "BEGIN IMMEDIATE") do
      try do
        case fun.() do
          {:ok, value} ->
            case Sqlite3.execute(ledger.db, "COMMIT") do
              :ok ->
                {:ok, value}

              {:error, _reason} = error ->
                rollback(ledger)
                error
            end

          {:error, _reason} = error ->
            rollback(ledger)
            error

          other ->
            rollback(ledger)
            {:error, {:invalid_transaction_result, other}}
        end
      catch
        kind, reason ->
          rollback(ledger)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp rollback(ledger) do
    Sqlite3.execute(ledger.db, "ROLLBACK")
    :ok
  end

  defp execute_one_change(ledger, sql, values) do
    with :ok <- execute_statement(ledger, sql, values),
         {:ok, 1} <- Sqlite3.changes(ledger.db) do
      :ok
    else
      {:ok, count} -> {:error, {:unexpected_change_count, count}}
      error -> error
    end
  end

  defp execute_statement(ledger, sql, values) do
    with_statement(ledger, sql, fn statement ->
      with :ok <- Sqlite3.bind(statement, values),
           :done <- Sqlite3.step(ledger.db, statement) do
        :ok
      end
    end)
  end

  defp scalar(db, sql) do
    case Sqlite3.prepare(db, sql) do
      {:ok, statement} ->
        try do
          case Sqlite3.step(db, statement) do
            {:row, [value]} -> {:ok, value}
            {:error, reason} -> {:error, reason}
            _other -> {:error, :invalid_pragma_result}
          end
        after
          Sqlite3.release(db, statement)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp with_statement(ledger, sql, fun) do
    case Sqlite3.prepare(ledger.db, sql) do
      {:ok, statement} ->
        try do
          fun.(statement)
        after
          Sqlite3.release(ledger.db, statement)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp invoke_hook(hook, point) do
    case hook.(point) do
      :ok -> :ok
      other -> {:error, {:invalid_fault_hook_return, other}}
    end
  end

  defp result_digest(result) do
    {:elara_er1_result, @result_digest_version, result}
    |> encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp valid_digest?(digest) when is_binary(digest) and byte_size(digest) == 64 do
    String.match?(digest, ~r/\A[0-9a-f]{64}\z/)
  end

  defp valid_digest?(_digest), do: false

  defp encode(term), do: :erlang.term_to_binary(term, [:deterministic])
  defp decode(binary), do: :erlang.binary_to_term(binary, [:safe])
  defp no_fault(_point), do: :ok
end
