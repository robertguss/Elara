# Harness

A coding agent for a local git checkout. Elixir 1.20, OTP 29, one Mix app, one dependency (`req`). It reads, writes, edits, and runs shell commands in the current working directory.

## Requirements

Install Elixir 1.20 and OTP 29. Clone this repo. From the repo root:

```bash
mix deps.get
```

The agent works on whatever directory you run Mix from. Put project rules in `AGENTS.md` in that directory if you want them in the system prompt.

## Log in with a Grok subscription

```bash
mix harness.login
```

Open the printed URL. Enter the printed code. Tokens land in `~/.harness/auth.json` (mode 600). If that file is missing and `~/.grok/auth.json` exists, harness imports it.

Then ask one question, or stay in a conversation:

```bash
mix harness.ask "what files are in this repo?"
mix harness.chat
mix harness.chat --continue
```

`mix harness.ask` prints one turn and exits. A failed turn exits with status 1.

`mix harness.chat` starts a new session. `mix harness.chat --continue` resumes the newest usable session for the current working directory. Both forms accept an optional first prompt:

```bash
mix harness.chat "what starts the application?"
mix harness.chat --continue "what did we establish?"
```

Your line becomes a `you` block. Tool calls print as dim metadata. The answer sits on the page. Type the next prompt at `> `.

| Input | Idle | Mid-turn |
| --- | --- | --- |
| text | Starts a turn | Refused. Use `/interrupt` |
| `/interrupt` or `/stop` | Ignored | Cancels the turn |
| `/resume` | Lists saved sessions for this working directory | Refused. Use `/interrupt` |
| `/resume N` | Resumes session N in the current chat | Refused. Use `/interrupt` |
| `/quit`, `/exit`, `/q`, or Ctrl-D | Exits with status 0 | Interrupts, then exits. A second `/quit` exits immediately |
| `/help`, `/h`, `/?` | Prints commands | Prints commands |
| `//text` | Sends `/text` as a prompt | Refused |

Session files live under `~/.harness/sessions/<cwd-key>/`. Continuation and in-chat resume are scoped to the current working directory.

Provider errors print and return you to `> `. They do not exit the chat.

## Use an API key instead

Skip login when you have a key. `HARNESS_API_KEY` wins over `XAI_API_KEY`. Both use the OpenAI-compatible chat API.

```bash
export HARNESS_API_KEY=...
# optional:
export HARNESS_MODEL=grok-4
export HARNESS_BASE_URL=https://api.x.ai/v1
mix harness.ask "summarize mix.exs"
```

`HARNESS_MODEL` defaults to `grok-4`. `XAI_MODEL` is an alias. `HARNESS_BASE_URL` defaults to `https://api.x.ai/v1`.

If login succeeds and chat still returns HTTP 403, the subscription cannot call the API. Set `XAI_API_KEY` or `HARNESS_API_KEY`. Logging in again does not fix that.

## Tools

Built-in tools are `read`, `write`, `edit`, and `bash`. `edit` replaces one exact `old_text` with `new_text`. A turn stops after 12 model iterations, 30 seconds per tool, or 16 KiB of tool output.

## Call it from Elixir

```elixir
{:ok, session} = Harness.start_session()
{:ok, answer} = Harness.ask(session, "what files are in this repo?")
```

`Harness.ask/2` blocks until the turn ends. For live events, subscribe and ask asynchronously:

```elixir
{:ok, session} = Harness.start_session()
:ok = Harness.subscribe(session)
:ok = Harness.ask_async(session, "list the public functions")

receive do
  {:harness, ^session, {:turn_ended, outcome}} -> outcome
end
```

`Harness.interrupt/1` cancels the current turn. A second `ask` while a turn is running returns `{:error, :busy}`. Chat persists session history after every message. `mix harness.ask` does not.

`start_session/1` accepts `provider:`, `cwd:`, `tools:`, `system:`, `max_iterations:`, `max_tool_output_bytes:`, `tool_timeout_ms:`, `persist:`, and `resume:`. `resume:` is `nil` (new session), `:latest` (newest usable file for `cwd`), or a session path. Omit `provider` to use `Harness.Config.resolve/0` (env key or saved login).

## Develop

```bash
mix test
mix format
```

Tests do not call the network. They use `Harness.Provider.Scripted`.
