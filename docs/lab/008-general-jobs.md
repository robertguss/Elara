# 008 — General jobs and correlated completion

- **Question:** Can one profile-driven job and correlated completion path
  preserve RQ-4 behavior with less production and infrastructure code?
- **Hypothesis:** Replacing test-job/thread-wait special cases preserves durable
  admission, one immutable completion, execution-loss uncertainty, bounded
  cancellation reporting and held capacity across restarts, with a net decrease.
  Net increase or behavior loss refutes the hypothesis.
- **Queue item:** LAB-8 / ROB-1088 · **Date:** 2026-10-06
- **Baseline:** `a4f8013da2e5ac6af047e293e53b5cc58d4bf640` after LAB-5/LAB-6 and
  receipt callback recovery. Linear selection and plan are authoritative.

## Scope and comparison

Implement in bounded reviewed chunks: opt-in native head/tail output; the
existing manager generalized to trusted profiles with a mix_test profile and
test_job alias; correlated job/child/inbox completion and a shared wait contract;
server/TUI operator acknowledgment; then integrated chaos and line comparison.
Keep v1 durable records, admission-before-dispatch, stable identity/conflicts,
uncertainty/no-retry, related-thread authority, handoff lineage, durable inbox
acceptance/dedup, paused delivery and wake budget. No in-memory-only completion
authority or automatic owner acceptance. The separately approved capped
real-model awaited-completion run remains a genuine owner gate; perform all
independent scripted work before Needs Input and continue other issues.

The baseline count manifest is
`lab/results/rob-1088-general-jobs-20261006/baseline-source-counts.json`:
126 tracked source/infrastructure files, 48,375 lines. The declared scope is all
tracked `.ex/.exs/.rs/.sh/.py` except tests, docs, raw lab results and TUI examples;
it includes native inline test blocks and all new compatibility/native/runtime/
infrastructure files. Report test and raw orchestration sizes separately; do not
hide added code by moving or renaming it. Final net lines and session special
cases are still pending. No original LAB-5 corpus or LAB-3 measurement is reused.

## Chunk 1 — Native output policy

Ordinary Exec/bash retains its default truncate-and-kill policy. An explicit
`output_policy: :head_tail` requires the stub's advertised capability before
submission; older v1 stubs remain usable with the default policy. The native
reader forwards at most floor(cap/2) prefix bytes, retains the final ceil(cap/2)
bytes as a suffix, and keeps draining until actual exit, deadline or cancel.
At cap 1 only the last byte is retained. A bounded drain pass returns to control
and deadline polling under continuous output.

The terminal supplies its suffix and capped flag. The owner validates exact
prefix/suffix sizes, total/retained counters and gap flag for the selected policy,
rejecting malformed evidence as indeterminate. `Result.output` concatenates the
retained prefix and suffix; `output_capped` explicitly reports omitted middle
bytes, and `bytes_sent` includes both retained parts. This is a reporting cap,
not a termination cause. Actual nonzero exit, timeout and cancellation evidence
are preserved. No new terminal is inferred from lost native execution.

Five public checks fail against the baseline (0/5): early cap termination
prevents the late side effect/nonzero exit, continuous output never reaches its
deadline, and minimum/odd/below-cap accounting lacks the new contract. The
eight public positive/cleanup controls then pass. The expanded 20 checks include
older-stub pre-admission rejection/default compatibility, one valid wire fixture
and nine malformed tail/counter/flag/termination cases. Fixture owners are
registered before fallible waits, including named stub owners before status
readback. Teardown settles the command owner before directory removal and
independently observes actual native/stub OS stop; the forced-failure control
checks the same path. Named fake stubs verify wire validation, not native effects.

Removing capability negotiation fails the pre-admission assertion (0/1).
Removing gap-flag validation accepts false capped accounting (8/9, only that
assertion fails). Both source mutations are restored byte-exact. A first control
setup anchor failed before source mutation/compilation; that error remains
classified in the raw namespace. Self-review also makes the capped flag truthful for the unchanged default
cap-kill policy. Its explicit regression brings the final policy checks to 21
and combined focused run to 67, seed 1088, in 24.1 s, including original Exec,
executor, TestJobs and job-chaos contracts. The earlier 66/24.0 s run remains
retained. Rust format/Clippy with warnings denied and seven native tests pass;
compile warnings-as-errors and Elixir format/diff pass.

