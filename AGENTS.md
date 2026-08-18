# AGENTS.md

## Cursor Cloud specific instructions

Harness is a single Mix app (an Elixir coding-agent CLI). Standard commands live
in `README.md` (the "Develop" section) and `mix.exs`; the notes below only cover
things that are non-obvious in the Cloud environment.

### Toolchain

- Elixir 1.20 / Erlang/OTP 29 are provided by the base environment (installed
  under `/opt/elixir` and `/opt/otp`, symlinked into `/usr/local/bin`). They are
  part of the VM snapshot, not the update script. The update script only
  refreshes project deps with `mix deps.get`.
- Hex/Rebar are already installed in `~/.mix`, so `mix deps.get` runs
  non-interactively.

### Lint / test / build / run

- Lint (check only): `mix format --check-formatted`. Auto-format: `mix format`.
- Test: `mix test`. Tests never touch the network — they use
  `Harness.Provider.Scripted`.
- Build: `mix compile`.
- Run the CLI: `mix harness.ask "..."`, `mix harness.chat`, `mix harness.login`.

### Gotchas

- `mix test` intentionally logs a `[error] ... (RuntimeError) boom` line from a
  crash-recovery test (`Harness.SessionTest.CrashTool`). This is expected; the
  run still ends with all tests passing. Do not treat that log line as a
  failure.
- The real agent (`mix harness.ask` / `mix harness.chat`) needs xAI/Grok
  credentials: `HARNESS_API_KEY` (preferred) or `XAI_API_KEY`, or an interactive
  `mix harness.login` (tokens land in `~/.harness/auth.json`). Without
  credentials these commands fail at the network call.
- To exercise the full agent loop (session + read/write/edit/bash tools) without
  credentials, drive it with the scripted provider via the public API:
  `Harness.start_session(provider: {Harness.Provider.Scripted, agent_pid}, cwd: dir, persist: false)`,
  where `agent_pid` is an `Agent` holding a queue of canned
  `{:ok, %Harness.Message.Assistant{}}` turns. This is the same mechanism the
  test suite uses.
- Chat/ask session files persist under `~/.harness/sessions/<cwd-key>/`;
  `mix harness.chat --continue` resumes the newest session for the current
  working directory.
