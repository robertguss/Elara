defmodule Elara.Lab.HistogramTest do
  use ExUnit.Case, async: true

  alias Elara.Lab.Histogram

  defp snapshot(values, min \\ 0, max \\ 9_999) do
    histogram = Histogram.new(min, max)
    Enum.each(values, &Histogram.record(histogram, &1))
    Histogram.snapshot(histogram)
  end

  test "nearest-rank percentiles over 1 ms buckets" do
    assert %{count: 100, p50: 50, p95: 95, p99: 99, max: 100} =
             Histogram.percentiles(snapshot(Enum.to_list(1..100)))

    assert %{count: 3, p50: 7, p95: 7, p99: 7, max: 7} =
             Histogram.percentiles(snapshot([7, 7, 7]))

    assert Histogram.percentiles(snapshot([])) == nil
  end

  test "9,999 ms is in range and 10,000 ms overflows, ranking as infinity" do
    snap = snapshot([9_999, 10_000])
    assert snap.overflow == 1
    assert snap.counts == %{9_999 => 1}
    assert %{p50: 9_999, p99: :infinity, max: :infinity} = Histogram.percentiles(snap)
  end

  test "extra infinite observations rank above every recorded value" do
    snap = snapshot(Enum.to_list(1..95))
    assert %{count: 100, p95: 95, p99: :infinity} = Histogram.percentiles(snap, 5)
    assert %{count: 101, p95: :infinity} = Histogram.percentiles(snap, 6)
  end

  test "values below the range underflow and rank lowest" do
    snap = snapshot([-1_001, -1_000, 5], -1_000, 9_999)
    assert snap.underflow == 1
    assert %{p50: -1_000, max: 5} = Histogram.percentiles(snap)
    assert %{count: 3} = Histogram.percentiles(snap)
    assert Histogram.percentiles(snapshot([-2_000], -1_000, 9_999)).p50 == :neg_infinity
  end

  test "at_least counts values at or above a threshold, overflow included" do
    snap = snapshot([48, 49, 50, 51, 12_000])
    assert Histogram.at_least(snap, 50) == 3
    assert Histogram.at_least(snap, 49) == 4
    assert Histogram.at_least(snap, 10_000) == 1
  end
end
