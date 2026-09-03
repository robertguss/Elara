---
name: verify-elara
description: Drive Elara's Mix CLI, persistent chat, and Rust TUI the way a user does. Use when proving ask/chat/TUI/session/tool behavior, after changing those surfaces, or before claiming a user-visible fix works.
---

# Verify Elara

Elara is a Mix-run coding agent. A user touches `mix elara.ask`, `mix elara.chat`, and `mix elara.tui`. There is no web UI. The public Elixir API is the only way to set `cwd:` because the Mix tasks use process cwd and have no `--cwd` flag.

This skill is for a later agent that has never seen the app. Read `features/README.md`, then the feature file, then drive that path. Do not substitute `mix test` for a user-path proof.

## Launch

There is no long-lived default server. Launch means: compile once, create an isolated HOME and disposable cwd, then start each drive in its own process.

From the Elara repo root:

```bash
.cursor/skills/verify-elara/bin/launch
export ELARA_VERIFY_STATE=/tmp/elara-verify-<run-id>/state.env
.cursor/skills/verify-elara/bin/doctor
```

Ready when `bin/doctor` prints `instance is safe to drive`. Launch also prints `ELARA_VERIFY_STATE=...`.

What launch creates:

- Isolated `HOME` at `$VERIFY_ROOT/home` so sessions land in that tree, not `~/.elara`
- Scratch API cwd at `$VERIFY_ROOT/workspace`
- Detached git worktree at `$VERIFY_ROOT/worktree` for Mix tasks (their cwd is the session cwd)
- A free `ELARA_SERVER_PORT` reserved for this run
- Compile of the Mix project in the repo (`mix deps.get` + `mix compile`)
- `MIX_HOME`, `HEX_HOME`, and `CARGO_HOME` pointed at the user's real caches so isolated `HOME` does not trigger a fresh Hex/Cargo download

Teardown is `bin/cleanup`. It removes `$VERIFY_ROOT` and the worktree. It does not delete evidence.

If the checkout does not compile, stop and fix that before driving.

## Doctor

Read-only. Run first whenever anything looks off.

```bash
.cursor/skills/verify-elara/bin/doctor
.cursor/skills/verify-elara/bin/doctor --toolchain-only
```

Doctor must report:

- Elixir 1.20 and OTP 29, plus `cargo` and `flock`
- This run's `HOME` is `$VERIFY_ROOT/home`, not the user's home
- Worktree contains `mix.exs`
- `ELARA_SERVER_PORT` is free, or owned by a PID recorded in `state.env`
- Whether user credentials exist (values are never printed)

Refuse to drive if doctor fails. A shared `~/.elara` or a listener on this run's port that we did not start is not safe.

## Drive

Helpers (from repo root, after launch):

```bash
.cursor/skills/verify-elara/bin/drive scripted-chat --feature chat --lines '/help,/quit'
.cursor/skills/verify-elara/bin/drive scripted-ask --feature ask --prompt 'summarize this workspace' --reply 'workspace contains README.md'
.cursor/skills/verify-elara/bin/drive scripted-ask --feature tools --prompt 'write the note' --tool write --path nested/note.txt --content hello --reply 'wrote it'
.cursor/skills/verify-elara/bin/drive mix-ask-usage --feature ask
.cursor/skills/verify-elara/bin/drive mix-ask-unauth --feature ask --prompt 'summarize this workspace'
.cursor/skills/verify-elara/bin/drive tui-headless --feature tui
.cursor/skills/verify-elara/bin/drive --help
```

Stable handles (not coordinates):

