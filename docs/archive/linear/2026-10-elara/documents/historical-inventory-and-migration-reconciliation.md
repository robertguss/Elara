# Historical inventory and migration reconciliation

- **Created:** 2026-10-02T00:11:10.318Z by Robert Guss
- **Updated:** 2026-10-06T00:27:24.362Z
- **Linear URL:** https://linear.app/robert-guss/document/historical-inventory-and-migration-reconciliation-c30963eda745

---

# Delivery update — 2026-10-02

Migration PR [https://github.com/robertguss/Elara/pull/8](<https://github.com/robertguss/Elara/pull/8>) is merged at ca01d8a8b2b2ae213ac8e406bcaeb63192431039. Owner authorized push/PR/merge; both reported GitHub checks succeeded. No deployment. Earlier local-only/pending statements below are historical.

# Migration inventory (historical import snapshot)

The status, authority and cutover statements below describe the initial import, not current execution. Current issue descriptions and the Current handoff govern. As verified on 2026-10-05, LAB-9 is merged in PR #13; LAB-3's final rerun is paused and unrun; LAB-5's pilot and recovery fix are delivered, with the broader experiment unfinished. The project now has 46 issues. The owner retired the separate role-based workflow on 2026-10-05; historical staffing and publication statements below are provenance.

Imported2026-10-02 from [ROADMAP](<https://github.com/robertguss/Elara/blob/03b257159f987e0baf4de9b57f71af156721a5d0/ROADMAP.md>) and [HANDOFF](<https://github.com/robertguss/Elara/blob/03b257159f987e0baf4de9b57f71af156721a5d0/HANDOFF.md>). These immutable full snapshots preserve original wording; Linear descriptions carry actionable scope/acceptance and current status. No historic result reverified. Original completion dates are in descriptions; Linear timestamps reflect import.

LAB-0..9 map in order to ROB-1080..1089. LAB0–2 Done; LAB3 Needs Input; LAB4–9 Backlog/unselected. Host gate ROB1090; post-LAB3 direction ROB1091; retention ROB1092; branches ROB1093; advisories ROB1094; Coordinator ROB1095; PTY ROB1096. Parked children profiling1097, offline replay1098, live change1099, events1100, BEAM placement1101, Core loop1102, intent roster1103, Port receipts1104, gateway/plugin trust1105, daily driver1106. Deferred TUI acceptance1107/1108. Six explicit exclusions in Direction document are not backlog issues.

Technical dependency links preserve roadmap edges. LAB3 additionally host gate; LAB4 additionally direction discussion; LAB6 Coordinator gate. Post-LAB3 owner pause applies project-wide, including already-technically-unblocked LAB5/9. No priorities, due dates or automatic Ready items added. Owner decisions do not consume lab execution slot.

# Historical shipped/canceled/deferred inventory

Original IDs/statuses preserved below; full pre-pivot Results/checks/limits at [pre-pivot roadmap](<https://github.com/robertguss/Elara/blob/6ac8343/ROADMAP.md>), narratives in docs/harness-experiments.md. Commit references are historical evidence, not new merge claims.

| ID | Original status | Result | Commit(s) |
| -- | -- | -- | -- |
| ER-1–3 | CANCELED | Durable-effects research method stop | 57f6b12 |
| PROD-1 | DONE | Receipt-backed local write public path | 4d87900,dd8629b |
| PROD-2 | CANCELED | Receipt-backed edit; effects frozen at PROD1 | 79ded48 |
| SPLIT-1 | DONE | Rust exec stub/bash Port | ff8bcb2 |
| SPLIT-2 | DONE | Protocolv2 snapshot attach/sequenced patches | ef43018,54ea404 |
| SPLIT-3 | DONE | Streaming providers/content deltas | 7c99e7d |
| SPLIT-4 | DONE | Rust TUI projection | 80a65cd |
| PROV-1/2 | DONE | Codex subscription, reasoning/model/effort/usage | b440861,fb7a6a3 |
| TUI-1/MAC-1/TUI-2 | DONE | Embedded server/macOS cleanup/Markdown | 131fc52,991f2b4,220c18c |
| TUI-3/4/5/7 | DEFERRED | Implemented composer/navigation/inspection/layouts/themes; hands-on acceptance dropped | 0e1cbda,de46872,e7c67bf,0c968dc; ROB1107 |
| TUI-8 | DEFERRED | Quiet chrome implemented; visual review dropped | b972b27; ROB1108 |
| INPUT-1/INST-1 | DONE | References/images, scoped instructions/skills | 57f930c,da9a690 |
| TUI-6/CTRL-1 | DONE | Lifecycle/durable input queue/steering | d5085b8,3219bf7 |
| THREAD-1/2 | DONE | Worktree children/durable communication | bd4fa99,a4f0651 |
| CTX-1 | DONE | Linked successor auto-handoff | e25058e |
| PLUGIN-1/2 | DONE | Discovery/reload/agent-authored plugin experiment | 8728298,43b283a |
| LOOP-1/DIAG-1 | DONE | Repeated-call policy/check diagnosis | 20a8eda,1b24bfe |
| JOB-1–12/TEST-1 | DONE | Supervised jobs/recovery/cancellation/specialists/suite repairs | c6ebf10,306ca87,6ac8343 |
| SPLIT-5 | CANCELED | Daily-driver go/no-go retired at lab pivot | none |

# Scope and cutover (historical pre-publication record)

User authorized tracking migration, not execution of imported work. Lab registrations/evidence remain in repo; raw laptop data is NOT copied by this import. No deletion or data-cleanup grant. Original Mac conditions, tool aliases and verification are dated observations, not orb facts.

Oracle plan review required: Ready must mean authorization; allow zero executable items while paused; migrate all current-authority references, not just ROADMAP; hermetic pointer test cannot enforce remote queue. These are adopted in operating rules and planned cutover.

Delivery state: Linear project/issues/documents created; repository pointer/guidance/test changes verified and Oracle-reviewed locally; committed locally as 6592cd1730ce271c070436843df72035d4902c56 on chore/linear-tracking-migration after owner authorization; not pushed. Working tree clean. Publishing authorization remains pending. Other checkouts are not migrated until that delivery. No runtime changes, measurements or experiments performed.

## Migration verification

Lead re-read the project, all three documents, the 29-issue inventory, and the LAB-3/LAB-4/LAB-6 decision dependency relations through Linear MCP. Oracle reviewed the migration plan and local diff; its final focused verdict was no blockers after correcting the manual checklist authority reference. Oracle did not independently inspect remote Linear content.

Local checks: `mix test test/elara/roadmap_test.exs` first failed 2/2 against original docs, then passed 2/2 after cutover; expanded checklist coverage failed 1/2 before its correction, then passed 2/2. `mix format --check-formatted` and `git diff --check` passed. No runtime changes, full-suite run, or measurement run. Registered experiment note unchanged. Queue enforcement now belongs to Lead review in Linear, not these pointer tests.

Remaining delivery: authorize a dedicated migration branch push; no pull request, merge, or deployment is authorized. Until delivered, other checkouts retain prior guidance.
