# oh-my-pi: source review for Elara

Reviewed 2026-09-06. Repository: [can1357/oh-my-pi][repo]. Clone:
`/tmp/elara-harness-research-2026-09-06/oh-my-pi`.
Pinned revision: `6d3bc569d16cd7351073eaa767caed51021befbb`.

This review inspected the cloned implementation and selected regression-test bodies. No dependencies were installed, downloaded code executed, or tests run. “Test coverage” below means assertions found in source, not a verified passing run. The current source contains substantially more than the original Pi-derived loop: TypeScript agent/session orchestration, a native Rust editing layer, lifecycle management, and programmable agent orchestration. The useful transfer is a set of explicit runtime contracts, not wholesale adoption of this workspace.

These are extension hypotheses for Elara, not claims that its existing threads, plugin generations, context handoff, or Rust boundary are missing.

## 1. Prewalk as an explicit phase transition

`PrewalkCoordinator.advanceAtTurnEnd` implements a one-way model or thinking-effort switch. It observes completed tool results, waits for a successful `todo` when that tool is active, and switches after a direct `edit`/`write` or a mutating device call dispatched through `write`. It first waits for assistant and tool-result persistence, removes the hidden planning nudge, switches models, and injects a checklist. The planning nudge itself requests concrete steps, files, and verification. This is continuation of the same session after the first edit, not a second agent receiving only a plan. [Coordinator][prewalk], [planning prompt][prewalk-plan].

The trigger is deliberately narrow: bash does not count. The action predicate also does not check `isError`, unlike the successful-todo gate. Therefore “first successful mutation” is stronger than what this code guarantees. A failed edit, or substantial effects performed through bash, deserve explicit treatment in any adaptation. The tests demonstrate bash exclusion and edits before/after the todo gate using mock models. [Trigger][prewalk-trigger], [tests][prewalk-test].

**Elara experiment:** add a reducer-visible planning/execution phase and record the transition reason, source/target model, context projection, and first mutation receipt. Use the receipt boundary instead of inferring effects from tool names. Start with one model family or effort change; do not make multi-provider fidelity a prerequisite.

**Acceptance scenario:** exploration plus shell reads cannot accidentally transition; one successful receipt transitions once; a failed or cancelled write cannot masquerade as success; restarting immediately after transition does not repeat the edit.

Model switching resets provider sessions and records an ephemeral model-change entry. Cross-provider replay separately normalizes IDs and may strip signatures, demote visible thinking, or discard incompatible opaque/redacted content. This is not portable transfer of a model’s internal state. [Model controls][model-controls], [replay transformation][replay].

## 2. Resource-aware agent parking with generation fences

Finished agents can become idle, lose their live session after a TTL, retain transcript identity, and revive on demand. `AgentLifecycleManager` coalesces concurrent revival requests and binds adoption, disposal, and revival to the exact registry reference that started the operation. It detaches the session before disposing it, so a caller cannot obtain a session already being torn down. [Lifecycle implementation][lifecycle].

The more transferable idea is the stale-operation fence. Agent identity alone is insufficient when an old asynchronous completion races a replacement with the same name. Regression tests hold a revival open, tombstone the agent, then confirm the stale replacement is disposed rather than reattached; another test confirms concurrent revival calls invoke the reviver once. [Race tests][lifecycle-test].

**Elara experiment:** extend existing persistent threads with an explicit dormant state and incarnation reference, if idle resource use justifies it. A supervisor owns live incarnations; the durable thread identity and inbox survive separately. Rust receives lifecycle events and can display dormant, waking, running, and terminal states without owning revival policy.

**Acceptance scenario:** deliver two messages during wakeup, kill that incarnation, and finish a stale initialization. No stale process attaches, no message is lost, and a deliberately terminal thread stays terminal. BEAM monitors help detect death; durable identity, mailbox recovery, and tombstones still require application rules.

## 3. Separate provider slots from agent lifetimes

The provider concurrency wrapper acquires a semaphore for one streaming request and releases it when production ends. Holding that slot across the parent agent’s entire lifetime would deadlock a parent waiting for children that need the same limited provider. The current provider-settings table wires this specifically to Ollama Cloud; it is a useful implemented mechanism, not evidence of a universal scheduler. [Provider limiter][provider-limit].

The generic semaphore supports resizing without replacing the object that owns outstanding permits, and removes aborted waiters. Its parallel-map helper stops admitting work after failure, signals siblings, then drains launched work before surfacing the error. [Semaphore and worker pool][parallel].