All raw red/green/mutation/focused/native logs and reviewed control source remain
in `lab/results/rob-1088-general-jobs-20261006/`. Chunk 1 adds 99 counted source
lines (52 Elixir, 47 native including inline tests). This is not evidence of an
overall reduction. The integrated full suite passes 999 (11 properties, 988
tests), seed 1088, in 282.5 seconds at clean
`404ce8604d9728695be03f93170a918ae3e1dab9`. No BEAM or output-policy fixture
process remains after the suite; the retained postflight record hashes every
verification log. Immutable review/chunk delivery evidence is in Linear.
Profiles, correlated wake, UI acknowledgment, final chaos/net-line comparison
and the separately approved real-model gate remain in ROB-1088; this supporting
chunk does not complete LAB-8 acceptance.

## Chunk 2 — Trusted profiles and durable compatibility

`Elara.Jobs` owns the existing serial manager. The thin `Elara.TestJobs` entry
keeps its supervisor child ID, registered name, storage root, four-part admission
message and original alias tool schema. The new job tool selects a trusted
profile and JSON arguments. Fixed mix_test and owner-configured declarations
freeze argv/limits before prepared/execution writes and the parked runner's
dispatch. Duplicate or invalid declarations reject startup; invalid argument
or callback results reject admission before a record/effect. Both tools use
one capacity/delivery writer. Optional source fingerprints are explicit; the
active entry holds its admitted callback, and mismatched scopes compare unknown.
Invalid fingerprint evidence is a source error, without fabricating a pass claim.

New records use v2 and retain profile/arguments/argv/limits/policy, optional
fingerprint declaration, output cap flag and an owner/job-key correlation ID.
v1 lifecycle/counter/terminal validation remains. Pending v1 completion bodies
and source identities remain byte identical across acceptance retry, and old
running records become indeterminate without replay. Native v2 output validates
against its own cap/policy and exact gap flag. Review found and fixed a small-cap
recovery defect: not-started/indeterminate explanatory text needs its own 20,000
byte bound, separate from retained process output.

Corrected public red 0/2 establishes v1 admission and early cap termination.
The first red retains its unused-alias/early cleanup limitation. New fixture
cleanup registers ownership before admission, remembers every actual execution
lease even after manager bookkeeping retires, waits for runner DOWN and same-
epoch native settlement, and observes the native OS process before removal.
The existing record-codec fixture now derives correlation ID with its new job
ID; its original outcome/lifecycle/counter assertions are unchanged.

Preparations remain retained: first green18/19 exposed that fixture identity;
green23/25 had a message-field and startup-link fixture error; green27/28 had
an invalid assumption that failed startup always emits EXIT; startup rejection
now runs in a bounded, monitored fixture owner. Green28 omitted the lab test
because its path was wrong; corrected green38 includes all nine job recovery
checks. Final focused80 passes, seed1088, in29.3s: profiles13, legacy jobs17,
job recovery9 and Exec/output/executor41. Gap-validation removal fails exactly
the false-cap assertion (0/1). A forced assertion after actual native admission
fails only the intended assertion (0/1) while a retained witness confirms one
settled lease, stopped native PID and removed root. Its first attempt selected
no test after instrumentation shifted line numbers, and remains excluded. Both
source files are restored byte exact. No original lab corpus or model is used.

Raw source/control/readback and all logs remain in the existing ROB-1088
namespace. Full integrated1012 (11 properties,1001 tests) passes, seed1088,
285.6 seconds at clean `36a3a7a2cc56c73ee1595284fcdd1806fbb7baf7`.
Postflight hashes every profile log and confirms no BEAM/profile fixture process.
Compile warnings-as-errors and format/diff pass. Final review/delivery follow in
Linear; the final handoff/note update changes no runtime or test source.

The count manifest has128 source/infrastructure files and48,740 lines: +266
for profiles, +365 cumulative LAB-8 versus48,375 baseline. A first counting
preparation used the wrong TUI examples directory spelling and included52
excluded lines equally at all three revisions. The retained corrected manifest
matches the original baseline exactly; both deltas are unchanged. The current
increase is negative evidence for the reduction hypothesis. New profile tests
are564 lines, and the old codec fixture changes9 lines; tests and retained raw
orchestration stay separately reported and never hide infrastructure growth.
Correlated wake, operator server/TUI acknowledgment, fresh chaos/net-line
comparison and the separately approved real-model acceptance remain pending;
this profile chunk does not complete LAB-8.


## Chunk 3 — One correlated inbox wait

