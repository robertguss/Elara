# AGENTS.md

## Delivery and tracking

[Elara in Linear](https://linear.app/robert-guss/project/elara-7ee4b27c1215)
is the sole current planning and status source. The active agent owns issue
review, planning, implementation, verification, commits, and delivery in the
current session. No separate driver, builder, or oracle workflow is required.

Ready means explicitly authorized, not merely unblocked. The owner has granted
the active agent autonomy over queue order and selection: the agent may select the
next item and release it to Ready, recording the decision in an issue
comment. Keep at most one executable lab item, and none while
paused. Each issue is delivered on an issue branch `work/rob-<n>-<slug>`,
pushed, PR'd, and merged after review and passing required checks under the
owner's standing authorization. Done means
merged. Do not force-push, deploy, release, or delete evidence without a
specific owner decision. At each chunk end, the active agent rewrites
`HANDOFF.md` for the next session, pointing at Linear for queue, status, and review
evidence. Repository tests only check the durable pointers.

## Cursor Cloud specific instructions

Elara is a single Mix app (an Elixir coding-agent CLI) balancing BEAM harness
research with daily-use improvements. Standard commands live in
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

- Track scope, dependencies, decisions, Results, and status in Linear. After
  authorized evidence commits are reviewed and pushed, link them and update
  the issue before starting its successor. Mark Done only after merge.
- Work follows Linear's research questions (RQ-n) and lab queue (LAB-n). Start each
  experiment from a refutable hypothesis, prefer seeded runs against simulated
  or scripted providers, and keep real-model runs opt-in and capped.
- Write one page per experiment in `docs/lab/`; raw results go under
  `lab/results/`, not `docs/`. Build reusable lab infrastructure rather than
  single-use drivers.
