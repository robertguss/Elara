# Handoff — Phase 1, 2026-10-13

[Elara in Notion](https://app.notion.com/p/3f5700320c45817a9782f7e2e62bf2a1)
is the sole planning and status source. Read its page first: "You are here",
"This week" and "Decisions waiting for Robert" are kept current. Tasks live in
Dev Hub's Tasks database with Project set to Elara.

Phase 1 runs in three streams under the lead (D20). Read the
[Phase 1 plan](https://app.notion.com/p/3f8700320c45817e807fc65b894b9013)
and [Working Agreement](https://app.notion.com/p/3f8700320c4581818358c50f271e494f)
before continuing. Stream task order and current delivery status live there,
not in this handoff. The runtime stream starts with the stable daily build;
its launch and update commands are documented in README.md.
The development gate's file-descriptor requirement is documented under
"Develop": `bin/check` raises its soft limit to at least 4096, prints it and
refuses an insufficient hard limit. The daily launcher is unchanged.
The usage-anchored context meter, handoff recovery, delivery routing, and
independent copies are documented in README.md's "Automatic context handoff"
section. The runtime catalog supplies model windows through
`Elara.Provider.Visibility.context_window/1`; the TUI meter uses
`snapshot.inbox.context`.
That section also documents oldest-first tool-result clearing, configurable
recent-output protection, retained originals and independent copies of cleared
sessions. Clearing entries and freed bytes are Core facts in flight recordings.
Provider token counters, actual response models and immutable billing receipts
are documented in README.md's "Provider usage and estimated cost" section.
The authoritative cost summary is `snapshot.provider_view.usage.cost`.
Subscription usage has no API estimate; unknown prices remain unknown, and
partial sums are marked incomplete. Original C3 history remains billing evidence.
The TUI footer renders those totals and `inbox.context` through
`presentation::usage_footer`, without repricing or recounting history.
Wide and narrow priced, partial, subscription and unknown footer goldens live
in `native/elara-tui/tests/goldens/usage-*.txt`.
README.md's model-controls section documents the account-scoped live catalog,
offline cache, documented Grok windows and typed unverified model IDs.
`snapshot.provider_view.catalog` and its source/error fields are authoritative;
Core records catalog changes so window decisions replay without network IO.
Saved settings from another provider use startup defaults with a visible notice.
Command environment forwarding and `mix elara.env` diagnostics are documented
in README.md's "Command environment" section. Extra project names belong in
operator startup config, never an agent-editable project file.
`native/exec-stub/src/main.rs` buffers each guardian's incomplete event before
forwarding complete frames. `test/elara/exec_integration_test.exs` checks exact
per-command heads and tails across concurrent large outputs.
The worker-death proof in `test/elara/executor_test.exs` waits for the actual
side effect before killing the worker; `tool_started` alone does not prove it.
Crash-safe reopening and legacy receipt escape paths are documented in
`docs/sessions.md` under "Recover an interrupted write". A different live VM
that owns the ledger must stop before takeover; callbacks are never replayed.
Revalidation refusals before any callback attempt now durably fail the receipt
with zero attempts, leaving the next turn usable. Ledger schemas 1–3 migrate
to schema 4 without losing receipt or ownership evidence.
The TUI's shared code colors live in `native/elara-tui/src/syntax.rs`.
Colored Elixir and edit frames for all four themes live in
`native/elara-tui/tests/goldens/syntax-*.txt`.
The confirmed TUI controls and clipboard fallback are documented in README.md's
TUI section. `native/elara-tui/src/actions.rs` owns action bindings and help;
Esc closes panels or interrupts, and consecutive Ctrl-C requests a safe quit.
README.md's "Custom keys" documents local `keymap.json`, action names,
collision fallback and fixed panel/editor controls. The per-Model keymap drives
both lookup and effective hints. New actions need an exhaustive `Action::name`
case and registration; slash-only registration does not assign a default key.
Turn and session workspace diffs are documented in that section. The shell's
private checkpoints live in `Elara.WorkspaceDiff`; the Rust diff panel lives in
`native/elara-tui/src/workspace_diff.rs`. Snapshots include bash changes but
never alter the workspace index or HEAD. Missing baselines report unavailable.
Session reports read predecessor banks across handoffs, with imported objects
rooted under separate `refs/elara/chain/` refs. Missing evidence and unsealed
handoff attribution boundaries are labelled; predecessor undo remains excluded.
Confirmed turn undo is documented beside `/diff` in README.md. The shell owns
preflight, restore, and interrupted-attempt records in the same snapshot bank;
Rust owns only the confirmation panel in `workspace_undo.rs`. System notices
persist in history and provider context, and handoff indexes retain their
original entry references. Reopening records uncertainty without replaying
filesystem writes. Changed touched paths or gitlinks refuse the whole undo.
New coding worktrees are kept outside protected Elara state; the location and
operator override are documented under "Persistent delegated children".
Existing children keep their recorded paths, without relocation or deletion.
The child-lifecycle PTY proof in `test/support/threads_pty.py` waits for the
uniquely filtered child's row before inspecting or opening it; random IDs can
fuzzy-match short names, so selection is not inferred from stale terminal bytes.
File-tool roots, protected paths, and resolved symlinks are documented in
README.md's "File-tool fence" section. Internal skill/session/plugin reads are
separate; the fence is not an OS sandbox. Grep and glob share that policy:
explicit scopes are resolved and recursive filenames authorized before any
content search. README.md's "Workspace search" section describes their limits.
The TUI's `/read-only` changes model-tool mutation permission from the next call,
including mid-turn. Its authoritative footer mode, transcript transition positions,
copy/child/handoff inheritance and trusted plugin declarations are documented in
README.md and `docs/plugins.md`. It has no default shortcut under D22.
Command-text rules, exact-call `/approve`, exact-byte approval of repository
rule loosening, and the one-shot CLI refusal path are documented in README.md's
"Command rules and approval" section. They are not an OS sandbox.
The TUI's `/limits` and session-local overrides are documented in README.md's
execution section. They follow delivery ownership and reset to startup config
when a session restarts, including children and handoff successors.
Retained local command output and `output_read` are documented in that section.
`Elara.Output.capture/2` also accepts content chunks for fetch and MCP tools.
Transcript-owned vaults copy only referenced handles; source history authorizes
handoff inheritance. Remote retained-output transport remains Phase 5 work.
Personal and project MCP configs, exact-config and catalog approval, explicit
read-only marks, and the supervised client API are documented in README.md's
"Approve an MCP server" section. Model-facing tools are a separate integration.
The lab's current async-site inventory is pinned in
`lab/test/elara/lab_profile_test.exs`; its classifier distinguishes server
connections from session handoff relay tasks. Historical registrations stay
unchanged. Current lab fixtures use a 16K-token handoff window, trace
`Context.budget/3` and isolate coding worktrees beside their session state.
`docs/lab/README.md` describes recovery registration version 2 and reproduction
of historical versions. Delivery is tracked in
[Dev Hub](https://app.notion.com/p/3f8700320c4581a59c2cdf3a839a5ae0).
The [lead thread](https://ampcode.com/threads/T-01a1358b-4a9e-71b9-bed8-90de5e5b14ee)
coordinates stream dependencies and questions for Robert. Resume the assigned
stream from its Notion task status and merged code on `origin/main`; do not
repeat the planning or start replacement threads. Current progress and pending
decisions stay in Notion, not this file.

## Where Elara stands

On 12–13 Oct 2026 Robert reoriented the project in an interview recorded as
decisions D1 to D20 in the Notion Decision Log:

- Elara is Robert's own daily-driver coding agent, and nothing else is
  promised (D2). It is a coding agent, not a language (D1).
- Two bets, both still to build: **uniforms**, a harness fitted to the
  language, framework and project (D4, Phase 2), and **surgical context**,
  results kept in BEAM processes the model queries instead of compacting a full
  window (D13, Phase 3). The first uniform is Elixir (D5).
- Three ways of working: one session, a lead with helpers, and many sessions
  (D6). Pace is all-in (D9).
- Today's code is being simplified toward the daily driver: the lab moved out,
  honest "unknown" results stay, and recording is to get cheap (D7).
- Robert decides direction and anything he would notice as a user; agents
  decide the rest, including merges (D8). Paid model APIs are capped at
  US$100 a month (D14).

## Phase 0, Reset: done

- main is green, and `bin/check` runs every product check (not the lab) in
  about 3 minutes (pull requests #69 and #70).
- Linear is retired; its history is in `docs/archive/linear/` (#71, D11).
- The lab is its own Mix project in `lab/`; the product app no longer ships it
  (#72, D7). Root `mix test`: 684 tests and 11 properties. Lab:
  `cd lab && mix deps.get && mix test`, 390 tests and properties.
- A known flake: `test/elara/context_test.exs:213` can fail with
  `{:error, :locked}` under load (a Phase 1 task in Notion).

## Now: Phase 1, Usable every day

Robert does his real Elixir work in Elara with the generic kit. The spec is
the Phase 1 page of the Notion Roadmap. Its five design questions are decided:
near the context limit, an honest meter and clearing old tool results before
any handoff (D15); fence and scrub plus deny and ask lists, sandbox later
(D16); MCP behind two fixed tools (D17); a safeguarded fetch tool plus Exa
search (D18); Claude Code and pi style keys with a keymap file (D19). Phase 1
runs from a lead thread with three streams: the TUI and interaction; the
runtime and providers; context and safety (D20). Follow-ups found in Phase 0
are tasks in Notion.

## Rules that matter

Follow `AGENTS.md` and the Notion Working Agreement. Ask Robert one question
at a time, with options and a recommendation, and send nothing else while a
question waits. Robert starts new threads himself: give him copy-paste prompts
rather than creating threads, unless he says otherwise. One task, one branch,
one pull request; run `bin/check` before pushing; a reviewer agent checks every
pull request before an agent merges it. Never force-push, delete evidence,
deploy or release without Robert.
