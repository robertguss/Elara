# AGENTS.md

## Cursor Cloud specific instructions

Elara is a single Mix app (an Elixir coding-agent CLI). Standard commands live
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
  `Elara.Provider.Scripted`.
- Build: `mix compile`.
- Run the CLI: `mix elara.ask "..."`, `mix elara.chat`, `mix elara.login`.

### Gotchas

- `mix test` intentionally logs a `[error] ... (RuntimeError) boom` line from a
  crash-recovery test (`Elara.SessionTest.CrashTool`). This is expected; the run
  still ends with all tests passing. Do not treat that log line as a failure.
- The real agent (`mix elara.ask` / `mix elara.chat`) needs xAI/Grok
  credentials: `ELARA_API_KEY` (preferred) or `XAI_API_KEY`, or an interactive
  `mix elara.login` (tokens land in `~/.elara/auth.json`). Without credentials
  these commands fail at the network call.
- To exercise the full agent loop (session + read/write/edit/bash tools) without
  credentials, drive it with the scripted provider via the public API:
  `Elara.start_session(provider: {Elara.Provider.Scripted, agent_pid}, cwd: dir, persist: false)`,
  where `agent_pid` is an `Agent` holding a queue of canned
  `{:ok, %Elara.Message.Assistant{}}` turns. This is the same mechanism the test
  suite uses.
- Chat session files persist under `~/.elara/sessions/<cwd-key>/`;
  `mix elara.chat --continue` resumes the newest session for the current working
  directory.

### Roadmap and status

- `ROADMAP.md` is the sole current roadmap and status source. Update its queue
  and item Result in the same commit that changes an item's status.
