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
```

`mix harness.ask` prints one turn and exits. A failed turn exits with status 1.

`mix harness.chat` keeps one session. Optional first prompt:

```bash
mix harness.chat "what starts the application?"
```

Your line becomes a `you` block. Tool calls print as dim metadata. The answer sits on the page. Type the next prompt at `> `.

| Input | Idle | Mid-turn |
| --- | --- | --- |
| text | starts a turn | refused. use `/interrupt` |
| `/interrupt` or `/stop` | ignored | cancel the turn |
| `/quit`, `/exit`, `/q`, or Ctrl-D | exit 0 | interrupt, then exit. a second `/quit` exits immediately |
| `/help`, `/h`, `/?` | print commands | print commands |
| `//text` | send `/text` as a prompt | refused |

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

`Harness.interrupt/1` cancels the current turn. A second `ask` while a turn is running returns `{:error, :busy}`. History lives in the session process. It is gone when that process dies.

`start_session/1` accepts `provider:`, `cwd:`, `tools:`, `system:`, `max_iterations:`, `max_tool_output_bytes:`, and `tool_timeout_ms:`. Omit `provider` to use `Harness.Config.resolve/0` (env key or saved login).

## Develop

```bash
mix test
mix format
```

Tests do not call the network. They use `Harness.Provider.Scripted`.
