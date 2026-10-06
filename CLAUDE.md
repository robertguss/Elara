# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this is

Elara is a BEAM-native coding agent (Mix app `:elara`) that runs from source —
there is no installed `elara` executable. User-facing surfaces are
`mix elara.ask`, `mix elara.chat`, `mix elara.tui`, `mix elara.server`,
`mix elara.worker`, `mix elara.login`, and the public `Elara` Elixir API. There
is no web UI.

Elara is primarily a **BEAM harness research lab**; daily use is secondary. Work
follows the research questions (RQ-n) and lab queue (LAB-n) in
[Elara in Linear](https://linear.app/robert-guss/project/elara-7ee4b27c1215).
Build product features only when an experiment needs them.

Linear is the sole current planning and status source. `ROADMAP.md` and
`HANDOFF.md` are durable pointers, not duplicate tracking documents. Follow
the delivery rules in `AGENTS.md`. The active agent performs the work in the
current session. Record continuation and review evidence in
Linear. Ready requires explicit selection; dependencies alone do not authorize
work. Allow no executable item while paused and at most one otherwise. The
active agent reviews queue discipline in Linear; `test/elara/roadmap_test.exs`
checks repository pointers only, without network access.
Experiment notes live in `docs/lab/`, one
page each; raw results go under `lab/results/`, not `docs/`.
`docs/harness-experiments.md` is the pre-pivot experiment log. `AGENTS.md` holds
environment notes; `MANUAL_TEST_CHECKLIST.md` is a manual verification
worksheet, not a status source.

## Toolchain

Elixir 1.20, Erlang/OTP 29, Rust 1.88+ with `cargo`, `rustfmt`, and Clippy, plus
the `flock` command (session locking) and `python3` (PTY-driven TUI tests).
Distro Rust 1.85 is too old for the TUI dependencies. `.agents/setup` provisions
this in cloud environments.

## Commands

```bash
mix deps.get
mix compile --warnings-as-errors
mix format                      # mix format --check-formatted to lint only
mix test
mix test test/elara/session_test.exs          # one file
mix test test/elara/session_test.exs:120      # one test by line

cd native/exec-stub  && cargo fmt --check && cargo clippy && cargo test
cd native/elara-tui  && cargo fmt --check && cargo clippy && cargo test
```

- `mix compile` always rebuilds `native/exec-stub` through the custom
  `:exec_stub` compiler in `mix.exs`. It fails if `cargo` is missing, and
  refuses to replace a stub binary that a running Elara process still holds
  (`:etxtbsy`) — stop long-lived sessions or use a separate `MIX_BUILD_PATH`.
- `native/elara-tui` is built lazily on the first `mix elara.tui`, cached
  against a source digest in `priv/native/elara-tui.sha256`.
- Rust TUI frame goldens live in `native/elara-tui/tests/goldens/`; regenerate
  with `ELARA_UPDATE_GOLDENS=1 cargo test`.
- Tests never hit the network — they drive `Elara.Provider.Scripted`. `mix test`
  intentionally logs `(RuntimeError) boom` from a crash-recovery test; that is
  not a failure.
- Test isolation happens before the app starts. `config/runtime.exs` (test env
  only) clears `ELARA_*` and `XAI_API_KEY`, points `TMPDIR`, `:sessions_root`
  and `:skills_home` into one per-run directory, and raises the top-level supervisor's `:max_restarts`
  (production keeps OTP's 3 in 5 seconds) because crash-recovery tests kill
  `Elara.TestJobs` and `Elara.Exec` on purpose. `test/elara/test_environment_test.exs`
  proves the launch clearing in a subprocess. Tests tagged `:requires_app` are
  excluded under `mix test --no-start`. Tests that need skills pass `home:` or
  `skill_paths:` explicitly. Reproduce order-dependent failures with
  `mix test --seed N`.
- `.cursor/skills/verify-elara/` is a user-path verification harness
  (`bin/launch`, `bin/doctor`, `bin/drive`, `bin/cleanup`) that runs Elara under
  an isolated `HOME` and a disposable git worktree. Use it — not `mix test` — to
  prove user-visible ask/chat/TUI/session behavior.

## Running the agent

The Mix tasks use the Mix process's cwd as the session working directory and
have **no `--cwd` flag**; only the Elixir API accepts an absolute `cwd:`. To
exercise the full loop without credentials:

```elixir
Elara.start_session(provider: {Elara.Provider.Scripted, agent_pid}, cwd: dir, persist: false)
```

where `agent_pid` is an `Agent` holding a queue of canned
`{:ok, %Elara.Message.Assistant{}}` turns — the same mechanism the suite uses.

Provider selection lives in `Elara.Config.resolve/1`:
`ELARA_PROVIDER=openai-codex|grok`, else `ELARA_API_KEY`, else `XAI_API_KEY`,
else saved Grok OAuth. Other env vars: `ELARA_MODEL`, `ELARA_BASE_URL`,
`ELARA_REASONING_EFFORT`, `ELARA_CODEX_AUTH_SOURCE`, `ELARA_SERVER_PORT`
(default 4048), `ELARA_WORKER_TOKEN`, `ELARA_SKILL_PATHS`,
`ELARA_TUI_STATE_DIR`, `ELARA_TUI_APPEARANCE_FILE`.

State lives under `~/.elara/`: `sessions/<cwd-key>/` (JSONL transcripts),
`sessions/_threads/` (delegated children), `sessions/_thread_messages/`
(transport receipts), `sessions/_effect_executors/` (durable ledgers),
`auth.json` / `openai-codex-auth.json`. Tests redirect this via the
`:elara, :sessions_root` app env (see `config/runtime.exs`).

## Architecture

The governing decision is `docs/rust-elixir-split.md`: **Elixir is the single
authority; Rust owns two edge programs across process boundaries.** No NIFs.
Rust may own view/editor state and local appearance preferences, never session
persistence or workspace mutation authority.

**Session core (`lib/elara/session/core.ex`)** is a pure state machine — no IO,
processes, clocks, or `make_ref`. Refs are a monotonic counter in state, so
every transition replays deterministically from facts. `lib/elara/session.ex` is
the GenServer _shell_ around it: bookkeeping only (tasks, timers, monitors,
subscribers, effect journal). Anything that must be replayable belongs in Core;
anything that touches the world belongs in the shell.

**Persistence and replay.** `Elara.Session.Store` writes private JSONL per
session tree with parent-linked entries, which is what makes `/resume`, `/tree`,
`/fork`, and `/clone` work. `Elara.FlightRecorder` writes versioned
deterministic recordings of the facts fed to Core and replays them offline to
detect divergence.

**Protocol and clients.** `Elara.Protocol` (v2, 16 MiB line limit) is the
versioned JSON command/event protocol; `Elara.Protocol.Projector` materializes a
snapshot so a fresh client gets state rather than only missed events.
`Elara.Server` is the local TCP gateway for detachable sessions; the Rust TUI
(`native/elara-tui`) is a pure projection over it. `mix elara.tui` starts an
_embedded_ server (dies with the command) when the port is free;
`mix elara.server` is the long-lived one.

**Execution.** `Elara.Exec` supervises the Rust execution stub
(`native/exec-stub`) over an Erlang Port; each command runs in its own process
group so cancel/timeout/byte-cap can SIGKILL the group. Stub loss reports
`indeterminate`, never success. `Elara.Executor` is the serializable
placement-independent request boundary; `Elara.Executor.Router` picks
local/plugin/remote by capability, health, affinity, and load.

**Durable effects (`lib/elara/effect/`).** Frozen at PROD-1 scope:
receipt-backed local `write` only. A job is admitted once by
`{job_id, operation_digest}`; only an accepted job whose callback never started
may be continued; after a callback starts without durable terminal evidence the
result is `indeterminate`, never retried. The executor ledger (SQLite via
`exqlite`, schema 2) has three terminal states, `completed | failed |
indeterminate`: a callback that returns uncertainty, crashes or returns an invalid
result is recorded as `indeterminate`. Callbacks run in linked workers with
one serial ledger writer. Worker DOWN while the writer survives records an
indeterminate terminal; writer/VM loss retains unresolved attempted receipts,
without a startup terminalization rule or callback replay. Test terminal states with
`ExecutorLedger.is_terminal_state/1`, never a hand-written list. Schema 1 ledgers
migrate in place. The controller journal sits beside the session JSONL. The
house rule is
**fail uncertain mutations closed** — workspace bytes may prove a postcondition
but never causal job completion.

**Threads (`lib/elara/threads.ex`, `threads/communication.ex`).** Sessions, not
the coordinator, own delegated children: managed git branch/worktree per child,
max 4 concurrent children per VM, delegation depth 3. `Threads.related?/2` is
the canonical authority for `thread_send`/`thread_read` — text and supplied
workspace paths never grant access, and sender identity comes from execution
context, never tool arguments. The Communication actor never calls a model.
Coordinator batch patterns, candidate judging and map/reduce were retired under
ROB-1095/LAB-6. Threads has no automatic judging or reduction contract.

**Handoff (`lib/elara/session/handoff.ex`, `session/context.ex`).**
`Context.budget/2` is a conservative pre-request byte estimate (independent of
the protocol/attachment limits); at a safe boundary the session freezes and
continues in a linked successor. Chains are bounded to eight. The handoff index
is extractive evidence pointing at originals, not a claim of complete
summarization.

**Prompt surface.** `Elara.Prompt` composes the system prompt from `AGENTS.md`
ancestry plus `Elara.Skills` metadata (Agent Skills format). Skills load
_metadata_ into context; bodies load selectively through the `skill` tool.
`Elara.Plugin` loads trusted local `.elara/plugins/*.exs` tools with
generation/lease-based atomic reload. Project check evidence/diagnosis tools
belong to the project plugin, not the built-in roster. Session binds evidence
and provider updates to the current tool caller/incarnation; plugins may opt
read-only tools into immediate interruption with `cancel_on_interrupt: true`.

## Conventions that matter here

- Start each experiment from a refutable hypothesis in Linear. A result
  against the hypothesis is a finding; record it rather than tuning the
  experiment until it passes.
- Prefer seeded, repeatable runs against simulated or scripted providers.
  Real-model runs are opt-in, capped, and reported separately. Many seeded runs
  beat one annotated anecdote.
- Lab infrastructure (simulated providers, fault injection, the seeded runner)
  is in scope when a queued experiment needs it. Build it once for reuse; do not
  write single-use drivers.
- Lab infrastructure establishes runtime properties, not user-visible behavior.
  Claims about what a user sees still need the public product path (the
  verify-elara harness).
- Keep write-ups proportional: one page per experiment in `docs/lab/`, issue
  Results of at most five lines, and raw data out of `docs/`.
- Moduledocs are one-line statements of authority and boundary (e.g. "Mechanical
  shell around Core. Bookkeeping only."). Keep that register; state what a
  module does _not_ guarantee.
- Do not describe durable delivery, receipts, or worktrees as exactly-once
  external effects or as an OS sandbox — the docs are deliberately precise about
  this, and `write`/`edit`/`bash` are explicitly not sandboxed.
- Under the applicable authorization, review, commit and push evidence, then
  link it and update the Linear issue before starting its successor. Done means
  merged; a pushed branch is not Done.

## Tracking

Linear: team ROB, project Elara
