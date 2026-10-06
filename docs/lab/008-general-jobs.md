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
overall reduction. Integrated suite, immutable review and chunk delivery are
pending; profiles, correlated wake, UI acknowledgment, final chaos/net-line
comparison and the separately approved real-model gate remain in ROB-1088.
