# Synthesis

Base. [Candidate 1](b33f67e6-1bd5-4666-b254-05f70376fc63). The
[cross-judge](8908e4f0-6a19-4b09-b4fa-667a46f4af96) scored it 34.5/35. I agree.
The parent read every package. Candidate 1 is the only sketch that is both
Pi-small and wire-legal on interrupt.

The contract is `/tmp/arena-elixir-harness/candidate-1/SKETCH.md` plus the
grafts below. Do not invent a fifth shape.

## Grafts

From [candidate 2](4f6dec56-1e6d-49ab-bb93-ab99f94552bb). The provider callback
threads state so a refresh can return a new token blob.

```elixir
@callback chat(config(), Request.t()) ::
            {:ok, Harness.Message.Assistant.t(), config()}
            | {:error, Harness.Provider.Error.t(), config()}
```

The shell writes the returned config back. That is how Grok OAuth refresh stays
a provider concern.

From [candidate 4](65e0233f-b90f-4563-9af4-880e1a46a3ac).

- Inspect redaction on credential structs.
  `@derive {Inspect, except: [:access_token, :refresh_token, :api_key]}`.
- Repeated identical tool calls in one turn append
  `{:error, "repeated tool call"}` and do not run. Candidate 1 already reserved
  this as a future row. Ship the row.
- Keep I2. Every tool call gets a result, including interrupt.

From Pi, at the invoker's request.

- Fourth builtin. `edit` with `path`, `old_text`, `new_text`. Exact match, one
  replacement.
- Tiny system prompt. Tools plus a few guidelines. Load `AGENTS.md` from cwd if
  it exists.
- No `--plan`. No plugin loader. No MCP. No compaction.

From the invoker.

- Default auth is Grok subscription OAuth, not an API key.
- `mix harness.login` uses RFC 8628 device code against `https://auth.x.ai`.
- Public Grok-CLI client id `b1a00492-073a-47ea-816f-4c329264a828`.
- Scope `openid profile email offline_access grok-cli:access api:access`.
- Store `~/.harness/auth.json` mode 600. Refresh on expiry. xAI rotates refresh
  tokens. Persist the new pair or login is dead.
- If `~/.grok/auth.json` exists and harness has no tokens, import it.
- Chat against `https://api.x.ai/v1/chat/completions` with the bearer token.
  Default model `grok-4`.
- `HARNESS_API_KEY` plus optional `HARNESS_BASE_URL` remains the test and BYOK
  path.
- HTTP 403 after a good login is a named entitlement error. Point at
  `XAI_API_KEY`. Re-login will not help.

## Rejections

- Candidate 4 `--plan`, `Tool.Param` DSL, `Transcript`, `Cursor`, Effect/Reply
  vocabulary. Too much for a Pi core.
- Candidate 2 fingerprints, turn-budget types, tool behaviour, Application-heavy
  named sessions.
- Candidate 3 `{:halted, _}` as a terminal phase that cannot ask again, and
  MFA-only without the edit tool.
- Token streaming in v1. Per-event output is enough.
- Loopback PKCE login. Device code works on SSH and is the path Hermes kept.

## Verification of the pick

| Rubric               | C1     | C2     | C3     | C4     |
| -------------------- | ------ | ------ | ------ | ------ |
| Usage first          | yes    | yes    | yes    | yes    |
| Phase sum type       | yes    | yes    | yes    | yes    |
| Wire at boundary     | yes    | yes    | yes    | yes    |
| Pi-small surface     | yes    | no     | closer | no     |
| Single writer        | yes    | yes    | yes    | yes    |
| Wire-legal interrupt | yes    | no     | no     | yes    |
| Room for Grok login  | Config | Config | Config | Config |

C2 and C3 lose on dangling tool calls. C4 loses on baked plan mode and module
count.
