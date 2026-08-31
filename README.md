# Elara

Elara is a BEAM-native coding-agent research platform for a local working
directory, intended to grow into a daily-use tool. It can inspect and edit
files, run shell commands, keep persistent conversations, load local tools, and
move tool execution to a separate worker. Its research focus is durable,
causally explainable work—not feature-for-feature parity with existing agents.

> [!WARNING] The built-in `write`, `edit`, and `bash` tools can change files and
> run any command available to the Elara process. Use Elara only in a checkout
> you are prepared to modify. Local tools are not sandboxed.

## Run from source

Elara currently runs from this Mix project; it does not install a standalone
`elara` executable. You need Elixir 1.20, Erlang/OTP 29, and the `flock`
command.

```bash
git clone https://github.com/robertguss/elixir-harness.git
cd elixir-harness
mix deps.get
```

The `mix elara.ask` and `mix elara.chat` commands use the Mix process's current
directory as the session working directory. With the commands above, that is the
Elara checkout itself. Those commands do not currently accept a `--cwd` option.
To target another directory, use the [Elixir API](docs/elixir-api.md) and pass
an absolute `cwd:`.

The working directory controls relative tool paths, shell commands, local plugin
discovery, session scope, and the optional `AGENTS.md` appended to the system
prompt.

## Authenticate

### Grok login

```bash
mix elara.login
```

Open the printed URL and enter the device code. Elara stores tokens in
`~/.elara/auth.json` with mode `0600` and refreshes them when needed. If that
file does not exist but `~/.grok/auth.json` does, Elara imports it.

If a successful login is followed by HTTP 403, the account is not entitled to
use the API. Logging in again will not fix it; use an API key instead.

### API key

`ELARA_API_KEY` takes precedence over `XAI_API_KEY`. Either selects the
OpenAI-compatible provider.

```bash
export ELARA_API_KEY='...'
# Optional; these are the defaults:
export ELARA_MODEL='grok-4'
export ELARA_BASE_URL='https://api.x.ai/v1'
```

`XAI_MODEL` is accepted when `ELARA_MODEL` is unset. Model and base URL
environment variables apply to API-key authentication; saved Grok login uses the
xAI endpoint and `grok-4`.

## Ask or chat

Run one turn and exit:

```bash
mix elara.ask "summarize this repository"
```

The command prints tool activity and the answer. It exits with status 1 on a
provider error, interruption, timeout waiting for the turn, or turn limit. This
one-shot command does not persist its session.

Start a persistent conversation:

```bash
mix elara.chat
mix elara.chat "what starts this application?"
mix elara.chat --name "runtime investigation"
mix elara.chat --continue
```

`--continue` resumes the newest usable session for the current working
directory. Provider errors end only the current turn and return to the prompt.

Common chat commands:

| Command                           | Result                                                          |
| --------------------------------- | --------------------------------------------------------------- |
| `/help`                           | Show all commands.                                              |
| `/interrupt` or `/stop`           | Cancel the active turn.                                         |
| `/resume` / `/resume N`           | List or resume a saved session for this working directory.      |
| `/tree` / `/tree N`               | List user turns or branch from one in the current session file. |
| `/fork` / `/fork N`               | List user turns or branch into a new session file.              |
| `/clone`                          | Copy the current history path into a new session.               |
| `/name TEXT`                      | Name the current session.                                       |
| `/reload`                         | Reload this session's local plugins.                            |
| `/why` / `/why N`                 | Explain the transition behind the latest event or event N.      |
| `/quit`, `/exit`, `/q`, or Ctrl-D | Exit; during a turn, interrupt first.                           |

Prefix a prompt with `//` to send text beginning with `/`. Commands that change
session state are refused during a turn; interrupt the turn first.

See [Sessions and chat](docs/sessions.md) for persistence, branching, and the
full command behavior.

## Built-in tools

- `read` reads a file.
- `write` writes a file and creates parent directories.
- `edit` replaces exactly one occurrence of `old_text` with `new_text`.
- `bash` runs a shell command with stdout and stderr merged.

Relative paths and shell commands use the session working directory. The local
file tools call `Path.expand/2`; absolute paths and `..` can therefore reach
outside that directory. Use a container or other OS sandbox when the model or
workspace is not trusted.

Each turn allows 12 model iterations by default. Each tool has a 30-second
timeout, and tool output is truncated to 16 KiB before it enters model history.

## More user guides

- [Sessions and chat](docs/sessions.md): resume, branch, clone, and inspect why
  an event occurred.
- [Live plugins](docs/plugins.md): add trusted, stateful local tools and reload
  them without restarting a session.
- [Detached sessions and remote workers](docs/detached-and-remote.md): keep a
  session alive after a client disconnects and execute tools elsewhere.
- [Elixir API](docs/elixir-api.md): target another directory, subscribe to
  events, configure sessions, replay recordings, and coordinate child sessions.
- [Elara roadmap](https://linear.app/robert-guss/project/elara-ff8cc023e770):
  the canonical implementation status, evidence gates, and future research
  horizons.
- [Elara vision](docs/elara-vision.md)
  ([HTML companion](docs/elara-vision.html)): explore a BEAM-native fabric for
  durable missions, workspace cells, evidence, causality, and SDLC automation.
- [Software production frontiers](docs/software-production-frontiers.md)
  ([HTML companion](docs/software-production-frontiers.html)): a compact
  research map for rethinking intent, code, review, CI, local development,
  production, and the wider agentic SDLC.
- [Living software](docs/living-software.md)
  ([HTML companion](docs/living-software.html)): software as a continuously
  adapting constitutional system, compiled into implementation and governed by
  evidence, authority, causality, and human judgment.
- [Experimental lab](docs/experiments/README.md): research methods, provenance,
  repeatable run records, measurement rules, and the
  [Mission Receipt experiment](docs/experiments/001-mission-receipt.md).

## Develop

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Tests use `Elara.Provider.Scripted` and do not call the network. One
crash-recovery test intentionally logs a `RuntimeError) boom` error; the final
test result determines whether the run passed.
