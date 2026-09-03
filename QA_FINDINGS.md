# Elara manual QA findings — 2026-09-03

Action list from a full verify-now run of [`MANUAL_TEST_CHECKLIST.md`](MANUAL_TEST_CHECKLIST.md).
Fix these elsewhere; this file is the handoff.

| Field | Value |
| --- | --- |
| Commit tested | `c97862a` (merge of PR #7, `add-verify-elara-skill`) |
| Environment | Debian 13; Elixir 1.20.4 / OTP 29.0.6; rustc/cargo **1.98.1** (rustup). Apt rustc **1.85** is insufficient for the TUI. |
| Provider | Grok device login only (`~/.grok/auth.json` imported → `~/.elara/auth.json` mode 600) |
| Scope | All checklist sections that can be verified now. **Skipped:** §15 multi-week SPLIT-5 table; ChatGPT/Codex subsection; API-key subsection (no keys). |

## Rollup

Almost all checklist items **PASS**. One hard product **FAIL**. Remaining rows are docs/checklist/API polish.

| Area | Result |
| --- | --- |
| §1 Build baseline | 11/11 PASS (with rustc ≥1.88) |
| §2 Grok auth | PASS (token refresh UNVERIFIED; API key/Codex SKIPPED) |
| §3 TUI daily smoke | 13/13 PASS |
| §4 ask/chat | Mostly PASS; **1 FAIL** (`--continue` after bash/read) |
| §5–7 TUI/server/tools/effects | 44 PASS, 0 FAIL, 1 UNVERIFIED |
| §8–9, §11–12, §14 | 64/64 PASS |
| §10 remote workers | 10/10 PASS |
| §13 coordinators | 11/11 PASS |

---

## P0 — product bug (must fix + test)

### 1. `mix elara.chat --continue` → `:invalid_intent_record` after bash/read

- **Expected:** Resume newest cwd-scoped session and print transcript.
- **Observed:** `Could not start chat: :invalid_intent_record` (exit 1).
- **Evidence:** Session JSONL had bash+read turns. Effects sqlite had `controller_intents` rows stuck in `state=intent` with **0** `controller_observations`. Text-only sessions in another cwd resumed fine.
- **Repro:** Clean cwd → chat turn that uses `bash` and/or `read` → exit → `mix elara.chat --continue`.
- **Fix intent:** Resume/reconcile must not treat unmatched **non-write** controller intents as a hard invalid resume, **or** those tools must not leave dangling intents without observations. Durable receipts are frozen at PROD-1 **write** scope — do **not** silently receipt bash/edit unless that is an explicit design change. Restore daily-driver `--continue` without lying about write causality.
- **Prove:** Automated regression: resume after a turn that used bash (and read if distinct).

---

## P1 — docs, checklist, API polish

### 2. Toolchain requirements underspecified

- Apt `rustc 1.85`: no rustfmt/clippy; cannot build `native/elara-tui` (`ratatui 0.30` needs rustc **≥1.88**). §1 only passes with rustup ≥1.88.
- **Fix:** Document min rustc (≥1.88), rustfmt, and clippy in `README.md`, `AGENTS.md`, and checklist setup. Optionally improve Mix/cargo error when the toolchain is too old.

### 3. Live `exec-stub` ETXTBSY when a second Mix process compiles

- While `mix elara.tui`, `mix elara.server`, or `mix elara.worker` holds `_build/.../priv/native/exec-stub`, another Mix in the same checkout that recompiles hits `File.CopyError` **ETXTBSY**.
- Workarounds seen: `mix run --no-compile` / `mix eval --no-compile`; separate `MIX_BUILD_PATH` for extra workers. Mix 1.20 rejects `mix --no-compile elara.worker` as a global flag.
- **Fix:** Document for multi-terminal server/TUI/worker setups. Prefer a small durable DX improvement if safe (e.g. skip copy when binary unchanged and busy, or a clearer error). Do not break the stub build.

### 4. Checklist wording: tool timeout vs ask exit code

- `mix elara.ask` with a ≥30s bash command: tool times out, model finishes, ask exits **0**.
- Checklist currently groups “wait timeout” with nonzero ask exit.
- **Fix:** Clarify that default **tool** timeout is a tool error inside a successful ask unless the turn itself fails; distinguish from CLI wait-timeout / turn-limit / interrupt nonzero exits.

### 5. Session file modes

- JSONL / effects sqlite / `.flight` / `.lock` are mode **600**.
- SQLite `-shm` / `-wal` are often **644**.
- **Fix:** Checklist should state confidentiality for durable session artifacts and note shm/wal are runtime and may differ.

### 6. Write confinement: session path vs bare `Elara.Tools.write/2`

- Direct `Tools.write` accepted abs / `../` / symlink-through paths.
- Session declarative write rejected them.
- **Fix:** Checklist/docs must say confinement applies to the default local **session/declarative write** path, not the bare Tools helper.

### 7. Coordinator missing `prompt:` crashes instead of typed error

- Omitting `prompt:` → `{:error, {:coordinator_crashed, {:badkey, :prompt, ...}}}` plus Task `KeyError`.
- Duplicate ids correctly return `{:error, :duplicate_child_ids}`.
- **Fix:** Validate child specs; return a typed error (e.g. `:prompt_required` / `:invalid_child_spec`) without crashing the coordinator task. Add a test.

### 8. Optional DX: headless TUI exit via `mix eval`

- Wrapping headless TUI with `mix eval --no-compile`: Mix reported exit **0** even when the TUI binary exited **1** (undersized frame).
- **Fix:** Document using `mix elara.tui` directly, or propagate exit status if easy.

---

## Out of scope / not defects

- Codex subscription and API-key checklist rows (intentionally skipped).
- Grok token refresh (not exercised; tokens still valid).
- §15 SPLIT-5 multi-week evidence table.
- Model probabilistic re-queue of an interrupted `sleep` on the next ask (usability only).
- “Used in real daily work?” answers for plugins/remote/durable recovery (QA-only session).
- Interactive Escape/Ctrl-C detach without interrupting on long-lived server (UNVERIFIED in §5; headless detach analog + §3 embedded Escape PASS).

---

## Suggested fix order

1. P0 `--continue` / `:invalid_intent_record` + regression test.
2. Coordinator typed error for missing `prompt:`.
3. Docs/checklist items 2–6 and 8 in the same PR or a docs follow-up.

Do not mark SPLIT-5 done from this QA alone.
