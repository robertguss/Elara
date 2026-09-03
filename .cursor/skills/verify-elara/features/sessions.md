# Sessions

Sessions persist chat history per working directory, can be named, continued, listed, and branched. Files live under `$HOME/.elara/sessions/<cwd-key>/` with mode `0600`.

## Sub-features

- `session-create` writes a JSONL file for a new persisted chat.
- `session-name` sets a display name with `--name` or `/name TEXT`.
- `session-continue` resumes the newest usable session for this cwd.
- `session-resume` lists cwd-scoped sessions and switches with `/resume N`.
- `session-tree` branches in the same file with `/tree N`.
- `session-fork` copies history before a turn into a new file with `/fork N`.
- `session-clone` copies the current path into a new file without re-submitting.

## How to get to it (user POV)

- Run `mix elara.chat` (new session) or `mix elara.chat --continue`.
- Run `mix elara.chat --name "runtime investigation"`.
- Type `/resume`, `/resume N`, `/name TEXT`, `/tree`, `/tree N`, `/fork`, `/fork N`, or `/clone` at the `> ` prompt.

## Driving it with verify-elara

Preconditions:

- `bin/doctor` reports the instance is safe to drive.
- Isolated HOME is empty of sessions for `$WORKSPACE`.
- Scripted drives use `--persist` so files land under isolated `$HOME/.elara/sessions`.

- **Create named session.** Run `.cursor/skills/verify-elara/bin/drive scripted-chat --feature sessions --persist --name "verify session" --lines 'ping,/quit' --reply 'pong'`. Exit code `0`. Transcript contains `pong`. A `*.jsonl` appears under `$HOME/.elara/sessions/<cwd-key>/` with mode `600`.
- **Continue.** Run `.cursor/skills/verify-elara/bin/drive scripted-chat --feature sessions --continue --lines '/quit'`. Exit code `0`. Transcript reprints the earlier `ping` / `pong` path before the prompt.
- **Continue miss.** After cleanup of session files only (not evidence), `--continue` with no saved session fails with `No saved session for this directory.`
- **Name.** In a persisted scripted chat, send `/name verify-renamed,/quit`. Transcript contains `session named`.
- **Resume list.** Send `/resume,/quit`. Transcript lists the cwd-scoped session, newest first.
- **Proof.** Copy or `ls -l` the JSONL into `artifacts/sessions/<run-id>/` along with the transcript. A second drive that continues must show the first prompt in the reprinted transcript. Do not keep these files in the user's `~/.elara`.

## Gotchas

- Persistence is scoped by the absolute cwd. `$WORKSPACE` and `$WORKTREE` are different keys.
- Plain `mix elara.chat` creates a new session. It does not silently continue.
- `--continue` fails instead of creating a session when none exist.
- A second process cannot take the same persisted session lock. Expect `Session is already open.`
- `/tree` stays in the same file. `/fork` and `/clone` create a new file.
- Resume, tree, fork, clone, and name require an idle session.
- `mix elara.ask` uses `persist: false` and will not show up in `--continue`.
