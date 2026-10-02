# ROB-1085 round-one review probes (historical archive)

Source: [independent Tester thread](https://ampcode.com/threads/T-01a0fc63-9721-73bc-8c62-4ae02bf3e529).
Reviewed candidate: [e3edc7a46fec0288701e3b3364f84fdbbae22412](https://github.com/robertguss/Elara/commit/e3edc7a46fec0288701e3b3364f84fdbbae22412).

These are historical, pre-follow-up-repair diagnostic probes, preserved unchanged
from that thread's ignored artifacts. They are not accepted pilot measurements,
current acceptance evidence, or product tests. Their outputs require the
interpretation and qualifications recorded in the source thread; in particular,
absence of raw `activeId` is valid when the persisted active input is nil.

- `rob1085-observer-deadline-probe.exs`: persisted-state, report, and deadline probes.
- `rob1085-late-start-probe.exs`: timed-out start and late supervised child probe.
- `rob1085-runtime-mutations.exs`: temporary in-VM implementation mutations.

**Mutation scripts are not product tests and must only run in disposable
checkouts.** Use disposable checkouts and isolated temporary state for all these
probes: they write and remove temporary state, start processes, and suspend
coordinators or supervisors. The mutation script recompiles altered implementation
modules in its VM. Do not run these against shared state or a live session.

This commit preserves code only. No scripts, tests, or measurements were run as
part of archival preservation, and no product files were changed.
