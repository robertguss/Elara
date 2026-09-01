# EXP-003 V6 internal execution failure

> - **Protocol:** ER-3/FND-2-v6
> - **Disposition:** invalid; stopped without repair, resume, replacement, or
>   retry
> - **Frozen command commit:**
>   [`c54e857`](https://github.com/robertguss/elixir-harness/commit/c54e857abe1c8dddd29e0531e4508726f2e0a9e0)
> - **Source manifest SHA-256:**
>   `b415272e106db54087edbd54500c3544c94ca13b2d42950c0a63b82a38c0973c`
> - **Qualification report SHA-256:**
>   `8ef12be71c61bded368bca509d9b2d3ea6ef2e2aa44b24a698d641843576ed23`
> - **Failed checkpoint:**
>   [`internal-confirmatory-execution-failed.checkpoint.json`](../../test/fixtures/benchmark/exp003-v6/internal-confirmatory-execution-failed.checkpoint.json)
> - **Checkpoint SHA-256:**
>   `9b8dce8dce1a53761e7f842a9648f22e1e75b65cd9c2b3ec5d7865112e72f4bb`
> - **Canonical completed-records SHA-256:**
>   `165fb02b010a3bfe42189a3ebbf5f652c08ef46c87e8c6993f76c57497c5f1aa`
> - **Canonical issue:**
>   [ROB-870](https://linear.app/robert-guss/issue/ROB-870/er3-v6-execute-the-frozen-internal-confirmatory-comparison)

## Disposition

The one authorized V6 internal execution is invalid. The command stopped
fail-closed after 18 completed held-out fault runs and one unmatched start. It
did not produce an aggregate execution report, run the no-fault timing schedule,
calculate `B` or `T`, or authorize replay, dogfood, or GATE-3.

The command, adapter, corpus, schedule, scorer, and thresholds must not be
repaired for V6. The failed state must not be resumed, and the missing run must
not be retried or replaced. Any future confirmatory attempt requires a new
preregistered protocol and fresh evidence boundary.

## Frozen preflight and command

Immediately before execution:

- the worktree was clean at
  `HEAD == origin/main == c54e857abe1c8dddd29e0531e4508726f2e0a9e0`;
- the V6 manifest, qualification report, qualification checkpoint, and all 12
  frozen command source identities matched exactly;
- the qualification score was exactly `valid=true,status=Pass` with zero V6
  confirmatory exposure; and
- state, workspace, output, and replay-output paths were absent.

The command was invoked once:

```text
mix run priv/benchmark/run_internal_confirmatory.exs -- execute \
  test/fixtures/benchmark/exp003-v6/manifest.json \
  test/fixtures/benchmark/exp003-v6/internal-confirmatory-qualification.json \
  /tmp/elara-rob870-v6-execute-state \
  /tmp/elara-rob870-v6-execute-workspace \
  /tmp/elara-rob870-v6-execution.json
```

It exited nonzero with:

```text
{:run_failed, :fault,
 %{"condition" => "baseline", "order_index" => 1,
   "row_id" => "P06-F1", "run_index" => 1},
 {:harness_failure, {:adapter_error, :invalid_frozen_plan}}}
```

No execution output file was created.

## Exact failure

The first three ordered rows—`S04-F2`, `P08-F2`, and `W02-F2`—completed all six
frozen repetitions, producing 18 completed records: nine baseline and nine
receipts. Event 37 then durably recorded the start of baseline repetition 1 for
`P06-F1`; no matching completion exists.

P06 is the selected two-step patch task. Its plan has two tool calls followed by
final assistant text and requires a continuation after a live successful target
effect. The frozen Elara adapter maps only a single step with exactly one tool
call followed by final assistant text. It therefore rejected P06 as
`:invalid_frozen_plan` before target execution.

The development qualification did not expose this incompatibility because its
three development adapter fixtures—P01, S02, and W01—are all single-step. The V6
preflight proved fixture construction and task-level operation semantics, but it
did not drive every candidate plan through the frozen command adapter.

Authoritative frozen inputs and command boundaries:

- [P06 in the V6 manifest](https://github.com/robertguss/elixir-harness/blob/c54e857abe1c8dddd29e0531e4508726f2e0a9e0/test/fixtures/benchmark/exp003-v6/manifest.json)
- [single-step adapter mapping](https://github.com/robertguss/elixir-harness/blob/c54e857abe1c8dddd29e0531e4508726f2e0a9e0/lib/elara/benchmark/elara_adapter.ex#L119-L143)
- [development qualification task derivation](https://github.com/robertguss/elixir-harness/blob/c54e857abe1c8dddd29e0531e4508726f2e0a9e0/lib/elara/benchmark/qualification.ex#L69-L92)
- [stop-on-first-failure orchestration](https://github.com/robertguss/elixir-harness/blob/c54e857abe1c8dddd29e0531e4508726f2e0a9e0/lib/elara/benchmark/internal_confirmatory.ex#L199-L228)

## Preserved raw evidence

The canonical checkpoint contains 37 events:

| Event class        | Count |
| ------------------ | ----: |
| fault started      |    19 |
| fault completed    |    18 |
| no-fault started   |     0 |
| no-fault completed |     0 |

All 18 completed event record hashes independently match their canonical raw
records. The completed rows are exactly `S04-F2`, `P08-F2`, and `W02-F2`.

The partial records are not scoreable and must not be treated as a smaller
denominator. They also contain an independent invalidity signal: all three
receipts repetitions for `S04-F2` are `harness_failure` with
`recovery_class_mismatch`, `unexpected_converged_workspace`, and
`unclassified_recovery`. No aggregate safety, effect-size, timing, Narrow, or
Gate claim is made from partial evidence.

## Exposure and required next actions

| Exposure                                                 | Count |
| -------------------------------------------------------- | ----: |
| V6 held-out target fault runs completed                  |    18 |
| V6 held-out target fault runs started without completion |     1 |
| V6 no-fault timing runs                                  |     0 |
| V6 external fault runs                                   |     0 |
| V6 dogfood runs                                          |     0 |
| V6 `B` or `T` calculations                               |     0 |

ROB-871 must take its protocol-required non-execution path because there is no
complete valid internal report. ROB-872 cannot select Continue, Narrow, Pivot,
or Stop from complete V6 evidence and must close without a thesis decision or
BEAM-superiority claim.
