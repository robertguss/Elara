# Attempt 1 — invalid harness measurement

This is not a recovery measurement. Do not treat it as one of the registered
30 runs, and do not replace it with attempt 2.

- **Candidate:** `b9a9ec00a4e5f0802c33045b5380c16d9a0f3dbf`
- **Command:** `MIX_ENV=dev mix elara.lab sweep session_recovery --over fault=provider_started,provider_streaming,tool_running --n 10 --seed 42 --results /tmp/elara-lab-1085`
- **Started:** 2026-10-02T01:59:12Z
- **Directory:** `/tmp/elara-lab-1085/session_recovery/20261002T015912688401Z-sweep-fault-seed42`
- **Exit:** Mix raised `sweep incomplete`. Every child exited 1. Present counts were 0/10 for each fault. Curve fields were null.

Every child failed before writing a result line:

    Protocol.UndefinedError: protocol JSON.Encoder not implemented for Elara.Message.User

The failure was in `Elara.Lab.write_results/2`. The scenario returned Message
structs inside the result map. No accepted ids, receipts, history counts,
marker counts, or timings were recorded.

The raw directory was deleted by `rm -rf /tmp/elara-lab-1085` before attempt 2.
That deletion was a Builder mistake. The first log excerpt above is the
retained evidence; the directory itself is not recoverable from this orb.
