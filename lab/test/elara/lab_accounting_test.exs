defmodule Elara.Lab.Client.AccountingTest do
  use ExUnit.Case, async: true

  alias Elara.Lab.Client.Accounting

  # ttft 300 ms, 50 deltas/s (20 ms apart), 5-delta answers, window [1_300, 1_500).
  defp acc(opts \\ []) do
    Accounting.new(
      Keyword.merge(
        [sim_id: "u", ttft_ms: 300, interval_ms: 20.0, answer_deltas: 5, window: {1_300, 1_500}],
        opts
      )
    )
  end

  defp row(request, started, choice \\ :answer, emitted \\ 0, state \\ :started),
    do: {{"u", request}, started, choice, emitted, state}

  defp stamp(request, index), do: String.pad_trailing("#{request}:#{index}", 20, ".")

  defp arrive(acc, request, index, now, cutoff \\ nil, rows \\ []),
    do: Accounting.arrival(acc, stamp(request, index), now, cutoff, fn -> rows end)

  test "latency is arrival minus the stamp's intended time, with window membership" do
    acc = Accounting.ingest(acc(), [row(3, 1_000)])

    assert {acc, {:observed, 5, true, true}} = arrive(acc, 3, 0, 1_305)
    assert {acc, {:observed, 12, true, true}} = arrive(acc, 3, 1, 1_332)
    # intended 1_380 and 1_400 are in the cohort; arrival 1_500 is outside the window.
    assert {acc, {:observed, 0, true, true}} = arrive(acc, 3, 2, 1_340)
    assert {acc, {:observed, 1, true, true}} = arrive(acc, 3, 3, 1_361)
    assert {_acc, {:observed, 120, true, false}} = arrive(acc, 3, 4, 1_500)
  end

  test "the cohort is intended times in [window start, window end)" do
    acc = Accounting.ingest(acc(window: {1_320, 1_360}), [row(3, 1_000)])
    # intended: 1_300, 1_320, 1_340, 1_360, 1_380
    assert {_, {:observed, _, false, _}} = arrive(acc, 3, 0, 1_310)
    assert {_, {:observed, _, true, _}} = arrive(acc, 3, 1, 1_330)
    assert {_, {:observed, _, true, _}} = arrive(acc, 3, 2, 1_345)
    assert {_, {:observed, _, false, _}} = arrive(acc, 3, 3, 1_365)

    summary = Accounting.finalize(acc, [row(3, 1_000, :answer, 5, :completed)], 2_000)
    assert summary.expected_in_cohort == 2
  end

  test "an unreceived answer followed by a full answer keeps both attributions exact" do
    rows = [row(3, 1_000, :answer, 5, :completed), row(6, 5_000, :answer, 5, :completed)]
    acc = Accounting.ingest(acc(window: {0, 10_000}), rows)

    {latencies, acc} =
      Enum.map_reduce(0..4, acc, fn index, acc ->
        {acc, {:observed, latency, true, true}} = arrive(acc, 6, index, 5_300 + index * 20 + 7)
        {latency, acc}
      end)

    assert latencies == [7, 7, 7, 7, 7]
    summary = Accounting.finalize(acc, rows, 6_000)
    assert summary.expected == 10 and summary.emitted == 10 and summary.received == 5
    assert summary.emitted_unreceived == 5
    assert summary.unreceived_in_cohort == 5
    assert summary.fully_received_answers == 1
  end

  test "an arrival for a request not yet ingested looks it up; an unknown one is unattributed" do
    assert {acc, {:observed, 1, _, _}} = arrive(acc(), 6, 0, 5_301, nil, [row(6, 5_000)])
    assert {acc, :unattributed} = arrive(acc, 9, 0, 9_301)
    assert {acc, :unattributed} = Accounting.arrival(acc, "garbage", 9_400, nil, fn -> [] end)
    acc = Accounting.ingest(acc, [row(7, 6_000, {:tool, "bash"})])
    assert {acc, :unattributed} = arrive(acc, 7, 0, 6_400)
    assert Accounting.finalize(acc, [], 10_000).unattributed == 3
  end

  test "arrivals after the cutoff are counted apart and are not received" do
    acc = Accounting.ingest(acc(), [row(3, 1_000)])
    assert {acc, {:observed, _, _, _}} = arrive(acc, 3, 0, 1_310, 1_310)
    assert {acc, :post_cutoff} = arrive(acc, 3, 1, 1_311, 1_310)

    summary = Accounting.finalize(acc, [row(3, 1_000, :answer, 2, :started)], 1_310)
    assert summary.received == 1 and summary.post_cutoff == 1
    assert summary.emitted_unreceived == 1 and summary.expected_unemitted == 3
  end

  test "an unreceived cohort delta is a proven failure only when the stop is >= 50 ms after it" do
    acc = Accounting.ingest(acc(window: {0, 10_000}), [row(3, 1_000)])
    # intended 1_300 .. 1_380; stop 1_350 proves 1_300 (50 ms), not 1_320 (30 ms).
    summary = Accounting.finalize(acc, [row(3, 1_000, :answer, 0, :started)], 1_350)
    assert summary.unreceived_in_cohort == 5
    assert summary.proven_late_unreceived == 1

    summary = Accounting.finalize(acc, [row(3, 1_000, :answer, 0, :started)], 1_349)
    assert summary.proven_late_unreceived == 0
  end

  test "a completed short answer is non-compliant; an interrupted one is censored" do
    short = Accounting.finalize(acc(), [row(3, 1_000, :answer, 4, :completed)], 2_000)
    assert short.non_compliant_answers == 1 and short.interrupted == 0

    cut = Accounting.finalize(acc(), [row(3, 1_000, :answer, 4, :started)], 2_000)
    assert cut.non_compliant_answers == 0 and cut.interrupted == 1
  end

  test "the oldest pending expected delta tracks the next unreceived index" do
    acc = Accounting.ingest(acc(), [row(3, 1_000), row(1, 900, {:tool, "read"})])
    assert Accounting.oldest_pending(acc) == 1_300
    {acc, _} = arrive(acc, 3, 0, 1_301)
    assert Accounting.oldest_pending(acc) == 1_320

    acc = Enum.reduce(1..4, acc, fn i, acc -> elem(arrive(acc, 3, i, 1_400), 0) end)
    assert Accounting.oldest_pending(acc) == nil
  end

  test "a late earlier index fills its hole; a duplicate is counted apart and not observed" do
    acc = Accounting.ingest(acc(), [row(3, 1_000)])
    {acc, {:observed, _, _, _}} = arrive(acc, 3, 1, 1_330)
    {acc, {:observed, _, _, _}} = arrive(acc, 3, 0, 1_331)
    assert {acc, :duplicate} = arrive(acc, 3, 0, 1_332)
    assert Accounting.oldest_pending(acc) == 1_340

    summary = Accounting.finalize(acc, [], 2_000)
    assert summary.out_of_order == 1 and summary.duplicates == 1 and summary.received == 2
  end

  test "received counts only unique indices; holes stay unreceived in the cohort" do
    acc = Accounting.ingest(acc(window: {0, 10_000}), [row(3, 1_000)])
    {acc, {:observed, _, _, _}} = arrive(acc, 3, 4, 1_400)
    assert Accounting.oldest_pending(acc) == 1_300

    # Holes at 0..3 (intended 1_300 .. 1_360); the stop at 1_400 proves 1_300 .. 1_340.
    summary = Accounting.finalize(acc, [row(3, 1_000, :answer, 5, :completed)], 1_400)
    assert summary.received == 1 and summary.received_in_cohort == 1
    assert summary.unreceived_in_cohort == 4 and summary.proven_late_unreceived == 3
    assert summary.expected_in_cohort == summary.received_in_cohort + summary.unreceived_in_cohort
  end

  test "an index outside the answer is invalid and not observed" do
    acc = Accounting.ingest(acc(), [row(3, 1_000)])
    assert {acc, :invalid} = arrive(acc, 3, 5, 1_400)
    assert Accounting.finalize(acc, [], 2_000).invalid == 1
  end
end
