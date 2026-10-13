# Handoff — Phase 0, 2026-10-13

[Elara in Notion](https://app.notion.com/p/3f5700320c45817a9782f7e2e62bf2a1)
is the sole planning and status source. Read its page first: "You are here",
"This week" and "Decisions waiting for Robert" are kept current. Tasks live in
Dev Hub's Tasks database with Project set to Elara.

## Where Elara stands

On 12–13 Oct 2026 Robert reoriented the project in an interview recorded as
decisions D1 to D14 in the Notion Decision Log:

- Elara is Robert's own daily-driver coding agent, and nothing else is
  promised (D2). It is a coding agent, not a language (D1).
- Two bets: **uniforms**, a harness fitted to the language, framework and
  project (D4), and **surgical context**, results kept in BEAM processes the
  model queries instead of compacting a full window (D13). The first uniform
  is Elixir (D5).
- Three ways of working: one session, a lead with helpers, and many sessions
  (D6). Pace is all-in (D9).
- Today's code is simplified toward the daily driver: the lab moves into its
  own project, honest "unknown" results stay, recording gets cheap (D7).
- Robert decides direction and anything he would notice as a user; agents
  decide the rest, including merges (D8). Paid model APIs are capped at
  US$100 a month (D14).
- Linear is retired; its history is in `docs/archive/linear/` (D11).

## Now: Phase 0, Reset

Done means: main green with one script that runs every check; the lab in its
own Mix project with its recovery check passing; Linear exported and closed;
the repo pointing to Notion; the Phase 1 spec written. The Notion Roadmap's
Phase 0 page lists each task and its state.

## Rules that matter

Follow `AGENTS.md` and the Notion Working Agreement. Ask Robert one question
at a time, with options and a recommendation, and send nothing else while a
question waits. One task, one branch, one pull request; run the checks before
pushing; a reviewer agent checks every pull request before an agent merges it.
Never force-push, delete evidence, deploy or release without Robert.
