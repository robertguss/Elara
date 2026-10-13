# AGENTS.md

## Delivery and tracking

[Elara in Notion](https://app.notion.com/p/3f5700320c45817a9782f7e2e62bf2a1)
is the sole current planning and status source: the Product Brief, the Roadmap
and its phases, the Working Agreement, the Decision Log and the Weekly Updates.
Tasks live in Dev Hub's Tasks database with Project set to Elara; experiments
are tasks of kind Spike. Linear is retired, and its history is archived in
`docs/archive/linear/`.

The active agent owns planning, implementation, verification, commits, and
delivery for the current phase in the current session, following the Notion
Working Agreement. Robert decides direction and anything he would notice as a
user; agents decide the rest. Ask Robert one question at a time, with real
options and one recommendation, and send nothing else while a question waits.
Record his answers in the Decision Log with his own words.

Deliver one task per branch (`work/<slug>`) and one pull request, kept small.
Run `bin/check` before every push. A reviewer agent checks every pull request;
an agent merges once the checks pass and the review approves. Done means
merged. Never force-push, deploy, release, or delete evidence without a
specific decision from Robert. New ideas go to the Notion Idea Parking Lot
with the phase where they belong, not into the current phase. At each chunk
end, the active agent updates the Notion Elara page and rewrites `HANDOFF.md`
for the next session. Repository tests only check the durable pointers.

## Cursor Cloud specific instructions

Elara is a single Mix app (an Elixir coding agent with a Rust TUI) built as
Robert's daily driver. Standard commands live in
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

- Every check before a push: `bin/check` (compile with warnings as errors, format,
  both Rust crates with strict Clippy, then `mix test`).
- Lint (check only): `mix format --check-formatted`. Auto-format: `mix format`.
- Test: `mix test`. Tests never touch the network — they use
  `Elara.Provider.Scripted`.
- Build: `mix compile`.
- Run the CLI: `mix elara.ask "..."`, `mix elara.chat`, `mix elara.login`.
- The research lab is a separate Mix project in `lab/` that neither `mix test`
  nor `bin/check` runs: `cd lab && mix deps.get && mix test` (see
  `docs/lab/README.md`).

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

- Track scope, decisions and status in Notion. Work follows the Roadmap's
  current phase; each phase's spec lists what is in and out of scope. Update the
  phase page and the task when a change merges.
- Experiments come in two tiers. Probes are quick, unregistered and labelled as
  anecdotes. Claims ("Elara does X better", "a uniform helps") are registered
  with a refutable hypothesis before they run, checked by someone other than
  the author, and kept when they fail. Real-model runs stay under the monthly
  cap for paid APIs (US$100, D14).
- Write one page per experiment in `docs/lab/`; raw results go under
  `lab/results/`, not `docs/`.
