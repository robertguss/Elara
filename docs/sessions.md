# Sessions and chat

`mix elara.chat` is the persistent, interactive Elara client. It writes
conversation history after each message and lets you resume or branch that
history later.

## Start and continue

```bash
# New session
mix elara.chat

# New session with a display name and optional first prompt
mix elara.chat --name "fix parser" "inspect the parser tests"

# New process, newest session for this working directory
mix elara.chat --continue
mix elara.chat --continue "continue the previous investigation"
```

Session files live under `~/.elara/sessions/<cwd-key>/`. They are scoped by the
session working directory. Durable JSONL, effects SQLite, `.flight`, and `.lock`
artifacts are created with mode `0600`. SQLite's transient `-wal` and `-shm`
sidecars exist only while a database is open and may have a mode determined by
SQLite and the process umask. Starting plain `mix elara.chat` creates a new
session; it does not silently continue an old one.

Only one turn runs in a session at a time. A second prompt and commands that
change history are refused until the active turn finishes or you run
`/interrupt`. Provider failures return to the `> ` prompt without ending chat.

## Resume and name sessions

Run `/resume` to list saved sessions for the current working directory, newest
first, then `/resume N` to switch the current chat to one of them. Its
transcript is printed after the switch.

Use `/name TEXT` to update the current session's display name. You can also name
a new session with `mix elara.chat --name TEXT`.

`mix elara.chat --continue` is the noninteractive shortcut for resuming the
newest usable session. If there is no saved session for the current directory,
startup fails instead of creating one.

### Recover an interrupted write

The built-in local `write` tool records a durable intent and executor receipt.
When `--continue` finds an unresolved write, Elara reconciles those records
before accepting another prompt:

- a durable terminal receipt is returned without writing the file again;
- an accepted write whose callback never started may continue under the same job
  and executor identity; and
- a callback attempt without a terminal receipt is reported as `indeterminate`
  and is not retried.

Current file contents can prove that desired bytes are present, but cannot by
themselves prove which job wrote them. Elara therefore fails closed when causal
evidence is missing.

## Branch conversation history

Elara stores a tree of messages rather than only a linear transcript.

### Branch in the same session

1. Run `/tree` to list user turns on the active path.
2. Run `/tree N` to select one.

Elara moves the active history to just before that user turn and re-submits the
selected prompt. Later messages on the old path remain in the same JSONL file
but are no longer sent to the model on the new path.

### Fork into another session

1. Run `/fork` to list user turns.
2. Run `/fork N` to select one.

Elara copies the history before that turn into a new session, switches to it,
and re-submits the selected prompt. The source session is unchanged.

Run `/clone` to copy the complete current path into a new session without
re-submitting a prompt. `/fork` and `/clone` create new session files; `/tree`
does not.

## Interrupt and exit

- `/interrupt` and `/stop` cancel the current provider or tool turn.
- `/quit`, `/exit`, `/q`, and Ctrl-D exit an idle chat.
- During a turn, quit first requests an interrupt and then exits when the turn
  ends. A second quit exits immediately.
- `/help`, `/h`, and `/?` work while idle or during a turn.
- `//text` sends `/text` as a normal prompt rather than parsing it as a command.

An interrupted tool call is recorded as interrupted in history so a later
provider request does not receive an unmatched tool call.

## Explain an event with `/why`

Every session keeps a deterministic flight recording of state transitions. After
a turn, run:

```text
/why
/why 7
```

`/why` explains the transition that emitted the latest event. `/why N` selects
an event sequence. The output includes the recording and transition identity,
the triggering fact, and its causal chain.

Persistent sessions write a versioned `.flight` file beside their session JSONL.
The [Elixir API](elixir-api.md#recordings-status-and-replay) can load and replay
it without calling the model or executing tools.

## Command reference

| Input                          | Idle                             | During a turn         |
| ------------------------------ | -------------------------------- | --------------------- |
| text                           | Start a turn.                    | Refused.              |
| `/interrupt`, `/stop`          | No-op.                           | Cancel the turn.      |
| `/reload`                      | Reload local plugins.            | Refused.              |
| `/why`, `/why N`               | Explain an event.                | Refused.              |
| `/resume`, `/resume N`         | List or switch sessions.         | Refused.              |
| `/tree`, `/tree N`             | List or branch in this session.  | Refused.              |
| `/fork`, `/fork N`             | List or fork into a new session. | Refused.              |
| `/clone`                       | Clone the current history path.  | Refused.              |
| `/name TEXT`                   | Name the session.                | Refused.              |
| `/help`, `/h`, `/?`            | Show help.                       | Show help.            |
| `/quit`, `/exit`, `/q`, Ctrl-D | Exit.                            | Interrupt, then exit. |
