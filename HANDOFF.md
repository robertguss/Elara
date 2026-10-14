# Handoff — Phase 1, 2026-10-14

[Elara in Notion](https://app.notion.com/p/3f5700320c45817a9782f7e2e62bf2a1)
is the sole planning and status source. Read its page first: "You are here",
"Waiting on Robert" and "This week" are kept current. Tasks live in Dev Hub's
Tasks database with Project set to Elara.

The PM thread keeps this file, `ROADMAP.md` and the Notion status pages
current, and refreshes them daily (decisions D27 and D28). Lead and stream
threads keep their own Tasks rows current instead; they don't edit this file.

## Where Elara stands

Robert reoriented the project on 12–13 Oct 2026. The decisions are D1 to D14
in the Notion Decision Log:

- Elara is Robert's own daily-driver coding agent, and nothing else is
  promised (D2). It is a coding agent, not a language (D1).
- Two bets, both still to build: **uniforms**, a harness fitted to the
  language, framework and project (D4, Phase 2), and **surgical context**,
  results kept in BEAM processes the model queries instead of compacting a full
  window (D13, Phase 3). The first uniform is Elixir (D5).
- Three ways of working: one session, a lead with helpers, and many sessions
  (D6). Pace is all-in (D9).
- Robert decides direction and anything he would notice as a user; agents
  decide the rest, including merges (D8). Paid model APIs are capped at
  US$100 a month (D14).

## Phase 0, Reset: done on 13 Oct

main is green and `bin/check` gates every push (#69, #70). Linear is retired
and archived in `docs/archive/linear/` (#71). The lab is its own Mix project in
`lab/` (#72).

## Now: Phase 1, Usable every day

The spec, plan and status are on the
[Phase 1 page](https://app.notion.com/p/3f8700320c45817e807fc65b894b9013).
Its five design questions were decided on 13 Oct (D15 to D19). It runs from a
lead thread with three streams: TUI and interaction; runtime and providers;
context and safety (D20).

The build is done: 59 pull requests (#74 to #132) merged on 13 and 14 Oct.
What remains:

- Robert's acceptance week: five working days of real Elixir work in Elara,
  logged in the Notion Daily-use log.
- X1, context calibration, measured on that week's recorded sessions.
- Two test-stability fixes, then three consecutive full loaded `bin/check` runs
  passing on one main commit.

The [lead thread](https://ampcode.com/threads/T-01a1358b-4a9e-71b9-bed8-90de5e5b14ee)
coordinates stream dependencies and asks Robert's questions. Resume an
assigned stream from its Notion task and the merged code on `origin/main`; do
not repeat the planning or start replacement threads. When Phase 1 closes, the
lead gives Robert the prompt for the Phase 2 lead thread.

## Before you push

Follow `AGENTS.md`: one task, one `work/<slug>` branch, one pull request,
`bin/check`, then a reviewer agent. README.md's "Develop" section lists the
exact checks. `bin/check` raises the soft file-descriptor limit to at least
4096 and refuses an insufficient hard limit. It includes the lab's compile,
formatting and full test suite, and fails product tests on compilation
warnings. `rust-toolchain.toml` pins Rust 1.98.1 with rustfmt and Clippy;
rustup downloads it on the first Cargo command.

## Where Phase 1 behavior is documented

- Stable daily build (`bin/elara-update`, `elara-stable`): README.md,
  "Stable daily build".
- Provider retries, usage and estimated cost: README.md, "Transient provider
  failures" and "Provider usage and estimated cost". The authoritative cost
  summary is `snapshot.provider_view.usage.cost`.
- Model catalog and windows: README.md, "Rust TUI";
  `snapshot.provider_view.catalog` and
  `Elara.Provider.Visibility.context_window/1`.
- Context meter, handoff and clearing old tool results: README.md, "Automatic
  context handoff". The TUI meter reads `snapshot.inbox.context`.
- TUI server limits, external editor, suspend and reattach: README.md, "Rust
  TUI". A local "Reattaching…" notice does not claim control.
- Long-session redraw: `native/elara-tui/src/reconstruction.rs` owns one
  background layout worker and one replaceable pending snapshot. Old transcript
  rows stay visible until a matching replacement is ready; prompt and
  navigation state stay on the UI thread. Rows keep source ranges, and
  per-grapheme cells are built only for the viewport. Session snapshots reuse
  the inbox token estimate while keeping provider window and image-cost
  semantics separate. The lazy TUI builder always uses the release profile,
  including the daily build, and its cache digest includes the build recipe.
- Keys, the keymap file and help: README.md, "Custom keys";
  `native/elara-tui/src/actions.rs`.
- `/diff`, `/undo` and bounded checkpoints: README.md, "Rust TUI";
  `Elara.WorkspaceDiff`, `native/elara-tui/src/workspace_diff.rs` and
  `workspace_undo.rs`.
- `/read-only`: README.md, "Rust TUI"; `docs/plugins.md` for plugin
  declarations. `/limits`, retained output and `output_read`: README.md,
  "Workspace search" (the execution limits that follow it).
- Syntax colors: `native/elara-tui/src/syntax.rs`, with goldens in
  `native/elara-tui/tests/goldens/syntax-*.txt`.
- Footer usage and meter: `presentation::usage_footer`, with goldens in
  `native/elara-tui/tests/goldens/usage-*.txt`.
- Command environment and fnox secrets: README.md, "Command environment" and
  "Project secrets through fnox".
- File-tool fence, grep and glob: README.md, "File-tool fence" and "Workspace
  search".
- Command rules and `/approve`: README.md, "Command rules and approval".
- MCP servers, `mcp_search` and `mcp_call`: README.md, "Approve an MCP
  server".
- `web_fetch` and Exa search: README.md, "Fetch public pages" and "Search the
  web through Exa".
- Coding worktrees outside protected state: README.md, "Persistent delegated
  children".
- Append-only transcripts, recordings and recovering an interrupted write:
  `docs/sessions.md`.
- Lab registration, job recovery and X2: `docs/lab/README.md` and
  `docs/lab/x2-unknown-results.md`.

None of these guardrails is an OS sandbox.

## Test lifecycle lessons from Phase 1

Each of these fixed an intermittent failure. Keep the pattern when you add
similar tests:

- Wait for the actual side effect, not an intent event: the worker-death proof
  in `test/elara/executor_test.exs` waits for the side effect before killing the
  worker, and `test/elara/test_jobs_test.exs` waits for execution before
  expecting cancellation and for successor activation before reading its inbox.
- `test/support/tui_notifications_pty.py` gates counts on the rendered final
  outcome, not reply text or an early Idle. `test/support/threads_pty.py` waits
  for the uniquely filtered child row before selecting it.
- Teardown stops the session actors a test started before restoring global
  roots and deleting state; client detach alone does not settle a closing turn.
  Thread-communication fixtures stop the shared transport before changing the
  sessions root.
- Line-chat and input-queue fixtures own small Git workspaces instead of
  capturing the developer checkout.
- `test/elara/web_fetch_test.exs` gives the linked network worker its own
  startup budget before testing cancellation.
- `native/exec-stub/src/main.rs` buffers each guardian's incomplete event
  before forwarding complete frames; `test/elara/exec_integration_test.exs`
  checks per-command heads and tails across concurrent large outputs.
- The lab's async-site inventory is pinned in
  `lab/test/elara/lab_profile_test.exs`.
