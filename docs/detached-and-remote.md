# Detached sessions and remote workers

Elara has two separate runtime features for work that should not live entirely
inside one interactive client:

- A local server owns sessions while clients attach and detach.
- Authenticated workers execute selected tools in mapped workspaces.

## Detachable sessions

For a normal one-terminal session, run:

```bash
mix elara.tui new
```

If nothing is listening on the selected port, the Mix task starts an embedded
Elixir server before launching the Rust client. The embedded server lives only
for that command, so exiting the TUI also ends its live sessions.

For turns to continue after the TUI exits and for later live reattachment, start
a long-lived server in one terminal:

Set `ELARA_SERVER_TOKEN` to a random shared token of 32–512 bytes in the
server terminal and every client terminal. For example, generate one with
`openssl rand -hex 32` and place the same value in each terminal's environment.
Keep it private. The server refuses to listen without it; new, list, attach
and reconnect requests all authenticate before session operations. The
embedded Mix TUI generates a token automatically when none is configured.
Direct protocol clients send it as `token` on the first request; unsupported
protocol versions remain unsupported after authentication.

Elara's execution stub strips this token from ordinary child-command environments.

```bash
mix elara.server
```

Compile once before starting a multi-terminal server/worker setup. Concurrent
Mix commands safely skip reinstalling the exec-stub binary when its bytes are
unchanged. If you modify the Rust stub while a server or worker is running from
the same build, stop those processes before recompiling or give them separate
`MIX_BUILD_PATH` values. For diagnostic Elixir snippets, `--no-compile` belongs
after `mix run` or `mix eval`; it is not a global `mix` flag.

The server process owns provider configuration. For a ChatGPT/Codex subscription
login, start it with `ELARA_PROVIDER=openai-codex` in its environment; setting
that variable only on the TUI process does not change an existing server.

It listens only on `127.0.0.1:4048`. Use `--port PORT` to change the server
port. `mix elara.tui new` detects and uses this existing server instead of
starting an embedded one.

Create a server-owned session from another terminal:

```bash
mix elara.tui new
```

The status bar shows the stable session ID. Save it, then reconnect later with:

```bash
mix elara.tui SESSION_ID
```

The creating attachment's current directory becomes the new session's working
directory. Reattaching does not change it.

Ctrl-C clears the prompt; a second Ctrl-C in a row quits, as does `/detach`.
Against a long-lived server, quitting detaches without interrupting the current
turn or stopping the session. Against an embedded server the TUI asks for
confirmation first, because its live sessions end with it. `mix elara.tui` is
a Rust `ratatui` projection client for session protocol v2: every attachment
starts from an atomic materialized snapshot and then applies ordered patches.
The client stores each session's last sequence and incarnation in
`~/.elara/tui/cursors.json`. A sequence gap, malformed patch, or incarnation
change causes exactly one fresh snapshot request while resynchronization is
pending; the client never reconstructs current state from an incomplete event
history. The server process must remain running; this is client detachability,
not recovery after the server VM exits.

Inside the TUI, type a prompt and press Enter. Esc interrupts the active turn
once any open tool viewer or search is closed; `/interrupt` does the same.
Assistant messages and streaming content render as terminal Markdown; user
prompts and tool output remain literal. List this directory's saved and live
sessions without attaching:

```bash
mix elara.tui list
```

Only one controlling attachment can ask or interrupt. Additional read-only
clients can observe the event stream:

```bash
mix elara.tui SESSION_ID --observe
```

The TUI has its own session commands, including `/sessions` (Ctrl-O), `/new`,
`/name`, `/tree`, `/fork`, `/clone` and `/reload` (which refreshes the
snapshot; plugins reload with `/plugins reload`); each sends a protocol command
that the Elixir session carries out. `/resume` belongs to
`mix elara.chat`.

Port configuration:

```bash
mix elara.server --port 14048
mix elara.tui new --port 14048

# The TUI also reads this when --port is absent:
export ELARA_SERVER_PORT=14048
```

For deterministic diagnostics without taking over a terminal, `--headless`
renders the current state with ratatui's off-screen `TestBackend` and exits once
an optional `--ask` turn ends. `--event-dump` writes every received JSON frame
with its arrival latency:

```bash
mix elara.tui SESSION_ID --headless --event-dump --ask "check the build"
```

Run `mix elara.tui` directly when its exit status is part of the check. Wrapping
the task in `mix eval` can hide the nested task's nonzero exit status.

### Session protocol

The loopback TCP protocol uses newline-delimited JSON with a 16 MiB maximum
message size. Before authentication the first frame is limited to 16 KiB and
must arrive within 30 seconds; the 16 MiB limit applies only after the token
is accepted. Every request includes `version`. The server supports only
session protocol version 2; v1 (cursor replay of retained events) was retired in
LAB-2 and is rejected as `unsupported_version`.

- **v2:** The `attached` response contains `session_id`, `incarnation`, `head`,
  `mode` and `snapshot`, and never replays events. A client may still send
  `cursor` and `incarnation`; the server checks the cursor's shape and ignores
  both. The snapshot contains session identity, the complete encoded message
  history, tool calls with `pending`, `running`, `succeeded`, `failed`, or
  `indeterminate` status and outcome, current turn state, session usage totals
  from the provider view, and in-progress content-delta state. Subsequent
  `patch` messages carry the session incarnation, sequence, and an ordered
  `ops` array.

