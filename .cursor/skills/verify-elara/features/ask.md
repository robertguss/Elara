# One-shot ask

One-shot ask runs a single prompt through `mix elara.ask`, prints tool activity and the answer, then exits. It does not persist a session.

## Sub-features

- `ask-usage` rejects a missing prompt.
- `ask-unauth` refuses to start when no login or API key is available.
- `ask-turn` prints `[turn]`, the answer, and `[done]`, then exits 0.
- `ask-tools` prints `  ->` / `  <-` lines when the model calls a tool.
- `ask-failure` exits 1 on provider error, interrupt, wait timeout, or turn limit.

## How to get to it (user POV)

- Run `mix elara.ask "summarize this workspace"` from an Elara checkout.
- Run `mix elara.ask` with no prompt.
- Call `Elara.start_session/1` then `Elara.ask/2` when the Mix cwd must not be the session cwd.

## Driving it with verify-elara

Preconditions:

- `bin/doctor` reports the instance is safe to drive.
- Isolated HOME has no auth files.
- `$WORKSPACE/README.md` exists (launch writes it).

- **Usage gate.** Run `.cursor/skills/verify-elara/bin/drive mix-ask-usage --feature ask`. Exit code `1`. stderr contains `usage: mix elara.ask "prompt"`.
- **Login gate.** Run `.cursor/skills/verify-elara/bin/drive mix-ask-unauth --feature ask --prompt "summarize this workspace"`. Exit code `1`. stderr contains `Not logged in. Run \`mix elara.login\``.
- **Scripted turn.** Run `.cursor/skills/verify-elara/bin/drive scripted-ask --feature ask --prompt "summarize this workspace" --reply "workspace contains README.md"`. Exit code `0`. `render.txt` contains `[turn] summarize this workspace`, `workspace contains README.md`, and `[done]`.
- **Credentialed Mix turn.** Only when doctor reports real credentials and you export them for the drive. Run `.cursor/skills/verify-elara/bin/drive mix-ask --feature ask --prompt "Reply with exactly: ask works"`. Exit code `0`. stdout contains `[done]`. This is a different entry point from scripted-ask; do not mark it verified from the scripted drive.
- **Proof.** Keep `command.txt`, `stdout.txt`, `stderr.txt`, `exit_code.txt`, and `render.txt` under `artifacts/ask/<run-id>/`. Confirm isolated `$HOME/.elara/sessions` has no new JSONL from the one-shot scripted drive (`persist` is off).

## Gotchas

- Mix ask uses the Mix process cwd as the session cwd. Drive Mix from `$WORKTREE`, never the user's dirty checkout.
- Isolated HOME has no tokens. `mix-ask` without exported credentials is the unauth gate, not a successful turn.
- One-shot ask does not persist. A later `--continue` must not offer this conversation.
- `[done]` alone is not enough when tools ran. Require the `  ->` / `  <-` lines or a file side effect from [Built-in tools](./tools.md).
