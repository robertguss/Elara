# Elara daily-driver roadmap review — 2026-09-04

## Verdict

TUI-3 remains the next executable item. The previous roadmap covered terminal
foundations but did not describe the complete daily-driver product agreed with
the owner. ROADMAP.md now captures that contract and sequences its delivery.
This review changes documentation only; no feature is newly marked DONE.

The review read the entire roadmap, reconciled the architecture decision,
inspected relevant provider, prompt, session, coordinator, and persistence code,
and examined official Grok Build and Amp references. Seven document-review
lenses covered coherence, feasibility, design, security, product, scope, and
adversarial assumptions. No cross-provider review was used.

## Material conclusions

1. **Keep the existing Rust/Elixir boundary for implementation.** The three
   layouts are alternate presentations of one canonical session. Elixir can own
   durable threads and routing while Rust owns editor, navigation, and appearance.
   BEAM supervision supplies useful runtime primitives; persistence, delivery
   deduplication, workspace isolation, and effect recovery still require explicit
   application behavior. The existing architecture checkpoint remains meaningful.
2. **Do not equate the existing coordinator with communicating threads.** Its
   children disable persistence, use temporary coding worktrees, and end with
   batch lifecycle assumptions. THREAD-1/2 address durable identities, preserved
   work, messaging, follow-ups, navigation, and recovery using existing sessions.
3. **Provider support is a prerequisite, not a visual detail.** The current
   ChatGPT adapter is text-only for user input and ignores reasoning-summary
   events. The actual subscription route must demonstrate reasoning summaries,
   model/effort controls, image inputs, and usable usage/context information.
   A bounded preflight now precedes layout investment; public API docs do not
   prove subscription support. Full implementation remains PROV-2.
4. **Grok supplies interaction patterns, not the full product scope.** Borrow
   composer handling, file completion, queue/send-now behavior, semantic themes,
   inspectable tools, and disk-image attachment patterns. Elara intentionally
   keeps thinking expanded by default. Three layouts/four independent themes are
   explicit requirements; broader Grok feature parity and MCP are excluded.
5. **Automatic continuation needs stronger guarantees than a generated prompt.**
   CTX-1 now covers persisted stages, successor ownership, queued inputs, child
   reports, attachments, stop precedence, uncertain mutations, provenance, and
   repeated-handoff semantic checks. Original messages remain retrievable.
6. **Trial evidence must come from real terminals and real provider use.**
   Browser studies and scripted tests cannot establish clipboard, keyboard,
   mouse, resize, or subscription behavior. Acceptance requires Ghostty/WezTerm
   exercises and relevant credential-backed checks before primary-use evaluation.

## Review findings incorporated

| Lens | Finding | Resolution |
| --- | --- | --- |
| Feasibility | Unframed multiline paste cannot reliably be distinguished from Enter | Bracketed paste plus explicit safe fallback; actual binding checks |
| Design | Separate thinking views could show the wrong turn during history inspection | Explicit turn identity, live/history binding, overlay focus and transition checks |
| Design | Approved visual references were not durably addressable from the plan | Separate local archival branch and visual-reference document |
| Security | A generated handoff could elevate tool/child text into owner instructions | Canonical settings transfer, source roles/IDs, and adversarial provenance tests |
| Scope | Provider viability was checked after substantial layout investment | Bounded subscription capability preflight before TUI-7 |
| Adversarial | Repeated handoffs could lose corrections despite transport correctness | Seeded multi-handoff checks for corrections, unfinished work, and evidence |

Coherence and product reviews found no remaining actionable omission in the
revised contract. This does not certify the unimplemented features. Historical
DONE Results were retained unchanged, with the new contract explicitly
superseding older scope and queue advice. The architecture addendum preserves
the original five-feature measurement cohort and reports expanded work separately.

## Delivery order and limits

TUI-3 composer → TUI-4 transcript → TUI-5 tools → subscription preflight →
TUI-7 layouts/themes → PROV-2 provider → INPUT-1 references/images → INST-1
instructions/skills → TUI-6 session lifecycle → CTRL-1 queue/steer → THREAD-1
persistent children → THREAD-2 communication → CTX-1 automatic continuation →
SPLIT-5 daily-driver evaluation. ROADMAP.md is the sole live queue.

No product tests or live subscription calls were run for this documentation
review. Verification checks roadmap IDs, dependency references, local links,
historical Result preservation, archival integrity, and whitespace. Required
provider capabilities and real terminal usability remain unverified until their
implementation acceptance checks. No roadmap commit or push was made; only the
separate local prototype archive was committed.

## Evidence

- [Current contract and queue](../ROADMAP.md)
- [Grok Build source research](grok-build-tui-research.md), pinned to a source revision
- [Amp threads research](amp-thread-research.md), including conflicting handoff documentation
- [Approved visual references](elara-tui-visual-reference.md)
- [Architecture decision and current addendum](rust-elixir-split.md)

The research notes distinguish observed source/documentation from inference;
neither is a second roadmap. Amp's product thread mechanisms are useful
references, not evidence of its internal delivery guarantees or proof of Elara's
implementation. No external source code was copied into product code.
