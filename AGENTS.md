# AGENTS.md

## Review workflow

When running inside Herdr beside another coding agent, the builder (left pane)
loads the `driver` skill and the reviewer (right pane) loads the `oracle` skill.
Every step gets an oracle plan review and diff review before it is committed.
Each session covers one agreed chunk of work and ends with a reviewed
`HANDOFF.md` at the repository root, from which both agents restart fresh.

## Cursor Cloud specific instructions

Elara is a single Mix app (an Elixir coding-agent CLI) that is primarily a BEAM
harness research lab; daily use is secondary. Standard commands live in
`README.md` (the "Develop" section) and `mix.exs`; the notes below only cover
things that are non-obvious in the Cloud environment.

### Toolchain

- Elixir 1.20 / Erlang/OTP 29 are provided by the base environment (installed
  under `/opt/elixir` and `/opt/otp`, symlinked into `/usr/local/bin`). They are
  part of the VM snapshot, not the update script. The update script only
  refreshes project deps with `mix deps.get`.
- Hex/Rebar are already installed in `~/.mix`, so `mix deps.get` runs
  non-interactively.
- Rust 1.88 or newer is required for both native crates. `rustfmt` and Clippy
  are required for development checks; `.agents/setup` installs a pinned Rust
  toolchain with both components in cloud environments.

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
- Test-only `config/runtime.exs` clears `ELARA_*` and `XAI_API_KEY` and points
  state and user skill discovery at per-run temporary directories before the app
  starts, so the developer's shell and skills cannot change results. Tests that need skills pass `home:` or `skill_paths:` explicitly.
- The real agent (`mix elara.ask` / `mix elara.chat` / `mix elara.tui`) needs
  provider credentials. `ELARA_PROVIDER=openai-codex` after
  `mix elara.login openai` uses a ChatGPT/Codex subscription; otherwise
  `ELARA_API_KEY` or `XAI_API_KEY`, or `mix elara.login` for Grok (tokens land
  in `~/.elara/`). Without credentials these commands fail at the network call.
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
- Work follows its research questions (RQ-n) and lab queue (LAB-n). Start each
  experiment from a refutable hypothesis, prefer seeded runs against simulated
  or scripted providers, and keep real-model runs opt-in and capped.
- Write one page per experiment in `docs/lab/`; raw results go under
  `lab/results/`, not `docs/`. Build reusable lab infrastructure rather than
  single-use drivers.
