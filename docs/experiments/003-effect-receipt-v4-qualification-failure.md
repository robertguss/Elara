# EXP-003: ER-3/FND-2-v4 qualification failure

> - **Disposition:** v4 stopped; no confirmatory execution authorized
> - **Canonical issue:**
>   [ROB-856](https://linear.app/robert-guss/issue/ROB-856/er3-v4-build-qualify-and-freeze-the-confirmatory-entrypoint)
> - **Source manifest:**
>   `14cc3a57763f0ab48f4b68a70317916d09ff4bee64ba18d150480dd1315820a2`
> - **Raw checkpoint:**
>   `test/fixtures/benchmark/exp003-v4/internal-confirmatory-qualification-failed.checkpoint.json`
> - **Raw checkpoint SHA-256:**
>   `e206f46325c420f5c664a0c185b223896e4a745ab598cc7091350769e5878a41`

## Observation

The checked-in v4 command completed all 72 development fault runs and the full
72-run development no-fault timing shape. Its atomic checkpoint contains 288
matched `started`/`completed` events, every raw record, and no unmatched run.
All tasks have `exposure_split=development_adapter_fixture`. No held-out v4
fault row, held-out no-fault timing row, comparator fault, dogfood task, or
confirmatory `B`/`T` result was observed.

Scoring then exposed an internally contradictory frozen expectation. Every F4
baseline repetition correctly produced:

- `primary_recovery_class=manual_recovery`;
- `causal_terminal_evidence_observed=false`; and
- `terminal_convergence_ms=null`.

Every F4 receipts repetition produced `automatic_terminal` with bounded causal
terminal proof. The manifest nevertheless represented
`causal_terminal_evidence_expected_to_survive` as one row-level `true` value,
and the runner/scorer applied it to both conditions. The scorer therefore
reported `Fail` for three unique baseline F4 development rows (nine
repetitions), despite their matching the frozen baseline recovery class and safe
action.

The complete development-only diagnostic was:

```text
valid=true, status=Fail
B=12, T=3, B-T=9, material_improvement=true
knowledge_and_safe_action.pass=true
causal_terminal_convergence.pass=false
causal_terminal_convergence.applicable_repetitions=18
no_fault_correctness.pass=true
timing.pass=true
```

Canonical report writing then failed because the unchanged scorer carries its
terminal failure diagnostics as Elixir tuples, which `JSON.Encoder` cannot
encode. No final qualification report was written.

## Why v4 stops

The base preregistration requires a new protocol version and future seed even
when a factual error is discovered before confirmatory exposure. The v4
amendment also freezes the unchanged scorer and says an inconsistent entrypoint
run is retained rather than retried. Correcting the scalar condition model or
serialization in place and rerunning v4 would violate those rules.

V5 must represent causal-terminal applicability explicitly per condition, select
the condition-specific scalar in every emitted record, apply the same
condition-specific expectation in immutable scoring checks, serialize all score
diagnostics canonically, and reject any qualification whose score is not `Pass`.
V4's checkpoint remains development failure evidence and is never used as v5
qualification evidence.

## Frozen command identities

| Artifact                                       | SHA-256                                                            |
| ---------------------------------------------- | ------------------------------------------------------------------ |
| `lib/elara/benchmark/internal_confirmatory.ex` | `856cf4b16c156c1dbb462186d60d1e472ca0de7041f6506d5e930e6f0ccd4588` |
| `priv/benchmark/run_internal_confirmatory.exs` | `f3ff39bb7a0184e7cbe99414bf457b7510fa0b225e22de7e27e5e1cd46d1bea4` |
| `lib/elara/benchmark/elara_adapter.ex`         | `d95ba568b3b03ac15477e65596b3fece7023310ff3694e617ec1f50f3d472183` |
| `lib/elara/benchmark/runner.ex`                | `3b3ab321dcd0540bc1a8532be834021c8d3f471b7c87951a5626a6663f084a71` |
| `lib/elara/benchmark/qualification.ex`         | `0935535262146339b388d2e220c11b2b24b06b436544d03ab752b931d9b3e825` |
| `lib/elara/benchmark/scorer.ex`                | `5eca1f7bfac64dc52d398e1ecf2a1d95b53b1ae36e3165348bb108666ac013a5` |
| qualification manifest                         | `df817f2439071ce4050d18820bb4b5bef7d642a614638f5a44415c9838888d46` |

## Reproduction command

```text
mix run priv/benchmark/run_internal_confirmatory.exs -- \
  qualify test/fixtures/benchmark/exp003-v4/manifest.json \
  /tmp/elara-exp003-v4-qualification-state \
  /tmp/elara-exp003-v4-qualification-workspace \
  test/fixtures/benchmark/exp003-v4/internal-adapter-qualification.json
```
