# Sessions and chat

`mix elara.chat` is the persistent, interactive Elara client. It writes
conversation history after each message and lets you resume or branch that
history later.

Transcript saves append a complete JSONL batch containing new messages and the
latest session metadata. They do not rewrite earlier messages. The session
holds its transcript file open and syncs it after the final inbox update, before
reporting a completed or interrupted turn. Shutdown and unclaimed bootstrap
writes also sync. During a turn, completed batches are readable, but are not
promised to survive a power loss before that sync.

A final batch without its newline is ignored on reopen, even if its JSON looks
complete. The next writer removes that tail under the session lock before
appending. A malformed complete line or an invalid message is an error, not
evidence that can be discarded. Version 1 transcripts remain readable and gain
batches on their next save without rewriting their original bytes. Older Elara
builds cannot read the new batches. Branches retain their off-path messages;
copies include only the selected path.

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

Directory aliases that resolve to the same existing directory share session
listing and lookup, including macOS `/var` and `/private/var` paths. Resuming
keeps the saved workspace path and effect identity. Existing storage keys and
files are preserved; lookup reads a header from each workspace bucket to find
aliases before loading matching histories.

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

Under R7, executor startup records an `indeterminate` terminal for an orphaned
attempt only under both exclusive ownership locks plus durable VM/writer/callback
identity proving the old owners are dead. A different live VM refuses takeover,
naming its OS PID, node and start time: stop it first. Startup never replays the
callback. A live callback timeout leaves the queue barrier in place until a
durable terminal exists.

If a write is refused during reopen before its callback ever started (for
example, its pinned path now points elsewhere), its receipt is durably failed
with zero attempts. No write runs, and the next turn can proceed.

Ledger schema 4 migrates schemas 1–3 in place without changing their receipts
or incarnation evidence. Legacy attempts from schemas 1 and 2 retain
`attempt_incarnation: nil`, so startup never auto-terminalizes them. A session
blocked by a legacy attempt stays idle and refuses a new turn for missing proof.
Use `/clone` or `/fork` to continue in a separate session. Neither command repairs
the original receipt or proves that the old effect completed.

### Why recovery uses two lockfiles

The executor uses separate `.writer.lock` and `.callbacks.lock` files beside
the ledger. The writer holds an exclusive lock for its lifetime. Before
`begin_attempt`, the linked worker acquires a shared callback lock and confirms
that acquisition to the writer. Every new attempt records the VM's incarnation
and its writer/callback PIDs. Startup holds both locks exclusively and checks
the durable owner identities while it repairs orphaned attempts. Loss of a lock
Port alone is not proof that its Erlang callback stopped.

A guardian alone cannot supply durable ownership proof across writer or VM
loss. A single lock changed from exclusive to shared would leave a gap during
the ownership change. Two lockfiles keep writer ownership separate from callback
lifetime without that gap. Recovery uses neither elapsed-time guesses nor lockfile
unlinking. The files remain in place; releasing the operating-system locks does
not require deleting them.

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

An interrupted tool call gets a result in history so a later provider request
does not receive an unmatched tool call. When a session reopens after dying
mid-turn, the first unresolved call is the only one that can have started. If
its arguments parsed, it is recorded as `indeterminate`, even for a read-only
tool, because the current tool set cannot prove what it did. The calls after
it are recorded as `interrupted`. All repairs are saved together. One limit:
if the session dies again while executor-backed recovery is still writing its
results, a later reopen may record a call that never started as
`indeterminate`. That errs toward uncertainty, never toward a false error.

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
