defmodule Elara.Exec do
  @moduledoc "Supervised owner of the bounded Rust command-execution stub."

  use GenServer

  @protocol_version 1
  @handshake_timeout_ms 2_000
  @restart_delay_ms 100

  defmodule Result do
    @moduledoc "Terminal command result reported by the execution stub."

    @enforce_keys [
      :output,
      :code,
      :signal,
      :termination,
      :bytes_total,
      :bytes_sent,
      :elapsed_ms
    ]
    defstruct [
      :output,
      :code,
      :signal,
      :termination,
      :bytes_total,
      :bytes_sent,
      :elapsed_ms
    ]

    @type termination :: :exited | :cancelled | :timed_out | :truncated
    @type t :: %__MODULE__{
            output: binary(),
            code: non_neg_integer() | nil,
            signal: pos_integer() | nil,
            termination: termination(),
            bytes_total: non_neg_integer(),
            bytes_sent: non_neg_integer(),
            elapsed_ms: non_neg_integer()
          }
  end

  @type run_error :: {:not_started, String.t()}
  @type run_result :: {:ok, Result.t()} | {:error, run_error()} | {:indeterminate, String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec run([String.t()], keyword()) :: run_result()
  def run(argv, opts \\ []) do
    GenServer.call(__MODULE__, {:run, argv, opts}, :infinity)
  end

  @doc false
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    binary = Keyword.get_lazy(opts, :binary, &binary_path/0)

    case open_stub(binary) do
      {:ok, port, os_pid, buffer} ->
        {:ok, initial_state(binary, port, os_pid, buffer)}

      {:error, reason} ->
        {:stop, {:exec_stub_unavailable, reason}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
    :ok
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       available: not is_nil(state.port),
       generation: state.generation,
       os_pid: state.os_pid,
       jobs: map_size(state.jobs)
     }, state}
  end

  def handle_call({:run, argv, opts}, _from, %{port: nil} = state) do
    case validate_run(argv, opts) do
      {:ok, _request} ->
        {:reply, {:error, {:not_started, "execution stub is restarting"}}, state}

      {:error, message} ->
        {:reply, {:error, {:not_started, message}}, state}
    end
  end

  def handle_call({:run, argv, opts}, from, state) do
    case validate_run(argv, opts) do
      {:ok, request} ->
        id = job_id(state.generation)
        owner = elem(from, 0)
        monitor = Process.monitor(owner)

        job = %{
          from: from,
          monitor: monitor,
          phase: :submitted,
          chunks: [],
          bytes_seen: 0,
          max_bytes: request.max_bytes
        }

        jobs = Map.put(state.jobs, id, job)
        monitors = Map.put(state.monitors, monitor, id)
        state = %{state | jobs: jobs, monitors: monitors}

        command = %{
          "id" => id,
          "op" => "run",
          "argv" => request.argv,
          "cwd" => request.cwd,
          "env" => request.env,
          "max_bytes" => request.max_bytes,
          "timeout_ms" => request.timeout_ms
        }

        if send_command(state.port, command) do
          {:noreply, state}
        else
          {:noreply, replace_stub(state, "request submission failed")}
        end

      {:error, message} ->
        {:reply, {:error, {:not_started, message}}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case process_data(%{state | buffer: state.buffer <> data}) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:noreply, replace_stub(state, reason)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:noreply, replace_stub(state, "stub exited with status #{status}")}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:noreply, replace_stub(state, "stub port closed: #{inspect(reason)}")}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {id, monitors} ->
        case Map.fetch(state.jobs, id) do
          {:ok, job} ->
            job = %{job | from: nil, chunks: []}
            state = %{state | jobs: Map.put(state.jobs, id, job), monitors: monitors}

            if send_command(state.port, %{"id" => id, "op" => "cancel"}) do
              {:noreply, state}
            else
              {:noreply, replace_stub(state, "cancellation submission failed")}
            end

          :error ->
            {:noreply, %{state | monitors: monitors}}
        end
    end
  end

  def handle_info(:restart_stub, %{port: nil} = state) do
    case open_stub(state.binary) do
      {:ok, port, os_pid, buffer} ->
        {:noreply, %{state | port: port, os_pid: os_pid, buffer: buffer}}

      {:error, _reason} ->
        Process.send_after(self(), :restart_stub, @restart_delay_ms)
        {:noreply, state}
    end
  end

  def handle_info(:restart_stub, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp initial_state(binary, port, os_pid, buffer) do
    %{
      binary: binary,
      port: port,
      os_pid: os_pid,
      generation: 1,
      buffer: buffer,
      jobs: %{},
      monitors: %{}
    }
  end

  defp validate_run(argv, opts) do
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)
    env = Keyword.get(opts, :env, %{})
    max_bytes = Keyword.get(opts, :max_bytes, 16_384)
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    cond do
      not (is_list(argv) and argv != [] and Enum.all?(argv, &valid_string?/1)) ->
        {:error, "argv must be a non-empty list of strings without NUL bytes"}

      not valid_string?(cwd) ->
        {:error, "cwd must be a string without NUL bytes"}

      not valid_environment?(env) ->
        {:error, "env must contain string keys and values without NUL bytes"}

      not (is_integer(max_bytes) and max_bytes > 0) ->
        {:error, "max_bytes must be a positive integer"}

      not (is_integer(timeout_ms) and timeout_ms > 0) ->
        {:error, "timeout_ms must be a positive integer"}

      true ->
        {:ok,
         %{
           argv: argv,
           cwd: cwd,
           env: Map.new(env),
           max_bytes: max_bytes,
           timeout_ms: timeout_ms
         }}
    end
  end

  defp valid_string?(value), do: is_binary(value) and not String.contains?(value, <<0>>)

  defp valid_environment?(environment) when is_map(environment) or is_list(environment) do
    Enum.all?(environment, fn
      {key, value} ->
        valid_string?(key) and key != "" and not String.contains?(key, "=") and
          valid_string?(value)

      _entry ->
        false
    end)
  end

  defp valid_environment?(_environment), do: false

  defp process_data(state) do
    parts = :binary.split(state.buffer, "\n", [:global])
    {lines, [buffer]} = Enum.split(parts, -1)

    Enum.reduce_while(lines, {:ok, %{state | buffer: buffer}}, fn line, {:ok, state} ->
      case decode_event(line) do
        {:ok, event} ->
          case process_event(event, state) do
            {:ok, state} -> {:cont, {:ok, state}}
            {:error, reason, state} -> {:halt, {:error, reason, state}}
          end

        {:error, reason} ->
          {:halt, {:error, reason, state}}
      end
    end)
  end

  defp decode_event(line) do
    case JSON.decode(line) do
      {:ok, %{} = event} -> {:ok, event}
      _invalid -> {:error, "stub returned invalid JSON"}
    end
  end

  defp process_event(%{"id" => id, "ev" => "started", "pid" => pid}, state)
       when is_binary(id) and is_integer(pid) and pid > 0 do
    update_job(state, id, fn
      %{phase: :submitted} = job -> {:ok, %{job | phase: :started}}
      _job -> {:error, "duplicate or out-of-order started event"}
    end)
  end

  defp process_event(
         %{"id" => id, "ev" => "chunk", "stream" => "combined", "bytes" => bytes},
         state
       )
       when is_binary(id) and is_list(bytes) do
    with {:ok, chunk} <- decode_bytes(bytes) do
      update_job(state, id, fn
        %{phase: :started} = job when job.bytes_seen + byte_size(chunk) <= job.max_bytes ->
          chunks = if job.from, do: [chunk | job.chunks], else: []
          {:ok, %{job | chunks: chunks, bytes_seen: job.bytes_seen + byte_size(chunk)}}

        %{phase: :started} ->
          {:error, "chunk exceeded the job byte cap"}

        _job ->
          {:error, "out-of-order chunk event"}
      end)
    else
      :error -> {:error, "stub returned invalid chunk bytes", state}
    end
  end

  defp process_event(%{"id" => id, "ev" => "exit"} = event, state) when is_binary(id) do
    case Map.fetch(state.jobs, id) do
      {:ok, %{phase: :started} = job} ->
        case terminal_result(event, job) do
          {:ok, result} ->
            if job.from, do: GenServer.reply(job.from, {:ok, result})
            {:ok, delete_job(state, id, job)}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:ok, _job} ->
        {:error, "out-of-order exit event", state}

      :error ->
        {:error, "event referenced an unknown job", state}
    end
  end

  defp process_event(
         %{"id" => id, "ev" => "rejected", "stage" => stage, "message" => message},
         state
       )
       when is_binary(id) and is_binary(stage) and is_binary(message) do
    case Map.fetch(state.jobs, id) do
      {:ok, %{phase: :submitted} = job} ->
        if job.from,
          do: GenServer.reply(job.from, {:error, {:not_started, "#{stage}: #{message}"}})

        {:ok, delete_job(state, id, job)}

      {:ok, _job} ->
        {:error, "rejected event arrived after a job started", state}

      :error ->
        {:error, "event referenced an unknown job", state}
    end
  end

  defp process_event(%{"ev" => "protocol_error", "error" => error}, state)
       when is_binary(error),
       do: {:error, "stub protocol error: #{error}", state}

  defp process_event(%{"ev" => "pong", "protocol" => @protocol_version}, state),
    do: {:ok, state}

  defp process_event(_event, state), do: {:error, "stub returned an invalid event", state}

  defp update_job(state, id, update) do
    case Map.fetch(state.jobs, id) do
      {:ok, job} ->
        case update.(job) do
          {:ok, job} -> {:ok, %{state | jobs: Map.put(state.jobs, id, job)}}
          {:error, reason} -> {:error, reason, state}
        end

      :error ->
        {:error, "event referenced an unknown job", state}
    end
  end

  defp terminal_result(event, job) do
    with %{
           "code" => code,
           "signal" => signal,
           "cancelled" => cancelled,
           "timed_out" => timed_out,
           "truncated" => truncated,
           "bytes_total" => bytes_total,
           "bytes_sent" => bytes_sent,
           "elapsed_ms" => elapsed_ms
         } <- event,
         true <- valid_exit_identity?(code, signal),
         true <- Enum.all?([cancelled, timed_out, truncated], &is_boolean/1),
         true <- Enum.count([cancelled, timed_out, truncated], & &1) <= 1,
         true <- valid_counter?(bytes_total),
         true <- valid_counter?(bytes_sent),
         true <- valid_counter?(elapsed_ms),
         true <- bytes_sent == job.bytes_seen and bytes_sent <= job.max_bytes,
         true <- valid_total?(bytes_total, bytes_sent, truncated, job.max_bytes) do
      termination =
        cond do
          cancelled -> :cancelled
          timed_out -> :timed_out
          truncated -> :truncated
          true -> :exited
        end

      {:ok,
       %Result{
         output: job.chunks |> Enum.reverse() |> IO.iodata_to_binary(),
         code: code,
         signal: signal,
         termination: termination,
         bytes_total: bytes_total,
         bytes_sent: bytes_sent,
         elapsed_ms: elapsed_ms
       }}
    else
      _invalid -> {:error, "stub returned inconsistent terminal accounting"}
    end
  end

  defp valid_exit_identity?(code, signal) do
    (is_integer(code) and code >= 0 and is_nil(signal)) or
      (is_nil(code) and is_integer(signal) and signal > 0)
  end

  defp valid_counter?(value), do: is_integer(value) and value >= 0

  defp valid_total?(total, sent, true, max), do: total > sent and sent == max
  defp valid_total?(total, sent, false, _max), do: total == sent

  defp decode_bytes(bytes) do
    if Enum.all?(bytes, &(is_integer(&1) and &1 >= 0 and &1 <= 255)) do
      {:ok, :erlang.list_to_binary(bytes)}
    else
      :error
    end
  end

  defp delete_job(state, id, job) do
    Process.demonitor(job.monitor, [:flush])

    %{
      state
      | jobs: Map.delete(state.jobs, id),
        monitors: Map.delete(state.monitors, job.monitor)
    }
  end

  defp replace_stub(state, reason) do
    close_port(state.port)

    Enum.each(state.jobs, fn {_id, job} ->
      Process.demonitor(job.monitor, [:flush])

      if job.from do
        GenServer.reply(
          job.from,
          {:indeterminate, "execution outcome indeterminate: #{reason}"}
        )
      end
    end)

    state = %{
      state
      | port: nil,
        os_pid: nil,
        generation: state.generation + 1,
        buffer: "",
        jobs: %{},
        monitors: %{}
    }

    Process.send_after(self(), :restart_stub, @restart_delay_ms)
    state
  end

  defp open_stub(binary) do
    cond do
      not File.regular?(binary) ->
        {:error, "expected executable at #{binary}"}

      File.stat!(binary).mode |> Bitwise.band(0o111) == 0 ->
        {:error, "stub is not executable: #{binary}"}

      true ->
        do_open_stub(binary)
    end
  end

  defp do_open_stub(binary) do
    port =
      Port.open({:spawn_executable, binary}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide
      ])

    case await_ready(port, "") do
      {:ok, buffer} ->
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        {:ok, port, os_pid, buffer}

      {:error, reason} ->
        close_port(port)
        {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp await_ready(port, buffer) do
    receive do
      {^port, {:data, data}} ->
        buffer = buffer <> data

        case :binary.split(buffer, "\n") do
          [line, rest] ->
            case JSON.decode(line) do
              {:ok,
               %{
                 "ev" => "ready",
                 "protocol" => @protocol_version,
                 "stub_version" => version
               }}
              when is_binary(version) ->
                {:ok, rest}

              _invalid ->
                {:error, "stub returned an invalid ready handshake"}
            end

          [_partial] ->
            await_ready(port, buffer)
        end

      {^port, {:exit_status, status}} ->
        {:error, "stub exited during startup with status #{status}"}

      {:EXIT, ^port, reason} ->
        {:error, "stub port closed during startup: #{inspect(reason)}"}
    after
      @handshake_timeout_ms -> {:error, "stub ready handshake timed out"}
    end
  end

  defp send_command(nil, _command), do: false

  defp send_command(port, command) do
    Port.command(port, [JSON.encode!(command), "\n"])
  rescue
    ArgumentError -> false
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp binary_path, do: Application.app_dir(:elara, "priv/native/exec-stub")

  defp job_id(generation) do
    unique = System.unique_integer([:positive, :monotonic])
    "#{generation}-#{unique}"
  end
end
