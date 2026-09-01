# ER-2 real-mutation contract (FND-ER2-v1)

Status: frozen by Linear issue
[ROB-827](https://linear.app/robert-guss/issue/ROB-827/er2-fnd-freeze-real-mutation-contracts-and-matrix).

Machine-readable manifest:
[`004-real-mutations-er2-manifest.json`](004-real-mutations-er2-manifest.json).

## Freeze boundary

- Repository baseline: `bcf1daa265d0609e6f5b16014065ce497a986951`.
- The manifest version is `FND-ER2-v1`.
- This document and the manifest freeze the experiment before any ER-2 fault row
  executes.
- Existing `write`, `edit`, and `bash` behavior may be characterized before the
  freeze. No result from a new ER-2 row may be used to amend this contract.
- An amendment after an ER-2 row has executed invalidates that run as
  confirmatory evidence. A changed contract receives a new version, new fixture
  tokens, and fresh seeds.

Linear is the roadmap and status source. This file is immutable evidence, not a
second roadmap.

## Question and bounded claim

ER-2 asks whether operation-aware evidence can improve the safe next action
after process, message, or ledger loss without weakening the ER-1 identity and
admission rules.

The claim is deliberately narrower than exactly-once execution:

1. one job ID and operation digest has at most one durable admission;
2. a conflicting digest or replacement owner never executes that admission;
3. after a durable callback-attempt count of one without a terminal receipt, the
   callback is not invoked again;
4. typed operations may independently prove that a desired postcondition is
   currently satisfied, but that observation does not prove that this job
   completed or caused it;
5. an opaque shell operation without a declared postcondition remains
   indeterminate after possible execution and receipt loss; and
6. the user receives the most specific truthful classification and safe next
   action supported by source-qualified evidence.

The experiment does **not** claim power-loss durability, exactly-once callback
invocation, causal completion from workspace state, multi-file transactionality,
or generic understanding of shell commands.

## Experimental boundary

ER-2 adds internal experimental operations around the durable ER-1 executor. It
does not change the public tool schemas frozen at the baseline:

| Public tool | Baseline arguments             | Baseline implementation                    |
| ----------- | ------------------------------ | ------------------------------------------ |
| `write`     | `path`, `content`              | parent creation followed by `File.write/2` |
| `edit`      | `path`, `old_text`, `new_text` | read, literal replacement, `File.write/2`  |
| `bash`      | `command`                      | `System.shell/2` in the session workspace  |

The experiment invokes real filesystem and operating-system effects from the
durable executor callback. Test-only hooks may stop the owning BEAM process at
the frozen boundaries. Public `write`, `edit`, and `bash` keep their existing
behavior until GATE-2 selects a scope.

All paths below are normalized, relative paths beneath a fresh temporary
workspace. Absolute paths, `..`, NUL bytes, symlink components, symlink targets,
and non-regular final targets are rejected as structured states. The
experimental contract must not silently follow a symlink or replace a directory,
device, or socket.

## Digest-bound operation schemas

The canonical job digest already binds tool name and version, arguments,
workspace identity, capabilities, and authority. The complete operation object
below is supplied as the job arguments, so every listed field is digest-bound.
Map keys have stable string names and SHA-256 values are lowercase hexadecimal.

### Declarative write v1

```json
{
  "schema": "elara.declarative_write.v1",
  "path": "relative/path.txt",
  "expected": { "state": "absent" },
  "desired": { "content": "exact UTF-8 bytes", "sha256": "..." },
  "parent_policy": "create",
  "replacement": "same_directory_temp_rename"
}
```

`expected` is either `{"state":"absent"}` or
`{"state":"regular","sha256":"..."}`. `desired.sha256` must match the exact
bytes in `desired.content` before admission. The operation may create parents,
writes a unique temp file in the target directory, and renames it over the
target. Parent creation and temp cleanup are not a directory transaction.

For process crashes, the primary target must be observable only as the exact
preimage or exact desired bytes—never a prefix, suffix, or mixed image. Temp
artifacts are auxiliary effects and are measured separately. No claim is made
for kernel, machine, or storage-device failure because v1 does not require file
and directory `fsync`.

### Literal single-file patch v1

```json
{
  "schema": "elara.literal_patch.v1",
  "path": "relative/path.txt",
  "preimage_sha256": "...",
  "old_text": "one exact occurrence",
  "new_text": "replacement bytes",
  "postimage_sha256": "...",
  "replacement": "same_directory_temp_rename"
}
```

The observed regular-file digest must equal `preimage_sha256`; `old_text` must
then occur exactly once; and replacing that occurrence must produce
`postimage_sha256`. Otherwise no mutation occurs. Exact postimage bytes prove a
currently satisfied postcondition and make reapplication unsafe; they do not
prove this job caused or completed the edit. A concurrent unrelated edit that
matches neither digest is a conflict rather than permission to overwrite it.

The same process-crash atomic-visibility and nonclaims as declarative write
apply. Multi-file patches, fuzzy matching, syntax-aware patches, and merge
resolution are outside v1.

### Opaque shell v1

```json
{
  "schema": "elara.opaque_shell.v1",
  "command": "opaque shell source",
  "relative_cwd": ".",
  "environment": { "KEY": "explicit value" },
  "timeout_ms": 5000,
  "postcondition": null
}
```

Command source, relative working directory, the complete explicit environment
map used by the fixture, and semantic timeout are digest-bound. Inherited
environment is excluded from the fixture. A fixture may instead declare this
test-only postcondition adapter:

```json
{
  "kind": "files_sha256",
  "files": [{ "path": "relative/path", "sha256": "..." }]
}
```

The adapter only observes its declared files. Elara must not parse command
source, infer idempotence, or turn an exit code, process disappearance, or
matching postcondition into causal completion without a terminal receipt. A
matching adapter may support `postcondition_satisfied_no_retry`; a shell without
an adapter remains causally and operationally indeterminate after possible
execution and lost receipt.

## Source-qualified facts

Every report preserves these facts independently. A derived label never replaces
the facts from which it came.

| Fact                | Source                       | Values                                                 |
| ------------------- | ---------------------------- | ------------------------------------------------------ |
| controller intent   | controller journal           | count and job digest, or unavailable                   |
| executor admission  | executor ledger              | count, owner, digest, or unavailable                   |
| callback attempt    | executor ledger              | count or unavailable                                   |
| terminal receipt    | executor ledger              | state, count, encoded result, or unavailable           |
| callback invocation | test ground-truth observer   | count                                                  |
| primary effect      | operation observer           | target replacements or declared shell effects          |
| auxiliary effect    | operation observer           | temp files, PID files, and other named fixture effects |
| workspace state     | fresh filesystem observation | state plus digest or observation error                 |
| process lifetime    | external Linux observer      | `not_spawned`, `alive`, `terminated`, or `unknown`     |
| session result      | transcript/session process   | count and classification                               |

An executor ledger that was deleted is `unavailable`; it is never reported as
zero. Ground-truth counters are experiment evidence, not runtime authority. The
process observer runs outside the process being killed and checks the exact PID
recorded by the fixture. Failure to obtain a PID or a conclusive observation is
`unknown`, not `terminated`.

### Independent derived dimensions

- **Workspace observation:** `expected_preimage`, `exact_postimage`, `conflict`,
  `absent`, `non_file`, `symlink_rejected`, `unavailable`, or `not_applicable`.
- **Causal terminal knowledge:** `not_started`, `completed`, `failed`, or
  `unproven`.
- **Historical execution knowledge:** `not_invoked`, `invoked`, or `unknown`.
- **Session classification:** `not_started`, `success`, `error`, or
  `indeterminate`.
- **Safe next action:** one frozen action from the manifest, never an arbitrary
  prose recommendation.

`exact_postimage` and `completed` are intentionally different. A receipt can
prove completion even if another actor later changes the file. Conversely,
desired bytes can be present with no receipt, proving current satisfaction but
not who produced them.

## Reconciliation rules

Rules are evaluated from durable facts first, then operation observation:

1. No durable intent means this job is `not_started`; a caller may create a new
   job ID.
2. An intent without executor admission may be submitted once with the same ID,
   digest, owner, and authority.
3. An accepted job with durable callback-attempt count zero may be continued by
   the accepted owner.
4. An accepted job with callback-attempt count one and no terminal receipt is
   never reinvoked. Typed observation may refine workspace state and the safe
   no-write action, but session and causal state remain `indeterminate` and
   `unproven`.
5. A terminal receipt controls causal/session classification. A later workspace
   observation is reported separately.
6. After executor-ledger loss, an exact typed postcondition permits only
   `postcondition_satisfied_no_retry`; it does not recreate a receipt. An
   initially conflicting or unavailable observation requires
   `manual_investigation`. If rule 8's mandatory re-observation changes an exact
   postcondition to `conflict`, use `refresh_then_report_conflict`.
7. A shell adapter follows rule 6. Shell without an adapter always uses
   `manual_investigation` after possible execution and receipt loss.
8. Before acting on a workspace observation, the implementation re-observes it.
   If it changed, the stale result cannot authorize a write or completion claim.

Cleanup may remove only a uniquely named temp artifact bound to the same job ID
and digest. Temp cleanup is not permission to rerun or change the primary
target.

## Deterministic schedules

The shared eight cuts preserve the ER-1 order:

| ID  | Boundary                                                    | Expected recovery                                                   |
| --- | ----------------------------------------------------------- | ------------------------------------------------------------------- |
| C1  | before controller intent commit                             | `not_started`; no executor or primary effect                        |
| C2  | after intent commit, before dispatch                        | same-ID submission; one terminal result                             |
| C3  | after executor receipt, before controller acceptance commit | query accepted job; one terminal result                             |
| C4  | after acceptance commit, before acceptance reply            | query accepted job; one terminal result                             |
| C5  | after acceptance reply, before callback                     | accepted owner continues attempt zero; one terminal result          |
| C6  | after primary effect, before terminal commit                | no retry; `indeterminate`, with workspace state reported separately |
| C7  | after terminal commit, before terminal reply                | recover exact receipt; one terminal result                          |
| C8  | after terminal reply, before session result persistence     | manually rehydrate exact reply; one terminal result                 |

Typed operations additionally stop after precondition observation but before
temp creation, and after temp completion but before rename. Shell additionally
stops after child spawn but before its declared primary effect, after the
primary effect while the process remains alive, and after process exit but
before the callback returns. A timeout-after-effect row records descendant
process lifetime independently of session classification.

Hooks are one-shot barriers. A test must prove it reached the hook before
killing the named owner. Recovery has bounded polling and must fail rather than
sleep indefinitely. Filesystem rows converge within 2,000 ms; shell and
process-lifetime rows within 5,000 ms.

## Controls and matrix

The manifest freezes 24 shared crash rows (three classes by eight cuts), seven
operation-specific cut rows, and class-specific state, identity, ownership,
ledger-loss, timeout, and stale-observation controls. Each row names an expected
fact bundle. `U` in a durable-count expectation means unavailable evidence, not
zero.

Required controls include:

- no fault;
- same job ID plus same digest resubmission;
- same job ID plus conflicting digest rejection;
- replacement-owner rejection;
- typed already-desired, conflict, multiple-match, non-file, and symlink states;
- shell success, nonzero exit after an effect, adapter and no-adapter ledger
  loss, and process-lifetime observation; and
- a stale-observation race in which an adversary changes a typed target after
  observation and before the safe action.

Rows selected in `repeated_cross_class_rows` execute 20 times for each frozen
seed `424243`, `525253`, and `626263`. All other rows execute once per seed in
their owning implementation issue. Membership, tokens, commands, selection, and
expected labels come only from the manifest.

## Safety and validity invariants

Any violation below is a GATE-2 Stop, regardless of averages:

1. more than one durable admission for a job ID;
2. execution under a conflicting digest, owner, workspace, or authority;
3. callback reinvocation after durable attempt count one;
4. more primary target commits than the row permits;
5. a typed target observed as bytes other than the exact preimage or postimage
   at a deterministic sampling point;
6. overwriting a conflict, symlink, or non-file;
7. labeling causal completion without a matching terminal receipt;
8. treating unavailable durable evidence as zero;
9. claiming an opaque shell is safe to rerun from command inspection, exit
   status, process lifetime, or an undeclared postcondition; or
10. a result outside its convergence bound or a required observation reported as
    unavailable/unknown because the harness failed to instrument it.

An intentionally observed shell descendant that remains alive is a reported
result, not by itself a protocol violation. Failure to observe it is invalid
instrumentation.

## GATE-2 decision contract

GATE-2 is semantic; timing and implementation convenience cannot change the
decision. Apply this precedence:

1. **Stop** if any safety/validity invariant fails, a required row is missing,
   or a row differs from its frozen expected causal/session/action semantics.
2. **Universal** if all rows pass and the common declared-postcondition protocol
   supplies the frozen safe no-retry refinement for declarative write, literal
   patch, and the shell fixture with an explicit adapter, while the no-adapter
   shell remains truthfully indeterminate.
3. **Typed-only — write + patch** if Universal does not qualify and all write
   and patch rows pass, including their improvement and stale-observation rows.
4. **Typed-only — write** if the combined scope does not qualify and every write
   row passes.
5. **Typed-only — patch** if no earlier scope qualifies and every patch row
   passes.
6. **Snapshot-dependent** if no typed scope qualifies, no Stop condition exists,
   every non-stale row in at least one predeclared typed scope passes, and that
   scope fails only because observation and action cannot be linearized in the
   frozen stale-observation row. This outcome authorizes a separate bounded
   workspace-lease or immutable-snapshot experiment; it does not claim success.
7. **Stop** otherwise.

An expected `indeterminate` row can pass. “Pass” means truthful agreement with
the frozen evidence and action contract, not conversion of every fault into
success. A Gate Result must name the first applicable branch, row-level
evidence, deviations, and remaining uncertainty.

## Verification contract

FND-ER2-v1 is complete when:

- the manifest parses as JSON and has unique fixture, schedule, and row IDs;
- every row references an existing operation, fixture, schedule, and
  expectation;
- all eight shared cuts occur exactly once for each operation class;
- every repeated row is a member of the frozen matrix;
- all SHA-256 fixture digests match their declared content;
- the current public write/edit/bash tests pass without production changes;
- formatting and warnings-as-errors compilation pass; and
- no ER-2 fault row has executed before this freeze commit.

## Known uncertainty retained for later evidence

- Whether process death while a port-backed `System.shell/2` call is active also
  terminates every descendant OS process is not assumed; ER-2 measures it.
- Same-directory rename gives process-crash atomic target visibility on the
  experiment platform, not power-loss durability.
- SHA-256 equality is treated as byte identity for this experiment.
- External actors can change a workspace. The stale-observation rows test the
  boundary; no global exclusive ownership is assumed.
- The experiment can establish that the protocol fits Elara's BEAM ownership
  boundaries. It does not by itself establish a comparative BEAM advantage.
