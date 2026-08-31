# EXP-003 / ER-1: frozen effect-receipt contract

> **Status:** Frozen by ROB-667; target implementation has not begun **Contract
> version:** ER-1/FND-1-v1 **Frozen against:**
> `23e603550253c69846795b13cc2f2670f1122e21` **Canonical issue:**
> [ROB-667](https://linear.app/robert-guss/issue/ROB-667/fnd-1-freeze-the-er-1-contract-and-baseline-current-behavior)
> **Date:** 2026-08-31

This is the executable contract for the ER-1 synthetic marker experiment. It
freezes the baseline, protocol, fault schedules, evidence policy, expected
truth, permitted recovery, bounds, and eligible Narrow scope before the target
exists. Later implementation and matrix issues may report deviations; they may
not edit this contract after observing target results.

## Claim and limits

ER-1 tests whether a controller-owned stable job ID and operation digest,
durable intent, durable executor acceptance, and evidence-driven reconciliation
can prevent duplicate external mutation and false classification while
preserving honest indeterminacy. It does not claim generic exactly-once callback
invocation, runtime superiority, or durability for every Elara effect.

The generic safety claim is **no duplicate external mutation**. Admission,
callback attempt, and external mutation are separate measurements.

`Elara.Session.Core` remains unchanged. Cancellation, leases, fencing,
distributed ownership, production worker migration, providers, plugins, real
write/edit/bash support, and a public job API are outside ER-1.

## Pinned current baseline

### Observed sequence

```text
Core.step emits {:run_tool, core_ref, call, tool}
  -> Flight Recorder writes transition_end and file.sync/1
  -> Session assigns {recording_id, sequence, effect_index}
  -> Session persists ordinary assistant/message effects
  -> ordinary/plugin dispatch discards that causal effect ID
  -> Router selects an in-memory worker checkout
  -> remote worker decodes one socket request and spawns a linked job
  -> callback mutates the workspace
  -> one terminal socket reply returns through Router and the session Task
  -> Core consumes {:tool_result, core_ref, outcome}
  -> Flight Recorder syncs that reducer transition
  -> Session.Store rewrites and renames the JSONL transcript with ToolResult
```

The Flight Recorder transition is synced before dispatch, but it is not a
mutation intent or executor receipt. `Session.Store` uses temp-file rename but
does not call `file.sync`; no host-power-loss guarantee is inferred. Router
checkouts and worker jobs are volatile. Socket loss kills the socket-scoped
worker job. Mutating transport loss becomes `:indeterminate`; read-only
transport loss may select another worker. A session is a temporary child and is
not automatically restarted.

On manual reopen, `Session.Core.repair_history/1` adds `{:error, "interrupted"}`
for unresolved tool calls and `Session` persists that repair. This makes the
conversation wire-legal. It proves neither external failure nor external success
and is never admissible effect-reconciliation evidence.

### Current-versus-target truth table

“N/A / non-equivalent” means the baseline has no corresponding durable seam; the
nearest current observation is included without inventing equivalence.

<table>
  <thead>
    <tr>
      <th>Row / frozen cut</th>
      <th>Current baseline</th>
      <th>Target final truth</th>
      <th>Session classification</th>
      <th>Permitted target action</th>
      <th>Bound</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>1 — before controller intent commit</td>
      <td><strong>N/A / non-equivalent.</strong> A Flight Recorder effect may be synced, but there is no intent commit, query, or automatic session restart.</td>
      <td>No intent / <code>unknown</code> / marker count 0; definitely not admitted, invoked, or mutated.</td>
      <td>Failure: <code>not_started</code> (not executor <code>failed</code>).</td>
      <td>Do not reconcile or auto-retry; a later user request may allocate and commit a new job.</td>
      <td>One journal scan, 0 executor queries, ≤1,000 ms.</td>
    </tr>
    <tr>
      <td>2 — after intent commit, before dispatch</td>
      <td><strong>N/A / non-equivalent.</strong> No baseline intent exists.</td>
      <td>Intent / eventually <code>completed</code> / marker count 1. Before reconciliation, executor is <code>unknown</code> and no callback could have run.</td>
      <td>Success.</td>
      <td>Query original owner; on <code>unknown</code>, submit the same ID/digest once.</td>
      <td>≤2 queries + 1 submit, ≤1,000 ms.</td>
    </tr>
    <tr>
      <td>3 — after executor receipt, before acceptance commit</td>
      <td><strong>N/A / non-equivalent.</strong> Decode/receipt is volatile and there is no acceptance transaction or hook.</td>
      <td>Intent / eventually <code>completed</code> / marker count 1. The first volatile receipt admitted nothing.</td>
      <td>Success.</td>
      <td>Restart the same executor owner, query, then submit same ID/digest once on <code>unknown</code>.</td>
      <td>≤2 queries + 1 submit, ≤1,000 ms.</td>
    </tr>
    <tr>
      <td>4 — after acceptance commit, before acceptance reply</td>
      <td><strong>N/A / non-equivalent.</strong> No baseline acceptance record or acceptance reply exists.</td>
      <td>Intent / <code>accepted</code> then <code>completed</code> / marker count 1; one admission and no pre-crash callback attempt.</td>
      <td>Success.</td>
      <td>Query original owner; continue that accepted job once because durable attempt count is 0.</td>
      <td>≤2 queries + 1 continue, ≤1,000 ms.</td>
    </tr>
    <tr>
      <td>5 — after acceptance reply, before callback invocation/mutation</td>
      <td><strong>N/A / non-equivalent.</strong> The current worker sends only a terminal reply.</td>
      <td>Intent + observed <code>accepted</code> / <code>accepted</code> then <code>completed</code> / marker count 1; no pre-crash callback attempt.</td>
      <td>Success.</td>
      <td>Continue only on the same accepting owner because durable attempt count is 0.</td>
      <td>≤2 queries + 1 continue, ≤1,000 ms.</td>
    </tr>
    <tr>
      <td>6 — after external mutation, before completion commit</td>
      <td>Exact target commit seam is <strong>N/A / non-equivalent</strong>. Nearest tested baseline kills a worker after a shell marker appears and receives one <code>:indeterminate</code> result.</td>
      <td>Intent + observed <code>accepted</code> / <code>accepted</code> with callback-attempt count 1 / marker count 1 and <code>postcondition_satisfied</code>; executor completion is unproved.</td>
      <td><code>:indeterminate</code>. Missing: durable causal <code>completed</code> or <code>failed</code>.</td>
      <td>Query and observe once; never reinvoke, resubmit, or fail over. Preserve marker and report safe manual acceptance/inspection.</td>
      <td>1 query + 1 workspace observation, ≤1,000 ms.</td>
    </tr>
    <tr>
      <td>7 — after completion commit, before completion reply</td>
      <td><strong>N/A / non-equivalent.</strong> No baseline completion ledger exists.</td>
      <td>Intent + observed <code>accepted</code> / <code>completed</code> / marker count 1.</td>
      <td>Success recovered from causal terminal evidence.</td>
      <td>Query the original ledger and persist exactly one session result; no callback.</td>
      <td>1 query, ≤1,000 ms.</td>
    </tr>
    <tr>
      <td>8 — after completion reply, before session-result persistence</td>
      <td><strong>N/A / non-equivalent in durability.</strong> A volatile current terminal reply can race transcript append; reopen repairs it to <code>interrupted</code>, which is not effect truth.</td>
      <td>Intent + observed <code>completed</code> / <code>completed</code> / marker count 1; transcript initially has no result.</td>
      <td>Success recovered from causal terminal evidence.</td>
      <td>Manually rehydrate the same session, verify/query terminal evidence, and persist exactly one result before Core hydration repair.</td>
      <td>≤1 query + 1 result append, ≤1,000 ms.</td>
    </tr>
  </tbody>
</table>

## Frozen target protocol

The required order is:

```text
controller intent commit
  -> executor receipt
  -> durable acceptance commit
  -> acceptance reply
  -> durable callback-attempt increment
  -> callback invocation
  -> external marker mutation
  -> durable completion commit
  -> completion reply
  -> controller observation commit
  -> session-result persistence
```

The callback-attempt increment is the invocation-attempt observation and occurs
immediately before invocation. It is not a terminal state. Acceptance reply
always precedes the increment and mutation. Completion reply always follows a
terminal commit.

### Identity and digest

The controller-owned job ID is versioned and derived from the synced Flight
Recorder effect identity `(recording_id, transition sequence, effect_index)`;
the model-provided tool-call ID is correlation data, never the sole identity.
The controller commits that ID before dispatch and reloads it rather than
deriving a replacement after restart.

The v1 operation digest is SHA-256 over deterministic external-term encoding of
this versioned tuple:

```text
{:elara_er1_operation, 1,
 operation_kind, tool_name, tool_version, canonical_arguments,
 workspace_id, sorted_required_capabilities, authority_scope,
 marker_schema_version}
```

Map insertion order cannot affect the encoding. Changes to operation kind, tool
version, arguments, workspace, capabilities/authority, or schema version must
change the digest.

### State and evidence vocabulary

- Executor durable state is only `accepted`, `completed`, or `failed`. `unknown`
  is a query observation meaning no surviving record.
- Controller durable state is `intent` plus the last executor observation it has
  durably proven. Intent alone proves neither receipt nor acceptance.
- `accepted` proves exactly one ID/digest-bound admission. It proves no callback
  invocation, external mutation, or terminal outcome.
- `callback_invoked` is represented by the durable attempt count changing from 0
  to 1 before invocation. It proves an attempt, not its outcome.
- `external_mutation_observed` is the independently read marker count/token. The
  ER-1 marker bytes include ID/digest correlation, but any workspace writer
  could reproduce them; without exclusive authority/fencing and an atomic
  receipt they are not causal completion proof.
- `postcondition_satisfied` is current workspace state. It may justify a safe
  next action but never manufactures executor `completed`.
- Executor `completed` or `failed` requires the accepting ledger's committed
  causal result/error and result digest.
- Session success/failure requires corresponding admissible truth.
  `:indeterminate` means no causal terminal fact establishes success or failure
  and may coexist with intent, acceptance, callback-attempt, mutation, or
  postcondition evidence.
- A synced Flight Recorder effect may identify and correlate a job. It does not
  prove dispatch, acceptance, invocation, mutation, or completion.
- Transcript contents and transcript repair are never admissible external
  execution evidence.

### Invariants

1. One admission per job ID/digest; admission count is 0 or 1.
2. Same ID with a different digest is rejected before callback or mutation.
3. No duplicate external marker mutation.
4. No callback reinvocation unless the entire external mutation is atomically
   deduplicated and causally receipted by ID/digest. The ER-1 marker is
   deliberately non-deduplicating, so a durable attempt count of 1 permanently
   forbids reinvocation.
5. No false success and no false error.
6. No accepted-job failover. Recovery addresses the same logical executor ID and
   its reopened ledger; a replacement executor is prohibited.
7. No-fault execution has exactly one admission, one callback attempt, one
   external mutation, one durable completion, and one terminal session result.
8. Admission, callback-attempt, external-mutation, and session-result counts are
   asserted separately.
9. Process restart policy is not mutation retry policy. Restart may reload
   evidence; it may continue an accepted job only when durable attempt count is
   0 and only on the same owner.
10. Causal terminal evidence, current postcondition, historical-execution
    knowledge, and session classification remain separate fields.

## Fixture, ownership, storage, and fault mechanics

### Marker fixture

The only ER-1 mutation is test-owned and non-deduplicating. Every callback
invocation appends one uniquely countable record containing the job ID, digest,
and a fixture token. It returns a result whose digest can be stored in the
executor ledger. The marker file and its parent temporary workspace are owned by
`test/elara/effect/`; production write/edit/bash/plugin/provider paths are not
redirected.

The executor ledger owns admission and callback-attempt counts. The workspace
marker owns external-mutation count. The session store owns terminal-result
count. No one source substitutes for another.

### Controller seam and manual rehydration

The integration seam is a test-only effect sidecar called from the Session shell
after Flight Recorder transition sync and before dispatch of the marker's
mutating `run_tool` effect. It receives the existing effect ID, creates/loads
the controller job, commits intent, and submits through the test executor.
Nonmutating tools retain the current direct path. `Elara.Session.Core` gains no
job state, fact, phase, or recovery policy.

Session children remain `restart: :temporary`. Controller-crash rows explicitly
wait for the old owner and lock to exit, then start a new owner for the same
session ID, session path, controller database, original executor ID, and
workspace. Before normal `Core.new/2` hydration can persist `interrupted`, a
pre-hydration recovery step resolves committed jobs from journal/ledger evidence
and appends a proven terminal result or the frozen honest classification. It
does not use the repaired transcript as effect evidence.

### Transactional primitive

Controller journal and test-executor ledger are separate embedded SQLite
databases on disk. They use explicit schema and digest versions, unique keys on
job ID, a unique `(job_id, operation_digest)` admission, transactions,
`PRAGMA journal_mode=WAL`, and `PRAGMA synchronous=FULL`. ROB-668/669 may select
the smallest maintained Elixir SQLite adapter; no Ecto layer is required.

Minimum tested guarantee:

- a transaction acknowledged committed is visible after killing its owning
  process, closing the connection, and reopening from the same path;
- a crash before commit leaves no row/state transition;
- a row is never partially visible and uniqueness survives reopen;
- executor terminal result/error and result digest commit atomically;
- the database files and marker workspace survive named process crashes.

The matrix does not simulate disk deletion, filesystem corruption, machine power
loss, dishonest storage, or loss of both journal and ledger. SQLite settings are
not evidence beyond the close/kill/reopen tests.

### Deterministic hooks

Each hook is a test-only barrier which reports arrival and waits. The test kills
the named owner while it is blocked; no sleep establishes semantic ordering.

| Row | Hook                                                    | Owner killed             |
| --- | ------------------------------------------------------- | ------------------------ |
| 1   | `:before_intent_commit`                                 | controller/session owner |
| 2   | `:after_intent_commit_before_dispatch`                  | controller/session owner |
| 3   | `:after_receipt_before_accept_commit`                   | executor owner           |
| 4   | `:after_accept_commit_before_accept_reply`              | executor owner           |
| 5   | `:after_accept_reply_before_callback`                   | executor owner           |
| 6   | `:after_external_mutation_before_completion_commit`     | executor owner           |
| 7   | `:after_completion_commit_before_completion_reply`      | executor owner           |
| 8   | `:after_completion_reply_before_session_result_persist` | controller/session owner |

The observation deadline for every row is 1,000 ms of monotonic time beginning
only after all owners required by that row report ready. A “query attempt” is
one ledger query. “Continue” is the one same-owner transition from accepted
attempt-count 0 to its first attempt; it is not submit, duplicate submit, or
failover. No periodic polling, backoff, or action occurs after the stated
attempt maximum or deadline.

## Detailed crash schedules

All rows assume the controller database, executor database, session file, Flight
Recorder file, and workspace survive unless the cut precedes their named commit.
Killing a process loses its mailbox, stack, tasks, sockets, and uncommitted
transaction. Delivered/dropped below refers to protocol messages, not
test-barrier notifications.

### Row 1 — before controller intent commit

- **Crash/failpoint:** kill the temporary controller/session owner while blocked
  at `:before_intent_commit`, after the reducer effect transition is synced but
  before opening/committing the intent transaction.
- **Messages:** no submit, receipt, acceptance reply, or completion reply is
  delivered; the pending local effect dispatch is dropped with the owner.
- **Durable facts / last fact:** Flight Recorder has the emitted effect
  identity; controller has no intent; executor query is `unknown`. Last durable
  effect fact is “effect emitted”; last durable job fact is **none**.
- **Workspace/proof:** marker count 0. Under dispatch-after-intent ordering, the
  absent atomic intent proves no dispatch, admission, callback, or mutation.
- **Storage/restart:** uncommitted controller work is lost; all existing files
  survive. After the old lock is released, manually start the same session
  owner. Executor was untouched.
- **Admissible evidence:** Flight Recorder identity, reopened controller journal
  absence, executor `unknown`, and marker count. Transcript repair is excluded.
- **Historical knowledge:** definitely not admitted, invoked, or mutated.
- **Classification/action:** session-visible failure `not_started`; this is not
  executor `failed`. Do not create/reconcile/retry a job automatically. A later
  explicit user operation may create a new committed job.
- **Convergence:** one journal scan, zero executor queries, marker/admission/
  attempt/result counts all 0, and truthful failure/safe action within 1,000 ms.

### Row 2 — intent committed, dispatch not begun

- **Crash/failpoint:** kill controller at
  `:after_intent_commit_before_dispatch`.
- **Messages:** none leaves the controller; all executor replies are absent.
- **Durable facts / last fact:** controller has one v1 intent bound to the
  original executor ID; executor is `unknown`. Last durable fact is `intent`.
- **Workspace/proof:** marker count 0 at crash; intent proves no execution.
- **Storage/restart:** committed intent survives; volatile session state is
  lost. Manually start the same controller/session; executor remains the same
  live owner and ledger.
- **Admissible evidence:** controller intent, original executor query, ledger
  response, and final marker/result counts; never transcript repair.
- **Historical knowledge:** before reconciliation there was no admission,
  invocation, or mutation.
- **Classification/action:** query original owner. `unknown` permits exactly one
  same-ID/digest submit because callback-before-acceptance is impossible. Await
  its normal terminal evidence and classify success; no replacement/failover.
- **Convergence:** at most two queries and one submit; final counts 1 admission,
  1 attempt, 1 mutation, 1 result and `completed`/success within 1,000 ms.

### Row 3 — receipt delivered, acceptance not committed

- **Crash/failpoint:** deliver submit and block the executor at
  `:after_receipt_before_accept_commit`; kill that executor owner.
- **Messages:** submit/receipt is delivered. Acceptance and completion replies
  are absent; the socket and uncommitted receipt state are dropped.
- **Durable facts / last fact:** controller intent survives; executor has no row
  after reopen (`unknown`). Last durable fact is controller `intent`.
- **Workspace/proof:** marker count 0 at crash. Protocol ordering proves no
  callback before acceptance commit.
- **Storage/restart:** reopen the same executor ID from the same ledger first;
  controller stays live. Uncommitted executor work is lost; journal/workspace
  survive.
- **Admissible evidence:** intent and the reopened original ledger's `unknown`;
  receipt barrier is test ground truth, not a durable admission.
- **Historical knowledge:** receipt occurred, but admission/invocation/mutation
  definitely did not.
- **Classification/action:** one same-ID/digest submit to that same owner is
  permitted on `unknown`; no failover. Final classification is success.
- **Convergence:** at most two queries and one submit; final counts 1/1/1/1 and
  terminal success within 1,000 ms.

### Row 4 — acceptance committed, acceptance reply not sent

- **Crash/failpoint:** kill executor at
  `:after_accept_commit_before_accept_reply`.
- **Messages:** submit/receipt is delivered. Acceptance reply is dropped; no
  completion reply exists.
- **Durable facts / last fact:** controller has intent with no proven executor
  observation; executor has `accepted`, admission count 1, attempt count 0. Last
  durable fact is executor `accepted`.
- **Workspace/proof:** marker count 0 at crash. Attempt count 0 proves no
  callback attempt under the frozen ordering.
- **Storage/restart:** reopen the same executor ID/ledger; controller stays
  live. No replacement is registered.
- **Admissible evidence:** original ledger `accepted`, count 0, and subsequent
  causal terminal row. Transcript and marker absence alone are not used.
- **Historical knowledge:** exactly one admission, no callback or mutation yet.
- **Classification/action:** query returns accepted; its delivered accepted
  observation precedes one explicit same-owner continue. Continue atomically
  increments attempt count then invokes once. Duplicate submit/query itself does
  not invoke. Final classification is success.
- **Convergence:** at most two queries plus one continue; final counts 1/1/1/1
  and terminal success within 1,000 ms.

### Row 5 — acceptance delivered, callback not invoked

- **Crash/failpoint:** deliver acceptance, durably store the controller's
  accepted observation, block executor at `:after_accept_reply_before_callback`,
  then kill executor.
- **Messages:** submit/receipt and acceptance reply are delivered; completion
  reply is absent.
- **Durable facts / last fact:** controller intent + last observation accepted;
  executor accepted, admission count 1, attempt count 0. Last durable fact is
  the accepted observation.
- **Workspace/proof:** marker count 0 at crash; durable attempt count 0 proves
  no callback attempt.
- **Storage/restart:** reopen same executor ID/ledger; controller remains live.
- **Admissible evidence:** both accepted records, zero attempt count, later
  terminal ledger evidence, and independent final counts.
- **Historical knowledge:** admitted exactly once and not yet invoked/mutated.
- **Classification/action:** one same-owner continue is permitted; resubmit and
  failover are prohibited. Final classification is success.
- **Convergence:** at most two queries plus one continue; final 1/1/1/1 counts
  and terminal success within 1,000 ms.

### Row 6 — external mutation happened, completion not committed

- **Crash/failpoint:** after the durable attempt increment and one marker
  append, block at `:after_external_mutation_before_completion_commit`; kill
  executor.
- **Messages:** submit/receipt and acceptance reply are delivered. No completion
  reply exists.
- **Durable facts / last fact:** controller intent + accepted observation;
  executor state accepted, admission count 1, callback-attempt count 1, no
  terminal result. Last durable fact is `callback_invoked` while state remains
  accepted—not completion.
- **Workspace/proof:** marker count 1 with matching ID/digest; current
  `postcondition_satisfied` and test ground truth say one external mutation.
  Because marker creation is not atomically fenced/receipted with exclusive
  authority, observation does not prove executor `completed`.
- **Storage/restart:** reopen same executor ID/ledger; controller stays live;
  marker survives. The missing completion transaction is absent.
- **Admissible evidence:** intent, accepted, attempt count 1, terminal-row
  absence, and noncausal marker/postcondition observation. Transcript is
  excluded.
- **Historical knowledge:** admitted and attempted; runtime lacks a causal
  terminal fact. Test ground truth records one mutation, but cannot elevate the
  runtime classification.
- **Classification/action:** `:indeterminate` with all surviving evidence and
  missing causal `completed`/`failed` named. Do not continue, reinvoke, submit,
  retry, or fail over. Preserve marker and advise inspection/manual acceptance.
- **Convergence:** exactly one query and one workspace observation; counts
  admission 1, attempt 1, mutation 1, session result 1 indeterminate; truthful
  knowledge and safe action within 1,000 ms. Terminal convergence is neither
  required nor permitted without an atomic exclusive causal receipt.

### Row 7 — completion committed, completion reply not sent

- **Crash/failpoint:** commit completed state/result/result digest, block at
  `:after_completion_commit_before_completion_reply`, then kill executor.
- **Messages:** submit/receipt and acceptance reply are delivered; completion
  reply is dropped.
- **Durable facts / last fact:** controller intent + accepted observation;
  executor `completed`, admission 1, attempt 1. Last durable fact is executor
  `completed` with causal result digest.
- **Workspace/proof:** marker count 1 and postcondition satisfied, but
  completion comes from the ledger, not workspace inference.
- **Storage/restart:** reopen same executor ID/ledger; controller stays live.
- **Admissible evidence:** durable terminal row and digest; marker is a separate
  corroborating observation.
- **Historical knowledge:** this accepted job completed once.
- **Classification/action:** query terminal evidence, persist one success
  result, and never invoke/submit again.
- **Convergence:** one query; final counts 1/1/1/1 and terminal success within
  1,000 ms.

### Row 8 — completion delivered, session result not persisted

- **Crash/failpoint:** deliver completion, durably store the controller's
  completed observation, block before feeding/persisting the ToolResult at
  `:after_completion_reply_before_session_result_persist`, then kill controller.
- **Messages:** submit/receipt, acceptance reply, and completion reply are all
  delivered. The local session-result fact/write is dropped.
- **Durable facts / last fact:** controller intent + completed observation;
  executor completed; session has no ToolResult. Last durable fact is the
  controller's causal completed observation backed by executor terminal proof.
- **Workspace/proof:** marker count 1; postcondition is corroboration only.
- **Storage/restart:** executor stays live. After old session lock release,
  manually rehydrate same session/controller paths. Session JSONL has the tool
  call but no result.
- **Admissible evidence:** controller completed observation and, at most, one
  confirming original-ledger query. Existing transcript is used only as the
  destination/correlation record, never to infer execution truth.
- **Historical knowledge:** this accepted job completed once; only result
  persistence was interrupted.
- **Classification/action:** append exactly one success ToolResult before
  generic `interrupted` hydration repair, record result-persisted, and never
  invoke/submit again.
- **Convergence:** at most one query and one append; final counts 1/1/1/1 and
  terminal success within 1,000 ms.

## Frozen controls

1. **No fault.** Baseline exact marker control is **N/A / non-equivalent**:
   current remote-write coverage observes one direct write and one ToolResult
   but has no marker, intent, acceptance, attempt, or completion ledger. Target
   runs the full ordered protocol. Assert one intent, admission, acceptance,
   attempt, marker record, completed row/result digest, completion reply, and
   terminal session ToolResult; executor and session classify success. No count
   may be inferred from another. Bound: no reconciliation, ≤1,000 ms after
   submit.
2. **Same ID / same digest replay.** Baseline is **N/A / non-equivalent**:
   tool-call IDs are not durable controller identities, there is no operation
   digest or ledger, and Core's same-name/args turn-local rejection is not this
   protocol. Target pauses once in accepted/attempt-count-0 state. Duplicate
   submit and query must return that existing evidence without new admission or
   invoking callback. Continue the already accepted job once, then repeat submit
   and query against terminal state; they return the same terminal evidence.
   Final counts remain admission 1, attempt 1, mutation 1, result 1. Bound: each
   response ≤1,000 ms; no reconciliation attempts beyond the one declared
   continue.
3. **Same ID / conflicting digest.** Baseline is **N/A / non-equivalent**
   because it has no durable job/digest conflict check. Target uses an existing
   accepted job and submits the same ID with a digest changed by one canonical
   operation field. Reject `digest_conflict` before callback/mutation; admission
   remains 1 and conflict mutation delta is 0. Release the original accepted job
   once and assert final 1/1/1/1 counts. Query by ID still returns only the
   original digest/evidence. Bound: rejection ≤1,000 ms; no retry or failover.

## Preregistered GATE-1 Narrow scope and precedence

There is exactly one eligible strict Narrow scope:

1. **Observable marker-shaped, original-owner mutations.** Operations must have
   (a) a stable declarative postcondition independently observable without
   invoking the callback, (b) separately countable external mutations, and (c)
   reconciliation against the original accepting executor ledger. The ER-1
   marker makes this scope nonempty. All eight cuts and all three controls still
   apply; no row may be removed. The surviving claim would be limited to
   truthful safe-next-action convergence for marker-shaped observable
   operations, including indeterminate row 6, rather than operation-independent
   durable mutation semantics.

GATE-1 evaluates Stop first, then full-scope Continue, then this Narrow scope,
then Pivot only for a demonstrated sidecar ownership contradiction. No other
Narrow scope is eligible. In particular, no individual cut/row subset,
happy-path-only subset, terminal-evidence-only subset, storage-survival subset,
or post-hoc operation subset may be selected. Atomically deduplicated/causally
receipted mutations are not an ER-1 Narrow candidate because the deliberately
non-deduplicating marker does not populate that scope.

## Baseline evidence and implementation handoff

The decisive baseline tests are:

- `Elara.ExecutorTest`: “filesystem and shell tools execute in an authenticated
  remote workspace”, “read-only requests retry once on another healthy matching
  worker”, and “worker death yields one indeterminate mutation result and
  replacement continues”.
- `Elara.SessionTest`: “provider invocation observes the user append already
  durable”, “tool crash isolates and continues”, and “resume persists
  interrupted tool results before the next turn”.
- `Elara.FlightRecorderTest`: “records causal transitions and replays without
  provider or tool effects”, “detects core behavior changes and supports
  transition fault injection”, and “persistent recordings retain event causes
  and distinguish incomplete transitions”.

ROB-668 implements only identity/digest/intent and the first two controller
hooks. ROB-669 implements the separate executor ledger, submit/query semantics,
attempt observation, and executor hooks. ROB-670 adds the marker, same-owner
continue rule, pre-hydration reconciliation, and controls. ROB-671 executes this
unchanged matrix and records observed counts/evidence/bounds. ROB-672 applies
the frozen gate precedence.

## Deviations and remaining uncertainty at freeze

- No target behavior, SQLite adapter, journal, ledger, marker, or crash hook is
  implemented by ROB-667; only the contract and baseline are frozen.
- The current JSONL transcript's rename is not treated as a synced durable job
  store. Target journal/ledger reopen guarantees must be demonstrated directly.
- The marker's matching ID/digest bytes are intentionally noncausal because
  there is no exclusive workspace authority or atomic receipt. Row 6 must stay
  indeterminate even when its postcondition is visibly satisfied.
- ER-1 does not test executor ledger deletion, disk corruption, host power loss,
  or accepted-job migration. Loss of causal terminal proof remains explicitly
  indeterminate.
- The pre-hydration sidecar is selected because the current shell already owns
  dispatch and persistence while Core is pure. If implementation proves that
  boundary impossible without changing Core phases, that concrete contradiction
  is GATE-1 Pivot evidence; it is not permission to silently change the
  contract.

## Required verification record

ROB-667 records exact outputs for:

```bash
mix test test/elara/executor_test.exs
mix test test/elara/session_test.exs
mix test test/elara/flight_recorder_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Expected crash-recovery logging from `Elara.SessionTest.CrashTool` is retained
and judged by ExUnit's final status rather than hidden.

Recorded on the pinned baseline in the ROB-667 checkout:

- `mix test test/elara/executor_test.exs` — `Result: 7 passed`.
- `mix test test/elara/session_test.exs` — `Result: 19 passed`; the expected
  `Elara.SessionTest.CrashTool` `RuntimeError: boom` was printed.
- `mix test test/elara/flight_recorder_test.exs` — `Result: 3 passed`.
- `mix format --check-formatted` — exit 0 with no output.
- `mix compile --warnings-as-errors` — exit 0; 41 Elara files compiled.
- `mix test` — `Result: 179 passed`; the same expected crash log was printed.
