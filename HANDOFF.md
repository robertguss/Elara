# Handoff — driver chunk ending 2026-10-03

Linear is the queue and status source: the
[Elara project](https://linear.app/robert-guss/project/elara-7ee4b27c1215) and
its
[current handoff](https://linear.app/robert-guss/document/current-handoff-lab-3-attribution-and-continuation-569eb39fa4cd)
document. Record continuation state, blockers, review evidence, and delivery
there. This file is the driver's chunk-end handoff for the fresh driver and
oracle. It points at Linear rather than restating it. The complete pre-migration
handoff is preserved in the
[import snapshot](https://github.com/robertguss/Elara/blob/03b257159f987e0baf4de9b57f71af156721a5d0/HANDOFF.md);
its host observations are historical.

## 1. State

Observed 2026-10-03 on the owner's M3 Max (macOS, AC power), checkout
`/Users/robertguss/Projects/startups/Elara`. Branch `main`, clean, equal to
`origin/main`. Reviewed through `ee3296e`; pushed through `ee3296e`. No `work/`
branches remain on origin. Re-check HEAD, the working tree and the remote before
acting.

## 2. Queue

Linear: team ROB, project Elara. The live queue, parked questions and gates
are in the top entry of the Linear
[current handoff](https://linear.app/robert-guss/document/current-handoff-lab-3-attribution-and-continuation-569eb39fa4cd)
(2026-10-03). In short: nothing is executable,
[ROB-1083](https://linear.app/robert-guss/issue/ROB-1083) waits on the owner,
and [ROB-1085](https://linear.app/robert-guss/issue/ROB-1085) is the next
released item to plan.

## 3. Read these first

- `AGENTS.md` `## Driver` (config and delivery rules) and `CLAUDE.md`.
- The Linear issue you pull, all of its comments, and the project's "Direction,
  research agenda and operating rules" document.
- For LAB-3: `docs/lab/003-concurrency-baseline.md`. The registration is under
  Runs → Attribution (lines 154–295, never edited); the results are in the
  Results, Interpretation and Limits "### Attribution" subsections.
- `docs/lab/README.md` for the lab task, report and compare recipes and the
  ROB-1217 diagnostics.

## 4. Context

- The owner resumed execution on 2026-10-02. The instruction was to work through
  the whole backlog, decisions included, and do as much as possible, with Claude
  as driver, Codex as oracle and a fresh Pi worker per step. The Amp
  Lead/Builder/Tester orbs are retired (ROB-1215).
- This machine is the registered LAB-3 host. Retained raw evidence lives under
  `lab/results/` (gitignored, untracked). Oracle recomputations read it locally.
- LAB-3 so far: N=10 is valid and ranked, with session-class own time led by
  `:json`, `term_to_binary` and `:crypto`, and mild waiting evidence, so no
  bottleneck is claimed. Both N=500 profiles are invalid. In the instrumented
  rerun, `profile_start` was handled on time, but setup took about 132.6 s
  before the census, and 29 users exited `:no_client`. Nothing is attributed. Do
  not describe the coordinator backlog as the cause; the oracle corrected that
  reading.

## 5. This chunk

PRs #12–#16 (`e5702c0`..`ee3296e`) delivered ROB-1215, ROB-1089, ROB-1217 and
two ROB-1083 write-ups. The list is in the Linear current handoff's top entry.
Each issue's `[driver]` completion comment records its oracle rounds, findings
and verify results, and whether the oracle checked them independently.

## 6. Decisions and authorizations in force

All are recorded in Linear: the standing delivery authorization in AGENTS.md
`## Driver` and the current handoff's top entry, the LAB-5 release on
ROB-1085, and the LAB-3 rerun limit on ROB-1083. Nothing extra is held in
this file.

## 7. Operational state

- Worker: `pi` with no arguments, one fresh pane per step, split below the
  oracle, named `worker-<tab>`. No worker is running.
- No measurement, sampler or Elara BEAM is running. Retained evidence:
  `lab/results/concurrency/20261002T210908440701Z-…` and
  `20261003T123711789702Z-…`, plus their `lab3-profile*` logs. Keep all
  `lab/results` (ROB-1092: retain).
- The previous driver reached Linear through the GraphQL API with
  `$LINEAR_API_KEY`, because no Linear MCP was loaded in its session; the
  oracle's session did have one. Discover the tools available to you.
  Driver comments start with `[driver]`.

## 8. Conventions and gotchas

- The shell is zsh: `PIPESTATUS` is unset there. Run measurements under explicit
  Bash and capture `${PIPESTATUS[@]}` immediately.
- Quote heredocs (`<<'EOF'`) for prompts and briefs. An unquoted heredoc ran
  backticked text as commands twice this chunk.
- `pgrep -lf beam.smp` self-matches Herdr prompt text that contains "beam.smp".
  Use `pgrep -x beam.smp` with `ps -o pid,args`.
- Do not run tests or compiles in the checkout while a sweep runs, including the
  oracle.
- The only CI is the Socket checks; there is no `mix test` in CI. Run the full
  suite locally and save its output to a file, because one SSE failure's detail
  was lost to a grep filter (ROB-1216).
- Known intermittents: `attachment_test.exs:408` task census, the sampler peer
  count, and the OpenAI fragmented-SSE test.
- Profile write-ups: Table N residuals use the registered `erlang_binary_memory`
  reading. Table L needs source-audited callee hops. The `other` class modules
  come from `repetitions.jsonl`.
- `herdr agent prompt --wait` can outlast a 10-minute tool call. Fall back to
  `herdr agent wait`, and read only once the agent is idle.

## 9. Skills

Required: `driver` for the driver, `oracle` for the oracle, `worker` for each
worker. Optional: `herdr`.
