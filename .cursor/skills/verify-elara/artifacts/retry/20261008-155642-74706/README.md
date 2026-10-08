# provider retry — ROB-1343

Five `scripted-ask` drives from one launch, each kept in its own labelled
subdirectory because `bin/drive` reuses the run's evidence path. Every drive
is the public ask path: real session, real `Elara.CLI.render/1`,
`Elara.Provider.Scripted` only as the LLM stand-in. No credentials, no network,
no real model.

`--retry-attempts` also sets the backoff base to 250ms so a drive does not wait
on the shipped defaults. The `[retry]` line names the upper bound of the wait.

## Drives

| Label | Script | Exit | What the render shows |
| --- | --- | --- | --- |
| `recover` | one 503, then the answer, 3 attempts | 0 | one `[retry] attempt 2 of 3`, the answer, `[done]` |
| `exhaust` | three 503s, 3 attempts | 1 | attempts 2 and 3, then `[done] provider error: 503 service overloaded` |
| `retry-after` | one 429 with `Retry-After: 1s` | 0 | `[retry] attempt 2 of 2 in 1.0s`; `elapsed_ms=1698` |
| `terminal` | one 401, 3 attempts allowed | 1 | `[done] provider error: 401 invalid api key` and no `[retry]` line |
| `persist` | same as `recover`, session saved | 0 | `session.jsonl` holds one user entry and one assistant entry, mode 0600 |

Linux scripted drives are not Mac/WezTerm acceptance. The TUI status row is
proved by the Rust frame test `awaiting_retry_turn_state_is_accepted_and_shown`,
not by a driven TUI session: `tui-headless` renders after the turn settles and
has no scripted provider.