`completion_wait` waits on an owned job or direct related thread through the
existing Session inbox. `thread_wait` uses the same cancellable untimed Task
boundary; research children retain both entries when the parent grants them.
There is no new actor, ledger or dependency. Correlation is optional strict
outer report metadata with exactly source (`job` or `thread`) and bounded ID.
A thread uses its logical source and active-branch User entry ID; only handoff
needs an optional header carrying that occurrence. A new User clears the
carried value, and branch revision uses the current ancestry. Header reopening
retains it. Job IDs use the existing owner/job key, including v1 bodies.

Successful live tool claims consume only their matching still-pending input,
with the ToolResult in the same atomic store write. Abort/crash/stale results
cannot consume it. External observers do not consume. Cancelled input returns
an error; previously failed processing retains its receipt/error. Optional
preview and thread status details shrink before JSON encoding to fit the tool
limit; if identity metadata cannot fit, the tool errors and retains the input.
A 1,024-byte handoff regression first exposed mid-JSON Core truncation; its
repaired receipt stays valid and bounded. Full status remains available from
the observer API, and full original evidence stays retained.

Explicit receipts carry awaited=true, correlation, full input ID, receipt state
and an untrusted preview. Automatic provider context carries awaited=false and
correlation without changing saved User bodies or agent provenance. Other
arrivals remain subject to the existing serial drain, pause, receipt barriers
and eight-wake budget. One awaited input cannot trigger a second report wake.
Monitored caller/target/transport loss retires subscriptions without replay.
The existing transport stages immutable evidence before asynchronous completion
notification and dispatch; it does not synchronously call back into a source
publishing its completion. Running and already-finished parents can supply
requested evidence to their direct child. Same logical-thread waits reject.

Legacy artifacts derive absent correlation from their immutable source leaf's
User ancestry, never from a later current turn. Identical legacy transport and
inbox entries can gain outer metadata; conflicting typed values never replace
one another. Original artifact bytes, bodies, evidence and receipt identities
remain unchanged. V1 accepted inbox evidence can gain correlation on an explicit
wait without rerunning its job. Tiny-limit failure preserves that pending input.

Focused134 checks pass, seed1088,78.1s: held native job/atomic reopen, two thread
turns and unrelated completion, parent-direction wait, real child handoff,
legacy artifact/v1 body compatibility, strict codec/branch identity, cancelled
and failed receipts, caller/target/transport loss, pause/budget, original child
ownership, input recovery and finite job recovery. Compile warnings-as-errors,
format and diff checks pass. The first full suite at68b0356 passes1019/1020
(11/11 properties,1008/1009 tests;seed1088,316.1s). The tiny children
concurrency regression retained its directory because reports were staged but
not yet admitted:33 staged,13 accepted/delivered,0 pending; reports_settled
was false while actor/transport checks passed. The shared completion cast had
omitted the original immediate flush_reports admission call. Restoring that
one line makes the exact public regression pass1/1 (43excluded,7.0s). Scheduling
:flush alone only delivers admitted reports. No assertion or timing was weakened.
Raw failure and repair logs remain retained. The broader repair check then
passed60/61 (90.2s), failing the existing delayed-admission settlement test.
That test also reproduced0/1 alone. A temporary local trace observed783 receipt
reads for27 admitted reports and transport_quiescent=false. The upgrade scan
revisited already typed transports on every queued completion, unnecessarily
reading recipient receipts. Restoring the typed-transport admission skip keeps
legacy metadata upgrades and avoids those background reads. On repaired source
86a5c3321c9b8135395388439b807eb71a06643b, both public regressions and all17
communication checks pass19/19 (42excluded,10.1s). The same diagnostic trace now
observes24 receipt reads for24 admitted reports, transport_quiescent=true and
1/1 pass (43excluded,2.9s). Report counts differ between runs; these are diagnostic
regressions, not pooled or registered measurements. The temporary fixture is
restored byte-exact, and compile warnings-as-errors/format/diff pass. A fresh
frozen full suite atc430c1e passes1019/1020 (11/11 properties,1008/1009 tests;
seed1088,306.6s). Completion/settlement checks pass; the sole failure is the
existing attachment PTY oversize-error observation. ROB-1331's independent
fixture PR#56 merges ate096868: reuse its existing8s wait for the same actual
visible error. A1.2s owned rendering delay fails old0/1 and passes new1/1; ordinary
product1/1 and both teardown witnesses pass. Integrated main changes only that
fixture among240 frozen source/test hashes; no completion/runtime change.
Full at clean6b00b962838bdb9f0169e8961286712e9ecdc868 passes1020
(11properties,1009tests;seed1088,318.2s), exit0. Postflight verifies every one
of240 frozen source/test hashes, a clean tree. Subsequent ownership audit finds one unrelated WTS VM and
no Elara BEAM; it is left running. Raw completion-*
artifacts and their hashes remain retained in completion-postflight.json.
Temporary trace instrumentation adds15 test-only lines and is fully restored;
raw Python controls231 lines are separately counted. This is supporting
verification, not final LAB-8 chaos/model acceptance. The final handoff URL
and its durable-pointer test constant change after the cloud document rename;
the three guidance checks cover that metadata update. A final review then
updates job/test_job instruction strings that previously demanded ending the
turn after start: both now describe completion_wait or ending the turn. The
focused job/legacy/context46 pass (27.8s), and compile warnings-as-errors/format/
diff pass. Execution logic remains the full-tested source; real-model prompt
behavior remains separately approval-gated. No source line count changes.

