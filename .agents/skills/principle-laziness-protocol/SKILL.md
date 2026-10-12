---
name: principle-laziness-protocol
description: "Apply when refactoring, evaluating diff size, or tempted to add abstractions, layers, or signal threading. Bias toward deletion and the smallest change that solves the problem."
disable-model-invocation: true
---

> **Harness note (pstack-portable):** this skill was written for Cursor. Before you spawn subagents, ask structured questions or read transcripts, read `.agents/pstack/HARNESS.md` for the Amp, Claude Code, Codex and Grok Build equivalents. Role models come from `pstack.config.yaml`.

# Laziness Protocol

- **Consolidate decisions.** Do not repeat the same choice in several places. Put it behind one source of truth and pass the result as a simple flag.
- **Minimize the diff.** Make the smallest change that solves the problem. Fewer lines beat "elegant" boilerplate.
