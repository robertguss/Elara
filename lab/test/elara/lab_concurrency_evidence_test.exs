defmodule Elara.Lab.Scenarios.Concurrency.EvidenceTest do
  use ExUnit.Case, async: true

  alias Elara.Lab.Scenarios.Concurrency.Evidence

  @settled %{
    leftover_users: 0,
    leftover_sessions: 0,
    leftover_tasks: 0,
    leftover_clients: 0,
    exec_jobs_pending: 0,
    exec_epoch_changed: false,
    leftover_watchers: 0,
    threads_quiescent: true,
    transport_quiescent: true,
    reports_settled: true,
    children_stopped: true,
    actors_held: true,
    actors_unchanged: true
  }

  test "cleanup is confirmed only when nothing survives and execution settled in one epoch" do
    assert Evidence.cleanup_confirmed?(@settled)

    for {key, value} <- [
          leftover_users: 1,
          leftover_sessions: 1,
          leftover_tasks: 1,
          leftover_clients: 1,
          exec_jobs_pending: 1,
          exec_epoch_changed: true,
          leftover_watchers: 1,
          threads_quiescent: false,
          transport_quiescent: false,
          reports_settled: false,
          children_stopped: false,
          actors_held: false,
          actors_unchanged: false
        ] do
      refute Evidence.cleanup_confirmed?(Map.put(@settled, key, value)), "#{key}"
    end
  end

  defp completion(key, recipient), do: %{"key" => key, "recipient" => recipient}

  defp message(key, recipient, delivery, kind \\ "report"),
    do: %{"key" => key, "recipient" => recipient, "delivery" => delivery, "kind" => kind}

  test "reports count staging, acceptance and delivery; a completion with its message is settled" do
    completions = [completion("a", "p"), completion("b", "p")]

    messages = [
      message("a", "p", "accepted"),
      message("b", "p", "pending"),
      message("x", "p", "accepted", "agent")
    ]

    assert Evidence.reports(completions, messages) ==
             %{staged: 2, accepted: 2, delivered: 1, pending: 1, settled: true}
  end

  test "a completion without its message is settled only when its recipient has 64 pending" do
    pending = for n <- 1..64, do: message("m#{n}", "p", "pending", "agent")
    staged = [completion("new", "p")]

    assert Evidence.reports(staged, pending).settled
    refute Evidence.reports(staged, tl(pending)).settled
    refute Evidence.reports(staged, Enum.map(pending, &%{&1 | "recipient" => "q"})).settled
  end

  defp persisted(id, answers), do: %{id: id, answers: answers}

  test "every reported session is persisted once with one answer per completed turn" do
    turns = [{"a", true}, {"a", true}, {"b", true}, {"b", false}]
    ok = Evidence.reconcile(["a", "b"], turns, [persisted("a", 2), persisted("b", 1)], false)
    assert ok.sessions_persisted and ok.answers_persisted
  end

  test "a missing or duplicated session record fails; an extra one fails unless censored" do
    turns = [{"a", true}]
    refute Evidence.reconcile(["a", "b"], turns, [persisted("a", 1)], false).sessions_persisted
    refute Evidence.reconcile(["a", "b"], turns, [persisted("a", 1)], true).sessions_persisted

    dup = [persisted("a", 1), persisted("a", 1)]
    refute Evidence.reconcile(["a"], turns, dup, false).sessions_persisted

    extra = [persisted("a", 1), persisted("x", 0)]
    refute Evidence.reconcile(["a"], turns, extra, false).sessions_persisted
    assert Evidence.reconcile(["a"], turns, extra, true).sessions_persisted
  end

  test "persisted answers must equal completed turns, or cover them when censored" do
    turns = [{"a", true}, {"a", true}]
    refute Evidence.reconcile(["a"], turns, [persisted("a", 1)], false).answers_persisted
    refute Evidence.reconcile(["a"], turns, [persisted("a", 3)], false).answers_persisted
    assert Evidence.reconcile(["a"], turns, [persisted("a", 3)], true).answers_persisted
    refute Evidence.reconcile(["a"], turns, [persisted("a", 1)], true).answers_persisted
    refute Evidence.reconcile(["a"], turns, [], false).answers_persisted
  end

  test "every persisted tool failure counts, whenever it was persisted" do
    assert Evidence.tool_failures([false, true, false, true, false]) == 3
    assert Evidence.tool_failures([false]) == 1
    assert Evidence.tool_failures([true, true]) == 0
    assert Evidence.tool_failures([]) == 0
  end
end