Removing claimed consumption fails its sole executed held-job check (0/1).
Removing transport dependency retirement fails its sole executed loss check
(0/1). The transport control's two teardown-witness attempts did not save their
witness; no teardown claim is accepted from them. A separate actual failure
with native execution and an owned completion waiter admitted fails only the
forced assertion (0/1), with a saved witness proving one stopped caller, one
settled execution lease, native OS stop and root removal. All temporary source
mutations restore byte-exact. A first script-generation syntax error happened
before mutation; early test setup/assertion and header reopen failures remain
retained as preparations. No original lab corpus or real model is reused.

`completion-source-counts.json` independently reproduces the baseline and prior
profile manifests:129 files/49,206 source/infrastructure lines, +466 this chunk,
+831 cumulative versus48,375 baseline. Session grows203 lines; one named
thread_wait execution branch becomes one shared wait branch. Test changes add548
net lines, and retained raw Python control orchestration is231 lines, separately
reported. Two count preparations assumed the wrong manifest schema and produced
no count; excluded. The increase is negative evidence for the reduction
hypothesis. Operator acknowledgment, fresh final chaos/comparison and the
separately approved real-model acceptance remain pending. This supporting chunk
does not complete LAB-8.

## Chunk 4 — Operator job acknowledgment

The attached v2 server reuses Jobs status and acknowledge_stopped for its own
logical session's jobs. Observers can inspect; acknowledgment requires control,
a nonempty job ID of at most128 bytes and explicit confirm_stopped:true. Extra
session/force/settlement fields cannot override the attached owner or backend.
Only indeterminate capacity is released after stopped confirmation; original
status, output, completion identity/body and inbox receipt remain unchanged.
Duplicate start still returns that evidence and never replays execution.

TUI /job and /ack-job-stopped reuse the existing Inspection pane and slash help.
The latter explicitly confirms the command and descendants stopped. An optional
JSON-string argument preserves opaque whitespace/Unicode IDs; malformed/empty/
over128-byte IDs retain the draft and show usage. No actor, ledger, record field,
profile, model acknowledgment tool or dependency is added.

Public TCP acceptance first failed0/1 with invalid_command, then passed1/1.
Two native checks first failed0/2, then passed2/2: command parsing/controller
restrictions and actual rendered Inspection in every layout for held/unknown
and released/operator_confirmed evidence, retaining indeterminate and escaped
untrusted output. Focused JobsProfile/TestJobs/Server41 pass (19.8s), including
existing real native known-pending/late-settlement guards. These are scripted
and native buffer checks, not physical owner or real-model acceptance.

Removing controller authority or explicit confirmation each fails the sole
executed public check0/1. A separate forced assertion after three attached
sockets fails0/1; its saved a2 witness proves server/foreign session stopped,
sockets closed and temporary root removed. All temporary mutations restore
source bytes exactly. The first cleanup preparation's hardcoded line shifted
when instrumentation was inserted and selected the preceding passing test;
no witness existed, so that attempt is excluded rather than cleanup evidence.
Raw operator-* logs/manifests/scripts remain in the same retained namespace.

The frozen count is129 files/49,363 source/infrastructure lines, +157 this
chunk/+988 cumulative. The declared count includes native inline tests;
Elixir test changes add122 lines and raw control Python is77 lines, reported
separately. Session stays2860 lines. Compile warnings-as-errors, Mix/native
format, Clippy all-targets warnings-as-errors, native118 and diff checks pass.
The full suite at clean `f248162cd81cebc28fed3cb78f7e460d707981af` passes1021
(11 properties,1010 tests), seed1088,308.3s. All240 source/test hashes match the
before-suite freeze afterward. Postflight observes0 global/Elara BEAM; no quiet-
host or comparative timing claim. Frozen count and postflight manifests retain
artifact hashes and source boundaries; later readbacks are separate. Fresh final chaos/net
comparison and separately approved real-model acceptance remain pending.

