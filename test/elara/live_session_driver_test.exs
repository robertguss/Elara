Code.require_file("../support/live_session_driver.exs", __DIR__)

defmodule Elara.LiveSessionDriverTest do
  use ExUnit.Case, async: false
  alias Elara.{Message, Session.Handoff}
  alias Elara.TestSupport.LiveSessionDriver, as: Driver

  defmodule Controlled do
    @behaviour Elara.Provider
    def chat(owner, request) do
      send(owner, {:model, self(), request})

      receive do
        {:answer, text} -> {:ok, %Message.Assistant{text: text}, owner}
        {:fail, error} -> {:error, error, owner}
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "elara-driver-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    old = Application.get_env(:elara, :sessions_root)
    Application.put_env(:elara, :sessions_root, Path.join(root, "sessions"))

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Elara.SessionSup),
          do: DynamicSupervisor.terminate_child(Elara.SessionSup, pid)

      Application.put_env(:elara, :sessions_root, old)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "passive observation preserves the configured provider and catalog budget", %{root: root} do
    alias Elara.Auth.OpenAICodex, as: Tokens
    alias Elara.Provider.OpenAICodex

    tokens = %Tokens{
      access_token: "fake",
      refresh_token: "fake",
      account_id: "fake",
      expires_at: System.system_time(:second) + 3600
    }

    provider = {OpenAICodex, OpenAICodex.new(tokens, model: "gpt-5.4-mini")}
    session = start(root, provider: provider, pause_inputs: true, context_limit: nil)
    before = Elara.snapshot(session).snapshot
    result = run(session)
    assert result.outcome == "paused"
    assert Elara.child_config(session).provider == provider
    assert Elara.snapshot(session).snapshot == before
    assert before["inbox"]["context"]["limit"] == 272_000
    assert result.actions == []
  end

  test "retained replay finds an already finished successor without another prompt", %{root: root} do
    {:ok, queue} = Agent.start_link(fn -> [{:ok, %Message.Assistant{text: "DONE"}}] end)

    source =
      start(root,
        provider: {Elara.Provider.Scripted, queue},
        seed_history: [%Message.Assistant{text: String.duplicate("e", 60_000)}]
      )

    assert {:error, :interrupted} = Elara.ask(source, "finish retained goal")
    successor = await_owner(source)
    await(fn -> Elara.status(successor).phase == :idle end)
    result = run(source)
    assert result.outcome == "complete", inspect(result)
    assert result.session == successor
    assert Enum.map(result.sessions, & &1.id) == [source, successor]
    assert result.actions == []
    assert result.gaps == []
    assert Enum.count(result.turns, &(&1.outcome == "completed")) == 1
    assert Agent.get(queue, & &1) == []
  end

  test "a paused successor stays paused until an explicit resume", %{root: root} do
    source =
      start(root,
        pause_inputs: true,
        seed_history: [%Message.Assistant{text: String.duplicate("e", 60_000)}]
      )

    assert {:error, :interrupted} = Elara.ask(source, "finish retained goal")
    successor = await_owner(source)
    assert run(source).outcome == "paused"
    refute_receive {:model, _, _}
    task = Task.async(fn -> run(source, nil, resume_inputs: true) end)
    assert_receive {:model, model, _}, 2000
    send(model, {:answer, "DONE"})
    result = Task.await(task)
    assert result.outcome == "complete", inspect(result)
    assert [%{action: "resume_inputs", session: ^successor, result: ":ok"}] = result.actions
    refute_receive {:model, _, _}
  end

  test "observation follows a handoff occurring after a new prompt", %{root: root} do
    source = start(root, seed_history: [%Message.Assistant{text: String.duplicate("e", 60_000)}])
    task = Task.async(fn -> run(source, "finish retained goal") end)
    assert_receive {:model, model, _}, 2000
    send(model, {:answer, "DONE"})
    result = Task.await(task)
    assert result.outcome == "complete", inspect(result)
    assert result.session != source
    assert [%{action: "ask", result: ":ok"}] = result.actions
    assert result.errors == []
  end

  test "busy submission is reported without adding a prompt or interrupting work", %{root: root} do
    session = start(root)
    :ok = Elara.ask_async(session, "existing work")
    assert_receive {:model, model, _}
    assert run(session, "extra prompt").outcome == "busy"
    assert [%Message.User{text: "existing work"}] = Elara.transcript(session)
    assert Process.alive?(model)
    send(model, {:answer, "DONE"})
  end

  test "new prompts cannot succeed from old completion markers", %{root: root} do
    session = start(root)
    task = Task.async(fn -> Elara.ask(session, "old work") end)
    assert_receive {:model, model, _}
    send(model, {:answer, "DONE"})
    assert {:ok, "DONE"} = Task.await(task)
    task = Task.async(fn -> run(session, "new work") end)
    assert_receive {:model, model, _}
    send(model, {:fail, %Elara.Provider.Error{kind: :bad_response, message: "offline"}})
    result = Task.await(task)
    assert result.outcome == "provider_error"
    assert [%{error: error}] = result.errors
    assert error =~ "offline"
    refute_receive {:model, _, _}
  end

  test "timeout leaves active work alone and releases its observer", %{root: root} do
    session = start(root)
    task = Task.async(fn -> run(session, "work", timeout_ms: 100) end)
    assert_receive {:model, model, _}
    assert Task.await(task).outcome == "driver_deadline"
    assert Process.alive?(model)
    await(fn -> Elara.status(session).subscriber_count == 0 end)
    send(model, {:answer, "DONE"})
  end

  test "an old marker does not complete observation of an active later turn", %{root: root} do
    session = start(root)
    task = Task.async(fn -> Elara.ask(session, "old work") end)
    assert_receive {:model, model, _}
    send(model, {:answer, "DONE"})
    Task.await(task)
    :ok = Elara.ask_async(session, "still running")
    assert_receive {:model, model, _}
    assert run(session, nil, timeout_ms: 100).outcome == "driver_deadline"
    send(model, {:answer, "DONE"})
  end

  test "explicit initial resume never clears a later user pause", %{root: root} do
    session = start(root, pause_inputs: true)
    task = Task.async(fn -> run(session, "new work", resume_inputs: true) end)
    assert_receive {:model, _model, _}, 2000
    await(fn -> not Elara.snapshot(session).snapshot["inbox"]["paused"] end)
    Elara.interrupt(session)
    result = Task.await(task)
    assert result.outcome == "paused"
    assert [%{action: "ask"}, %{action: "resume_inputs"}] = result.actions
    assert Elara.snapshot(session).snapshot["inbox"]["paused"]
    refute_receive {:model, _, _}
  end

  test "a known running job can wake the observer after a provider error without a retry", %{
    root: root
  } do
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule DriverFixture.MixProject do
      use Mix.Project
      def project, do: [app: :driver_fixture, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/job_test.exs"), """
    defmodule DriverFixtureTest do
      use ExUnit.Case
      test "one execution" do
        File.write!("started", "1", [:append])
        wait()
        assert true
      end
      defp wait do
        unless File.exists?("release") do
          Process.sleep(10)
          wait()
        end
      end
    end
    """)

    session = start(root)
    ctx = %Elara.Tool.Ctx{session_id: session, cwd: root, tool_name: "test_job"}

    {:ok, _} =
      Elara.TestJobs.run(
        %{"action" => "start", "job_id" => "driver-job", "target" => "test/job_test.exs"},
        ctx
      )

    on_exit(fn -> Elara.TestJobs.run(%{"action" => "cancel", "job_id" => "driver-job"}, ctx) end)
    await(fn -> File.exists?(Path.join(root, "started")) end)

    task =
      Task.async(fn ->
        run(session, "wait for the job", pending_jobs: ["driver-job"], timeout_ms: 10_000)
      end)

    assert_receive {:model, model, _}, 2000
    send(model, {:fail, %Elara.Provider.Error{kind: :bad_response, message: "offline"}})
    assert Task.yield(task, 100) == nil
    File.write!(Path.join(root, "release"), "")
    assert_receive {:model, model, request}, 5000
    assert List.last(request.messages).agent_source["message_id"] == "driver-job"
    send(model, {:answer, "DONE"})
    result = Task.await(task)
    assert result.outcome == "complete", inspect(result)
    assert length(result.errors) == 1
    assert [%{action: "ask"}] = result.actions
    assert File.read!(Path.join(root, "started")) == "1"
    refute_receive {:model, _, _}
  end

  test "a stopped session is reported without reopening it", %{root: root} do
    session = start(root)
    {:ok, pid} = Elara.session_pid(session)
    GenServer.stop(pid)
    assert run(session).outcome == "session_unavailable"
    assert {:error, :session_not_found} = Elara.session_pid(session)
  end

  test "replay records an evicted prefix instead of claiming complete event evidence", %{
    root: root
  } do
    {:ok, queue} =
      Agent.start_link(fn -> List.duplicate({:ok, %Message.Assistant{text: "DONE"}}, 350) end)

    session = start(root, provider: {Elara.Provider.Scripted, queue}, context_limit: 10_000_000)
    for _ <- 1..350, do: assert({:ok, "DONE"} = Elara.ask(session, "work"))
    result = run(session)
    assert result.outcome == "complete"
    assert [%{session: ^session, from: 1, to: last_missing}] = result.gaps
    assert last_missing > 0
  end

  defp start(root, opts \\ []) do
    {:ok, id} =
      Elara.start_session(
        Keyword.merge(
          [
            cwd: root,
            home: root,
            skill_paths: [],
            plugins: [],
            system: "test",
            tools: [],
            provider: {Controlled, self()},
            context_limit: 100_000,
            max_tool_output_bytes: 1024
          ],
          opts
        )
      )

    id
  end

  defp run(id, prompt \\ nil, opts \\ []),
    do: Driver.run(id, prompt, Keyword.merge([completion_marker: "DONE", timeout_ms: 3000], opts))

  defp await_owner(id) do
    await(fn ->
      {:ok, store} = Handoff.store(id)
      h = Handoff.outgoing(store)
      if h && h["stage"] == "started", do: h["delivery_owner"]
    end)
  end

  defp await(fun, attempts \\ 200)
  defp await(_, 0), do: flunk("condition not reached")

  defp await(fun, attempts) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        Process.sleep(10)
        await(fun, attempts - 1)
    end
  end
end
