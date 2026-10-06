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
