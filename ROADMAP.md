# Elara roadmap

> **Canonical roadmap and status source** · **Updated:** 2026-09-02 · **Owner:**
> solo development with AI collaborators

This file is the only current plan and status source for Elara. Completed work
and retired research remain available in Git history rather than as parallel
roadmaps or archived planning documents in the working tree.

## Working rules

- Keep at most one item `IN PROGRESS`. Normally exactly one item is executable
  as either `TODO` or `IN PROGRESS`; later items remain `BLOCKED`.
- Mark an item `DONE` only after its Result records the pushed commit, checks,
  deviations, and remaining uncertainty.
- Exercise features through the public product path. Test-only infrastructure
  does not establish user-visible behavior.
- Prefer one complete vertical slice over additional research harnesses or
  speculative infrastructure.
- Fail uncertain mutations closed. Workspace bytes may prove a current
  postcondition, but not causal job completion.
- Commit and push each completed item before starting its successor.

Statuses are `TODO`, `IN PROGRESS`, `BLOCKED`, `DONE`, `CANCELED`, and
`INVALID`.

## Current direction

Elara has supervised session actors, a pure session reducer, persisted and
detachable conversations, capability-routed local and remote workers,
deterministic replay, live plugins, and an operation-aware durable-effects
subsystem.

The durable-effects research established useful subsystem behavior for stable
job identity, controller intent, executor receipts, declarative writes, literal
patches, and truthful opaque-shell uncertainty. It did not establish production
behavior because the receipt target was research-only and normal `ask`/`chat`
sessions could bypass it.

ER-3 is therefore closed as a **METHOD STOP**, not as a rejection of the
durable-effects thesis. Its condition-aware classifier could reject unexpected
outcomes as invalid instead of producing a valid negative comparison, so another
confirmatory version would not answer the product question. V9 is not planned.
The next work is the smallest production vertical slice.

## Execution queue

| ID     | Status | Item                                                    | Depends on       |
| ------ | ------ | ------------------------------------------------------- | ---------------- |
| PROD-1 | DONE   | Ship receipt-backed local declarative writes end-to-end | ER-3 METHOD STOP |
| PROD-2 | TODO   | Ship receipt-backed local literal edits end-to-end      | PROD-1           |

## PROD-1 — Ship receipt-backed local declarative writes end-to-end

**Status:** DONE

### Outcome

Make the built-in local `write` tool use the durable receipt protocol by default
through `Elara.start_session/1`, `mix elara.ask`, and `mix elara.chat`,
including recovery through `mix elara.chat --continue`. A user-visible write
must either have durable causal completion evidence or report truthful
uncertainty; it must never silently fall back to an unreceipted mutation.

### Scope

- Replace `Elara.Effect.Sidecar`'s hard-coded dependency on the research-only
  `Elara.Effect.TestExecutor` with the smallest explicit executor contract for
  its existing submit, query, and continue lifecycle. Keep `TestExecutor` as a
  test implementation of that contract.
- Add a supervised local executor that owns and reopens its durable
  `ExecutorLedger`, so controller or session loss does not destroy the mutation
  record. A resumed persisted session must address the same logical executor and
  ledger rather than creating an empty substitute.
- Route the built-in local `write` tool through `Elara.Effect.DeclarativeWrite`
  and the receipt sidecar. Preserve its public arguments and normal result shape
  while recording stable job identity, operation digest, controller intent,
  acceptance, callback attempt, and terminal evidence.
- Remove the silent `effect_executor == nil` direct-execution bypass for this
  write path. Executor startup, identity, ledger, or reconciliation failure must
  fail closed with an actionable error or an `indeterminate` result, never by
  rerunning the write outside the protocol.
- Reconcile unresolved writes during normal persisted-session continuation.
  Surface recovered terminal outcomes and truthful indeterminacy through the
  existing tool-result and CLI rendering paths.
- Exercise the vertical slice through the public session API with the scripted
  provider. Cover the existing crash boundaries, same-ID/different-digest
  rejection, terminal recovery without re-execution, and
  callback-attempted-without-terminal indeterminacy.

### Non-goals

No literal-patch, opaque-shell, plugin-mutation, or remote-worker production
wiring; no remote durable ledger; no generic exactly-once claim; no broad
session or router rewrite; no new confirmatory experiment; and no
BEAM-superiority claim. Patch, shell, and remote durability require separate
decisions after this local write slice is running through the product path.

### Acceptance criteria

- Default public session and CLI construction provides the production local
  executor. Built-in writes cannot reach `Router.execute/4` through the current
  nil-executor bypass.
- The executor contract is exercised by both the production executor and test
  executor; its durable ledger rejects a reused job ID with a different digest
  and preserves callback-attempt and terminal state across owner restart.
