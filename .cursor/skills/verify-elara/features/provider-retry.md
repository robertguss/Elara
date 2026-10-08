# Transient provider failures

A flaky model API should not end a turn. When a provider call fails with a rate limit, an overload, a 5xx, or a connection dropped before anything was shown, Elara waits out a bounded backoff and asks the same request again, telling the operator each time. Authentication and invalid-request failures still end the turn at once, and a failure that arrives after the answer started streaming is reported rather than replayed.

## Sub-features

- `retry-recovers` prints a `[retry]` line, then the answer and `[done]`, exiting 0.
- `retry-exhausts` prints every `[retry]` line and then exits 1 with the final provider error.
- `retry-after` waits out a server `Retry-After` before the next attempt.
- `retry-terminal` never retries an auth or invalid-request failure.
- `retry-no-duplicates` leaves one user message and one assistant message in the session record.
- `retry-status` shows the pending retry as the TUI turn state.

## How to get to it (user POV)

- Run `mix elara.ask "..."` or `mix elara.chat` against a provider that is rate limiting or overloaded.
- Watch the TUI status row while a provider call is waiting to be retried.
- Set `ELARA_PROVIDER_RETRY_ATTEMPTS` / `ELARA_PROVIDER_RETRY_MAX_WAIT_MS`, or pass `provider_retry:` to `Elara.start_session/1`, to change or disable the bounds.
- Press Ctrl-C (or `/interrupt` in chat) while a retry is pending to abandon the wait.

## Driving it with verify-elara

Preconditions:

- `bin/doctor` reports the instance is safe to drive.
- Isolated HOME has no auth files; these drives use the scripted provider.
- `$WORKSPACE/README.md` exists (launch writes it).

- **Recovered turn.** Run `.cursor/skills/verify-elara/bin/drive scripted-ask --feature retry --prompt "summarize this workspace" --reply "workspace contains README.md" --fail-first 1 --retry-attempts 3`. Exit code `0`. `render.txt` contains `[turn] summarize this workspace`, one `[retry] attempt 2 of 3`, `workspace contains README.md`, and `[done]`.
- **Exhausted turn.** Run `.cursor/skills/verify-elara/bin/drive scripted-ask --feature retry --prompt "summarize this workspace" --fail-first 3 --retry-attempts 3`. Exit code `1`. `render.txt` contains `[retry] attempt 2 of 3`, `[retry] attempt 3 of 3`, and `[done] provider error: 503 service overloaded`, and no answer text.
- **Server-directed wait.** Run `.cursor/skills/verify-elara/bin/drive scripted-ask --feature retry --prompt "summarize this workspace" --fail-first 1 --fail-kind retry_after --retry-attempts 2`. Exit code `0`. `render.txt` contains `[retry] attempt 2 of 2 in 1.0s`, and `meta.txt` shows the drive took at least a second.
- **Terminal failure.** Run `.cursor/skills/verify-elara/bin/drive scripted-ask --feature retry --prompt "summarize this workspace" --fail-first 1 --fail-kind terminal --retry-attempts 3`. Exit code `1`. `render.txt` contains `[done] provider error: 401 invalid api key` and no `[retry]` line.
- **No duplicates.** Run the recovered turn again with `--persist --name "retry proof"`, then read the newest JSONL under `$HOME/.elara/sessions/`. It holds exactly one `user` entry and one `assistant` entry for the turn.
- **Retry status in the TUI.** Not reachable with `tui-headless`, which renders one frame after the turn settles and has no scripted provider. Prove the status row with the Rust frame test (`awaiting_retry_turn_state_is_accepted_and_shown`) and report it as a non-user-path proof.
- **Proof.** Keep `command.txt`, `stdout.txt`, `stderr.txt`, `exit_code.txt`, `render.txt`, and `meta.txt` under `artifacts/retry/<run-id>/`.

## Gotchas

- `--fail-first` counts attempts, not turns. With `--retry-attempts N`, `--fail-first N` exhausts the turn and `--fail-first N-1` recovers.
- `--retry-attempts` also shortens the backoff base to 250ms. Without it the shipped defaults apply and a drive can wait seconds.
- A `[retry]` line names the upper bound of the wait, not the jittered wait actually taken. Only a `Retry-After` drive has an exact delay.
- A failure after streamed output is never retried. A scripted stream that fails mid-answer must show `[done] provider error`, not a `[retry]` line.
- Lab scenarios disable retries on purpose. Do not read a lab run as proof of this path.
