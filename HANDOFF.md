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
The usage-anchored context meter, handoff recovery, delivery routing, and
independent copies are documented in README.md's "Automatic context handoff"
section. The runtime catalog supplies model windows through
`Elara.Provider.Visibility.context_window/1`; the TUI meter uses
`snapshot.inbox.context`.
Command environment forwarding and `mix elara.env` diagnostics are documented
in README.md's "Command environment" section. Extra project names belong in
operator startup config, never an agent-editable project file.
Crash-safe reopening and legacy receipt escape paths are documented in
`docs/sessions.md` under "Recover an interrupted write". A different live VM
that owns the ledger must stop before takeover; callbacks are never replayed.
The TUI's shared code colors live in `native/elara-tui/src/syntax.rs`.
Colored Elixir and edit frames for all four themes live in
`native/elara-tui/tests/goldens/syntax-*.txt`.

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
