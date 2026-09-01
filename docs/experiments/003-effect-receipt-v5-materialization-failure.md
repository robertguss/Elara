# EXP-003: ER-3/FND-2-v5 materialization failure

> - **Disposition:** v5 stopped; no corpus or confirmatory output materialized
> - **Canonical issue:**
>   [ROB-861](https://linear.app/robert-guss/issue/ROB-861/er3-v5-fnd-rematerialize-fresh-condition-correct-inputs)
> - **Committed beacon:** drand mainnet round `6428936`
> - **Derived seed:**
>   `9ddb3981ca995df34afee6c37d614726c1cec9a06317a3dab85ab75a31885468`

## Observation

At 2026-09-01T21:45:18Z, after the committed nominal time, both official relays
returned round `6428936` with randomness
`c9e677cb38d693e56180a238c080e7559905ceaf646cb9dfc1e84b7c2d89af58`. The
responses agree after decoding, the signature hashes to the randomness, and
`drand-client@1.4.2` verified both against the pinned chain hash and public key.

The frozen seed selected these 12 tasks in order:

```text
P02,S03,P03,W03,S04,W07,W02,S02,P07,W01,P06,S01
```

The first materializer run then raised `CondClauseError` at the selected-task
constructor dispatch. P02 is a valid preregistered candidate—"Make one exact
unique edit in a CRLF file without changing other bytes"—but the frozen
materializer can instantiate only 19 of the 20 candidates. P02 is the sole
missing constructor.

The failure occurred before writing `manifest.json`, `dogfood-plan.json`, or
`external-adapter-equivalence.json`. No task bytes, fault row, target process,
timing run, comparator, dogfood task, `B`, or `T` were produced.

## Why v5 stops

V5 required all 20 candidates and all 40 candidate/fault assignments to be
mechanically validated before seed selection. The compatibility profiles were
validated, but actual task construction remained selected-only, so that
precondition was false. Once the beacon revealed P02's selection, adding its
constructor would be a selection-conditioned materializer change.

The base amendment policy requires a new version and genuinely future seed even
for a pre-result factual correction. Oracle independently confirmed that
deterministic P02 construction cannot retroactively satisfy the preselection
validation boundary. V5 therefore stops without a retry. V6 must freeze P02 and
prove exhaustive 20/20 construction plus 40/40 semantic validation before its
future beacon.

## Beacon evidence

| Artifact                         | SHA-256                                                            |
| -------------------------------- | ------------------------------------------------------------------ |
| `api.drand.sh.json`              | `24898a55a44ab5b9146cd6e745db0d0a688ebca8261695180bcc55015dd98a04` |
| `drand.cloudflare.com.json`      | `0ab8759a9caa6dabd507ae39d88bdc955ae935f63c21b8996a6436807ff0a60b` |
| `verification.json`              | `26656c573f96abceb9a3b55eb0e933313b352974e42757ec5c0e5bcb37d2c1d1` |
| `verify.cjs`                     | `474e7f3e09859db544ab6a9d7ef13fdffeb3456baa0a195f0ba030d23df46e04` |
| `package.json`                   | `50ba65ec34a7c5b4276d8f719a1ffe6e4cd01a7429daed9fff52c3938aeb3bf8` |
| frozen v5 materializer           | `35fd59e3906ac44d1bcfafe60047d657aa1666d24e0c2a74c645d09bc9b6a05b` |
| frozen v5 compatibility contract | `256812afbb42f9c35f81a5c3a650dc59b34623acc88d48f44153033d01d8cfde` |

## Failed command

```text
mix run priv/benchmark/materialize_exp003_v5.exs
** (CondClauseError) no cond clause evaluated to a truthy value
    priv/benchmark/materialize_exp003_v2.exs:193: ...build_task/6
```
