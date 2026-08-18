# Session persistence

Read this file first in a fresh session. Build one slice. Stop. The next session
starts at the next unchecked slice.

Parent investigation (2026-08-17). Pi docs:
[Sessions](https://pi.dev/docs/latest/sessions),
[Session format](https://pi.dev/docs/latest/session-format). Do not copy Pi's
wire types.

## Context

`mix harness.chat` dies with the BEAM. History lives only in
`Harness.Session.Core` state. The user wants to quit and continue, then later
branch like Pi. Pi stores JSONL under `~/.pi/agent/sessions/`, keyed by cwd.
Each line after the header has `id` and `parentId`. The active tip is a leaf.
`/tree` moves the leaf in the same file. `/fork` and `/clone` write a new file.

## Scope

Included, in this order:

1. [Slice 1. Persist and resume](slice-1-persist-resume.md)
2. [Slice 2. In-file `/tree`](slice-2-tree.md)
3. [Slice 3. `/fork`, `/clone`, `/name`](slice-3-fork-clone.md)

Excluded until a later plan:

- Pi JSONL interoperability
- Compaction, `branch_summary`, custom/hook roles
- Phoenix, MCP, plan mode, plugin loader
- Session files inside the project working tree
- A full-screen tree widget
- Mid-turn crash recovery of in-flight tools

## Constraints

- Elixir 1.20, OTP 29. `req` stays the only Mix dep.
- `Core.step/2` remains the only history writer. Disk records what `step/2`
  already appended.
- History on the model path is still `[User | Assistant | ToolResult]`.
- Persist only after idle-safe appends. A tool result must be on disk before the
  next provider call (I2).
- Files live under `~/.harness/sessions/<cwd-key>/`. Copy the auth write style
  (temp file, rename, mode 600) from `Harness.Auth`.
- The on-disk shape is a tree from day one (`id`, `parentId`, `leaf`). Slice 1
  only ever writes a single spine. Do not ship a linear format that needs a
  v1-to-v2 migration.
- Chat stays a line client. `/tree` in slice 2 is a numbered list of user
  prompts.

## Alternatives

| Approach                                      | Verdict                                       |
| --------------------------------------------- | --------------------------------------------- |
| Linear JSONL now, add `parentId` later        | Rejected. That is Pi's v1-to-v2 tax.          |
| SQLite or DETS                                | Rejected. The user asked for JSONL files.     |
| Tree-shaped JSONL, linear spine until slice 2 | Chosen. Resume works. `/tree` is a leaf move. |

## Applicable skills

- **how** over `Session`, `Session.Core`, `Chat.Core`, and `Auth` before editing
  them.
- **Feature** playbook for each slice. One Feature per slice. Fresh session per
  slice.
- **control-cli** for resume and `/tree` on a real tty.
- `/deslop` before commit. **unslop** and **technical-writing** on README and
  this plan.
- **no-comments** before review.
- **interrogate** before shipping slice 2 if the leaf-rebuild design is
  contested.
- Cursor **babysit** after the PR for that slice.

## File pointers

| Path                                     | Why                                                                                                        |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `lib/harness/session/core.ex`            | Only history writer. `Core.new/1` always starts `history: []`. Hydrate on resume. Do not append from chat. |
| `lib/harness/session.ex`                 | `feed/2` runs `step/2`. Persist after `{:emit, {:message_appended, _}}` (I2). Sessions are `:temporary`.   |
| `lib/harness/event.ex`                   | Emit vocabulary. Persist on `message_appended`, not on `turn_ended` alone.                                 |
| `lib/harness/message.ex`                 | `User`, `Assistant`, `ToolResult`. Encode these, not Pi's union.                                           |
| `lib/harness/provider.ex`                | Resume must stay legal as `Request.messages`.                                                              |
| `lib/harness.ex`                         | `start_session/1` grows resume/continue opts. None exist yet.                                              |
| `lib/harness/chat.ex`                    | Always starts a fresh session. Argv is a seed prompt. `/resume` attaches here.                             |
| `lib/harness/chat/core.ex`               | Commands are `/quit`, `/interrupt`, `/help`. Add `/resume` idle-only next to `idle_line/1`.                |
| `lib/mix/tasks/harness.chat.ex`          | No `OptionParser` yet. Add `--continue`.                                                                   |
| `lib/harness/auth.ex`                    | `save_tokens/1`: `mkdir_p!`, write `path <> ".tmp.#{unique}"`, `chmod 0o600`, `rename`.                    |
| `test/harness/session_test.exs`          | Scripted process test. Closest reopen pattern.                                                             |
| `test/harness/chat_test.exs`             | Two scripted turns then `/quit` through `Chat.run/3`. Closest quit/reopen.                                 |
| `test/harness/chat/core_test.exs`        | Command table rows. Add `/resume` here.                                                                    |
| `test/harness/message_test.exs`          | Empty-assistant invariant. Encode these structs.                                                           |
| `test/harness/provider/open_ai_test.exs` | History to wire. Hydrated history must stay legal.                                                         |
| `design/HANDOFF.md`                      | I1–I5. Ignore the stale "no domain yet" paragraph.                                                         |
| `design/base/RATIONALE.md`               | Persistence was left out of the base on purpose. One effect consumer later.                                |

## Phases

1. [slice-1-persist-resume.md](slice-1-persist-resume.md)
2. [slice-2-tree.md](slice-2-tree.md)
3. [slice-3-fork-clone.md](slice-3-fork-clone.md)

Shared checks: [testing.md](testing.md).

## Verification

```bash
mix test
mix format --check-formatted
```

Plus the runtime check named in the slice you are building. Unit tests do not
count as resume proof.

## Implementation guidance

Start a Feature. Do not restart an arena on the file format. That choice is
closed.

Run **how** on the session shell and chat command table before you touch them.

Keep `Core.step/2` as the writer. If you need a new fact to rebuild history on
boot, add it as a load path into `Core.new/1` or a single `hydrate` constructor.
Do not append from the chat process.

`/deslop` each diff. **unslop** the README hunk. After the PR, babysit that PR
only.

Do not implement slice 2 types in slice 1 beyond `id`, `parentId`, and `leaf` on
disk. Do not implement `/fork` in slice 2.
