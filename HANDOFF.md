# Handoff

## 1. State

Observed 2026-09-26: repository `/Users/robertguss/Projects/startups/Elara`,
branch `main`. Work is reviewed through `0831374` and pushed through `0831374`
to `origin/main`. This handoff is committed on top of that commit. The working
tree was clean before this file. Re-check HEAD, `git status` and `origin/main`
before relying on this.

## 2. Read these first

- **`ROADMAP.md`** is the sole status source: research questions RQ-1 to RQ-5,
  the lab method, the LAB-0 to LAB-9 queue, and each item's scope and "Done
  when". LAB-2 is DONE and LAB-3 is TODO.
- **`CLAUDE.md` and `AGENTS.md`** hold the lab direction, conventions, test
  isolation and the driver/oracle review workflow.
- **`docs/lab/README.md`** explains how to run lab scenarios.
- **`docs/lab/002-lab-bench.md`** records the LAB-2 results, a finding, and the
  bench's limits.
- **`git log --oneline -20`**: each commit message is detailed.

## 3. Context

Elara became primarily a BEAM harness research lab on 2026-09-26, by the owner's
decision. Work follows the ROADMAP queue. Each experiment starts from a
refutable hypothesis, and a result against it is a finding. Review happens
between two agents in Herdr: the driver (left pane) builds and the oracle (right
pane) reviews, using the `driver` and `oracle` skills in `~/.agents/skills/`.

## 4. Agreed chunk and acceptance

- **Objective:** finish LAB-2 (the capped real-model run, slice E and the
  close-out). Then create the driver/oracle skills and opt Elara into them.
- **Excluded:** LAB-3 and later items.
- **Stopping condition:** LAB-2 is DONE and the workflow is committed.
- **Disposition:** `accepted`.

## 5. Verification and review

- **Capped real-model smoke run.** Run on `d8aef3e` with a clean tree, using
  `ELARA_PROVIDER=openai-codex mix elara.lab run smoke --provider real --max-requests 3`.
  Completed 1 of 1 turns in 4.4 s. Evidence:
  `lab/results/smoke/20260927T003850641782Z-seed1.jsonl`. Driver-run; the
  oracle checked the retained file.
- **Five-run bench results (note 002).** Run on `29a368d` with a clean tree,
  using `mix elara.lab run SCENARIO --n 5 --seed 42`, which runs seeds 42–46.
  Every check passed in all 5 runs of the three job scenarios. Evidence:
  `lab/results/{smoke/20260927T010752118337Z,concurrent_jobs/20260927T010800894725Z,session_crash/20260927T010803850698Z,provider_fault/20260927T010810377654Z}-seed42.jsonl`.
  Driver-run; the oracle checked the files. The later changes in `78b9221`
  (validating each test run, and reporting `primary_status_ms`) do not change
  these scenarios' checks.
- **Same seed reproduces its choices.** Checked by
  `test/elara/lab_test.exs` (smoke) and `test/elara/lab_scenarios_test.exs`,
  which runs each job scenario twice per seed. Both pass in the full suite.
- **Full suite.** `mix test` passed 584 on the tree committed as `78b9221`.
  Driver-reported; no record was kept.
- **Mutation checks.** Each new scenario, runner, simulator and v1-rejection
  test was run against a broken version and went red, then green once
  restored. Driver-reported; no record was kept, and the commit messages do not
  describe them.

The oracle (Astra, Codex) reviewed every LAB-2 commit and signed off on LAB-2 as
a whole, with its "Done when" criteria met. Every finding was fixed: one P1,
several P2s and three P3s. The oracle also signed off on the skills and on
`0831374`, after five P2s were fixed; its last P3 was fixed without another
round.

The oracle reviewed from source, and most reviews ran nothing. The live Herdr
restart and takeover steps in `end-of-chunk.md` are unproven until this handoff
exercises them.

## 6. Remaining work

The queue continues in `ROADMAP.md` order: LAB-3, then LAB-4 and LAB-5, then
LAB-6 to LAB-9, with the dependencies listed there.

## 7. Next chunk

**Proposed:** LAB-3, the RQ-2 concurrency baseline on unchanged code, as scoped
in `ROADMAP.md`.

- **Acceptance:** LAB-3's "Done when".
- **First action:** fix the reference workload's values in a new
  `docs/lab/003-…` note and plan the measurement harness on top of the lab
  bench. Then send that plan for review.

## 8. Decisions and authorizations in force

- **Lab direction:** the lab pivot, with daily use secondary.
- **Roadmap source:** `ROADMAP.md` is the sole status source.
- **Commits:** commit and push each completed item.
- **Real-model runs:** these need the owner's explicit go-ahead each time,
  because they spend subscription quota.
- **Protocol:** v1 is retired and v2 is the only session protocol.
- **Review workflow:** driver/oracle review applies to all work, and each chunk
  ends with a reviewed `HANDOFF.md`.

## 9. Open questions for the user

- **Unmerged branches:** what to do with `codex/harness-harvesting-ideas`,
  `codex/elara-tui-design-studies` and `exp/001-mission-receipt-design`. This
  blocks deleting or merging them.
- **Security advisories:** how to respond to `mint 1.9.3`'s advisories (one
  HIGH), pulled in via `req`. This blocks dependency upgrades.
- **LAB-6:** whether to rebuild the Coordinator's judging and map/reduce on
  Threads, or drop them. This blocks LAB-6.

## 10. Operational state

- **Running jobs or processes:** none.
- **Evidence to keep:** the files under `lab/results/` listed in section 5 are
  the only record of note 002's measurements and of the real smoke run, and git
  does not hold them. Keep them until the owner archives them or releases them
  for deletion. The three earlier `lab/results/smoke/20260926T2356*` files are
  pre-slice-E smoke runs; they are not cited, but release them the same way.
- **Temporary failure-evidence directories:** none.
- **Cleanup obligations:** none.

## 11. Conventions and gotchas

- **Questions:** the owner wants one question per message.
- **Mutation checks:** mutation-check every new test. Break the behavior, see
  the test go red, then restore it and see it go green.
- **`tr`:** in the owner's zsh, `tr` is aliased to `trash`, so don't use it.
- **`ls`:** aliased to `eza`, so use `/bin/ls` when flags matter.
- **Backticks:** never put backticks inside double-quoted shell strings, since
  zsh runs them. Send Herdr prompts from a file.
- **Markdown reflow:** a formatter hook reflows Markdown after each edit, so
  re-read a file before editing it again.
- **Suite run time:** `mix test` takes about 2 minutes. Replay a failing order
  with `mix test --seed N`.
- **Receipt ordering:** a session broadcasts `turn_ended` before it settles the
  input's receipt, so wait for the settled receipt before reading one.
- **Lab runner:** after unconfirmed cleanup, the runner leaves the global
  sessions root bound to that run's directory, so don't reuse that VM.
- **Job scenarios:** their choice digests are the same for every seed because
  their choices are scripted, so a digest proves the scripted path ran, not that
  the seed changes anything.

## 12. Skills

- **Required:** `driver` for the driver and `oracle` for the oracle.
- **Optional:** `herdr`, and `mattpocock-skills:tdd`, since LAB items are
  test-first.
