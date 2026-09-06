# Agent-authored plugin during a real coding task

Experiment conducted 2026-09-06. [Exact prompts](agent-authored-plugin-prompts.md)
are retained for inspection. [ROADMAP.md](../../ROADMAP.md), PLUGIN-2,
owns implementation status. The earlier [priorities](priorities.md) remain the
research assessment; this report adds observed evidence.

## Result

Elara authored a diagnostic plugin, used it to observe a real shell, and fixed
the macOS liveness assumption in the shell tests. Explicit discovery and a
subsequent revision worked in the same session and plugin process, preserving
the remembered probe. **The coding task succeeded with operator and review
assistance.** It did not complete unattended.

The useful shipped change is a portable test helper and a regression test.
The [authored plugin](fixtures/shell_liveness.exs) is preserved as an experimental
specimen outside automatic discovery. A roughly 180-line diagnostic wrapper is
not yet enough practical value to justify adding two permanent tools to every
session. This experiment supports further use of the plugin mechanism, but
does not establish a productivity advantage over a short script.

## Setup and boundaries

- PLUGIN-1 merged into `main` at `eb88160`; 34 focused checks passed on the
  merged tree. PLUGIN-2 began on `codex/agent-authored-plugin` from that merge.
- Real `Elara.Provider.OpenAICodex`, configured model `gpt-5.5`, effort `low`,
  using existing Codex authentication. No scripted provider supplied decisions.
- Public `Elara.start_session/1`, `Elara.ask/2`, and
  `Elara.reload_plugins/1`; one in-memory session, `ykd-vfmNEweeJk13YyWaVg`.
  This exercised the live-model API path, not the TUI interaction path.
- Repository instructions retained; empty user-skill home and `skill_paths: []`
  deliberately avoided the previously observed oversized skill catalog.
  Limits: 12 iterations per ask, 90-second tool timeout, 12,000-byte tool output.
- The operator explicitly requested plugin authoring and inspected source before
  activation between turns. This was not spontaneous tool invention or
  model-controlled installation. Persistence across VM restart was not tested.
- Seven prompts produced 50 tool results, including three repeated-call
  rejections. Two asks ended with `:turn_limit`; five completed normally.
  These are transcript counts, not a benchmark or success-rate estimate.

## What actually happened

| Step | Operator input | Observed outcome |
| --- | --- | --- |
| Reproduce and author | Identify S-EFFECT-LIVE; request a useful small plugin, no fix or activation yet | Elara reproduced the failure, identified the `/proc` assumption from source, and wrote `shell_liveness_probe` plus `shell_liveness_last`. A repeated `read` was rejected; it recovered with a targeted shell read. |
| Discover | Inspect complete source, explicitly reload | New plugin loaded as version 1, generation 1, PID `#PID<0.286.0>`. |
| Try live observation | Ask Elara to create a shell fixture and use its tool | Four probes found an exited process or no PID. Background/nohup attempts did not retain a usable shell; a foreground attempt timed out. The ask exhausted its iteration budget before fixing the test. |
| Supply controlled fixture | Operator started a shell in a separately managed terminal and supplied its path | Probes 5 and 6 observed the same live PID before and after the primary file appeared. An identical second probe was rejected; Elara recovered by adding the explicit PID argument. |
| Fix and verify | Continue the bounded task | Elara added a `ps` fallback, passed the focused test and all 20 existing shell tests, then formatted. An identical test rerun was rejected; a shell-command rerun passed. The ask hit its limit before cleanup and final reporting. |
| Close task | Explicit cleanup/report prompt | Remembered probe 6 survived the turn boundary. Elara released the controlled fixture and cleaned its temporary fixtures; the managed shell exited successfully. |
| Review corrections | Feed back faulty failure classification, then unavailable-procfs semantics | Elara first added a failing invalid-PID regression, corrected the helper and plugin, and passed 21 shell tests. A follow-up corrected the plugin's fallback semantics and removed duplicate observations. A direct compiled-plugin probe confirmed inconclusive observations remain unknown. |
| Upgrade | Inspect complete revision, explicitly reload, ask for remembered probe | Version 2, generation 2, same PID `#PID<0.286.0>`. `shell_liveness_last` returned probe 6 and its original file/PID state. Session then stopped cleanly. |

