# ROB-1085 round-two review diagnostics

- Source: [independent Tester thread](https://ampcode.com/threads/T-01a0fca1-a7ee-7537-8eb1-a734415c4a50).
- Reviewed candidate: [`3e961f7e96742126527658053e9b64770eda9c36`](https://github.com/robertguss/Elara/commit/3e961f7e96742126527658053e9b64770eda9c36).
- Status: historical pre-repair diagnostics only, captured before repairs to
  the findings from this review. These are not current acceptance evidence,
  product tests, pilot measurements, or replacement sweep results.

The two scripts and four logs were copied byte-for-byte from the source
thread's `.amp/in/artifacts/` directory after inspection for secrets. This
preservation commit does not rerun them or modify product code. The original
invalidated pilot evidence elsewhere under ROB-1085 remains unchanged.

| File | Historical purpose |
| --- | --- |
| `rob1085-independent.exs` | Persisted-store, reporting, deadline, and ownership probes. |
| `rob1085-independent.out` | Retained output of those independent probes. |
| `rob1085-source-mutant.exs` | In-memory source-mutation diagnostic driver. |
| `rob1085-source-mutants.out` | Retained output for six source mutants. |
| `rob1085-focused-rerun.out` | Focused recovery-suite rerun at seed 0; 23/24 passed. |
| `rob1085-full.out` | Full suite at seed 255980; 823/824 passed. |

**The mutation scripts are not product tests and must only run in disposable
checkouts.** They deliberately weaken loaded code or exercise process failure
and persisted-state corruption. They assume the reviewed candidate's APIs and
source text; do not integrate them into CI or interpret them as validation of
a later revision. Preservation does not authorize executing them.
