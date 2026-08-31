defmodule Elara.Effect.ControllerJournal do
  @moduledoc false

  use GenServer

  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Effect.Job
  alias Exqlite.Sqlite3

  @schema_version 2

  defmodule State do
    @moduledoc false
    defstruct [:db, :path, :configuration]
  end

  defmodule Observation do
    @moduledoc false

    @enforce_keys [:job_id, :operation_digest, :executor_record]
    defstruct [:job_id, :operation_digest, :executor_record, result_persisted?: false]

    @type t :: %__MODULE__{
            job_id: String.t(),
            operation_digest: String.t(),
            executor_record: Record.t(),
            result_persisted?: boolean()
          }
  end

  @type fault_hook :: (atom() -> :ok)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :path))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    path = Keyword.fetch!(opts, :path)

    %{
      id: {__MODULE__, Path.expand(path)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @spec commit_intent(GenServer.server(), Job.t(), fault_hook()) ::
          {:ok, Job.t()} | {:error, term()}
  def commit_intent(journal, %Job{} = job, fault_hook \\ &no_fault/1) do
    GenServer.call(journal, {:commit_intent, job, fault_hook}, :infinity)
  end

  @spec get(GenServer.server(), String.t()) :: {:ok, Job.t() | nil} | {:error, term()}
  def get(journal, job_id), do: GenServer.call(journal, {:get, job_id})

  @spec all(GenServer.server()) :: {:ok, [Job.t()]} | {:error, term()}
  def all(journal), do: GenServer.call(journal, :all)

  @spec observe(GenServer.server(), Record.t()) :: {:ok, Observation.t()} | {:error, term()}
  def observe(journal, %Record{} = record) do
    GenServer.call(journal, {:observe, record})
  end

  @spec observation(GenServer.server(), String.t()) ::
          {:ok, Observation.t() | nil} | {:error, term()}
  def observation(journal, job_id), do: GenServer.call(journal, {:observation, job_id})

  @spec mark_result_persisted(GenServer.server(), String.t()) ::
          {:ok, Observation.t()} | {:error, term()}
  def mark_result_persisted(journal, job_id) do
    GenServer.call(journal, {:mark_result_persisted, job_id})
  end

  @spec configuration(GenServer.server()) :: map()
  def configuration(journal), do: GenServer.call(journal, :configuration)

  @spec close(GenServer.server()) :: :ok
  def close(journal), do: GenServer.stop(journal, :normal)

  @impl true
  def init(path) do
    case open(path) do
      {:ok, db, configuration} ->
        {:ok, %State{db: db, path: path, configuration: configuration}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:commit_intent, job, fault_hook}, _from, state) do
    case commit_transaction(state.db, job, fault_hook) do
      {:ok, committed} ->
        :ok = fault_hook.(:after_intent_commit_before_dispatch)
        {:reply, {:ok, committed}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:get, job_id}, _from, state) do
    {:reply, select_one(state.db, job_id), state}
  end

  def handle_call(:all, _from, state) do
    {:reply, select_all(state.db), state}
  end

  def handle_call({:observe, record}, _from, state) do
    {:reply, observe_transaction(state.db, record), state}
  end

  def handle_call({:observation, job_id}, _from, state) do
    {:reply, select_observation(state.db, job_id), state}
  end

  def handle_call({:mark_result_persisted, job_id}, _from, state) do
    {:reply, persist_result_transaction(state.db, job_id), state}
  end

  def handle_call(:configuration, _from, state) do
    {:reply, state.configuration, state}
  end

  @impl true
  def terminate(_reason, %State{db: db}) do
    Sqlite3.close(db)
    :ok
  end

  defp open(path) do
    path = Path.expand(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, db} <- Sqlite3.open(path) do
      case initialize(db) do
        {:ok, configuration} ->
          :ok = File.chmod(path, 0o600)
          {:ok, db, configuration}

        {:error, reason} ->
          Sqlite3.close(db)
          {:error, reason}
      end
    end
  end

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
    with :ok <- ensure_schema(db),
         :ok <- Sqlite3.execute(db, "PRAGMA user_version=#{@schema_version}") do
      :ok
    end
  end

  defp initialize_schema(db, 1) do
    with :ok <- Sqlite3.execute(db, observation_schema_sql()),
         :ok <- Sqlite3.execute(db, "PRAGMA user_version=#{@schema_version}") do
      :ok
    end
  end

  defp initialize_schema(db, @schema_version), do: ensure_schema(db)
  defp initialize_schema(_db, version), do: {:error, {:unsupported_schema_version, version}}

  defp ensure_schema(db) do
    with :ok <- Sqlite3.execute(db, intent_schema_sql()),
         :ok <- Sqlite3.execute(db, observation_schema_sql()) do
      :ok
    end
  end

  defp intent_schema_sql do
    """
    CREATE TABLE IF NOT EXISTS controller_intents (
      job_id TEXT PRIMARY KEY,
      job_id_version INTEGER NOT NULL,
      operation_digest TEXT NOT NULL,
      digest_version INTEGER NOT NULL,
      schema_version INTEGER NOT NULL,
      state TEXT NOT NULL CHECK (state = 'intent'),
      workspace_id TEXT NOT NULL,
      authority_metadata BLOB NOT NULL,
      job BLOB NOT NULL,
      UNIQUE (job_id, operation_digest)
    ) STRICT
    """
  end

  defp observation_schema_sql do
    """
    CREATE TABLE IF NOT EXISTS controller_observations (
      job_id TEXT PRIMARY KEY,
      operation_digest TEXT NOT NULL,
      executor_record BLOB NOT NULL,
      result_persisted INTEGER NOT NULL CHECK (result_persisted IN (0, 1)),
      FOREIGN KEY (job_id) REFERENCES controller_intents(job_id)
    ) STRICT
    """
  end

  defp commit_transaction(db, job, fault_hook) do
    with :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      result =
        with {:ok, committed} <- insert_or_load(db, job),
             :ok <- fault_hook.(:before_intent_commit),
             :ok <- Sqlite3.execute(db, "COMMIT") do
          {:ok, committed}
        end

      case result do
        {:ok, _committed} = ok ->
          ok

        {:error, _reason} = error ->
          Sqlite3.execute(db, "ROLLBACK")
          error

        other ->
          Sqlite3.execute(db, "ROLLBACK")
          {:error, {:invalid_fault_hook_return, other}}
      end
    end
  end

  defp insert_or_load(db, job) do
    case select_one(db, job.job_id) do
      {:ok, nil} -> insert(db, job)
      {:ok, ^job} -> {:ok, job}
      {:ok, existing} -> {:error, {:job_id_conflict, existing.operation_digest}}
      {:error, _reason} = error -> error
    end
  end

  defp insert(db, job) do
    sql = """
    INSERT INTO controller_intents (
      job_id, job_id_version, operation_digest, digest_version, schema_version,
      state, workspace_id, authority_metadata, job
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
    """

    authority_metadata = %{
      required_capabilities: job.required_capabilities,
      authority_scope: job.authority_scope
    }

    values = [
      job.job_id,
      job.job_id_version,
      job.operation_digest,
      job.digest_version,
      job.schema_version,
      Atom.to_string(job.state),
      job.workspace_id,
      {:blob, encode(authority_metadata)},
      {:blob, encode(job)}
    ]

    with_statement(db, sql, fn statement ->
      with :ok <- Sqlite3.bind(statement, values),
           :done <- Sqlite3.step(db, statement) do
        {:ok, job}
      end
    end)
  end

  defp observe_transaction(db, %Record{} = record) do
    transaction(db, fn ->
      with {:ok, %Job{} = job} <- require_job(db, record.job_id),
           :ok <- require_observation_identity(job, record),
           {:ok, existing} <- select_observation(db, record.job_id),
           :ok <- require_observation_advance(existing, record),
           :ok <- upsert_observation(db, existing, record),
           {:ok, %Observation{} = observation} <- select_observation(db, record.job_id) do
        {:ok, observation}
      end
    end)
  end

  defp persist_result_transaction(db, job_id) do
    transaction(db, fn ->
      with {:ok, %Observation{}} <- require_observation(db, job_id),
           :ok <- update_result_persisted(db, job_id),
           {:ok, %Observation{} = updated} <- select_observation(db, job_id) do
        {:ok, updated}
      end
    end)
  end

  defp upsert_observation(db, existing, record) do
    result_persisted = if match?(%Observation{result_persisted?: true}, existing), do: 1, else: 0

    sql = """
    INSERT INTO controller_observations (
      job_id, operation_digest, executor_record, result_persisted
    ) VALUES (?1, ?2, ?3, ?4)
    ON CONFLICT(job_id) DO UPDATE SET
      operation_digest = excluded.operation_digest,
      executor_record = excluded.executor_record,
      result_persisted = controller_observations.result_persisted
    """

    execute_statement(db, sql, [
      record.job_id,
      record.operation_digest,
      {:blob, encode(record)},
      result_persisted
    ])
  end

  defp update_result_persisted(db, job_id) do
    execute_statement(
      db,
      "UPDATE controller_observations SET result_persisted = 1 WHERE job_id = ?1",
      [job_id]
    )
  end

  defp select_one(db, job_id) do
    sql = """
    SELECT job_id, job_id_version, operation_digest, digest_version, schema_version,
           state, workspace_id, authority_metadata, job
    FROM controller_intents
    WHERE job_id = ?1
    """

    with_statement(db, sql, fn statement ->
      with :ok <- Sqlite3.bind(statement, [job_id]) do
        case Sqlite3.step(db, statement) do
          {:row, row} -> decode_row(row)
          :done -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  defp select_all(db) do
    sql = """
    SELECT job_id, job_id_version, operation_digest, digest_version, schema_version,
           state, workspace_id, authority_metadata, job
    FROM controller_intents
    ORDER BY job_id
    """

    with_statement(db, sql, fn statement ->
      with {:ok, rows} <- Sqlite3.fetch_all(db, statement) do
        Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, jobs} ->
          case decode_row(row) do
            {:ok, job} -> {:cont, {:ok, [job | jobs]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
          error -> error
        end
      end
    end)
  end

  defp select_observation(db, job_id) do
    sql = """
    SELECT job_id, operation_digest, executor_record, result_persisted
    FROM controller_observations
    WHERE job_id = ?1
    """

    with_statement(db, sql, fn statement ->
      with :ok <- Sqlite3.bind(statement, [job_id]) do
        case Sqlite3.step(db, statement) do
          {:row, row} -> decode_observation(row)
          :done -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  defp decode_row([
         job_id,
         job_id_version,
         operation_digest,
         digest_version,
         schema_version,
         "intent",
         workspace_id,
         authority_binary,
         job_binary
       ]) do
    authority_metadata = decode(authority_binary)
    job = decode(job_binary)

    if match?(%Job{}, job) and
         job.job_id == job_id and
         job.job_id_version == job_id_version and
         job.operation_digest == operation_digest and
         job.digest_version == digest_version and
         job.schema_version == schema_version and
         job.state == :intent and
         job.workspace_id == workspace_id and
         authority_metadata == %{
           required_capabilities: job.required_capabilities,
           authority_scope: job.authority_scope
         } do
      {:ok, job}
    else
      {:error, :invalid_intent_record}
    end
  rescue
    ArgumentError -> {:error, :invalid_intent_record}
  end

  defp decode_row(_row), do: {:error, :invalid_intent_record}

  defp decode_observation([job_id, operation_digest, record_binary, result_persisted])
       when result_persisted in [0, 1] do
    record = decode(record_binary)

    if match?(%Record{}, record) and record.job_id == job_id and
         record.operation_digest == operation_digest do
      {:ok,
       %Observation{
         job_id: job_id,
         operation_digest: operation_digest,
         executor_record: record,
         result_persisted?: result_persisted == 1
       }}
    else
      {:error, :invalid_observation_record}
    end
  rescue
    ArgumentError -> {:error, :invalid_observation_record}
  end

  defp decode_observation(_row), do: {:error, :invalid_observation_record}

  defp require_job(db, job_id) do
    case select_one(db, job_id) do
      {:ok, nil} -> {:error, :unknown_job}
      other -> other
    end
  end

  defp require_observation(db, job_id) do
    case select_observation(db, job_id) do
      {:ok, nil} -> {:error, :observation_missing}
      other -> other
    end
  end

  defp require_observation_identity(
         %Job{job_id: job_id, operation_digest: operation_digest},
         %Record{job_id: job_id, operation_digest: operation_digest}
       ),
       do: :ok

  defp require_observation_identity(%Job{}, %Record{}), do: {:error, :observation_conflict}

  defp require_observation_advance(nil, %Record{}), do: :ok

  defp require_observation_advance(
         %Observation{executor_record: existing},
         %Record{} = record
       ) do
    cond do
      existing == record ->
        :ok

      existing.executor_id != record.executor_id ->
        {:error, :observation_conflict}

      observation_rank(record) > observation_rank(existing) ->
        :ok

      true ->
        {:error, :stale_observation}
    end
  end

  defp observation_rank(%Record{state: :accepted, callback_attempt_count: 0}), do: 0
  defp observation_rank(%Record{state: :accepted, callback_attempt_count: 1}), do: 1
  defp observation_rank(%Record{state: state}) when state in [:completed, :failed], do: 2

  defp transaction(db, fun) do
    with :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      try do
        case fun.() do
          {:ok, value} ->
            case Sqlite3.execute(db, "COMMIT") do
              :ok ->
                {:ok, value}

              {:error, _reason} = error ->
                rollback(db)
                error
            end

          {:error, _reason} = error ->
            rollback(db)
            error

          other ->
            rollback(db)
            {:error, {:invalid_transaction_result, other}}
        end
      catch
        kind, reason ->
          rollback(db)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp rollback(db) do
    Sqlite3.execute(db, "ROLLBACK")
    :ok
  end

  defp execute_statement(db, sql, values) do
    with_statement(db, sql, fn statement ->
      with :ok <- Sqlite3.bind(statement, values),
           :done <- Sqlite3.step(db, statement) do
        :ok
      end
    end)
  end

  defp scalar(db, sql) do
    with_statement(db, sql, fn statement ->
      case Sqlite3.step(db, statement) do
        {:row, [value]} -> {:ok, value}
        {:error, reason} -> {:error, reason}
        _other -> {:error, :invalid_pragma_result}
      end
    end)
  end

  defp with_statement(db, sql, fun) do
    case Sqlite3.prepare(db, sql) do
      {:ok, statement} ->
        try do
          fun.(statement)
        after
          Sqlite3.release(db, statement)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp encode(term), do: :erlang.term_to_binary(term, [:deterministic])
  defp decode(binary), do: :erlang.binary_to_term(binary, [:safe])
  defp no_fault(_point), do: :ok
end
