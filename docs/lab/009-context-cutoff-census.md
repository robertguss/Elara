# 009 — Recorded context-cutoff decisions

- **Question:** Can an offline cutoff comparison explain the first different
  context branch without replaying the shell or guessing omitted inputs?
- **Hypothesis H1:** Complete scripted observations reproduce the baseline
  branch and identify the first differing branch at the inclusive cutoff;
  missing data never counts as a match. Any skipped gate, precedence error,
  baseline mismatch or comparison past the first divergence/gap refutes H1.
- **Queue:** [ROB-1098](https://linear.app/robert-guss/issue/ROB-1098)
  · **Registered:** 2026-10-07, Linear comment
  `31f52817-5489-475f-b9f7-0eb103a53dc6`, before runtime edits.
- **Baseline:** [PR #64](https://github.com/robertguss/Elara/pull/64).

## Method and contract

Use fixed scripted public-session fixtures and independent arithmetic fixtures,
not model calls or a production corpus. Cover dispatch, handoff attempt/success/
failure, frozen precedence, slot denial, original causal IDs, file/live equality,
cutoff boundaries, missing/truncated observations, bad references/versions,
baseline inconsistencies and separate history-rebase segments. Accounting
fixtures include explicit/catalog/default limits, usage floors, images and
agent-authored input. The frozen shell guard uses injected in-flight state;
ordinary new asks reject frozen sources before this gate.

The additive v1 flight capability `context_gate: 1` records the existing live
budget and branch before its action. Observations use `fixed_reserves_v1`:
estimate + output + handoff + tool + uncertainty reserves >= cutoff. Frozen
always selects interruption; the other branches are **attempt** handoff and
**attempt** dispatch, not evidence those actions succeeded. Private provider
state and attachment bytes remain excluded. Default live policy is unchanged.

Call `Elara.FlightRecorder.ContextCensus.compare(recording_or_path, cutoff)`
with a positive integer absolute cutoff. No catalog lookup, Core stepping,
provider/tool execution, handoff preparation or slot acquisition occurs.
This holds recorded accounting fixed; changing `context_limit` would also
change reserves and is a different intervention.

Each segment reports eligible/compared/excluded counts and match, divergence,
unknown, or no decisions. Comparison stops at first divergence or gap; a
divergent observation counts as compared, an unknown one as excluded. Later
segments are separately conditional on their recorded baseline seeds, not a
continuation of the counterfactual. Legacy files report unsupported; invalid
references/incomplete transitions return errors. No outcome-quality, token-
savings, performance or cross-restart continuity claim is made.

## Verification

Raw logs: `lab/results/rob-1098-context-cutoff-20261007/`.

```sh
mix test test/elara/context_census_test.exs test/elara/flight_recorder_test.exs \
  test/elara/context_test.exs test/elara/threads_test.exs \
  test/elara/session/core_property_test.exs --seed 1098
mix test --seed 1098
mix compile --warnings-as-errors
mix format --check-formatted
```

Final focused run: **77 passed (11 properties, 66 tests)**. Full suite:
**1061 passed (11 properties, 1050 tests)**, seed 1098, 326.7 seconds on the
Linux x64 orb (Elixir 1.20.3 / OTP 29). Compile warnings-as-errors, format and
source/doc diff checks passed. Oracle follow-up found no remaining blockers.

The initial focused run was 56/57: the frozen fixture incorrectly supplied a
closure instead of a tool MFA. After fixing that fixture, oracle review exposed
two real candidate defects: fresh-VM safe decoding lacked branch atoms, and
malformed expected effects could erase coverage. Added regressions reproduced
both (12/14 passed before fixes); those candidate results are not acceptance.
The recorder now owns the atom vocabulary and the census validates coverage
envelopes before filtering. A separate BEAM loads/replays all three branches
without loading Session or Census. All failed logs remain beside final logs.

The corrected implementation supports H1 on these bounded fixtures only. No
production corpus was evaluated, and no preferred cutoff was selected. Future
corpus use requires fresh observations and must retain the same prefix limits.
