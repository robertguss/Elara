defmodule Elara.Lab.Jobs do
  @moduledoc """
  Gated test-job fixtures for lab scenarios. Lab-only. The fixture's test records
  each physical launch and its OS pid, then blocks until the scenario releases it,
  so a scenario can act while a job is provably running. Observation only: it
  never retries or reruns a job.
  """

  alias Elara.{Message, TestJobs, Tool}
  alias Elara.TestJobs.Record

  @target "test/job_test.exs"

  @doc "The fixture's test target."
  @spec target() :: String.t()
  def target, do: @target

  @doc "Write a Mix project at `cwd` whose one test blocks until `release/1`."
  @spec fixture(String.t()) :: :ok
  def fixture(cwd) do
    File.mkdir_p!(Path.join(cwd, "test"))

    File.write!(Path.join(cwd, "mix.exs"), """
    defmodule LabJobFixture.MixProject do
      use Mix.Project
      def project, do: [app: :lab_job_fixture, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(cwd, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(cwd, @target), """
    defmodule LabJobFixtureTest do
      use ExUnit.Case
      test "gated execution" do
        File.write!("os_pid", System.pid())
        File.write!("started", "1", [:append])
        wait()
        assert 17 * 23 == 391
      end
      defp wait do
        unless File.exists?("release") do
          Process.sleep(10)
          wait()
        end
      end
    end
    """)
  end

  @doc "Let the fixture's blocked test finish."
  @spec release(String.t()) :: :ok
  def release(cwd), do: File.write!(Path.join(cwd, "release"), "")

  @doc "Call the `test_job` tool as `session` would, returning its raw result."
  @spec call(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def call(session, cwd, action, job_id) do
    args = %{"action" => action, "job_id" => job_id, "target" => @target}
    TestJobs.run(args, %Tool.Ctx{session_id: session, cwd: cwd, tool_name: "test_job"})
  end

  @doc "Call `test_job` and decode a successful JSON result."
  @spec command(String.t(), String.t(), String.t(), String.t()) :: map()
  def command(session, cwd, action, job_id) do
    {:ok, json} = call(session, cwd, action, job_id)
    JSON.decode!(json)
  end

  @spec record(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def record(session, job_id), do: Record.load(Record.key(session, job_id))

  @doc "State of the job's completion input in `session`'s inbox; nil before delivery."
  @spec input_state(String.t(), String.t()) :: atom() | nil
  def input_state(session, job_id) do
    case Elara.input_status(session, "test-job:" <> Record.key(session, job_id)) do
      {:ok, %{state: state}} -> state
      _ -> nil
    end
  end

  @doc "True once the fixture's test has started and recorded its pid."
  @spec launched?(String.t()) :: boolean()
  def launched?(cwd),
    do: File.exists?(Path.join(cwd, "started")) and File.exists?(Path.join(cwd, "os_pid"))

  @doc "Physical launches of the fixture's test."
  @spec launches(String.t()) :: non_neg_integer()
  def launches(cwd) do
    case File.read(Path.join(cwd, "started")) do
      {:ok, text} -> byte_size(text)
      _ -> 0
    end
  end

  @doc "True when the fixture's recorded test process is gone (or a zombie)."
  @spec stopped?(String.t()) :: boolean()
  def stopped?(cwd) do
    case File.read(Path.join(cwd, "os_pid")) do
      {:ok, pid} ->
        case System.cmd("ps", ["-p", String.trim(pid), "-o", "stat="]) do
          {"", 1} -> true
          {state, 0} -> String.starts_with?(String.trim(state), "Z")
          _ -> false
        end

      _ ->
        true
    end
  end

  @doc "`test_job` actions the model requested, in order."
  @spec actions([Message.t()]) :: [String.t()]
  def actions(history) do
    for %Message.Assistant{tool_calls: calls} <- history,
        %Message.ToolCall{name: "test_job", args: {:ok, args}} <- calls,
        do: args["action"]
  end

  @doc "Inbox inputs (such as job completions) the model received."
  @spec inbox_inputs([Message.t()]) :: non_neg_integer()
  def inbox_inputs(history),
    do: Enum.count(history, &match?(%Message.User{agent_source: %{}}, &1))

  @doc """
  Release and cancel each `{session, cwd, job_id}` job, then wait until every
  record is released and its test process stopped. False when that cannot be
  confirmed, so the runner keeps the evidence.
  """
  @spec settle([{String.t(), String.t(), String.t()}]) :: boolean()
  def settle(jobs) do
    for {session, cwd, job_id} <- jobs do
      release(cwd)
      call(session, cwd, "cancel", job_id)
    end

    await(fn ->
      Enum.all?(jobs, fn {session, cwd, job_id} ->
        case record(session, job_id) do
          {:error, :enoent} -> true
          {:ok, record} -> record["slot"] == "released" and stopped?(cwd)
          _ -> false
        end
      end)
    end)

    true
  rescue
    _ -> false
  end

  @doc "Stop a session if it is running."
  @spec stop_session(String.t()) :: :ok
  def stop_session(id) do
    case Elara.session_pid(id) do
      {:ok, pid} -> GenServer.stop(pid)
      _ -> :ok
    end
  end

  @doc "Poll `fun` every 20 ms until true; raise after `timeout_ms`."
  @spec await((-> boolean()), pos_integer()) :: :ok
  def await(fun, timeout_ms \\ 15_000), do: await_until(fun, now() + timeout_ms)

  defp await_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      now() >= deadline ->
        raise "lab condition did not converge"

      true ->
        Process.sleep(20)
        await_until(fun, deadline)
    end
  end

  @doc "Monotonic milliseconds."
  @spec now() :: integer()
  def now, do: System.monotonic_time(:millisecond)
end
