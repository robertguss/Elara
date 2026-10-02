# ROB-1085 historical evidence invalidation

These files are retained for audit only. They are not accepted pilot evidence
and must not be edited to repair their claims.

## Attempt 1

- Candidate: `b9a9ec00a4e5f0802c33045b5380c16d9a0f3dbf`.
- Disposition: invalid harness attempt; 30 child errors; zero result records;
  raw evidence lost.
- Only `attempt-1-INVALID-HARNESS.md` and the historical command/thread
  narrative survive. Do not reconstruct or fabricate replacement records.

## Attempt 2

- Candidate: `8a2c2c5`.
- Disposition: invalid pilot evidence due to observer/protocol validation
  failure and a missed pre-review gate.
- The retained JSON and logs preserve the original bytes and erroneous flags.
  They do not establish terminal B/C completion, bounded recovery, bounded
  backlog, the registered causal protocol, or accepted reproduction.
- The narrow supported observation is that marker records contain A's input
  receipt `"session restarted"` and its associated persisted typed
  `{:error, "interrupted"}` tool outcome. That is a scientific negative, not a
  completed recovery result.

## Retention verification

Before relocation, 64 tracked files under `docs/lab/evidence/rob-1085` were
inventoried with SHA-256. After relocation to `lab/results/rob-1085`, the same
64 relative files had identical hashes. The normalized inventory digest was:

```text
d6a9f8b5bbe2a71b286caf3652dd5ea8953001d52f863c68cda206d24c330565
```

This manifest was added after that equality check and is not one of the 64
historical files.