| Surface | Handle | Meaning |
| --- | --- | --- |
| `mix elara.ask` | `[turn] <prompt>` | turn started |
| `mix elara.ask` | `  -> <tool>:` | tool started |
| `mix elara.ask` | `  <- ok (` / `  <- error:` | tool finished |
| `mix elara.ask` | `[done]` | successful turn |
| `mix elara.ask` with no prompt | `usage: mix elara.ask "prompt"` | usage error |
| `mix elara.ask` without auth | `Not logged in. Run \`mix elara.login\`` | config gate |
| `mix elara.chat` | `elara  ·  /help  /interrupt  /reload  /resume  /quit` | banner |
| `mix elara.chat` | `> ` | idle prompt |
| `mix elara.chat` | `/help` `/interrupt` `/stop` `/reload` `/why` `/resume` `/tree` `/fork` `/clone` `/name TEXT` `/quit` `/exit` `/q` | slash commands |
| `mix elara.chat` | `in a turn. /interrupt to cancel.` | mutation refused during a turn |
| TUI headless stdout | rendered 100×24 frame | session view |
| TUI headless stderr | `summary session=... incarnation=... head=...` | identity |
| TUI `list` | `SESSION\tSTATE\tHEAD\tCWD` | session table |
| Sessions | `$HOME/.elara/sessions/<cwd-key>/*.jsonl` mode `0600` | persisted chat |

`scripted-ask` and `scripted-chat` are the credential-free drives. They still use the real session, real `Elara.CLI.render/1`, and real `Elara.Chat.run/3`. `Elara.Provider.Scripted` is the production boundary for the LLM. Do not treat ExUnit as a substitute.

`mix-ask` and `mix-chat` are the real Mix tasks. They call `Elara.Config.resolve/0` and need `ELARA_API_KEY` / `XAI_API_KEY`, or a login under the **isolated** HOME. Isolated HOME has no tokens. A successful Mix turn therefore needs credentials exported in the drive process, and must run inside the worktree so tools cannot edit the user's checkout.

`tui-headless` without `--ask` may set a placeholder `ELARA_API_KEY` only so `new` can create a session. That key is not a provider. Do not pass `--ask` unless a real provider or a server started with a scripted provider will answer.

Never attach to `127.0.0.1:4048` unless this run started that listener and recorded its PID. Default port 4048 is the user's daily-driver server.

## Evidence

Write under:

```
.cursor/skills/verify-elara/artifacts/<feature>/<run-id>/
```

`bin/drive` always writes `command.txt`, `stdout.txt`, `stderr.txt`, `exit_code.txt`, and `meta.txt`. Scripted chat also writes `transcript.txt`. Scripted ask also writes `render.txt`.

Proof standards:

- Exercise the user path in the feature file. `mix test` is not that path.
- Capture the action and the resulting state, not only the last line.
- For mutations, read the file, session JSONL, or second command afterward.
- Scripted provider is allowed only as the LLM stand-in. Tools, chat commands, Mix usage/auth, and TUI attach must be real.
- A Mix dry-run does not exist. `mix-ask-unauth` is the auth gate, not a successful turn. Say so in the proof.
- Record the feature ID and the entry point (`mix elara.ask`, `scripted-chat`, `tui-headless`, …).

## Cleanup

```bash
.cursor/skills/verify-elara/bin/cleanup
```

Kills only PIDs listed in `state.env`. Removes `$VERIFY_ROOT` (must be `/tmp/elara-verify-*`) and `git worktree remove --force` on the worktree. Leaves `.cursor/skills/verify-elara/artifacts/` in place.

After cleanup, confirm the evidence directory still exists. If a drive failed, run cleanup before the next launch so ports and worktrees are not stranded.

## Isolate

Two verification runs can coexist if each has its own `VERIFY_ROOT`, HOME, worktree, and port. They cannot share:

- The user's `~/.elara`
- The repo working tree as a Mix-task cwd when tools may write
- Port 4048 unless this run owns it
- One persisted session file (flock). A second `mix elara.chat --continue` on the same HOME+cwd fails with `Session is already open.`

If doctor cannot prove isolation, stop. Do not drive the user's live session.

## Helpers

All helpers are executable. Invocations are above. `bin/drive --help` lists flags. Elixir scripts live in `scripts/` and are only called through `bin/drive`.
