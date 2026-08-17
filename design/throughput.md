# Throughput checkpoint

**Blocking first steps.** `mix new`, then `Message` + `Session.Core` + `core_test` covering the transition table. Nothing else starts until those tests pass.

**Independent workstreams.** After core is green, tools (read, write, edit, bash), the OpenAI-compatible adapter, and Grok auth can be written as separate files. One owner still, because they share Message and Provider types. Do not fan out writers onto `session/core.ex`.

**Shared mutable state.** The session process is the one writer of history. That is a real invariant. Serialize asks in that mailbox. Auth file writes are atomic temp-plus-rename. Arena candidates already used separate directories.

**Smallest safe decomposition.** One implementer for the Mix app. The types are the shared contract. Two writers on `lib/harness` would collide.