## Final scripted phase — Frozen integrated recovery

Operator PR#58 merged at b001c38, tree-equal to reviewed92e0470 after both
actual exact-head Socket checks passed; deliveryd4e39bfc and review69a263a8
retain exact full-testedf248162 boundaries. LAB8 remains Building, not Done.

Reuse the existing JobRecovery fixture/gates/deadlines/native probes with an
optional api:job selecting the public Jobs tool/run and mix_test arguments.
Absent option retains the original workload. Status/replay/ack compatibility
helpers observe the same primitive. The gate records actual tool identity and
Matrix requires general_job_api evidence for those rows. Missing evidence is
ineligible; false evidence is an eligible failure. Invalid API selection rejects
before fixture resources. No new scenario engine, provider, profile or actor.

The new five API checks first fail0/5; missing-Matrix-evidence check fails0/1.
Focused recovery/Matrix24 pass (13.3s), including forced preparation failures
through legacy and general APIs with actual actor/group stop assertions.
Compile warnings-as-errors, format and diff checks pass. Full1030 (11properties,
1019tests),seed1088,304.9s passes at clean aa78b730f8b47ed552262797d9efccefad3c7adb.
All240 source/test hashes match the before-suite freeze; postflight0 global/
Elara BEAM. Raw preparations/controls and exact source/count/postflight artifacts
remain retained. No comparative timing or quiet-host claim.

Plan dc1a9002 declares one fresh finite32-cell regression: original24 checkpoints,
3 receipt transport checkpoints and5 general-job admission loss checkpoints,
seeds1088700–1088731. Register exact source, compiled/native hashes, cells and
60-second timeout before launch in rob-1088-final-chaos-20261006-a1. Use the
existing MatrixRunner/S2 peers/production supervisor3/5/causal/OS cleanup checks;
stop on failed, ineligible or unconfirmed cleanup. No edits/compiles/tests during
launch. This is separate from the original registered1200 measurement and is
not a performance comparison or proof over every possible schedule.

Current declared count129 files/49,387 source+infrastructure lines,+24 final
recovery variant/+1,012 cumulative versus48,375. Native inline tests and all
compatibility/runtime/infrastructure additions remain included. Session stays
2860 versus2657 baseline (+203); no Session change in operator/final variants.
The baseline named thread_wait execution branch now shares one branch with
completion_wait; compatibility aliases remain rather than counting their
removal as a win. The total increase refutes the net-reduction hypothesis.
Registration430f832d was posted before launch at frozen measurement source
81dc6826013fe858c0cf02c844555aaf5358ebab (source/test bytes equal full-tested aa78b73).
It records364 compiled module identities/836 artifacts and529 required checks.
Registration SHA25627fe958afd68abcdf427fd4559e432c751bfad23b0ec34e355c687815268f9f8;
driver SHA2566e314ed3130e50a63c22fb4e0a564eaf8a93cfaf73d6fcb9042d511b58a79f2d.
The launcher actually exited0:32 recorded/32 eligible/32 passed,544 reported
checks all true, all five general-api proofs true, no ineligible or unconfirmed
cleanup rows. Each row matches the registered identity/parameters/source pin.
Canonical compiled/native artifact verification afterward exits0; all240
source/test hashes still match and global BEAM count is0. Raw rows, registration,
host conditions, logs, summary and hash postflight are retained in the fresh
namespace. Summary SHA256f78d7d53127b1e0baae64a6441c11f8d4641996d792119e91b2d9d7088bcf1bf.

This completes the finite scripted regression and net-line comparison. It does
not pool rows with LAB-5's original1200, establish comparative performance or
prove every schedule. Separately approved capped real-model awaited-completion
acceptance remains pending; overall LAB-8 must remain incomplete until that gate
is resolved. The net-reduction hypothesis is refuted by the measured increase.

Final scripted PR#59 merged at77591c02a659c0fcda495331d5469a377251d559,
2026-10-06T15:38:37Z; main tree-equal to reviewed7ca63a3 after both actual
exact-head Socket checks passed. Self-review2d2d74e9 and deliveryee7513fa retain
source/full/registration/results boundaries. Overall LAB8 is Needs Input for
the separately approved real-model gate, with no executable lab remaining.
