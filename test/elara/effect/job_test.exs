defmodule Elara.Effect.JobTest do
  use ExUnit.Case, async: false

  alias Elara.Effect.{ControllerJournal, Job}
  alias Elara.Message
  alias Elara.Message.ToolCall
  alias Elara.Tool

  defmodule MarkerTool do
    def run(%{"path" => path}, _ctx) do
      File.write!(path, "executed")
      {:ok, "executed"}
    end
  end

  defmodule ReadTool do
    def run(%{"path" => path}, _ctx) do
      {:ok, File.read!(path)}
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-effect-job-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, journal_path: Path.join(root, "controller.sqlite3")}
  end

  test "canonical operation digests are stable and sensitive to semantic inputs" do
    left_arguments = Map.new([{"path", "marker"}, {"metadata", Map.new([{"b", 2}, {"a", 1}])}])
    right_arguments = Map.new([{"metadata", Map.new([{"a", 1}, {"b", 2}])}, {"path", "marker"}])

    left = job(arguments: left_arguments, required_capabilities: ["shell", "filesystem:write"])

    right =
      job(arguments: right_arguments, required_capabilities: ["filesystem:write", "shell"])

    assert left.job_id == right.job_id
    assert left.operation_digest == right.operation_digest
    assert left.required_capabilities == ["filesystem:write", "shell"]
    assert left.schema_version == 1
    assert left.job_id_version == 1
    assert left.digest_version == 1

    changes = [
      job(operation_kind: :apply_patch),
      job(tool_version: "2"),
      job(arguments: %{"path" => "different"}),
      job(workspace_id: "other-workspace"),
      job(required_capabilities: ["filesystem:write", "shell"]),
      job(allowed_capabilities: ["filesystem:write"]),
      job(placement: :remote),
      job(marker_schema_version: 2)
    ]

    assert Enum.all?(changes, &(&1.job_id == job().job_id))
    assert Enum.all?(changes, &(&1.operation_digest != job().operation_digest))

    other_effect = job(effect_id: %{recording_id: "recording", sequence: 8, effect_index: 2})
    assert other_effect.job_id != job().job_id
    assert other_effect.operation_digest == job().operation_digest
  end

  test "committed intent and uniqueness survive owner and connection restart", context do
    intent = job()
    journal = start_journal(context.journal_path)

    assert ControllerJournal.configuration(journal) == %{
             journal_mode: "wal",
             schema_version: 1,
             synchronous: 2
           }

    assert {:ok, ^intent} = ControllerJournal.commit_intent(journal, intent)
    assert {:ok, ^intent} = ControllerJournal.commit_intent(journal, intent)
    assert {:ok, [^intent]} = ControllerJournal.all(journal)

    conflicting = job(tool_version: "2")
    operation_digest = intent.operation_digest

    assert {:error, {:job_id_conflict, ^operation_digest}} =
             ControllerJournal.commit_intent(journal, conflicting)

    assert :ok = ControllerJournal.close(journal)

    reopened = start_journal(context.journal_path)
    assert {:ok, ^intent} = ControllerJournal.get(reopened, intent.job_id)
    assert {:ok, [^intent]} = ControllerJournal.all(reopened)
    assert :ok = ControllerJournal.close(reopened)

    assert {:ok, stat} = File.stat(context.journal_path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  test "crash before intent commit leaves no recoverable job", context do
    intent = job()
    parent = self()
    journal = start_journal(context.journal_path)
    monitor = Process.monitor(journal)

    hook = fn point ->
      send(parent, {:fault_hook, point, self()})

      receive do
        {:continue, ^point} -> :ok
      end
    end

    commit_from_unlinked_process(journal, intent, hook)

    assert_receive {:fault_hook, :before_intent_commit, ^journal}
    Process.exit(journal, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^journal, :killed}
    assert_receive {:commit_result, {:exit, _reason}}

    reopened = start_journal(context.journal_path)
    assert {:ok, nil} = ControllerJournal.get(reopened, intent.job_id)
    assert {:ok, []} = ControllerJournal.all(reopened)
    assert :ok = ControllerJournal.close(reopened)
  end

  test "crash after intent commit leaves exactly one recoverable job", context do
    intent = job()
    parent = self()
    journal = start_journal(context.journal_path)
    monitor = Process.monitor(journal)

    hook = fn
      :before_intent_commit ->
        :ok

      :after_intent_commit_before_dispatch = point ->
        send(parent, {:fault_hook, point, self()})

        receive do
          {:continue, ^point} -> :ok
        end
    end

    commit_from_unlinked_process(journal, intent, hook)

    assert_receive {:fault_hook, :after_intent_commit_before_dispatch, ^journal}
    Process.exit(journal, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^journal, :killed}
    assert_receive {:commit_result, {:exit, _reason}}

    reopened = start_journal(context.journal_path)
    assert {:ok, ^intent} = ControllerJournal.get(reopened, intent.job_id)
    assert {:ok, [^intent]} = ControllerJournal.all(reopened)
    assert :ok = ControllerJournal.close(reopened)
  end

  test "mutating session dispatch waits for the durable intent", context do
    marker_path = Path.join(context.root, "marker")
    parent = self()

    hook = fn point ->
      send(parent, {:fault_hook, point, self()})

      receive do
        {:continue, ^point} -> :ok
      end
    end

    call = %ToolCall{
      id: "model-call-id",
      name: "marker",
      args: {:ok, %{"path" => marker_path}}
    }

    provider = script([{:ok, assistant(nil, [call])}, {:ok, assistant("done")}])

    tool = %Tool{
      name: "marker",
      version: "1",
      description: "test marker",
      parameters: %{"type" => "object"},
      capabilities: ["filesystem:write"],
      mutating: true,
      run: {MarkerTool, :run}
    }

    assert {:ok, session} =
             Elara.start_session(
               provider: provider,
               tools: [tool],
               plugins: [],
               persist: false,
               effect_journal_path: context.journal_path,
               effect_fault_hook: hook
             )

    asker = Task.async(fn -> Elara.ask(session, "run") end)

    assert_receive {:fault_hook, :before_intent_commit, journal}
    refute File.exists?(marker_path)
    send(journal, {:continue, :before_intent_commit})

    assert_receive {:fault_hook, :after_intent_commit_before_dispatch, ^journal}
    refute File.exists?(marker_path)

    reader = start_journal(context.journal_path)
    assert {:ok, [%Job{state: :intent}]} = ControllerJournal.all(reader)
    assert :ok = ControllerJournal.close(reader)

    send(journal, {:continue, :after_intent_commit_before_dispatch})
    assert {:ok, "done"} = Task.await(asker)
    assert File.read!(marker_path) == "executed"
    stop_session(session)
  end

  test "nonmutating session execution keeps the direct path", context do
    source_path = Path.join(context.root, "source")
    File.write!(source_path, "read result")
    parent = self()

    call = %ToolCall{
      id: "read-call",
      name: "probe_read",
      args: {:ok, %{"path" => source_path}}
    }

    provider = script([{:ok, assistant(nil, [call])}, {:ok, assistant("done")}])

    tool = %Tool{
      name: "probe_read",
      version: "1",
      description: "test read",
      parameters: %{"type" => "object"},
      capabilities: ["filesystem:read"],
      mutating: false,
      run: {ReadTool, :run}
    }

    assert {:ok, session} =
             Elara.start_session(
               provider: provider,
               tools: [tool],
               plugins: [],
               persist: false,
               effect_journal_path: context.journal_path,
               effect_fault_hook: fn point -> send(parent, {:unexpected_hook, point}) end
             )

    assert {:ok, "done"} = Elara.ask(session, "read")
    refute_receive {:unexpected_hook, _point}
    refute File.exists?(context.journal_path)
    stop_session(session)
  end

  defp job(overrides \\ []) do
    effect_id =
      Keyword.get(overrides, :effect_id, %{
        recording_id: "recording",
        sequence: 7,
        effect_index: 2
      })

    attrs =
      Keyword.merge(
        [
          operation_kind: :run_tool,
          tool_name: "marker",
          tool_version: "1",
          arguments: %{"path" => "marker"},
          workspace_id: "workspace",
          required_capabilities: ["filesystem:write"],
          allowed_capabilities: :all,
          placement: :any,
          marker_schema_version: 1
        ],
        Keyword.delete(overrides, :effect_id)
      )

    Job.new(effect_id, attrs)
  end

  defp start_journal(path) do
    {:ok, journal} = ControllerJournal.start_link(path: path)
    Process.unlink(journal)
    journal
  end

  defp commit_from_unlinked_process(journal, intent, hook) do
    parent = self()

    spawn(fn ->
      result =
        try do
          ControllerJournal.commit_intent(journal, intent, hook)
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {:commit_result, result})
    end)
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp assistant(text, calls \\ []) do
    {:ok, message} = Message.assistant(text, calls)
    message
  end

  defp stop_session(session) do
    {:ok, pid} = Elara.session_pid(session)
    GenServer.stop(pid)
  end
end
