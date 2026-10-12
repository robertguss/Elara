---
name: setup-pstack
description:
  Configure which models pstack uses per role, per harness (Amp, Claude Code,
  Codex, Grok Build), by editing pstack.config.yaml at the project root. Use for
  /setup-pstack, "configure pstack models", "pstack budget", or changing
  pstack's model choices.
---

# Setup pstack

pstack-portable replaced Cursor's version of this skill. Model choices live in
`pstack.config.yaml` at the project root, one entry per role, with a value for
each harness. Edits take effect on the next subagent spawn. Read
`.agents/pstack/HARNESS.md` for how roles map to spawns.

## Steps

### 1. Load the config

Read `pstack.config.yaml`. If it is missing, stop and tell the user to run
`npx github:robertguss/pstack-portable sync` at the project root, which creates
it with defaults.

### 2. Pick the harness

Ask which harness column to change: `amp`, `claude-code`, `codex`,
`grok`, or all four.
Default to the harness you are running in.

### 3. Detect available models

- **Amp:** run `amp plugins show-agent-options` and use its `provider/model`
  ids.
- **Claude Code:** `opus`, `sonnet`, `haiku` and `fable` are always valid, plus
  any full `claude-*` id the user names.
- **Codex:** ask the user for the model ids their account has, or keep
  `inherit`.
- **Grok Build:** run `grok models` and use the ids it lists.

`inherit` is always valid: the role runs on the thread's own model.

### 4. Budget, map, and confirm

Ask for a budget with these four options: `unlimited — max`, `large — xhigh`,
`medium — high`, `small — medium`. In Claude Code use AskUserQuestion.
Elsewhere, ask with numbered options. The budget sets the `@effort` suffix on
every real model value in the chosen columns. Claude Code and Grok Build ignore
effort, so skip the budget for those columns.

Show every role with its current and proposed value. Ask whether to accept, or
change specific roles. Offer the detected models plus `inherit`. Panel roles
(`arena-runners`, `architect-runners`, `interrogate-reviewers`,
`arena-cross-judge-pool`) take a list, and the list length sets the fan-out.

### 5. Validate and write

Every real model written must be in the detected set for its harness. Edit only
the values the user changed. Keep the comments, the key order and the other
harnesses' values. Don't add roles. Sync owns the role list.

### 6. Confirm

Tell the user which values changed and that they apply on the next spawn, with
no re-sync needed. Suggest committing `pstack.config.yaml` so orbs and teammates
get the same routing.

### 7. Offer a verification skill (optional)

Check whether the project has a way to drive the real app for proof, such as a
`verify-*` skill or an existing harness. If not, offer once to generate one with
`/create-verification-skill`. On no, move on.
