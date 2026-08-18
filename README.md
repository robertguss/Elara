# Harness

A coding agent for a local git checkout. Elixir 1.20, OTP 29, one Mix app, one
dependency (`req`). It reads, writes, edits, and runs shell commands in the
current working directory.

## Requirements

Install Elixir 1.20, OTP 29, and the `flock` command. Clone this repo. From the
repo root:

```bash
mix deps.get
```

The agent works on whatever directory you run Mix from. Put project rules in
`AGENTS.md` in that directory if you want them in the system prompt.

## Log in with a Grok subscription

```bash
mix harness.login
```

Open the printed URL. Enter the printed code. Tokens land in
`~/.harness/auth.json` (mode 600). If that file is missing and
`~/.grok/auth.json` exists, harness imports it.

Then ask one question, or stay in a conversation:

```bash
mix harness.ask "what files are in this repo?"
mix harness.chat
mix harness.chat --continue
mix harness.chat --name "display name"
```

To keep sessions running independently of a terminal, start the local server in
one process and attach from another:

```bash
mix harness.server
mix harness.attach new
# later, or from another terminal:
mix harness.attach SESSION_ID
mix harness.attach SESSION_ID --observe
```

The server listens only on `127.0.0.1:4048` and uses a versioned JSON protocol.
Set `HARNESS_SERVER_PORT` or pass `--port`. The first controlling attachment may
ask and interrupt; additional observers are read-only. Event cursors are saved
under `~/.harness/attach/`, so reconnecting clients replay only missed events.
Disconnecting a client does not interrupt its session or current tool call.

`mix harness.ask` prints one turn and exits. A failed turn exits with status 1.

`mix harness.chat` starts a new session. `mix harness.chat --continue` resumes
the newest usable session for the current working directory. Both forms accept
an optional first prompt:

```bash
mix harness.chat "what starts the application?"
mix harness.chat --continue "what did we establish?"
```

Your line becomes a `you` block. Tool calls print as dim metadata. The answer
sits on the page. Type the next prompt at `> `.

| Input                             | Idle                                                                    | Mid-turn                                                   |
| --------------------------------- | ----------------------------------------------------------------------- | ---------------------------------------------------------- |
| text                              | Starts a turn                                                           | Refused. Use `/interrupt`                                  |
| `/interrupt` or `/stop`           | Ignored                                                                 | Cancels the turn                                           |
| `/reload`                         | Reloads local plugins                                                   | Refused. Use `/interrupt`                                  |
| `/resume`                         | Lists saved sessions for this working directory                         | Refused. Use `/interrupt`                                  |
| `/resume N`                       | Resumes session N in the current chat                                   | Refused. Use `/interrupt`                                  |
| `/tree`                           | Lists user turns in the current session                                 | Refused. Use `/interrupt`                                  |
| `/tree N`                         | Re-submits user turn N from its parent, creating an in-file branch      | Refused. Use `/interrupt`                                  |
| `/fork`                           | Lists user turns that can start a separate session                      | Refused. Use `/interrupt`                                  |
| `/fork N`                         | Copies the path before user turn N into a new session and re-submits it | Refused. Use `/interrupt`                                  |
| `/clone`                          | Copies the current path into a new session and switches to it           | Refused. Use `/interrupt`                                  |
| `/name TEXT`                      | Names the current session for `/resume`                                 | Refused. Use `/interrupt`                                  |
| `/quit`, `/exit`, `/q`, or Ctrl-D | Exits with status 0                                                     | Interrupts, then exits. A second `/quit` exits immediately |
| `/help`, `/h`, `/?`               | Prints commands                                                         | Prints commands                                            |
| `//text`                          | Sends `/text` as a prompt                                               | Refused                                                    |

Session files live under `~/.harness/sessions/<cwd-key>/`. Continuation, resume,
branching, and forks are scoped to the current working directory. `/tree` keeps
abandoned branches in the same JSONL file; `/fork` and `/clone` create another
file.

Provider errors print and return you to `> `. They do not exit the chat.

## Use an API key instead

Skip login when you have a key. `HARNESS_API_KEY` wins over `XAI_API_KEY`. Both
use the OpenAI-compatible chat API.

```bash
export HARNESS_API_KEY=...
# optional:
export HARNESS_MODEL=grok-4
export HARNESS_BASE_URL=https://api.x.ai/v1
mix harness.ask "summarize mix.exs"
```

`HARNESS_MODEL` defaults to `grok-4`. `XAI_MODEL` is an alias.
`HARNESS_BASE_URL` defaults to `https://api.x.ai/v1`.

If login succeeds and chat still returns HTTP 403, the subscription cannot call
the API. Set `XAI_API_KEY` or `HARNESS_API_KEY`. Logging in again does not fix
that.

## Tools

Built-in tools are `read`, `write`, `edit`, and `bash`. `edit` replaces one
exact `old_text` with `new_text`. A turn stops after 12 model iterations, 30
seconds per tool, or 16 KiB of tool output.

