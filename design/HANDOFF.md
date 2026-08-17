# Cloud handoff

Continue this Feature. Do not restart the arena. Implement the Mix app against the synthesized sketch.

## Goal

A Pi-like Elixir coding harness on OTP 29 / Elixir 1.20. Smallest loop that can log in with a Grok subscription and edit a local repo.

## Already decided

Read these files in order:

1. `design/how-domain.md`
2. `design/SYNTHESIS.md`
3. `design/base/SKETCH.md` (candidate 1, the base)
4. `design/throughput.md`
5. `design/arena-rubric.md`

Base is candidate 1. Pure `Harness.Session.Core.step/2`. Mechanical GenServer shell. Tools as MFA data. Events to subscriber pids.

Grafts already chosen in SYNTHESIS.md. Do not add plan mode, Phoenix, MCP, compaction, or a plugin loader.

## Already on disk

- Mix app `:harness` with supervisor (`mix new` already ran)
- `req` in `mix.exs`
- Design docs under `design/`
- No domain implementation yet. `lib/harness.ex` and `lib/harness/application.ex` are Mix stubs.

## Data shape

Session phase is `:idle | {:calling_provider, ref, iteration} | {:running_tool, ref, call, rest, iteration}`.

History is `User | Assistant | ToolResult`. Assistant is built only by `Message.assistant/2` and cannot be empty.

A tool is `%Harness.Tool{name, description, parameters, run: {module, atom}}`. Never a closure.

`Core.step(state, fact) :: {state, [effect]}` is the only history writer.

Invariants from candidate 1:

- I1. Only `step/2` appends history.
- I2. Every assistant tool call has exactly one result before the next provider call, including interrupt.
- I3. Every fact sequence ends idle with `turn_ended`.
- I4. Mismatched refs are dropped.
- I5. Iteration never exceeds `max_iterations`.

## Implement in this order

1. `Message` + `Session.Core` + `test/harness/session/core_test.exs` covering the transition table, interrupt I2, stale refs, and repeated-tool rejection. `mix test` green before anything else.
2. Builtins in one file. `read`, `write`, `edit`, `bash`. `edit` is exact `old_text` -> `new_text` once.
3. Tiny system prompt. Append `AGENTS.md` from cwd when present.
4. Provider behaviour with threaded config:

   `chat(config, request) :: {:ok, assistant, config} | {:error, error, config}`

5. `Harness.Provider.OpenAI` for BYOK / tests. Pure `build_body/2` and `parse_response/1`. Scripted fake for process tests.
6. Grok OAuth (default path):
   - `mix harness.login` RFC 8628 device code
   - `https://auth.x.ai/oauth2/device/code` and `https://auth.x.ai/oauth2/token`
   - client id `b1a00492-073a-47ea-816f-4c329264a828`
   - scope `openid profile email offline_access grok-cli:access api:access`
   - write `~/.harness/auth.json` mode 600 via temp file + rename
   - refresh rotates the refresh token. Persist the new pair or login dies.
   - import `~/.grok/auth.json` when harness has no tokens
   - chat `https://api.x.ai/v1/chat/completions` bearer token, default model `grok-4`
   - Inspect redaction on credential fields
   - HTTP 403 is a named entitlement error. Tell the user to set `XAI_API_KEY`. Re-login will not help.
   - `HARNESS_API_KEY` + optional `HARNESS_BASE_URL` is the fallback
7. Session GenServer shell, `Harness` public API, `mix harness.ask`, per-event CLI output.
8. Application children. `Task.Supervisor` and `DynamicSupervisor` for sessions. Sessions are `:temporary`.

## Success

- `mix test` green. No live network in tests.
- `mix harness.ask "what files are in this repo?"` works after login or env key.
- `mix harness.login` prints a verification URL and user code.
- Core tests prove I2 on interrupt.
- One Mix app. No umbrella. No Phoenix.

## Comments

No narrating comments. Keep a comment only for a non-obvious why.

## Git

Commit in small units that match the order above. Open a PR when the loop runs and tests pass.
