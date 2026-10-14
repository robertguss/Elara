# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this is

Elara is a BEAM-native coding agent (Mix app `:elara`) that runs from source —
there is no installed `elara` executable; `bin/elara` is a source-backed
launcher that starts the TUI in the caller's directory. User-facing surfaces are
`mix elara.ask`, `mix elara.chat`, `mix elara.tui`, `mix elara.server`,
`mix elara.worker`, `mix elara.login`, the operator tasks `mix elara.trust`
(plugins), `mix elara.mcp`, `mix elara.env` and `mix elara.recordings`, the
daily build (`bin/elara-update`, then `elara-stable`), and the public `Elara`
Elixir API. There is no web UI.

Elara is **Robert's own daily-driver coding agent** (decision D2, 2026-10-13).
It is being built around two bets, neither implemented yet. **Uniforms**
(Roadmap Phase 2): the harness fits itself to the language, framework and
project it works in, with tools that return structured results, a feedback
loop, knowledge, guardrails and workflow, so the same model does measurably
better than in a generic harness (D4). **Surgical context** (Phase 3): tool
results stay in BEAM processes the model queries through handles, instead of
filling the window and compacting it (D13). The first uniform is Elixir (D5).
Research serves daily use; it is not a goal of its own.

[Elara in Notion](https://app.notion.com/p/3f5700320c45817a9782f7e2e62bf2a1)
is the sole current planning and status source: the Product Brief, the Roadmap
and its phases, the Working Agreement, the Decision Log, and tasks in Dev Hub's
Tasks database. `ROADMAP.md` is a durable pointer and `HANDOFF.md` a short
session handoff, not duplicate tracking documents; a PM thread keeps both and
the Notion status pages current (D27). Follow the delivery rules in `AGENTS.md`. The
active agent performs the work of the current phase in the current session;
`test/elara/roadmap_test.exs` checks repository pointers only, without network
access. Linear is retired; its history is archived in `docs/archive/linear/`.
Experiment notes live in `docs/lab/`, one page each; raw results go under
`lab/results/`, not `docs/`. `docs/harness-experiments.md` is the pre-pivot
experiment log. `AGENTS.md` holds environment notes; `MANUAL_TEST_CHECKLIST.md`
is a manual verification worksheet, not a status source.

## Toolchain

Elixir 1.20, Erlang/OTP 29, and Rust 1.98.1 with `cargo`, `rustfmt`, and
Clippy, pinned by `rust-toolchain.toml` (rustup fetches it; the crates declare a
1.88 minimum), plus the `flock` command (session locking), `rg` (the `grep` and
`glob` tools) and `python3` (PTY-driven TUI tests). Distro Rust 1.85 is too old
for the TUI dependencies. `.agents/setup` provisions Elixir, OTP and Rust in
cloud environments; `rg` and `python3` come from the base image.

## Commands

```bash
bin/check                       # product+lab compile and format, both Rust crates, mix test --warnings-as-errors, lab tests; run before pushing
mix deps.get
mix compile --warnings-as-errors
mix format                      # mix format --check-formatted to lint only
mix test
mix test test/elara/session_test.exs          # one file
mix test test/elara/session_test.exs:120      # one test by line

(cd native/exec-stub && cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings && cargo test --locked)
(cd native/elara-tui && cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings && cargo test --locked)
```

- `mix compile` always rebuilds `native/exec-stub` through the custom
  `:exec_stub` compiler in `mix.exs`. It fails if `cargo` is missing, and
  refuses to replace a stub binary that a running Elara process still holds
  (`:etxtbsy`) — stop long-lived sessions or use a separate `MIX_BUILD_PATH`.
- `native/elara-tui` is built lazily (always in release mode) on the first
  `mix elara.tui`, cached against a source digest (which includes the build
  recipe) in the app build's `priv/native/elara-tui.sha256`.
- `bin/check` raises the file-descriptor soft limit to at least 4096 and
  refuses an insufficient hard limit.
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
  excluded under `mix test --no-start`. The checkout's own `.agents/skills`
  (tooling for whoever develops Elara) is ignored in tests through
  `:ignored_skill_dirs`, so sessions whose cwd sits inside the checkout don't
  load it. Tests that need skills pass `home:` or `skill_paths:` explicitly.
  Reproduce order-dependent failures with `mix test --seed N`.
- `.cursor/skills/verify-elara/` is a user-path verification harness
  (`bin/launch`, `bin/doctor`, `bin/drive`, `bin/cleanup`) that runs Elara under
  an isolated `HOME` and a disposable git worktree. Use it — not `mix test` — to
  prove user-visible ask/chat/TUI/session behavior.
- The research lab (`Elara.Lab.*`, `mix elara.lab`, `Elara.Provider.Simulated`)
  is a separate Mix project in `lab/`; the product app does not ship it, and
  root `mix test` does not run its tests. `bin/check` compiles it with warnings
  as errors, checks its formatting, and runs its full test suite.
  It depends on `:elara` by path, reads the root `mix.lock`, and has test isolation in
  `lab/config/runtime.exs`. Run it from there:
  `cd lab && mix deps.get && mix test`, or `cd lab && mix elara.lab ...` (see
  `docs/lab/README.md`).

## Running the agent

Ask/chat use the Mix process's cwd by default and accept `--cwd DIR` to select
an existing workspace without changing the process directory. The Elixir API
accepts an absolute `cwd:`. To exercise the full loop without credentials:

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
`ELARA_TUI_STATE_DIR`, `ELARA_TUI_APPEARANCE_FILE`,
`ELARA_PROVIDER_RETRY_ATTEMPTS`, `ELARA_PROVIDER_RETRY_MAX_WAIT_MS`,
`ELARA_SERVER_TOKEN` (required by a long-lived server and its clients),
`ELARA_MAX_ITERATIONS`, `ELARA_TOOL_TIMEOUT_MS`, `ELARA_MAX_TOOL_TIMEOUT_MS`,
`ELARA_CONTEXT_KEEP_RESULTS`, `ELARA_CONTEXT_KEEP_TOKENS`,
`ELARA_COMMAND_RULES`, `ELARA_COMMAND_ENV`, `ELARA_FILE_ROOTS`,
`ELARA_WORKTREES_ROOT` (default `~/.elara-worktrees`), `ELARA_STABLE_DIR`
(daily build, default `~/.elara/daily`) and `XAI_MODEL`. README.md and
`docs/detached-and-remote.md` document each.

State lives under `~/.elara/`: `sessions/<cwd-key>/` (JSONL transcripts),
`sessions/_threads/` (delegated children), `sessions/_thread_messages/`
(transport receipts), `sessions/_effect_executors/` (durable ledgers), other
`sessions/_*` stores (test jobs, fnox, workspace snapshots, model catalogs),
`auth.json` / `openai-codex-auth.json` / `exa-auth.json`, `plugin-trust/` and
`mcp-trust/`, `tui/` and `tui-appearance.json`, and `daily/` (the stable build).
New coding worktrees live outside it, under `~/.elara-worktrees`. Tests redirect this via the
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
versioned JSON command/event protocol; the server sends a fresh client a
snapshot (`Elara.Protocol`) rather than only missed events.
`Elara.Protocol.Projector` is used only by tests.
`Elara.Server` is the local TCP gateway for detachable sessions; the Rust TUI
(`native/elara-tui`) is a pure projection over it. `mix elara.tui` starts an
_embedded_ server (dies with the command) when the port is free;
`mix elara.server` is the long-lived one.

**Provider retries (`lib/elara/provider/retry.ex`).** One policy for every
provider, because Core owns the only `{:call_provider, ...}` effect. `Retry` is
pure: it classifies a `Provider.Error` by kind and status and sizes a backoff
window; Core decides whether to replay and emits `{:await_retry, ...}`; the
shell picks the jittered wait inside that window and arms the timer. An attempt
that already streamed text or a typed part is never replayed — the error
surfaces, so nothing is duplicated. `Retry-After` is honored exactly, and
refused rather than shortened when it exceeds the remaining wait budget.
Retries re-dispatch one iteration and never consume `max_iterations`. Lab
scenarios that inject provider faults disable retries so their accounting keeps
its meaning.

**Execution.** `Elara.Exec` supervises the Rust execution stub
(`native/exec-stub`) over an Erlang Port; each command runs in its own process
group so cancel/timeout/byte-cap can SIGKILL the group. Stub loss reports
`indeterminate`, never success. `Elara.Executor` is the serializable
placement-independent request boundary; `Elara.Executor.Router` picks a local
or remote executor by capability, health, affinity, and load.

**Retained output (`lib/elara/output.ex`).** Local `bash` spools merged bytes
into a private transcript-owned vault before discarding its middle preview.
Capture and `output_read` return ordinary string outcomes, bounded to 16 KiB.
The 128 MiB object cap stops and reaps the command with a partial, indeterminate
result. Copies install only handles in copied tool evidence; handoff uses trusted
source history. No eviction or query language. `Ctx.output_owner` follows the
transcript ID when older in-place fork paths keep the actor's `session_id`.
Remote overrides retain the old unretained command path, not remote handles.

**Durable effects (`lib/elara/effect/`).** Frozen at PROD-1 scope:
receipt-backed local `write` only. A job is admitted once by
`{job_id, operation_digest}`; only an accepted job whose callback never started
may be continued; after a callback starts without durable terminal evidence the
result is `indeterminate`, never retried. Revalidation may durably fail an
accepted receipt with zero attempts: the refused callback never ran.
The executor ledger (SQLite via
`exqlite`, schema 4) has three terminal states, `completed | failed |
indeterminate`: a callback that returns uncertainty, crashes or returns an invalid
result is recorded as `indeterminate`. Callbacks run in linked workers with
one serial ledger writer. Worker DOWN while the writer survives records an
indeterminate terminal. R7 startup records an indeterminate terminal for orphaned
attempts only under exclusive writer and callback locks plus durable VM/writer/
callback identity proving that the old owners are dead. A different live VM
refuses takeover, naming its OS PID, node and start time: stop it first.
It never replays a callback. Schemas 1–3 migrate in place, retaining rows,
digests and incarnation evidence. Schemas 1 and 2 retain
`attempt_incarnation: nil` for legacy attempts.
Those attempts never auto-terminalize: the session stays idle, refuses a new
turn for missing proof, and permits `/clone` or `/fork` as a workaround. Live
timeout barriers remain until a durable terminal exists. Test terminal states
with `ExecutorLedger.is_terminal_state/1`, never a hand-written list.
The controller journal sits beside the session JSONL. The
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
`Context.budget/4` anchors on main-provider usage plus newer bytes ÷ 4 (each
image without reported usage adds 32,768 tokens) and
resolves the selected window through `Provider.Visibility.context_window/1`
before each request (independent of protocol/attachment limits). At 90%, the
session transfers delivery to a linked successor. Chains are bounded to eight.
The handoff index is extractive evidence pointing at originals, not a claim of complete
summarization.

**Prompt surface.** `Elara.Prompt` composes the system prompt from `AGENTS.md`
ancestry plus `Elara.Skills` metadata (Agent Skills format). Skills load
_metadata_ into context; bodies load selectively through the `skill` tool.
`Elara.Plugin` loads trusted local `.elara/plugins/*.{ex,exs}` tools with
generation/lease-based atomic reload. Project check evidence/diagnosis tools
belong to the project plugin, not the built-in roster. Session binds evidence
and provider updates to the current tool caller/incarnation; plugins may opt
read-only tools into immediate interruption with `cancel_on_interrupt: true`.

**Guardrails and integrations (Phase 1).** `Elara.Tools.FileFence` is the path
policy for `read`, `write`, `edit`, `grep` and `glob`: the workspace plus
operator `ELARA_FILE_ROOTS`, with protected paths refused. `Elara.CommandRules`
denies a bash call or holds it for exact-call `/approve`. `Elara.Fnox` resolves
approved fnox secrets per command and redacts them before output is retained.
`lib/elara/mcp/` supervises approved MCP servers behind `mcp_search` and
`mcp_call`. `Elara.WebFetch` and `Elara.WebSearch` keep pages behind output
handles with untrusted provenance. `Elara.WorkspaceDiff` keeps private
checkpoints for `/diff` and `/undo` without touching the index or HEAD. None of
these is an OS sandbox.

## Conventions that matter here

- Judge work by the current phase of the Notion Roadmap and by Robert's daily
  use. New ideas go to the Notion Idea Parking Lot with the phase where they
  belong; say so when a task starts drifting toward one.
- Experiments come in two tiers. Probes are quick, unregistered and labelled as
  anecdotes. Claims are registered with a refutable hypothesis before they run;
  a result against the hypothesis is a finding, so record it rather than tuning
  the experiment until it passes.
- Measure the harness on the bench: the same model on real tasks, with and
  without the change. Real-model runs stay under the paid-API cap (US$100 a
  month, D14) and are reported separately from scripted runs.
- Lab infrastructure establishes runtime properties, not user-visible behavior.
  Claims about what a user sees still need the public product path (the
  verify-elara harness).
- Keep write-ups proportional: one page per experiment in `docs/lab/`, and raw
  data out of `docs/`.
- Moduledocs are one-line statements of authority and boundary (e.g. "Mechanical
  shell around Core. Bookkeeping only."). Keep that register; state what a
  module does _not_ guarantee.
- Do not describe durable delivery, receipts, or worktrees as exactly-once
  external effects or as an OS sandbox — the docs are deliberately precise about
  this, and `write`/`edit`/`bash` are explicitly not sandboxed.
- One task, one branch, one pull request. Run `bin/check` before pushing; a
  reviewer agent approves before an agent merges; then update the Notion task
  row. The PM thread rolls task status into the Elara page and phase pages
  (D27). Done means merged; a pushed branch is not Done.

## Tracking

Notion: Dev Hub → Projects → Elara. Tasks: Dev Hub's Tasks database, Project = Elara.