Tool execution goes through `Harness.Executor.Router`. Tools declare required
capabilities, placement (`:local`, `:remote`, or `:any`), a version, and whether
they may mutate state. Sessions can restrict permissions with
`allowed_capabilities:` and identify remote workspaces with `workspace_id:`.

Run a capability-limited worker with a shared authentication token:

```bash
HARNESS_WORKER_TOKEN=secret mix harness.worker WORKSPACE_ID --cwd /workspace
```

Workers bind to loopback by default; `--public` binds all interfaces and should
only be used on a protected network. Register the endpoint on the brain node,
then mark selected tools for remote placement:

```elixir
:ok = Harness.register_worker(
  id: "sandbox-1",
  executor: {Harness.Executor.Remote, %{host: {127, 0, 0, 1}, port: 4049, token: "secret"}},
  capabilities: ["filesystem:read", "filesystem:write", "shell"],
  workspaces: ["WORKSPACE_ID"]
)

remote_tools = Enum.map(Harness.Tool.builtins(), &%{&1 | placement: :remote})
{:ok, session} = Harness.start_session(workspace_id: "WORKSPACE_ID", tools: remote_tools)
```

The wire request contains session/tool-call IDs, tool name/version and arguments,
workspace identity, deadline/cancellation identity, capabilities, and placement;
it never assumes the brain node's filesystem path. Reads can be retried on
another matching worker. Mutating calls are never blindly retried after a
transport loss: they produce an explicit `:indeterminate` tool result. Worker
disconnects cancel the worker-side job, while the session actor survives.

## Live plugins

Harness loads trusted local source plugins from `.harness/plugins/*.{ex,exs}`
when a session starts. Each file defines exactly one module implementing
`Harness.Plugin`:

```elixir
defmodule CounterPlugin do
  @behaviour Harness.Plugin

  alias Harness.Plugin.ToolSpec

  @impl true
  def metadata, do: %{id: "counter", version: "1"}

  @impl true
  def tools do
    [
      %ToolSpec{
        name: "counter",
        description: "Increment a session-local counter.",
        parameters: %{"type" => "object", "properties" => %{}}
      }
    ]
  end

  @impl true
  def init(_ctx), do: {:ok, 0}

  @impl true
  def handle_tool("counter", _args, _ctx, count) do
    next = count + 1
    {{:ok, "count=#{next}"}, next}
  end
end
```

Edit the file and run `/reload`. A successful reload installs a new immutable,
content-addressed code revision while the existing plugin process keeps its
state. Reload is refused during a turn or while an interrupted plugin call is
still running. Syntax, contract, tool-name collision, or migration failures
leave the previous generation active.

When the state shape changes, the new revision can implement
`migrate(old_state, old_metadata)` and return `{:ok, new_state}`. Without that
callback, the state term is preserved as-is. Plugin state should not contain
functions or structs defined by the reloadable module, and migration should not
mutate external state.

Plugin files may not define nested modules. Within a plugin, use `__MODULE__`
rather than its source module's literal name for self-references. All plugins
are trusted code and have the same operating-system access as Harness.

`Harness.start_session/1` accepts `plugins: [path, ...]` to select explicit
files, or `plugins: []` to disable discovery. The equivalent runtime APIs are
`Harness.plugins(session)` and `Harness.reload_plugins(session)`.

See the [manual live-reload checklist](design/plugins/manual-live-reload-checklist.md)
for an end-to-end test with a live xAI session.

## Call it from Elixir

```elixir
{:ok, session_id} = Harness.start_session()
{:ok, answer} = Harness.ask(session_id, "what files are in this repo?")
```

`Harness.ask/2` blocks until the turn ends. For live events, subscribe and ask
asynchronously:

```elixir
{:ok, session_id} = Harness.start_session()
:ok = Harness.subscribe(session_id)
:ok = Harness.ask_async(session_id, "list the public functions")

receive do
  {:harness, ^session_id, {:turn_ended, outcome}} -> outcome
end
```

Session IDs are stable strings. Public APIs temporarily also accept a live PID
for compatibility; `Harness.session_pid/1` resolves an ID for code that must
monitor the underlying process. `Harness.status/1` exposes phase, current
effect, mailbox length, task/subscriber counts, and event replay depth.

`Harness.interrupt/1` cancels the current turn. A second `ask` while a turn is
running returns `{:error, :busy}`. Chat persists session history after every
message. `mix harness.ask` does not.

`start_session/1` accepts `provider:`, `cwd:`, `tools:`, `plugins:`, `system:`,
`max_iterations:`, `max_tool_output_bytes:`, `tool_timeout_ms:`, `persist:`,
`resume:`, and `name:`. `resume:` is `nil` (new session), `:latest` (newest
usable file for `cwd`), or a session path. Omit `provider` to use
`Harness.Config.resolve/0` (env key or saved login).

## Develop

```bash
mix test
mix format
```

Tests do not call the network. They use `Harness.Provider.Scripted`.

Session persistence is planned in `design/sessions/overview.md`. Build one slice
per session.