- Persisted-session continuation reconciles each unresolved write once: terminal
  evidence is returned without mutation re-execution, accepted but unattempted
  work may continue only under the original durable identity, and an attempted
  write without causal terminal evidence is reported as `indeterminate` rather
  than retried.
- Targeted integration tests drive the write through `Elara.start_session/1` and
  the same configuration used by `ask` and `chat`.
- User documentation explains receipt-backed write and continuation behavior.
  `mix format --check-formatted`, `mix compile --warnings-as-errors`, targeted
  effect/session/CLI tests, and full `mix test` pass.
- The Result records the pushed commit, exact checks, deviations, remaining
  uncertainty, and the evidence-based decision for the next product slice.

### Result

**DONE (2026-09-02).** Pushed implementation commit
[`4d87900`](https://github.com/robertguss/elixir-harness/commit/4d879006d1795001b8b1282116ee6bf5227e0c7e)
to `origin/main` from a checkout synchronized at
`bd56cd9611da4f8c305ad5e4114da8d3540e03ea`.

The exact built-in local `write` now provisions a stable workspace executor,
commits a typed declarative-write intent, records acceptance and callback
attempt before mutation, performs same-directory atomic replacement, records a
terminal receipt, and preserves the existing successful `wrote N bytes to path`
tool result. `Elara.Effect.Sidecar` depends on the shared
`Elara.Effect.Executor` contract rather than `TestExecutor`; production and test
facades use the same ledger-owning server. The supervised production executor
reopens one ledger and executor identity for the same cwd/workspace pair.

Public `Elara.start_session/1` tests proved the write path without a usable
router, terminal continuation without rewriting, accepted/unattempted
continuation exactly once under the original identity, and attempted/nonterminal
continuation as `indeterminate` without retry. Contract tests proved durable
terminal and callback-attempt state across executor restart and
same-ID/different-digest rejection. A separate product-path test proved the
default production executor does not receipt `edit`.

Exact verification:

- `mix test test/elara/effect/production_write_test.exs` — 6 passed.
- `mix test test/elara/effect/production_write_test.exs test/elara/executor/protocol_test.exs test/elara/effect/job_test.exs test/elara/effect/marker_integration_test.exs test/elara/effect/write_reconciliation_test.exs test/elara/effect/crash_matrix_test.exs test/elara/session_test.exs test/elara/chat_test.exs`
  — 87 passed.
- `mix format --check-formatted` — exit 0.
- `mix compile --warnings-as-errors` — exit 0.
- `mix test` — 290 passed. The documented `CrashTool` `RuntimeError: boom` line
  was the only expected error log.
- `git diff --check` — exit 0 before commit; `git push origin main` advanced
  `origin/main` from `bd56cd9` to `4d87900`.

Deviations: the successful argument and result shapes are unchanged, but local
`write` is now intentionally workspace-confined: it rejects absolute/traversal
paths, symlink components, and non-file targets so the declarative preimage is
meaningful. This is a product safety change required by the frozen write
protocol, and is documented. No `edit`, `bash`, plugin, or remote receipt wiring
was added. The shared executor implementation was extracted rather than
duplicated behind two wrappers.

Remaining uncertainty: this establishes the local built-in write path and
process/owner restart behavior, not power-loss guarantees beyond SQLite's
configured WAL/FULL durability, generic exactly-once effects, remote durability,
or receipt-backed edit/shell behavior. One-shot `mix elara.ask` uses the durable
executor but intentionally has no persisted conversation to continue after its
process exits.

Decision: proceed to PROD-2 for the exact built-in local `edit`, using the
existing operation-aware literal-patch protocol and the same production
executor. It is the next smallest user-visible mutation slice and tests whether
the production boundary generalizes beyond whole-file replacement. Opaque shell
and remote-worker durability remain blocked on separate designs.

## PROD-2 — Ship receipt-backed local literal edits end-to-end

**Status:** TODO

### Outcome

Route the exact built-in local `edit` tool through `Elara.Effect.LiteralPatch`
and the production executor by default. Preserve its public arguments and normal
result shape while removing unreceipted fallback and reconciling unresolved
edits through normal persisted-session continuation.

### Scope and acceptance

- Derive and durably bind the expected preimage, exact one-match replacement,
  and postimage before dispatch; fail closed on invalid, missing, ambiguous,
  symlinked, or concurrently changed targets.
- Reuse the PROD-1 executor contract, stable local executor, controller journal,
  and truthful terminal/indeterminate rendering. Do not add shell, plugin, or
  remote receipt behavior.
- Drive no-fault and continuation states through `Elara.start_session/1`, prove
  the exact built-in edit cannot reach the router fallback, and prove `bash`
  remains outside production receipts.
- Update user documentation and pass targeted tests, format, warnings-as-errors
  compile, and the full test suite before recording and pushing the Result.