**Elara experiment:** distinguish budgets for provider requests, active agent turns, native jobs, and workspace mutations. A session process waiting for child results should not occupy a scarce provider slot. Expose admission waiting separately from model execution in the TUI.

**Acceptance scenario:** with a provider limit of one, a parent spawns a child and waits; the child still runs. Cancel a queued request and lower the limit while another is active; neither operation leaks capacity or admits too much work.

This is a strong BEAM fit because coordination can be explicit processes and messages. Cheap processes do not make provider quota, memory, or mutable workspace capacity unlimited.

The Rust boundary needs its own cancellation contract. Native blocking work receives a token that only observes cancellation when it checks `heartbeat()`; the N-API worker wrapper also catches panics at its foreign-function boundary. Elara should preserve its Port isolation and distinguish cancellation requested from native work actually stopped. Killing the BEAM owner alone is not evidence that an external command or native job has stopped. [Native implementation][native].

## 4. Programmable orchestration with a shared policy path

The eval `agent()` bridge returns a handle immediately, accepts a structured-output contract, and uses the same effective subagent-policy resolver as other spawn paths. Results expose parsed data alongside model, schema status, isolation, patch, and application metadata. Failures to apply isolated work become errors instead of a successful-looking schema object. Budget checks and plan-mode restrictions also occur at this bridge. [Eval agent bridge][eval-agent].

The important boundary is reuse of host-owned policy and lifecycle services from programmable orchestration. A generated script should not create a second, more permissive route to agents or tools. Test source includes shared spawn restrictions, depth limits, attenuated plan policy, concurrent handles, and structured output; the inspected cancellation test asserts that a waiting cell cannot settle while an underlying critical operation continues. [Policy tests][eval-policy], [handle tests][eval-handles], [cancellation ordering test][eval-cancel].

**Elara experiment:** expose a small capability API for spawn, await, select, cancellation, and typed results, routed through existing threads and effects. Begin with host-defined orchestration operations or an isolated interpreter. Arbitrary Elixir evaluation inside the main VM would confer far more authority than a capability API.

**Acceptance scenario:** a script starts two readers, awaits the first useful result, cancels the other, and emits only selected evidence. Every child remains visible in the recorder and TUI, shares normal policy enforcement, and cannot silently outlive its declared ownership scope.

## 5. Versioned edits and streaming previews, with honest commit semantics

The Rust edit session accumulates argument fragments and produces generation-tagged previews. At apply time it clears its read cache, stages edits, checks write policy, and delegates actual writes to a host `EditWriter`. The hashline engine associates edits with observed file content; matching content applies directly, drift can use recorded snapshots for recovery, and unresolved drift produces a diagnostic. Optional seen-line checks reject anchors the model has not observed. [Edit session][edit-session], [hashline recovery][hashline].

This supports a useful Elara division: Rust parses and previews a candidate; BEAM owns the effect decision, mutation receipt, and completion event. A preview is an advisory projection. The file must still be checked when committing.

**Acceptance scenario:** mutate the target externally after a preview, then commit. The harness either recomputes/revalidates safely or returns a conflict with current anchors. An incomplete preview cannot write anything.

Do not copy the word “atomic” without its boundary. A staging failure causes zero writes, as the Rust test asserts. But `Session.apply` subsequently writes files sequentially; a later writer failure leaves earlier writes in place. There is no automatic multi-file rollback here. [Apply implementation][edit-apply], [staging and re-read tests][edit-test]. Elara can improve this by retaining explicit per-file receipts and reporting partial application, rather than promising a filesystem transaction it does not implement.

## 6. Recoverable context offload and stable prompt prefixes

“Shake” mechanically replaces old tool text and large blocks with short references, preserving protected recent context and selected recovery/skill reads. Region detection is separate from artifact I/O. The session layer saves originals, creates placeholders, mutates history, persists the rewrite, and refreshes the live context. [Pure reducer layer][shake], [session orchestration][shake-host].

There is a material caveat: artifact saving can return `undefined` after failure, and the implementation continues with a bare placeholder. Thus recoverability is conditional. The inspected test verifies that, on the successful path, the artifact contains the original text and mixed image content remains intact. [Failure fallback][shake-fallback], [artifact test][shake-test].

**Elara experiment:** make artifact-backed context projections a lighter step before full handoff. Persist an immutable blob successfully before committing a projection that references it; retain source-event IDs and content digests. Treat prompt construction separately from the durable flight recorder and the user-visible transcript.

