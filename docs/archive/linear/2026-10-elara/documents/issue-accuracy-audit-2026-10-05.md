# Issue accuracy audit — 2026-10-05

- **Created:** 2026-10-06T00:28:32.829Z by Robert Guss
- **Updated:** 2026-10-06T00:30:49.843Z
- **Linear URL:** https://linear.app/robert-guss/document/issue-accuracy-audit-2026-10-05-8070f2f9117f

---

Reviewed all **46 Elara issues**, including archived items (none in the returned inventory), through their stable UUIDs. Read each full description, comments, status history, attachments, and relationships. Final readback verified all 46 descriptions after Linear's Markdown/smart-chip normalization, statuses, UUIDs, parents, and original blocking/related edges. Counts: **23 Done, 22 Backlog, 1 Needs Input**; no Ready/Planning/Building/In Review items.

**Corrections saved:** 41 descriptions, including completed results and resolved owner decisions, historical/current distinctions, and malformed provenance links. Five descriptions already matched the evidence ([ROB-1084](https://linear.app/robert-guss/issue/ROB-1084/lab-4-rq-3-isolation-under-misbehaving-sessions), [ROB-1087](https://linear.app/robert-guss/issue/ROB-1087/lab-7-rq-2rq-3-measured-fixes-with-unchanged-workloads), [ROB-1216](https://linear.app/robert-guss/issue/ROB-1216/intermittent-openai-provider-fragmented-sse-test-failure-under-full), [ROB-1233](https://linear.app/robert-guss/issue/ROB-1233/intermittent-opaqueshell-fixture-registration-convergence-failures), [ROB-1234](https://linear.app/robert-guss/issue/ROB-1234/session-recovery-choices-digest-is-not-seed-reproducible-hashes-per)). [ROB-1083](https://linear.app/robert-guss/issue/ROB-1083/lab-3-rq-2-finish-concurrency-attribution-and-conditional-close-out) changed Building → Needs Input to reflect its recorded measurement pause. Existing priorities, labels, ownership, parent hierarchy, dependencies, and historical comments were preserved. Linear automatically added related edges while resolving mentions; those additions were restored to the original set during readback.

The owner removed the previous role-based workflow and authorized all work in this session on 2026-10-05. AGENTS.md, CLAUDE.md, HANDOFF.md, and the guidance pointer test now support that arrangement. The project description and three project documents were reconciled. Historical staffing, pause, and migration records remain explicitly historical.

## Evidence and verification

Audit baseline: local main and remote main both `25fe51b0f6d75847d54d81fbd3204873c432b6ca`. [Immutable source tree](<https://github.com/robertguss/Elara/tree/25fe51b0f6d75847d54d81fbd3204873c432b6ca>). GitHub confirmed all referenced PR #8–31 merges and exact merge SHAs; remote branch inventory was read. Refreshed the codebase-memory graph and used bounded graph/source inspection. CodeScent tools and its configured local repository were unavailable.

Direct current checks:

* Full `mix test`: **886 passed**, 11 properties and 875 tests, seed **61482**, 250.8 seconds. Log: `/tmp/elara-linear-audit-20261005-mix-test.log`.
* Guidance test after final handoff edit: **3 passed**, seed **214982**.
* `mix compile --warnings-as-errors`, `mix format --check-formatted`, and `git diff --check`: passed.
* Rust TUI `cargo test --locked`: **116 passed** (98 + 2 + 13 + 3); execution stub: **6 passed**. Logs: `/tmp/elara-linear-audit-20261005-{tui,exec}-test.log`.
* No retired skill/model/routing requirements remain in AGENTS.md, CLAUDE.md, or HANDOFF.md. No BEAM remained at the final process check.

Retained records directly checked for provenance, completeness, checks, and eligibility:

* LAB-3 original profile at eaa88f9: 2 rows, N=10 valid, N=500 invalid.
* N=500 instrumented rerun at 26a64f1: 1 invalid row.
* [ROB-1238](https://linear.app/robert-guss/issue/ROB-1238/22-lab-3-one-n500-diagnostic-run-localizing-the-profile-setup-stall) diagnostic at 3854b7e: 1 invalid row; [ROB-1252](https://linear.app/robert-guss/issue/ROB-1252/22-lab-3-one-n500-diagnostic-run-with-the-sessionsup-probe) diagnostic at 3c4399f: 1 invalid row. Diagnostics remain outside measurement counts.
* LAB-5 pilot at c82a17f: 30 complete clean-provenance rows, indeterminate_without_receipt false in exactly 10.
* [ROB-1235](https://linear.app/robert-guss/issue/ROB-1235/4-lab-5-started-mutation-reopened-without-an-effect-executor-must-stay) fix verification at c8678b6: 30 complete clean-provenance rows, every check true. Separate from LAB-5 measurement counts.
* LAB-3 final attempt-2 output namespace is empty; the reviewed launcher remains unrun with a stale 8568f34 revision pin.

The five retained historical/archive branches remain; prior delivered work branches are gone. [ROB-1092](https://linear.app/robert-guss/issue/ROB-1092/decision-retain-archive-or-release-measurement-directories)'s retained directories and the newer diagnostic/recovery evidence are present.

## Limits and remaining work

This audit establishes tracking consistency with source, delivery evidence, current tests, and the retained records read above. Historical real-provider behavior, physical-terminal acceptance, every historical aggregate, and host-load race causes were not newly reproduced. Passing tests do not close unresolved intermittents or deferred human acceptance.

LAB-3's final N=500 rerun stays paused and unrun, and closure stays an owner decision. LAB-5's broader fault matrix and >=1000 schedules remain unfinished. [ROB-1091](https://linear.app/robert-guss/issue/ROB-1091/decision-post-lab-3-research-versus-daily-use-direction) remains the post-LAB-3 owner direction checkpoint. No registered measurement or real-provider run was launched and no retained experiment evidence was altered.

The audit changes AGENTS.md, a runtime prompt input. The old LAB-3 revision amendment allowed only HANDOFF.md to differ from the census fix. Before measurement resumption, choose/document a revision respecting the registration and review the launcher/brief amendment; do not silently broaden that allowance.

## Per-issue reconciliation

| Issue | Current status | Verified state or remaining scope | Evidence inspected |
| -- | -- | -- | -- |
| [ROB-1080](<https://linear.app/robert-guss/issue/ROB-1080>) | Done | Hermetic test runtime config, diagnostics and pointer checks remain present; current workflow wording corrected. | config/runtime.exs; test/elara/test_environment_test.exs |
| [ROB-1081](<https://linear.app/robert-guss/issue/ROB-1081>) | Done | Core properties and fail-closed outcomes remain implemented; LAB-9 is now delivered, shell chaos remains LAB-5. | docs/lab/001-core-properties.md; test/elara/session/core_property_test.exs; lib/elara/session/core.ex |
| [ROB-1082](<https://linear.app/robert-guss/issue/ROB-1082>) | Done | Bench, simulated provider, faults and seeded runner remain; later session_recovery digest exception is [ROB-1234](https://linear.app/robert-guss/issue/ROB-1234/session-recovery-choices-digest-is-not-seed-reproducible-hashes-per). | docs/lab/002-lab-bench.md; lib/elara/lab.ex; lib/elara/provider/simulated.ex |
| [ROB-1083](<https://linear.app/robert-guss/issue/ROB-1083>) | Needs Input | Paused final N=500 rerun remains unrun; valid N=10 and invalid N=500 evidence retained; census fix merged. | docs/lab/003-concurrency-baseline.md; lib/elara/lab/profile.ex; retained JSONL and launchers |
| [ROB-1084](<https://linear.app/robert-guss/issue/ROB-1084>) | Backlog | Isolation experiment remains unregistered/undelivered; LAB-3 and owner direction gates remain. | Linear relations; docs/lab/003-concurrency-baseline.md |
| [ROB-1085](<https://linear.app/robert-guss/issue/ROB-1085>) | Backlog | Valid 30-run pilot and recovery fix delivered; full matrix and >=1000 schedules remain. | docs/lab/005-shell-chaos.md; lib/elara/lab/scenarios/session_recovery.ex; retained JSONL |
| [ROB-1086](<https://linear.app/robert-guss/issue/ROB-1086>) | Backlog | Coordinator removal decision resolved; modules, tests and special cases remain pending LAB-5. | lib/elara/coordinator/engine.ex; lib/elara/effect/; lib/elara/session.ex; [ROB-1095](https://linear.app/robert-guss/issue/ROB-1095/decision-rebuild-coordinator-judgingmap-reduce-over-threads-or-drop) |
| [ROB-1087](<https://linear.app/robert-guss/issue/ROB-1087>) | Backlog | Measured product optimization experiment remains unselected; LAB-4/LAB-6 gates preserved. | Linear relations; note 003; current source |
| [ROB-1088](<https://linear.app/robert-guss/issue/ROB-1088>) | Backlog | TestJobs/thread_wait special cases still exist; unified Jobs/correlated wake experiment remains pending LAB-5. | lib/elara/test_jobs.ex; lib/elara/threads/communication.ex; lib/elara/session.ex |
| [ROB-1089](<https://linear.app/robert-guss/issue/ROB-1089>) | Done | LAB-9 acknowledgement backend/server/TUI paths and guards merged; removed stale paused/WIP claim. | PR #13 eaa88f9; lib/elara/threads.ex; lib/elara/session.ex; native/elara-tui/src/lib.rs |
| [ROB-1090](<https://linear.app/robert-guss/issue/ROB-1090>) | Done | Owner Mac/load/evidence decision was resolved; retained evidence is present, future launch still gated. | Owner comments; retained baseline directories |
| [ROB-1091](<https://linear.app/robert-guss/issue/ROB-1091>) | Backlog | Post-LAB-3 direction checkpoint remains open; removed obsolete LAB-9 pause/harness-only continuation. | Owner directions; LAB-3 relation; current handoff |
| [ROB-1092](<https://linear.app/robert-guss/issue/ROB-1092>) | Done | Retain-as-is decision recorded and directories present; sizes remain historical. | Owner comment; retained paths |
| [ROB-1093](<https://linear.app/robert-guss/issue/ROB-1093>) | Done | Five historical/archive branches retained; prior delivered work branches gone and LAB-9 merged. | Owner comment; current git ls-remote |
| [ROB-1094](<https://linear.app/robert-guss/issue/ROB-1094>) | Done | Mint floor/lock remain 1.10.2; historical remediation delivery confirmed. | PR #10 0f5e4a5; mix.exs; mix.lock; OpenAI loopback tests |
| [ROB-1095](<https://linear.app/robert-guss/issue/ROB-1095>) | Done | Owner chose deliberate removal; Coordinator code still exists pending LAB-6. | Owner comment; lib/elara/coordinator/engine.ex; test/elara/coordinator_test.exs |
| [ROB-1096](<https://linear.app/robert-guss/issue/ROB-1096>) | Done | Bounded investigation delivered negative Linux evidence; original Mac cause remains unresolved. | PR #11 514e81d; docs/lab/006-real-pty-investigation.md; lab/results/[ROB-1096](https://linear.app/robert-guss/issue/ROB-1096/investigate-intermittent-real-pty-threads-test-failure)/ |
| [ROB-1097](<https://linear.app/robert-guss/issue/ROB-1097>) | Backlog | Children profiling remains explicitly deferred; current attribution is sessions-only. | Owner registration; note 003; concurrency/profiling source |
| [ROB-1098](<https://linear.app/robert-guss/issue/ROB-1098>) | Backlog | Alternative reducer replay exists; handoff/wake policy still involves the shell. | lib/elara/flight_recorder.ex; lib/elara/session.ex |
| [ROB-1099](<https://linear.app/robert-guss/issue/ROB-1099>) | Backlog | Plugin reload exists; fault-injected session migration experiment remains gated on LAB-5/LAB-8. | lib/elara/plugin/server.ex; Linear relations |
| [ROB-1100](<https://linear.app/robert-guss/issue/ROB-1100>) | Backlog | Event-source extension remains parked, without a selected experiment. | Existing job/thread event paths; issue scope |
| [ROB-1101](<https://linear.app/robert-guss/issue/ROB-1101>) | Backlog | TCP worker placement remains implemented; BEAM distribution comparison is parked. | lib/elara/worker/server.ex; lib/elara/executor/remote.ex |
| [ROB-1102](<https://linear.app/robert-guss/issue/ROB-1102>) | Backlog | Core remains a pure reducer; loop-ownership change remains a future experiment. | lib/elara/session/core.ex; lib/elara/session.ex |
| [ROB-1103](<https://linear.app/robert-guss/issue/ROB-1103>) | Backlog | Current separate built-in tool roster remains; intent-roster experiment is unselected. | lib/elara/tool.ex |
| [ROB-1104](<https://linear.app/robert-guss/issue/ROB-1104>) | Backlog | Receipt-backed local write remains the durable-effects scope; general Port-job receipt idea is parked. | lib/elara/exec.ex; lib/elara/effect/; CLAUDE.md |
| [ROB-1105](<https://linear.app/robert-guss/issue/ROB-1105>) | Backlog | Gateway still binds loopback without authentication; repository plugin loading retains full authority. | lib/elara/server.ex; lib/elara/plugin/loader.ex |
| [ROB-1106](<https://linear.app/robert-guss/issue/ROB-1106>) | Backlog | Source Mix commands/API remain; daily-use extension and acceptance remain unselected. | lib/mix/tasks/; lib/elara.ex; CLAUDE.md |
| [ROB-1107](<https://linear.app/robert-guss/issue/ROB-1107>) | Backlog | Composer/navigation/tool-view/layout/theme code exists; hands-on acceptance remains deferred. | native/elara-tui/src/editor.rs; native/elara-tui/src/lib.rs; native/elara-tui/src/appearance.rs |
| [ROB-1108](<https://linear.app/robert-guss/issue/ROB-1108>) | Backlog | Quiet header/footer/chrome implementation exists; physical/visual acceptance remains deferred. | native/elara-tui/src/lib.rs; native/elara-tui/tests/goldens/ |
| [ROB-1215](<https://linear.app/robert-guss/issue/ROB-1215>) | Done | Historical workflow adoption delivered, later superseded; owner now requires direct session work. | PR #12 e5702c0; PR #26; current owner instruction |
| [ROB-1216](<https://linear.app/robert-guss/issue/ROB-1216>) | Backlog | Fragmented-SSE intermittent remains unresolved; no original detail/seed recovered and no proven fix. | test/elara/provider/open_ai_test.exs; original issue |
| [ROB-1217](<https://linear.app/robert-guss/issue/ROB-1217>) | Done | User-failure and timer/coordinator diagnostics are present; original missing-output finding is historical. | PR #15 26a64f1; lib/elara/lab/scenarios/concurrency.ex; lab tests |
| [ROB-1228](<https://linear.app/robert-guss/issue/ROB-1228>) | Done | Bounded setup-stall diagnosis delivered; subsequent diagnosis and fix also merged. | PR #21/#23; note 003; retained diagnostic JSONL |
| [ROB-1230](<https://linear.app/robert-guss/issue/ROB-1230>) | Done | Attempt-3 invalidation delivered; 30 error-only rows remain retained. | PR #18 897becb; note 005; retained attempt-3 JSONL |
| [ROB-1231](<https://linear.app/robert-guss/issue/ROB-1231>) | Done | JSON-safe finalization, provenance and smoke addendum delivered. | PR #19 c82a17f; SessionRecovery.finalize; runner regression |
| [ROB-1232](<https://linear.app/robert-guss/issue/ROB-1232>) | Done | Pilot write-up delivered: 30 valid rows, provider claim 20/20, predicted finding 10/10. | PR #20 3bf748d; note 005; attempt-4 JSONL |
| [ROB-1233](<https://linear.app/robert-guss/issue/ROB-1233>) | Backlog | OpaqueShell fixture convergence intermittent remains unresolved; original test code persists. | test/elara/effect/opaque_shell_test.exs; original issue |
| [ROB-1234](<https://linear.app/robert-guss/issue/ROB-1234>) | Backlog | choices_digest still hashes per-run input identities while README makes broader reproducibility claim. | [session-recovery observer](<https://github.com/robertguss/Elara/blob/25fe51b0f6d75847d54d81fbd3204873c432b6ca/lib/elara/lab/scenarios/session_recovery.ex>); docs/lab/README.md |
| [ROB-1235](<https://linear.app/robert-guss/issue/ROB-1235>) | Done | Conservative restart repair and atomic persistence implemented; separate fix verification 30/30 checks true. | PR #24 6401912; Core.repair_history; Session.persist_repairs; fix JSONL |
| [ROB-1237](<https://linear.app/robert-guss/issue/ROB-1237>) | Done | First-census phase timing delivered; later call timing and census change identified separately. | PR #21 f9ccd9b; lib/elara/lab/profile.ex |
| [ROB-1238](<https://linear.app/robert-guss/issue/ROB-1238>) | Done | One diagnostic delivered after gate stop; invalid profile stays outside LAB-3 measurements. | PR #23 d71e97f; note 003; diag1 JSONL |
| [ROB-1243](<https://linear.app/robert-guss/issue/ROB-1243>) | Done | SessionSup diagnosis delivered with bounded causal conclusion and remaining individual-init uncertainty. | PR #27/#28; note 003; diag2 JSONL |
| [ROB-1251](<https://linear.app/robert-guss/issue/ROB-1251>) | Done | Opt-in probe, running trace, census timing and session-start timing exist. | PR #27 3c4399f; lib/elara/lab/sup_probe.ex; running trace and sampler |
| [ROB-1252](<https://linear.app/robert-guss/issue/ROB-1252>) | Done | One probe-on diagnostic and note delivered; its profile remains invalid and uncounted. | PR #28 2e1cc79; note 003; diag2 JSONL |
| [ROB-1254](<https://linear.app/robert-guss/issue/ROB-1254>) | Backlog | Threads phase observation intermittent remains unresolved; added to current known-intermittent list. | test/elara/threads_test.exs:123; historical baseline report |
| [ROB-1255](<https://linear.app/robert-guss/issue/ROB-1255>) | Done | Links-based census fix is present and merged; final measurement has not yet tested it. | PR #30 8568f34; Profile.linked_children; lab_profile tests; README |

## Repository delivery

[robertguss/Elara#32](https://linear.app/robert-guss/review/retire-the-crew-workflow-and-refresh-the-elara-handoff-8de5ddeb1a34) merged on 2026-10-06 at 00:30:52Z (2026-10-05 local date) as `4ec59de765aa7e719e72bc8b5a5ee39471dc39d7`. Accepted branch commit: `6608c370289ed9dec398045543c24129947118d4`. Both Socket checks passed; CI does not run mix test. The merge tree is identical to the reviewed/tested branch tree. Local main is synchronized to the merge and the delivered remote work branch is removed.

The changes touch only AGENTS.md, CLAUDE.md, HANDOFF.md, and test/elara/roadmap_test.exs. All current Linear issue corrections and project-document updates were saved and read back. The owner-authorized workflow retirement is delivered; benchmark resumption and unfinished experiments retain their recorded gates.
