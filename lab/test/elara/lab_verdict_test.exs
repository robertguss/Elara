defmodule Elara.Lab.VerdictTest do
  use ExUnit.Case, async: true

  alias Elara.Lab.Verdict

  @ceiling 5_242_880
  @full for t <- 0..9, do: %{t: t * 100, per_session: 1_000}

  defp facts(overrides) do
    base = %{
      compliant: true,
      complete: true,
      latency: %{p95: 10, cohort: 1_000, cohort_known: true, proven_failures: 0},
      memory: %{samples: @full, from: 0, to: 1_000, sample_ms: 100, baseline: true},
      throughput: %{ratio: 0.99}
    }

    Map.merge(base, overrides, fn
      _key, %{} = left, %{} = right -> Map.merge(left, right)
      _key, _left, right -> right
    end)
  end

  test "a compliant complete run with full evidence holds every bound" do
    assert Verdict.bounds(facts(%{})) ==
             %{latency: "holds", memory: "holds", throughput: "holds"}
  end

  test "latency p95 of 49 ms holds, 50 ms and infinity fail" do
    assert Verdict.bounds(facts(%{latency: %{p95: 49}})).latency == "holds"
    assert Verdict.bounds(facts(%{latency: %{p95: 50}})).latency == "fails"
    assert Verdict.bounds(facts(%{latency: %{p95: :infinity}})).latency == "fails"
    assert Verdict.bounds(facts(%{latency: %{cohort: 0, p95: nil}})).latency == "undetermined"
  end

  test "an incomplete run fails latency only with a known cohort and 20 x B > C" do
    incomplete = %{complete: false}

    known = fn b ->
      facts(Map.put(incomplete, :latency, %{p95: :infinity, proven_failures: b}))
    end

    assert Verdict.bounds(known.(51)).latency == "fails"
    assert Verdict.bounds(known.(50)).latency == "undetermined"

    unknown = facts(Map.put(incomplete, :latency, %{cohort_known: false, proven_failures: 999}))
    assert Verdict.bounds(unknown).latency == "undetermined"
    assert Verdict.bounds(facts(incomplete)).latency == "undetermined"
  end

  test "memory at exactly the ceiling fails, also in an incomplete run" do
    high = List.replace_at(@full, 4, %{t: 400, per_session: @ceiling})
    assert Verdict.bounds(facts(%{memory: %{samples: high}})).memory == "fails"

    assert Verdict.bounds(facts(%{complete: false, memory: %{samples: high}})).memory ==
             "fails"

    below = List.replace_at(@full, 4, %{t: 400, per_session: @ceiling - 1})
    assert Verdict.bounds(facts(%{memory: %{samples: below}})).memory == "holds"
    assert Verdict.bounds(facts(%{complete: false})).memory == "undetermined"
  end

  test "memory holds only with full coverage of the eligible interval" do
    gap = Enum.reject(@full, &(&1.t in [400, 500]))
    unavailable = List.replace_at(@full, 3, %{t: 300, per_session: nil})
    late_start = Enum.drop(@full, 2)
    early_end = Enum.drop(@full, -2)

    for samples <- [gap, unavailable, late_start, early_end, []] do
      assert Verdict.bounds(facts(%{memory: %{samples: samples}})).memory == "undetermined"
    end

    assert Verdict.bounds(facts(%{memory: %{baseline: false}})).memory == "undetermined"

    # One eligible sample over the ceiling amid unavailable ones still fails.
    mixed = [%{t: 0, per_session: nil}, %{t: 100, per_session: @ceiling + 1}]
    assert Verdict.bounds(facts(%{memory: %{samples: mixed}})).memory == "fails"
  end

  test "samples outside [from, to) neither cover nor fail the bound" do
    after_load = @full ++ [%{t: 1_000, per_session: @ceiling * 2}]
    assert Verdict.bounds(facts(%{memory: %{samples: after_load}})).memory == "holds"

    before = [%{t: -100, per_session: @ceiling * 2} | @full]
    assert Verdict.bounds(facts(%{memory: %{samples: before}})).memory == "holds"
  end

  test "throughput ratio 0.95 holds, 0.9499 fails, incomplete is undetermined" do
    assert Verdict.bounds(facts(%{throughput: %{ratio: 0.95}})).throughput == "holds"
    assert Verdict.bounds(facts(%{throughput: %{ratio: 0.9499}})).throughput == "fails"

    assert Verdict.bounds(facts(%{complete: false, throughput: %{ratio: 0.1}})).throughput ==
             "undetermined"
  end

  test "a non-compliant workload leaves every bound undetermined" do
    failing =
      facts(%{
        compliant: false,
        latency: %{p95: :infinity, proven_failures: 1_000},
        memory: %{samples: [%{t: 0, per_session: @ceiling * 2}]},
        throughput: %{ratio: 0.1}
      })

    assert Verdict.bounds(failing) ==
             %{latency: "undetermined", memory: "undetermined", throughput: "undetermined"}
  end
end
