# Slice 1. Persist and resume

Back: [overview.md](overview.md)

**Status.** Not started. Build this first. Stop when the checks below are green. Do not start slice 2 in the same session.

## Goal

A chat you quit can be opened again. Same cwd. Same history. The file is already a tree with one spine.

## Changes

- New log module. Encode and decode our three message structs. Header line plus message lines. Append after each `message_appended`.
- Session shell. After `Core.step/2` emits a message, write that line and update `leaf`. Open-from-path rebuilds `history` by walking `leaf` to root (a single path in this slice).
- Public API. `start_session/1` accepts a resume path or "continue most recent for this cwd."
- Chat and Mix. `/resume` lists sessions for this cwd. `mix harness.chat --continue` opens the newest. Default chat still starts a new file.
- README. Document `--continue`, `/resume`, and the `~/.harness/sessions/` location.
- Tests. Pure encode/decode and walk. Process test: two scripted turns, "quit," reopen, third turn sees prior history.

Do not add `/tree`, `/fork`, `/clone`, or `/name`.

## Data structures

`Log.Header` holds `version`, `id`, `cwd`, `leaf`. `Log.Entry` holds `id`, `parentId`, `timestamp`, and a `User | Assistant | ToolResult`. On-disk `leaf` is the current tip id.

## Verification

**Static.** `mix test` and `mix format --check-formatted`.

**Runtime.** `control-cli` (tmux or PTY). Scripted or live provider. `mix harness.chat`, one prompt, `/quit`, `mix harness.chat --continue`. The second process must reprint or act on the first turn's history. A green unit suite without this check is not done.

## Done when

- A new chat creates a JSONL file under `~/.harness/sessions/<cwd-key>/`.
- Each appended message is one JSON line with `id` and `parentId`.
- `--continue` and `/resume` load that file into an idle session.
- `mix test` green. Runtime resume captured.
- Slice 2 and 3 files are untouched as product. Header already has `leaf`.
