# Harness

A Pi-like Elixir coding agent on OTP 29 / Elixir 1.20. One Mix app, one dependency (`req`).

```bash
mix harness.login
mix harness.ask "what files are in this repo?"
```

Or BYOK / tests:

```bash
export HARNESS_API_KEY=...          # or XAI_API_KEY
export HARNESS_MODEL=grok-4         # optional with resolve(); required for Config.from_env/1
export HARNESS_BASE_URL=https://api.x.ai/v1
mix harness.ask "summarize mix.exs"
```

## Library

```elixir
{:ok, session} = Harness.start_session()
{:ok, answer} = Harness.ask(session, "what files are in this repo?")
```

Built-in tools: `read`, `write`, `edit`, `bash`. Session core is a pure `step/2` state machine; the GenServer shell only turns mailbox messages into facts and runs effects.
