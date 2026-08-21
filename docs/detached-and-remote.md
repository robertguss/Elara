# Detached sessions and remote workers

Harness has two separate runtime features for work that should not live entirely
inside one interactive client:

- A local server owns sessions while clients attach and detach.
- Authenticated workers execute selected tools in mapped workspaces.

## Detachable sessions

Start the server in one terminal:

```bash
mix harness.server
```

It listens only on `127.0.0.1:4048`. Use `--port PORT` to change the server
port.

Create a server-owned session from another terminal:

```bash
mix harness.attach new
```

The first line prints a stable session ID. Save it, then reconnect later with:

```bash
mix harness.attach SESSION_ID
```

The creating attachment's current directory becomes the new session's working
directory. Reattaching does not change it.

Disconnecting the attachment does not interrupt the current turn or stop the
session. The client stores its last event cursor under `~/.harness/attach/`, so
reattaching replays missed retained events instead of the whole stream. The
server process must remain running; this is client detachability, not recovery
after the server VM exits.

Only one controlling attachment can ask or interrupt. Additional read-only
clients can observe the event stream:

```bash
mix harness.attach SESSION_ID --observe
```

Controller commands are `/interrupt`, `/inspect`, `/quit`, and `/exit`.
`/inspect` prints session status as JSON. The richer persistent-chat commands
such as `/resume`, `/tree`, and `/reload` belong to `mix harness.chat`, not the
attachment client.

Port configuration:

```bash
mix harness.server --port 14048
mix harness.attach new --port 14048

# The attach client also reads this when --port is absent:
export HARNESS_SERVER_PORT=14048
```

## Remote workers

A worker maps a logical workspace ID to a directory and exposes selected
capabilities. Start one with a shared token:

```bash
HARNESS_WORKER_TOKEN='replace-me' \
  mix harness.worker project-a \
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
:ok = Harness.register_worker(
  id: "sandbox-1",
  executor:
    {Harness.Executor.Remote,
     %{host: {127, 0, 0, 1}, port: 4049, token: "replace-me"}},
  capabilities: ["filesystem:read", "filesystem:write", "shell"],
  workspaces: ["project-a"]
)

remote_tools =
  Enum.map(Harness.Tool.builtins(), &%{&1 | placement: :remote})

{:ok, session} =
  Harness.start_session(
    cwd: "/absolute/path/on/the-brain-node",
    workspace_id: "project-a",
    tools: remote_tools
  )
```

The worker uses its own mapping for `project-a`; it does not receive or assume
the brain node's `cwd`. `mix harness.worker --cwd` configures that worker
mapping only. It is not a `--cwd` option for `mix harness.ask` or
`mix harness.chat`.

Inspect registered executors with `Harness.workers/0`. A session can restrict
tool permissions before routing with `allowed_capabilities:`:

```elixir
Harness.start_session(allowed_capabilities: ["filesystem:read"])
```

Read-only transport failures may retry another matching healthy worker. Mutating
tools are never blindly retried after transport loss because the side effect may
already have happened; Harness reports an `:indeterminate` tool result instead.

## Security boundary

Worker capability and workspace checks are enforcement layers, but they are not
an OS sandbox. Remote `read`, `write`, and `edit` reject absolute paths,
traversal, and symlink escapes. Concurrent path replacement and pre-existing
hard links can still defeat path-only checks. `bash` intentionally has all OS
access of the worker process.

Run workers handling untrusted or concurrently mutable content inside a
container or sandbox whose filesystem and network expose only what the worker
should use. This is always necessary for a worker with the `shell` capability.