**Acceptance scenario:** inject an artifact-write failure and confirm the context stays intact. After a successful reduction and restart, a recovery read returns the original bytes. Recovery reads themselves must not immediately be elided again.

The append-only context manager adds another useful mechanism: fingerprint system/tool prefixes and detect the earliest changed message, preserving the unchanged prefix. Its source documents the need to invalidate cached digests after in-place rewrites. Elara’s immutable data can simplify coherence, but cache savings remain provider-dependent. [Stable-prefix implementation][prefix].

## 7. Prepare concurrently, publish capabilities deterministically

Extension imports are prepared concurrently; factory binding runs sequentially in original path order so registration precedence remains deterministic. `runExtensionFactory` checkpoints the pending provider-registration queue and restores it if initialization throws, including registrations removed by the failed extension. [Loader][loader].

The rollback test explicitly checks that an earlier successful provider registration survives a later extension that unregisters it and then fails. [Registration test][loader-test]. This is narrowly scoped rollback: it does not undo arbitrary filesystem or network effects performed by module import or factory code.

**Elara experiment:** build on generation leases and idle reload: prepare a candidate capability generation, validate collisions and schemas, then publish one coherent generation. Perform slow preparation outside the owner process, but retain a single publication decision. Keep old generation leases valid for in-flight effects and reject late completions targeting a replaced candidate.

**Acceptance scenario:** an extension adds one capability, removes another, then fails initialization. The active registry and TUI capability list remain on the prior generation. Restarting an initializer must not rerun arbitrary external writes.

## Most useful direction for Elara

The strongest near-term transfers are explicit prewalk boundaries, separate resource admission, versioned edit proposals, and durable artifact-backed context projection. Agent dormancy and capability publication are refinements of existing architectural strengths. Programmable orchestration is the larger exploratory branch.

These can be evaluated with a few concrete scripted scenarios and the existing recorder; they do not require resurrecting a dedicated benchmark program. The common BEAM advantage is making ownership, transitions, cancellation, and observation explicit while Rust handles bounded parsing/rendering/native work. Supervision alone supplies neither effect idempotency nor transaction rollback.

[repo]: https://github.com/can1357/oh-my-pi/tree/6d3bc569d16cd7351073eaa767caed51021befbb
[prewalk]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/src/session/prewalk.ts#L141-L213
[prewalk-plan]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/src/prompts/system/prewalk-plan.md#L1-L12
[prewalk-trigger]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/src/session/prewalk.ts#L28-L54
[prewalk-test]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/test/agent-session-prewalk.test.ts#L110-L211
[model-controls]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/src/session/model-controls.ts#L264-L292
[replay]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/ai/src/providers/transform-messages.ts#L807-L908
[lifecycle]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/src/registry/agent-lifecycle.ts#L243-L355
[lifecycle-test]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/test/registry/agent-lifecycle.test.ts#L229-L291
[provider-limit]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/src/task/provider-concurrency.ts#L1-L100
[parallel]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/src/task/parallel.ts#L26-L214
[native]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/crates/pi-natives/src/task.rs#L75-L203
[eval-agent]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/src/eval/agent-bridge.ts#L110-L227
[eval-policy]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/test/eval/agent-bridge-policy.test.ts#L191-L300
[eval-handles]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/test/eval/agent-bridge-policy.test.ts#L581-L728
[eval-cancel]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/test/eval/agent-bridge-policy.test.ts#L973-L1038
[edit-session]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/crates/pi-edit/src/session.rs#L35-L75
[hashline]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/crates/pi-edit/src/modes/hashline/patcher.rs#L111-L250
[edit-apply]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/crates/pi-edit/src/session.rs#L219-L260
[edit-test]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/crates/pi-edit/tests/session.rs#L61-L123
[shake]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/agent/src/compaction/shake.ts#L1-L75
[shake-host]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/src/session/session-maintenance.ts#L636-L704
[shake-fallback]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/src/session/session-maintenance.ts#L706-L729
[shake-test]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/test/shake.test.ts#L114-L172
[prefix]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/agent/src/append-only-context.ts#L168-L224
[loader]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/src/extensibility/extensions/loader.ts#L358-L485
[loader-test]: https://github.com/can1357/oh-my-pi/blob/6d3bc569d16cd7351073eaa767caed51021befbb/packages/coding-agent/test/extension-provider-registration-rollback.test.ts#L78-L136