The controlling Codex session supplied the fixture, follow-up prompts, source
review and explicit reloads. Elara authored the plugin and test changes; the
operator subsequently moved the plugin unchanged into this report's fixtures.

## Concrete evidence

The original S-EFFECT-LIVE assertion expected `:alive` but received
`:terminated` on macOS. The helper read `/proc/<pid>/stat` and treated `ENOENT`
as termination, although macOS lacks that filesystem.

The live plugin recorded:

| Observation | PID | Primary file | Exit released | `ps` | Version-1 `/proc` label |
| --- | --- | --- | --- | --- | --- |
| Probe 5, before effect | 71760 | absent | no | `:alive` | `:missing` |
| Probe 6, after effect | 71760 | present | no | `:alive` | `:missing` |

The version-1 `:missing` label was itself imprecise. Revision 2 now distinguishes
an unavailable observer from a missing process. Its separately compiled
invalid-PID probe reported `procfs_state=:unavailable`, a `ps` diagnostic, and
`portable_liveness=:unknown`. Only blank status-1 `ps` output establishes
absence; other failures remain inconclusive. Zombie states remain terminated.

After reload, the remembered probe still contained its **historical version-1
labels**. Preserving this plain data demonstrated continuity; it did not
reclassify old evidence or claim the already-exited fixture was still alive.

The fixed helper keeps the Linux `/proc` path and uses `ps` when that path is
missing. The invalid-PID regression failed before the review correction
(`:terminated` instead of `:unknown`) and passed afterward. All **21 shell tests
passed**, including the three previously failing macOS lifecycle cases.

## Practical findings and next priority

1. **Fix repeated-call handling before another larger runtime experiment.**
   Legitimate observation after a state change and verification after an edit
   were rejected as repeated calls. Preserve bounded loop protection while
   allowing useful repeats. Acceptance should reproduce probe → change → probe
   and test → edit → same test, without argument tricks or changing tools.
2. **Make shell-job lifetime clearer to the model.** The execution stub kills
   the job's process group after the shell leader exits
   (`native/exec-stub/src/main.rs`, `child.try_wait` and `kill_group`). Ordinary
   `bash` is therefore not a persistent background-job interface. The failed
   fixture attempts should inform tool guidance; a supervised persistent-job
   API needs a separately justified use case. Keep current cleanup guarantees.
3. **Use generated plugins when retained state or reuse earns their cost.**
   This plugin consolidated observations and retained a useful last result.
   Source inspection, corrections, explicit activation and extra tool context
   also cost work. Try another real task after the repeat-call friction is fixed,
   rather than expanding immediately into core hot upgrades or a layout system.

This is one assisted experiment. No comparison group, elapsed-cost accounting,
token-cost measurement, Linux acceptance run, unattended-success claim, or
dedicated eval framework follows from it. Evals remain owner-deferred. The
recommendations above are proposed follow-up work, not newly scheduled items.

## Verification and publication

The authored plugin compiled and was exercised before archival. Independent
review found no remaining actionable issues after the corrections.
`mix format --check-formatted` (including the archived fixture explicitly),
`mix compile --warnings-as-errors`, and `git diff --check` passed.
Final full suite: **447/457 passed**, 10 failures, 196.9 seconds. The three
previously failing macOS shell cases now pass. Remaining failures are five
context-budget/handoff cases, queued-mutation recovery, saved-session listing,
two thread path/session-discovery cases, and an HTTP fixture startup timeout.
All were observed before this patch; their causes are still unresolved. This
run used the final layout with the diagnostic plugin outside auto-discovery.
The pushed implementation commit is recorded in PLUGIN-2's Result in
[ROADMAP.md](../../ROADMAP.md).
