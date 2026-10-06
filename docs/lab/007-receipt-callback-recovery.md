# 007 — Receipt callback ownership

- **Question:** Can a lost receipt-backed TCP callback release queued inputs
  without replaying the uncertain operation or inventing completion?
- **Hypothesis:** Separating the callback from its surviving ledger writer
  lets that writer record one indeterminate terminal after actual worker loss.
- **Queue item:** ROB-1104 · **Date:** 2026-10-06
- **Baseline:** merged main `eaeb3dd23f3432ccada2927c46d1263163d63ff9`.

## Finding and authority

The retained LAB-5 optional LocalExecutor client fault killed the ledger writer,
which was also the TCP callback owner. A reached indeterminate, but B/C remained
queued behind accepted/one-attempt/zero-terminal evidence despite physical native
cleanup. The original failed row, candidate and read-only ledger copy remain in
`lab/results/rob-1085-transport-recovery-preparation-20261006/`; neither that row
nor LAB-5's registered 1200-row measurement is changed or pooled with this work.

The executor still has one serial writer and retains its original admission,
digest, attempt, completion and reply order. The callback now runs in an owned
linked worker. The writer waits for that exact Task result or actual monitor
DOWN; worker loss records uncertainty with a valid result digest and one
terminal. It never infers success, failure or exactly-once external effects.
Exit trapping is scoped to that wait. Parent loss still stops the writer;
writer death kills its linked callback. A lost writer or VM leaves attempted
receipts unresolved, with no startup terminalization or callback replay rule.
No schema, acknowledgment bypass, cross-incarnation receipt authority or
concurrent-writer policy is added. Supported callbacks keep their ownership
link; arbitrary trusted code that unlinks itself is outside that boundary.

The default production receipt scope remains local declarative write. A
separate `receipt_backend=true` transport-lab mode explicitly configures the
optional receipt route. Default direct remote tools retain their existing
behavior. The lab independently observes the socket owner, callback/writer link,
registered writer identity and live read-only SQLite attempted receipt before
injection. After loss it checks the same surviving writer and receipt identity,
one indeterminate terminal, A/B/C completion, one native launch, actual native
settlement/cleanup, serving worker, and rejected submit/continue replay. SQLite
observation opens readonly and uses the existing validated record decoder.

## Verification so far

The original runtime passes 9/11 Executor checks; the two new controls fail.
The corrected red run kills the actual callback owner and times out waiting for
a causal terminal. The first red log also contains an invalid chained count
assertion; it was corrected before implementation and stays retained.

After splitting the processes, the first retained effect/input/executor suite
passes 113/120. Seven fixtures had equated callback self() with the writer PID.
Their checkpoint identities now prove the actual callback's link to the intended
writer, kill that same writer and require worker DOWN. Every original unresolved
receipt, no-retry, postcondition and causality assertion remains unchanged.
That suite then passes 120. Owned worker/writer cleanup is registered before
fallible waits; no raw failure is discarded.

The receipt transport mode passes all three named checkpoints. Premature loss
and released held checkpoints cannot count as nominated faults; forced failure
proves source, writer, callback, TCP/native actors and registry entry are gone.
The original direct-route checks remain. Removing the worker link independently
fails the original worker-DOWN assertion after writer death; registered cleanup
still passes, and reviewed source bytes were restored exactly.

Final combined effect/executor/input/transport verification passes 132 checks
(seed 1104) after narrowing exit trapping to the callback wait. Compile with
warnings-as-errors and format/diff checks pass.

Raw logs and reviewed control source:
`lab/results/rob-1104-receipt-recovery-20261006/`.
Final integrated suite, frozen fresh dev receipt rows, independent readback,
review and merged delivery are pending; current status is in Linear.