V2 has a closed patch operation set: `append_message`, `set_tool_status`,
`set_turn_state`, `set_usage`, and `append_content_delta`, which carries
streamed text. Negotiated extensions add `set_runtime_limits`
(`runtime_limits_v1`), `set_provider_view` (`provider_visibility_v1`) and
`set_inbox` (`input_queue_v1`); the server strips them, and the matching
snapshot fields, for clients that did not negotiate the extension. Clients
apply these operations to their last snapshot in sequence order. They ignore
already-applied sequences. On a gap, malformed patch, or incarnation change,
they send exactly one `{"version":2,"command":"resnapshot"}` while a snapshot
is pending. The server replies with a fresh `snapshot` message and atomic
`head`; queued patches at or below that head are stale and safe to ignore.

The operation payloads are:

```text
{"op":"append_message","index":N,"message":MESSAGE}
{"op":"set_tool_status","id":ID,"status":STATUS,"outcome":OUTCOME_OR_NULL}
{"op":"set_turn_state","turn":TURN}
{"op":"set_usage","usage":USAGE_OR_NULL}
{"op":"append_content_delta","message_id":ID,"text":TEXT}
```

`append_message` is idempotent at its zero-based `index`: an exact message
already present there is unchanged, the next index appends, and a gap or
different existing message is invalid. This lets every sequence fully reconcile
its atomic Core transition without duplicating messages. `set_tool_status`
updates the matching snapshot `tool_calls` entry. The Elixir line client used
during protocol bring-up consumed optional rendering hints on operations; the
Rust projection client does not need them to build state.

The initial request is `create`, `attach`, or the read-only `list`. After
attachment the core commands are `ask`, `interrupt`, `inspect` and
`resnapshot`; session lifecycle (`session_*`, `child_*`, `thread_parent`,
`job_*`), `read_only`, `workspace_diff`, `workspace_undo` and the negotiated
extensions add more. `lib/elara/server.ex` holds the full set.
Only a controlling attachment may mutate session state; observers receive the
same events or patches but control commands fail with `not_controller`.

## Remote workers

A worker maps a logical workspace ID to a directory and exposes selected
capabilities. Start one with a shared token:

```bash
ELARA_WORKER_TOKEN='replace-me' \
  mix elara.worker project-a \
  --cwd /workspace/project-a \
  --port 4049
```

The default capabilities are `filesystem:read`, `filesystem:write`, and `shell`.
Repeat `--capability CAPABILITY` to advertise a smaller set.

Workers bind to loopback by default. `--public` binds to all interfaces and
sends the shared token over a plain authenticated TCP protocol, not TLS. Use it
only on a protected network or inside a secure tunnel.

Register the endpoint in the VM that owns the session, then mark tools for
remote placement:

```elixir
:ok = Elara.register_worker(
  id: "sandbox-1",
  executor:
    {Elara.Executor.Remote,
     %{host: {127, 0, 0, 1}, port: 4049, token: "replace-me"}},
  capabilities: ["filesystem:read", "filesystem:write", "shell"],
  workspaces: ["project-a"]
)

remote_tools =
  Enum.map(Elara.Tool.builtins(), &%{&1 | placement: :remote})

{:ok, session} =
  Elara.start_session(
    cwd: "/absolute/path/on/the-brain-node",
    workspace_id: "project-a",
    tools: remote_tools
  )
```

The worker uses its own mapping for `project-a`; it does not receive or assume
the brain node's `cwd`. `mix elara.worker --cwd` configures that worker mapping
only. The `--cwd DIR` option of `mix elara.ask` and `mix elara.chat` is
separate: it selects the session's local workspace.

Inspect registered executors with `Elara.workers/0`. A session can restrict tool
permissions before routing with `allowed_capabilities:`:

```elixir
Elara.start_session(allowed_capabilities: ["filesystem:read"])
```

Read-only transport failures may retry another matching healthy worker. Mutating
tools are never blindly retried after transport loss because the side effect may
already have happened; Elara reports an `:indeterminate` tool result instead.

A worker also returns `indeterminate` itself when a mutating tool crashes, hits
its deadline, or has its command killed (timeout, cancellation or output cap)
while running. Non-mutating tools report those cases as errors. Workers and
clients reassemble protocol lines up to 16 MiB, so large results round-trip. The
worker protocol stays at version 2. An older client receives an `indeterminate`
result as an invalid response, which its router already reports as
`indeterminate` for mutating tools.

## Security boundary

Worker capability and workspace checks are enforcement layers, but they are not
an OS sandbox. Remote `read`, `write`, and `edit` reject absolute paths,
traversal, and symlink escapes. Concurrent path replacement and pre-existing
hard links can still defeat path-only checks. `bash` intentionally has all OS
access of the worker process.

Run workers handling untrusted or concurrently mutable content inside a
container or sandbox whose filesystem and network expose only what the worker
should use. This is always necessary for a worker with the `shell` capability.
