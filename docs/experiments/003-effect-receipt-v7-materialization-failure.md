# EXP-003: ER-3/FND-2-v7 materialization failure

> - **Disposition:** V7 invalid; stopped without repair, retry, selection, or
>   materialization
> - **Canonical issue:**
>   [ROB-875](https://linear.app/robert-guss/issue/ROB-875/er3-v7-fnd-materialize-fresh-command-path-qualified-inputs)
> - **Committed beacon:** drand mainnet round `6429446`
> - **Deterministically derivable seed:**
>   `cec34ff6d4d5e3cd08fb9ac1fdda458685e7e57a3199cb6e1e168734432dccd0`
> - **Failed materializer SHA-256:**
>   `c7553203e057a15fbe6fe18bb41f8f1edf6005582e1567e19727952f81af684c`

## Disposition

V7 is invalid. Its first materializer invocation stopped at the first frozen
source-identity guard, before reading the beacon artifacts, deriving the seed,
selecting a candidate, generating held-out literals, or writing a manifest,
dogfood plan, or external attestation. The command was not retried.

The beacon randomness was already public to the process and printed by the
successful official-client verification. Because the frozen seed and sampling
rules made every downstream choice deterministically computable from that
randomness, repairing the materializer and invoking it again would be a repair
under an exposed beacon. V7 therefore stops under its broad fail-closed rule:
“Any failure stops V7 without repair under the same beacon.”

A local correction to the stale path transformation was drafted after the
failure but never invoked. It was discarded, and the tracked materializer
preserves the exact failed source. Any future attempt requires a versioned
successor whose materializer is frozen and audited before a genuinely future
beacon is committed or fetched.

## Pre-beacon audit and verification

At `2026-09-02T02:00:22Z`, before fetching the beacon:

- `HEAD == origin/main == 60ddad4ff6da7819ffb4528f39c5145743742ed8` and the
  worktree was clean;
- the V7 protocol and preregistration matched their pushed hashes;
- the ROB-873 report matched
  `c7522da0fd1730b61241898450893b7761d59ea8dab0721cb01d0e4e7eabf435`;
- all frozen adapter, target-runner, neutral-runner, preflight,
  candidate-source, and compatibility-source identities matched; and
- the report still contained exactly 20 mappings, 40 no-fault runs, 17 eligible
  candidates, 34 assignments, 72 fault runs, 112 total command-path runs, and
  zero held-out exposure.

At `2026-09-02T02:00:53Z`, one invocation of the pinned `drand-client@1.4.2`
fetched only round `6429446` from the two committed relays. Both responses
matched on round, randomness, signature, and previous signature, and both
verified against the pinned default-mainnet chain hash and public key. The
verified randomness was
`04a354a886b685477dd10dc439ded5fd66202f1e4d7077ac1b019447f3c75049`. No alternate
round, relay, substitution, or retry was used.

## Exact failure

The failed source adapted the V6 materializer through textual transforms. It
updated the expected V7 preflight hash but failed to transform the snake-case
path `priv/benchmark/preflight_exp003_v6.exs` to its V7 counterpart. The first
generated guard therefore compared the V6 source bytes with the frozen V7 hash
and failed closed:

```text
mix run priv/benchmark/materialize_exp003_v7.exs
** (MatchError) no match of right hand side value:

    false

    priv/benchmark/materialize_exp003_v3.exs:17:
      Elara.Benchmark.Exp003V7Materializer.run/0
```

The next statement would have loaded compatibility data, and the beacon read
would have followed that. Neither occurred. No candidate frame was sampled and
no generated output path was created.

## Preserved evidence

| Artifact                    | SHA-256                                                            |
| --------------------------- | ------------------------------------------------------------------ |
| `api.drand.sh.json`         | `6e4f05a476f1ce700d250adc243e360e1b9138d9428f829341310c1f08a1518b` |
| `drand.cloudflare.com.json` | `6e4f05a476f1ce700d250adc243e360e1b9138d9428f829341310c1f08a1518b` |
| `verification.json`         | `bd5f1c7be2612e9832e8eb51bebee5cd29cf62d621b566f26425804621b43d11` |
| `verify.cjs`                | `7fc21b05daa29aa520964eebd1bd091c0a13b4ff5d1ee16f2d1908be9d99c066` |
| `package.json`              | `7674a6925d4d822771fbca3118c78208e20a8607bee8159aefc90e149c0d8291` |
| failed V7 materializer      | `c7553203e057a15fbe6fe18bb41f8f1edf6005582e1567e19727952f81af684c` |
| V7 protocol                 | `8b0c643649ac52d40c247694b3b28d7b819b1cbb96c1588a51c9328be482e257` |
| V7 preregistration          | `fbebaba1c4f5f38f79c8d770a21fabd0ddca4c3ccc6e1ecb5aa58f694010a693` |

## Exposure and downstream authorization

| Exposure                                                      |    Count |
| ------------------------------------------------------------- | -------: |
| V7 beacon fetches through the sole official-client invocation | 2 relays |
| V7 candidate selections                                       |        0 |
| V7 held-out literals generated                                |        0 |
| V7 materialized manifests                                     |        0 |
| V7 target fault runs                                          |        0 |
| V7 target timing runs                                         |        0 |
| V7 external fault runs                                        |        0 |
| V7 dogfood runs                                               |        0 |
| V7 `B` or `T` calculations                                    |        0 |

ROB-876 and ROB-877 are not authorized because no valid V7 corpus exists.
ROB-878 may only record its protocol-required non-execution, and the V7 gate may
not make a thesis decision from this invalid attempt. V7 supports no durable-
effects, comparative-runtime, product-scope, or BEAM-superiority claim.
