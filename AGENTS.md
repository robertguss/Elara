# AGENTS.md

## Research, experiments, and decision records

Git-tracked repository documents—not Amp threads, Harness Sessions, or orbs—are
the canonical research record. Before changing research semantics, experiment
design, evaluation, or related architecture, read:

- `docs/glossary.md` — canonical working vocabulary and stable term keys.
- `docs/decisions/README.md` — ADR process, status rules, template, and index.
- `docs/experiments/README.md` — Experimental Lab charter, record layers,
  provenance, retention, and curation rules.
- The relevant protocol under `docs/experiments/` and every ADR it lists as a
  governing decision.

Follow these rules:

- Add or revise a glossary entry before preregistration when a term can change a
  hypothesis, permission, state transition, measurement, evaluation, or
  conclusion. Protocols pin the glossary Git commit they use.
- Record a consequential research or design choice as a small numbered ADR in
  `docs/decisions/`; update the index and link the ADR from governed protocols.
  Do not create ADRs for routine edits with no meaningful alternative.
- Do not rewrite an accepted ADR to make history look different. A material
  change creates a superseding ADR; retain the prior rationale, alternatives,
  consequences, provenance, and revisit triggers.
- Keep source assertions, immutable raw records, normalized observations,
  interpretations, findings, and decisions distinct. Preserve negative,
  malformed, interrupted, and unexpected records subject to declared privacy and
  secret redaction.
- After preregistration, change protocol semantics only through an explicit,
  versioned amendment that states what changed, why, and which data had already
  been observed. Never silently mix runs from incompatible protocol versions.
- Respect each experiment's lifecycle status. Do not implement or execute a
  fixture, schema, runner, capture system, or product change while its protocol
  still reserves that work for a later phase.
- Run manifests must identify their protocol version, pinned glossary commit,
  and governing ADR IDs. Findings and later ADRs must cite the runs and
  decisions they use or affect.
- Use terms precisely: an Amp thread is not a Harness Session, an orb is an
  execution environment, and a run is one attempted condition/scenario
  execution.

For documentation changes, run `git diff --check`, validate embedded JSON, and
verify local Markdown links. Markdown and JSON are canonical unless a protocol
explicitly adopts another format; do not hand-maintain a second generated source
of truth.

## Cursor Cloud specific instructions

Harness is a single Mix app (an Elixir coding-agent CLI). Standard commands live
in `README.md` (the "Develop" section) and `mix.exs`; the notes below only cover
things that are non-obvious in the Cloud environment.

### Toolchain

- Elixir 1.20 / Erlang/OTP 29 are provided by the base environment (installed
  under `/opt/elixir` and `/opt/otp`, symlinked into `/usr/local/bin`). They are
  part of the VM snapshot, not the update script. The update script only
  refreshes project deps with `mix deps.get`.
- Hex/Rebar are already installed in `~/.mix`, so `mix deps.get` runs
  non-interactively.

### Lint / test / build / run

- Lint (check only): `mix format --check-formatted`. Auto-format: `mix format`.
- Test: `mix test`. Tests never touch the network — they use
  `Harness.Provider.Scripted`.
- Build: `mix compile`.
- Run the CLI: `mix harness.ask "..."`, `mix harness.chat`, `mix harness.login`.

### Gotchas

- `mix test` intentionally logs a `[error] ... (RuntimeError) boom` line from a
  crash-recovery test (`Harness.SessionTest.CrashTool`). This is expected; the
  run still ends with all tests passing. Do not treat that log line as a
  failure.
- The real agent (`mix harness.ask` / `mix harness.chat`) needs xAI/Grok
  credentials: `HARNESS_API_KEY` (preferred) or `XAI_API_KEY`, or an interactive
  `mix harness.login` (tokens land in `~/.harness/auth.json`). Without
  credentials these commands fail at the network call.
- To exercise the full agent loop (session + read/write/edit/bash tools) without
  credentials, drive it with the scripted provider via the public API:
  `Harness.start_session(provider: {Harness.Provider.Scripted, agent_pid}, cwd: dir, persist: false)`,
  where `agent_pid` is an `Agent` holding a queue of canned
  `{:ok, %Harness.Message.Assistant{}}` turns. This is the same mechanism the
  test suite uses.
- Chat/ask session files persist under `~/.harness/sessions/<cwd-key>/`;
  `mix harness.chat --continue` resumes the newest session for the current
  working directory.
