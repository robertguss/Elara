defmodule Harness.CoordinatorTest do
  use ExUnit.Case, async: false

  alias Harness.Coordinator
  alias Harness.Coordinator.{Result, Run}
  alias Harness.Message
  alias Harness.Provider

  defmodule BlockingProvider do
    @behaviour Provider

    @impl true
    def chat({parent, id} = config, %Provider.Request{} = request) do
      send(parent, {:child_provider_started, id, self(), request})

      receive do
        {:reply, ^id, text} ->
          {:ok, assistant(text), config}
      end
    end

    defp assistant(text) do
      {:ok, assistant} = Message.assistant(text, [])
      assistant
    end
  end

  defmodule StaticProvider do
    @behaviour Provider

    @impl true
    def chat({parent, id, answer} = config, %Provider.Request{} = request) do
      send(parent, {:static_request, id, request})
      {:ok, assistant(answer), config}
    end

    defp assistant(text) do
      {:ok, assistant} = Message.assistant(text, [])
      assistant
    end
  end

  defp asst(text) do
    {:ok, assistant} = Message.assistant(text, [])
    assistant
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Harness.Provider.Scripted, agent}
  end

  defp parent_session do
    {:ok, parent} =
      Harness.start_session(
        provider: script([{:ok, asst("parent answer")}]),
        persist: false,
        plugins: [],
        tools: []
      )

    assert {:ok, "parent answer"} = Harness.ask(parent, "parent question")
    parent
  end

  defp await_children(coordinator, count, attempts \\ 100) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      status = Coordinator.status(coordinator)

      if length(status.children) == count do
        {:halt, status.children}
      else
        Process.sleep(20)
        {:cont, nil}
      end
    end) || flunk("coordinator did not start #{count} children")
  end

  test "three isolated coding candidates survive one child death and a judge selects a winner" do
    parent = parent_session()
    parent_history = Harness.transcript(parent)
    test_pid = self()

    factory = fn spec -> {BlockingProvider, {test_pid, spec.id}} end

    {:ok, coordinator} =
      Harness.start_coordinator(parent,
        provider_factory: factory,
        max_concurrency: 3,
        token_budget: 10_000,
        time_budget_ms: 10_000
      )

    specs = [
      %{id: "one", role: :coding, prompt: "candidate one"},
      %{id: "dead", role: :coding, prompt: "candidate dead"},
      %{id: "two", role: :coding, prompt: "candidate two"}
    ]

    task =
      Task.async(fn ->
        Coordinator.run(coordinator, :candidates, specs,
          judge: %{id: "judge", role: :judge, prompt: "Return the winning candidate ID."}
        )
      end)

    starts =
      Enum.map(1..3, fn _ ->
        assert_receive {:child_provider_started, id, provider_pid, %Provider.Request{}}, 3_000
        {id, provider_pid}
      end)
      |> Map.new()

    children = await_children(coordinator, 3)
    status = Coordinator.status(coordinator)
    assert is_binary(status.run.id)
    assert status.parent_session_id == parent
    assert status.child_supervisor |> Process.alive?()
    assert status.run.budgets.concurrency == %{active: 3, limit: 3}
    assert status.run.budgets.queued == 0
    assert status.run.budgets.token_estimate.used > 0
    assert Enum.all?(children, &(&1.parent_session_id == parent and &1.run_id == status.run.id))
    assert Enum.all?(children, &(is_pid(&1.pid) and is_pid(&1.task_pid)))
    worktrees = Enum.map(children, & &1.worktree)
    assert Enum.all?(worktrees, &is_binary/1)
    assert length(Enum.uniq(worktrees)) == 3
    assert Enum.all?(worktrees, &File.dir?/1)

    assert Enum.all?(worktrees, fn path ->
             {_, status} = System.cmd("git", ["rev-parse", "--is-inside-work-tree"], cd: path)
             status == 0
           end)

    assert :ok = Coordinator.kill_child(coordinator, "dead")
    send(Map.fetch!(starts, "one"), {:reply, "one", "candidate one result"})
    send(Map.fetch!(starts, "two"), {:reply, "two", "candidate two result"})

    assert_receive {:child_provider_started, "judge", judge_pid, judge_request}, 3_000
    assert List.last(judge_request.messages).text =~ "candidate two result"
    send(judge_pid, {:reply, "judge", "one"})

    assert {:ok, %Run{} = run} = Task.await(task, 10_000)
    assert run.selected == "one"
    assert %Result{id: "judge", role: :judge, answer: "one"} = run.judge
    assert Enum.count(run.results, &(&1.status == :completed)) == 3
    assert Enum.any?(run.failures, &(&1.id == "dead" and &1.status == :failed))
    refute Map.has_key?(Map.from_struct(List.first(run.results)), :transcript)
    assert is_list(run.worker_health)

    assert Harness.transcript(parent) == parent_history
    {:ok, parent_pid} = Harness.session_pid(parent)
    assert Process.alive?(parent_pid)

    GenServer.stop(coordinator)
    refute Enum.any?(worktrees, &File.exists?/1)
    refute File.exists?(Path.dirname(List.first(worktrees)))
  end

  test "concurrency, token, time, and early-selection budgets are enforced" do
    parent = parent_session()
    test_pid = self()
    factory = fn spec -> {BlockingProvider, {test_pid, spec.id}} end

    {:ok, coordinator} =
      Harness.start_coordinator(parent,
        provider_factory: factory,
        max_concurrency: 1,
        token_budget: 100,
        time_budget_ms: 5_000
      )

    task =
      Task.async(fn ->
        Coordinator.run(
          coordinator,
          :parallel,
          [%{id: "first", prompt: "first"}, %{id: "second", prompt: "second"}],
          select: fn results ->
            if Enum.any?(results, &(&1.id == "first" and &1.status == :completed)),
              do: "first"
          end
        )
      end)

    assert_receive {:child_provider_started, "first", first_pid, _}, 1_000
    refute_receive {:child_provider_started, "second", _, _}, 100
    send(first_pid, {:reply, "first", "selected"})

    assert {:ok, %Run{selected: "first"} = selected} = Task.await(task)
    assert Enum.any?(selected.results, &(&1.id == "second" and &1.status == :cancelled))

    {:ok, budget_coordinator} =
      Harness.start_coordinator(parent,
        provider_factory: factory,
        token_budget: 1,
        time_budget_ms: 1_000
      )

    assert {:ok, %Run{} = budgeted} =
             Coordinator.run(budget_coordinator, :specialists, [
               %{id: "security", role: :security, prompt: "too many tokens"}
             ])

    assert [%Result{status: :budget_exceeded}] = budgeted.results

    {:ok, timed_coordinator} =
      Harness.start_coordinator(parent,
        provider_factory: factory,
        token_budget: 100,
        time_budget_ms: 30
      )

    assert {:ok, %Run{} = timed} =
             Coordinator.run(timed_coordinator, :parallel, [%{id: "slow", prompt: "wait"}])

    assert Enum.any?(timed.results, &(&1.id == "slow" and &1.status == :cancelled))
  end

  test "map/reduce receives compact results and forked history stops before the selected user turn" do
    parent = parent_session()
    [%{id: user_id}] = Harness.user_entries(parent)
    test_pid = self()

    answers = %{"map-a" => "A", "map-b" => "B", "reduce" => "A+B"}
    factory = fn spec -> {StaticProvider, {test_pid, spec.id, Map.fetch!(answers, spec.id)}} end
    {:ok, coordinator} = Harness.start_coordinator(parent, provider_factory: factory)

    assert {:ok, %Run{selected: "A+B"} = run} =
             Coordinator.run(
               coordinator,
               :map_reduce,
               [%{id: "map-a", prompt: "map A"}, %{id: "map-b", prompt: "map B"}],
               history: {:fork, user_id},
               reducer: %{id: "reduce", role: :reducer, prompt: "combine"}
             )

    assert_receive {:static_request, "reduce", reduce_request}
    assert List.last(reduce_request.messages).text =~ "Structured child results"
    assert List.last(reduce_request.messages).text =~ "\"answer\":\"A\""

    assert Enum.all?(run.results, &(&1.status == :completed))

    assert_receive {:static_request, "map-a", map_request}
    assert map_request.messages == [Message.user("map A")]
  end

  test "coding isolation options cannot be overridden and startup failures clean worktrees" do
    parent = parent_session()
    test_pid = self()
    factory = fn spec -> {BlockingProvider, {test_pid, spec.id}} end
    override = Path.join(System.tmp_dir!(), "coordinator-cwd-override")

    {:ok, coordinator} =
      Harness.start_coordinator(parent,
        provider_factory: factory,
        child_opts: [cwd: override, persist: true]
      )

    task =
      Task.async(fn ->
        Coordinator.run(coordinator, :parallel, [
          %{id: "isolated", role: :coding, prompt: "isolation"}
        ])
      end)

    assert_receive {:child_provider_started, "isolated", provider_pid, _}, 3_000
    [child] = await_children(coordinator, 1)
    assert Harness.cwd(child.session_id) == child.worktree
    assert Harness.status(child.session_id).recording_path == nil
    refute child.worktree == override
    send(provider_pid, {:reply, "isolated", "done"})
    assert {:ok, %Run{results: [%Result{status: :completed}]}} = Task.await(task)

    GenServer.stop(coordinator)
    refute File.exists?(child.worktree)
    refute File.exists?(Path.dirname(child.worktree))

    {:ok, failing} =
      Harness.start_coordinator(parent,
        provider_factory: factory,
        child_opts: [resume: :latest]
      )

    assert {:ok, %Run{results: [%Result{status: :failed, worktree: failed_path}]}} =
             Coordinator.run(failing, :parallel, [
               %{id: "startup-failure", role: :coding, prompt: "fail before session start"}
             ])

    refute File.exists?(failed_path)
    {worktree_list, 0} = System.cmd("git", ["worktree", "list", "--porcelain"])
    refute worktree_list =~ failed_path

    {:ok, raising} =
      Harness.start_coordinator(parent,
        provider_factory: fn _spec -> raise "provider factory failed" end
      )

    assert {:ok, %Run{results: [%Result{status: :failed, worktree: raised_path}]}} =
             Coordinator.run(raising, :parallel, [
               %{id: "provider-failure", role: :coding, prompt: "never starts"}
             ])

    refute File.exists?(raised_path)
    {worktree_list, 0} = System.cmd("git", ["worktree", "list", "--porcelain"])
    refute worktree_list =~ raised_path

    assert {:error, :duplicate_child_ids} =
             Coordinator.run(raising, :parallel, [
               %{id: "duplicate", prompt: "first"},
               %{id: "duplicate", prompt: "second"}
             ])

    blocking_factory = fn _spec ->
      send(test_pid, :factory_entered_after_worktree)

      receive do
        :unblock -> script([{:ok, asst("unused")}])
      end
    end

    {:ok, interrupted} =
      Harness.start_coordinator(parent, provider_factory: blocking_factory)

    spawn(fn ->
      result =
        try do
          Coordinator.run(interrupted, :parallel, [
            %{id: "interrupted", role: :coding, prompt: "stop during startup"}
          ])
        catch
          :exit, reason -> {:exit, reason}
        end

      send(test_pid, {:interrupted_run_result, result})
    end)

    assert_receive :factory_entered_after_worktree, 3_000
    interrupted_root = interrupted |> Coordinator.status() |> get_in([:run, :id])
    interrupted_root = Coordinator.Engine.run_root(interrupted_root)
    assert File.dir?(interrupted_root)
    assert [_worktree] = File.ls!(interrupted_root)

    GenServer.stop(interrupted)
    assert_receive {:interrupted_run_result, {:exit, _reason}}, 1_000
    refute File.exists?(interrupted_root)
    {worktree_list, 0} = System.cmd("git", ["worktree", "list", "--porcelain"])
    refute worktree_list =~ interrupted_root

    safe_factory = fn spec -> {StaticProvider, {test_pid, spec.id, "safe"}} end
    {:ok, hostile_id} = Harness.start_coordinator(parent, provider_factory: safe_factory)

    assert {:ok, %Run{results: [%Result{worktree: hostile_path}]}} =
             Coordinator.run(hostile_id, :parallel, [
               %{id: "..", role: :coding, prompt: "opaque worktree name"}
             ])

    assert_receive {:static_request, "..", _request}
    refute Path.basename(hostile_path) in [".", ".."]
    assert File.dir?(hostile_path)

    outside = Path.join(System.tmp_dir!(), "coordinator-cleanup-sentinel")
    File.write!(outside, "keep")

    assert {:error, :worktree_outside_run_root} =
             Coordinator.Engine.cleanup_worktree(
               File.cwd!(),
               Path.dirname(hostile_path),
               outside
             )

    assert File.read!(outside) == "keep"
    File.rm!(outside)

    GenServer.stop(hostile_id)
    refute File.exists?(hostile_path)
    refute File.exists?(Path.dirname(hostile_path))
  end
end
