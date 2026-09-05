# Subscription capability preflight

Observed 2026-09-04, before TUI-7. This is evidence for the current subscription
route, not a general availability promise. Queue and status remain in ROADMAP.md.

## Method

Used the existing Codex subscription session in memory, without copying its
credentials into Elara or changing project defaults. No API-key billing route,
login refresh, or real workspace content was used. Requests went to
`https://chatgpt.com/backend-api/codex/responses` with originator `elara`,
`store: false`, `stream: true`, and `reasoning.summary: auto`.
The authenticated catalog used `/codex/models?client_version=0.153.2`.

Five bounded synthetic requests covered a small arithmetic problem and a local
256×128 PNG with a red left half and blue right half. One request tested the
existing default; four completed on catalog-listed models. The
[sanitized evidence](fixtures/subscription-preflight-2026-09-04.json) contains
requested/returned model and effort, public event shapes, summaries, answers,
usage, and relevant catalog fields. It excludes credentials, account and item
identifiers, hidden catalog models, and encrypted/private reasoning.

## Observations

| Capability | Observed result | Implementation consequence |
| --- | --- | --- |
| Existing default `gpt-5.3-codex` | HTTP 400: not supported with this ChatGPT account route | PROV-2 must handle the unsupported default explicitly; no silent migration was performed |
| Model selection | `gpt-5.5` and `gpt-5.4-mini` completed; mini resolved to `gpt-5.4-mini-2026-03-17` | Preserve requested and served model identities separately |
| Effort controls | `gpt-5.5` low/high both completed and echoed the requested effort | Tested low/high; catalog advertises medium/xhigh too, but those were not probed |
| Public reasoning summaries | Both models streamed summary part/text events; requested auto resolved to detailed | Preserve output and summary indices; separate parts rather than concatenating headings |
| Disk image input | Both models identified `left=red, right=blue` from a PNG data URL | Backend capability is verified; Elara's production image-message path remains INPUT-1 work |
| Usage | Input/output/total, cached input, cache writes, and reasoning-token counts were returned | Preserve provided fields; request totals are not exact current context occupancy |
| Context catalog | Both tested models advertised `context_window: 272000`, `max_context_window: 272000` | Treat these as catalog limits; no boundary-saturation or exact occupancy test was performed |

The combined image/arithmetic request also returned `n=469`. Its public stream
included two reasoning-summary parts followed by an assistant message carrying
`phase: final_answer`. These facts support presentation design; they do not
establish recovery, tool interleaving, persistence, or interruption behavior.

## Boundaries and remaining work

The bounded preflight is complete. TUI-7 may build layouts with explicitly labeled
fixtures and show live reasoning as unavailable until PROV-2 supplies it. The
unsupported existing default and missing Elara-specific login remain blockers
for claiming a working live Elara subscription experience. PROV-2 owns model
selection/migration behavior and credential integration; this probe changed
neither. The existing Codex session was sufficient for the tests.

Public summary text is distinct from encrypted continuation data. PROV-2 must
preserve ordering/identity and test arbitrary SSE boundaries, absent summaries,
settings rejection, tool events, interruption, and resume. CTX-1 must keep
occupancy estimates explicitly labeled and use conservative reserves; the
catalog response is not a proof of the exact effective limit on every request.
No higher-capacity setting, unsupported effort, or all-model matrix was probed.

## Live Elara product proof

On 2026-09-04, the implemented adapter completed a synthetic session through
`Elara.start_session`, `Elara.set_provider_settings`, and `Elara.ask` on the same
subscription route. Explicit read-only Codex authentication loaded successfully;
the credential file remained byte-for-byte unchanged. The session selected
`gpt-5.5` with `high` effort, called the supplied `echo_marker` tool once with
`proof-469`, then returned the correct arithmetic result, 469, and the echo.

The tool-call response provided no public summary; the final response provided
one public summary followed by a distinct final answer. Both responses reported
the requested model and usage. Reported totals were 256 input, 65 output, and 27
reasoning tokens (reasoning is included in output); cached input and cache writes
were zero. The advertised limit remained 272,000, with exact occupancy unknown.
The labeled estimate includes serialized history, system text, tool schemas and
a 4096-byte framing reserve; it is not exact request/tokenizer measurement.

The [sanitized product proof](fixtures/subscription-product-proof-2026-09-04.json)
contains only synthetic public content, selected/served model, tool result, and
allowlisted telemetry. It omits credentials, account and response identities,
and private continuation data. This resolves the earlier default/login adapter
blockers. It does not expand the tested model/effort matrix or prove a saturated
context limit. Image capability remains established by the earlier synthetic
red/blue-image route probe; attachment delivery belongs to INPUT-1.

## Official documentation context

The [reasoning guide](https://developers.openai.com/api/docs/guides/reasoning)
documents opting into summaries with `reasoning.summary` and the `auto` setting.
The [GPT-5.3-Codex API model page](https://developers.openai.com/api/docs/models/gpt-5.3-codex)
describes image input, effort settings, and a 400,000-token API context window.
Those API facts did not establish subscription access: the actual subscription
request rejected that model, and the tested route's catalog advertised 272,000
for its tested alternatives. The observed route evidence above governs this
implementation; refresh it if the route or model contract changes.
