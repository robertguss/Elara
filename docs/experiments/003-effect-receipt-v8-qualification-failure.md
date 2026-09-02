# EXP-003 V8 qualification failure

> - **Preregistration version:** ER-3/FND-2-v8
> - **Roadmap item:** ER3-V8-4
> - **Disposition:** INVALID — frozen qualification command rejected the frozen
>   confirmatory protocol; no retry, repair, resume, replacement, or V8
>   execution
> - **Frozen protocol SHA-256:**
>   `3644b5a3c07663fe7be9f67a710689ce5df43eb4eceb306f2a5f76d8eb26949a`
> - **Materialization receipt SHA-256:**
>   `d152bece940eae9718ea3f000e0b4d4c662ca0af0c6fcff553e772d35b532508`
> - **Qualification preflight:** 2026-09-02T14:06:21Z
> - **Failure observation audit:** 2026-09-02T14:08:25Z
> - **Canonical status:** [`../roadmap.md`](../roadmap.md)

V8 had already validly fetched and materialized its committed beacon, selection,
and held-out literals in ER3-V8-3. ER3-V8-4 was the first permitted invocation
of the frozen qualification command against that fresh corpus. It failed at the
first final-protocol command-frame guard, before qualification state, workspace,
checkpoint, report, replay, target, or execution-claim creation.

## Preflight

Immediately before the sole attempt:

- `HEAD` and `origin/main` were clean and equal at
  `afdbf88e1a7854b61e4a57dfe2358669ab8b2d9c`.
- The frozen protocol, semantic commitment, all 17 source identities, all five
  semantic inputs, all 12 predecessor-artifact identities, all receipt-bound
  corpus files, both verifier-runtime files, and the permanent beacon claim
  matched their expected SHA-256 values.
- The baseline and receipts target commits were present.
- The qualification state root, workspace root, report, report temporary path,
  checkpoint destination, replay destination, and receipt-keyed confirmatory
  execution claim were all absent.
- The materialization receipt still recorded zero V8 target fault runs, target
  timing runs, external fault runs, dogfood runs, and no `B` or `T` calculation.

The exact command was invoked once:

```text
mix run priv/benchmark/run_exp003_v8.exs -- qualify docs/experiments/003-effect-receipt-v8-protocol.json 3644b5a3c07663fe7be9f67a710689ce5df43eb4eceb306f2a5f76d8eb26949a test/fixtures/benchmark/exp003-v8/materialization-receipt.json d152bece940eae9718ea3f000e0b4d4c662ca0af0c6fcff553e772d35b532508 /tmp/elara-er3-v8-4-qualification-state /tmp/elara-er3-v8-4-qualification-workspace test/fixtures/benchmark/exp003-v8/internal-confirmatory-qualification.json
```

Its exact output was:

```text
** (RuntimeError) EXP-003 V8 command failed: :commands
    priv/benchmark/run_exp003_v8.exs:83: (file)
    (elixir 1.20.3) lib/code.ex:1639: Code.require_file/2
```

The process exited with status 1. The command was not retried.

## Frozen mismatch

The invoked confirmatory protocol's `command_stack.commands` has the exact key
set:

```text
beacon_fetch,beacon_verify,beacon_verify_copy,execute,materialize,qualify,replay
```

The frozen command source requires that same map to have exactly:

```text
execute,qualify,replay
```

Specifically, `lib/elara/benchmark/exp003/command.ex` at frozen SHA-256
`c09aa9e80c9c340c918d0b43a76286378e078ea69ded6c8528d5931f028d56ea` contains:

```elixir
check(Enum.sort(Map.keys(commands || %{})) == ~w(execute qualify replay), :commands)
```

Both pre-beacon development protocols had only those three keys and therefore
passed the exercised command stack. The final confirmatory protocol added the
four frozen beacon/materialization commands to `command_stack.commands`, while
retaining the already-frozen exact-three-key guard. Changing either side after
beacon, selection, and literal exposure would be a result-conditioned protocol
repair and is forbidden.

## Preserved postcondition

After failure, all of these remained absent:

```text
/tmp/elara-er3-v8-4-qualification-state
/tmp/elara-er3-v8-4-qualification-workspace
test/fixtures/benchmark/exp003-v8/internal-confirmatory-qualification.json
test/fixtures/benchmark/exp003-v8/internal-confirmatory-qualification.json.tmp
test/fixtures/benchmark/exp003-v8/internal-confirmatory-qualification.checkpoint.json
test/fixtures/benchmark/exp003-v8/internal-confirmatory-qualification.replay.json
~/.elara/benchmark/exp003/execution-claims/d152bece940eae9718ea3f000e0b4d4c662ca0af0c6fcff553e772d35b532508.json
```

Therefore ER3-V8-4 produced zero qualification fault runs, zero qualification
no-fault runs, and zero checkpoint events. It did not invoke replay. V8 target
fault runs, target timing runs, comparator runs, external fault runs, dogfood
runs, `B`, and `T` all remain zero, and no confirmatory execution attempt was
claimed.

## Disposition

V8 is invalid without a qualification result. The failure is immutable and may
not be retried, repaired, resumed, replaced, denominator-reduced, or relabeled.
ER3-V8-5 through ER3-V8-7 are not authorized. Any continuation requires V9 with
a corrected, pre-beacon-exercised final protocol and genuinely future
randomness.

Deviations: none. Remaining uncertainty: qualification behavior beyond the first
command-frame guard was not observed.
