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
end
