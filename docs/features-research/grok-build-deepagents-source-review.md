# Harness source review: Grok Build and Deep Agents

Research date: September 6, 2026. Purpose: identify runtime experiments for Elara's Elixir authority and Rust presentation/execution boundaries. These are proposals for an experimental harness, not an implementation specification or a change to `ROADMAP.md`.

## Sources and evidence limits

Both requested repositories were shallow-cloned and inspected locally. No dependencies were installed and no downloaded programs, tests, or credentialed agent sessions were executed. “Implemented” below means an inspected implementation path; test citations establish intended coverage, not passing results from this investigation. Recommendations are adaptations, not claims that Elara lacks the corresponding foundation.

| Repository | Inspected commit | Local checkout |
| --- | --- | --- |
| `xai-org/grok-build` | `72a61251fcffb464bcc687aeb5a998e5a98ec0c9` | `/tmp/elara-harness-research-2026-09-06/grok-build` |
| `langchain-ai/deepagents` | `07d2952d346d81d06bd181db8c560a77f2b51bc8` | `/tmp/elara-harness-research-2026-09-06/deepagents` |

Codebase-memory and CodeScent tools were not exposed in this research session. Git inventories, ast-grep structural searches/outlines, and bounded source reads provided the fallback. All external source links below pin these commits.

## Grok Build

### What is actually published

This checkout contains substantial Rust agent-runtime, workspace, tool, and TUI source. It is not a binary-only distribution or just an installer repository. The README identifies the shell/runtime and pager/TUI crates separately and describes periodic synchronization from the vendor monorepo. `SOURCE_REV` records monorepo revision `a549186d9d39311f2d3ee4208db62af8c65aa476`. This establishes the inspected source snapshot, not equivalence to every released binary. [Repository overview][g-overview], [monorepo revision][g-revision]

The existing [Grok TUI research](../grok-build-tui-research.md) covers interaction contracts. The more useful additions here concern speculative work, resource ownership, and recovery boundaries.

### 1. Compute future context while the foreground session continues

Grok implements speculative first-pass compaction. Near the configured threshold, the turn loop starts a background task if the feature is active, a result is not already cached, and an in-flight guard admits it. The worker summarizes an older conversation prefix and records its length, fingerprint, model identity, and latency. At actual compaction, the runtime validates that prefix against the current conversation before combining its note with the live tail. Changed history or model identity causes fallback to the single-pass path; an empty or degenerate second-pass summary also falls back. [Launch site][g-prefire-launch], [worker and validation][g-prefire]

**Elara experiment:** extend the existing handoff machinery with an advisory process that prepares a candidate handoff index or summary from an immutable session prefix. Give each candidate a source boundary, content digest, provider/model identity, and capability epoch. Only the session actor may accept it. A process finishing successfully should mean “candidate available,” with acceptance recorded separately.

This gives the BEAM useful concurrent work beyond more coding agents: context preparation, evidence indexing, and retrieval warming can operate while the main turn runs. Rust can show pending, accepted, and discarded preparations from Elixir events. The cost is speculative model spend and another possible lossy summarization step; reduced waiting must not be assumed from concurrency alone.

**Acceptance scenario:** start preparation, change the source prefix or hand off the session, then deliver the old result. It must be discarded without modifying the active context. Grok's fingerprint tests demonstrate a small, concrete starting point. [Test source][g-prefire-tests]

### 2. Make child admission, cancellation, and resource release distinct

Grok gives initial child admission an explicit race policy: cancellation takes precedence over readiness, readiness over attempt completion, and completion over the admission deadline. Its tests exercise simultaneous readiness/completion and cancellation/readiness. Cleanup of an unpromoted child sends cancellation and shutdown, waits for its actor thread to exit, and preserves the worktree and workspace binding when exit cannot be confirmed within the bound. [Admission implementation][g-admission], [race tests][g-admission-tests], [cleanup implementation][g-child-cleanup]

Background completion also has a specific wake gate: cancelled or explicitly killed children do not wake the parent, nor do results already delivered to a waiter. The code calls out the race where a foreground child becomes backgrounded immediately before cancellation arrives. [Wake decision][g-wake]

**Elara experiment:** build on persistent supervised threads with a visible ownership state machine: requested, admitted, running, stopping, stopped, and retained resources awaiting reconciliation. Use process monitors for actor evidence and separate execution-guardian evidence for operating-system descendants. Record which observer established each terminal fact. A BEAM process exit must not be interpreted as proof that every external command or remote operation stopped.

**Acceptance scenario:** cancel while a child is being admitted; delay its shutdown acknowledgment and deliver a late completion. There must be no unwanted parent wake, no premature worktree deletion, and no second allocation that reuses resources whose owner remains uncertain. Rust should expose retained resources as actionable state.

### 3. Treat rewind as several recovery domains

Grok's workspace rewind distinguishes filesystem, Git, and hunk-tracker state. It can report or log partial restoration; failed filesystem restoration retains checkpoint domains for retry. Its persisted checkpoint bundle contains filesystem snapshots and optional hunk data. Both durable checkpoint storage and hunk rewind are implemented behind flags that default off in this snapshot. The store serializes persistence against truncation, bounds retention, and writes a flushed temporary file before rename. [Rewind domains][g-rewind], [flags and bundle][g-rewind-flags], [retention][g-checkpoint-store], [write path][g-checkpoint-write]

**Elara experiment:** connect conversational branching and recorded effects to an explicit workspace-recovery plan. For each effect, report whether it can be replayed read-only, reversed with a precondition, retained, or requires reconciliation. Extend receipt coverage deliberately before making broad restoration promises.

A replayed reducer and a restored workspace are different achievements. External network actions and arbitrary shell effects do not become reversible because the session process can restart. The attractive experiment is a Rust inspector showing a conversational branch alongside its filesystem/effect branch and the precise recovery status of each domain.

**Acceptance scenario:** restore a branch after an independent edit to a touched file. Preserve the independent change or surface a conflict, retain recovery evidence, and report any partial result. This is a later experiment because it expands mutation semantics considerably; Grok's default-off domains reinforce the need to distinguish code presence from default behavior.

## Deep Agents

### What is actually assembled

This repository contains both the Python Deep Agents library and the separate Deep Agents Code terminal application. The library assembles filesystem tools, subagents, summarization, tool-call repair, optional skills/memory, and optional human-intervention middleware around LangChain's `create_agent`. It passes an optional checkpointer and store through to that graph runtime. This is compositional harness source, not an independent implementation of all underlying LangGraph persistence guarantees. [Assembly and runtime boundary][d-assembly], [optional persistence parameters][d-persistence]

The highest-value comparison is how request views, capabilities, and lifecycle decisions are represented explicitly.

### 4. Separate retained evidence from the model's current view

Normal Deep Agents summarization records a summary message and absolute cutoff index, then projects the next model request as that summary plus the retained tail. Chained summarization translates effective-view offsets back to raw-state offsets. It does not simply replace all old state messages with a summary. However, the overflow-recovery path can emit replacement tail messages into state; the distinction is not absolute immutability. [Projection][d-projection], [request path and overflow updates][d-summarization]

Large tool-output eviction is another, separate mechanism: it saves text to a backend and substitutes a numbered head/tail preview and retrieval path. Replacement messages preserve identity, artifact, status, metadata, and non-text blocks. A failed tool-output write retains the original message. By contrast, conversation-history offload failure warns and still allows summarization without a recovery-file path. An older test name says “aborts,” but its assertions explicitly confirm this latter behavior. [Eviction helper][d-eviction], [failure test body][d-offload-failure]

**Elara experiment:** treat context as a versioned materialized view over retained evidence. Compare extractive handoff, summarized prefix, recent-tool eviction, and task-specific retrieval without changing which log is authoritative. Large artifacts can live outside process state, with messages carrying durable references and bounded previews. Require a verified evidence reference before claiming recoverability.

**Acceptance scenario:** produce a large tool result, compact twice, and request a middle section from the original output. The bytes, call identity, and exit status must remain available. Then fail artifact persistence and verify that no nonexistent recovery pointer is advertised. The useful measurement is the behavior of this scenario, not a new general benchmark program.

### 5. Mount resources with explicit backend semantics

`CompositeBackend` uses longest-prefix routing for file operations and strips the route before dispatch. This allows an artifact or memory namespace to use a different backend from the workspace. Shell execution is deliberately different: it always uses the default backend and requires execution support there. File routing does not make every virtual path available to a shell. Tests demonstrate large-output routing to a selected store and shell dispatch through the default sandbox. [Routing][d-routing], [execution boundary][d-execute], [test source][d-routing-tests]

**Elara experiment:** define a small artifact/resource behavior with supervised implementations for workspace files, immutable tool outputs, session evidence, and a remote artifact store. Attach backend identity and revision to a resource handle. Keep retention, consistency, mutability, and execution availability explicit instead of pretending every backend has POSIX semantics.

This could extend Elara's remote workers and capability generations: a session keeps logical evidence references while a backend process reconnects or a new implementation is activated. Rust renders resource provenance and availability; it does not select the authoritative backend.

**Acceptance scenario:** stop and restart the artifact-serving process while a session remains active. Old evidence handles must resolve to the same content, and a shell command mentioning a virtual artifact path must receive an accurate unsupported-path result unless that path was actually materialized.

### 6. Make child context and result contracts explicit

Deep Agents supports isolated children, forked children, and supplied compiled graphs. Isolated calls begin with the delegated task message and filter parent-private channels; forked calls inherit the effective parent conversation after applying its compaction event. Child results normally become one final tool message, with structured responses serialized when supplied. Other permitted state updates can also return, so “isolated context” is not equivalent to no shared state. Tests target private-state leakage between siblings. [Context construction][d-child-context], [result transfer][d-child-results], [private-state test][d-child-tests]

There is also remote asynchronous delegation: tools create a remote thread and run, store their IDs, and offer check/update/cancel operations. The shown cancellation implementation marks the tracked task cancelled after the remote cancel API call returns; it does not itself prove that external side effects have ceased. [Remote launch][d-remote-launch], [remote cancellation][d-remote-cancel]

**Elara experiment:** add an explicit context contract to the existing child-thread model: fresh task, selected evidence slice, or forked context; add a result contract containing findings, evidence references, changed artifacts, and unresolved uncertainty. Keep task identity independent from the current process identifier and provider context. The parent imports selected evidence, not an accidental union of every child's private state.

**Acceptance scenario:** run sibling research children with different context grants and structured outputs, restart one, and confirm that its private data does not appear in the other. A late result from an older attempt must be identifiable without replacing the current attempt's result.

### 7. Version the assembled harness policy

Deep Agents replaces custom middleware by name while preserving its stack position. It protects required filesystem/subagent scaffolding against profile exclusions, validates unmatched exclusions, places memory around prompt-caching concerns, and applies tool exclusions after tool-injecting custom middleware. The assembly source makes clear that order is part of behavior, not an implementation detail. [Replacement and required components][d-middleware], [ordering and exclusions][d-assembly]

**Elara experiment:** extend capability epochs with a compact, inspectable policy manifest. Pin a provider request and each admitted effect to the policy version that determined its tools, context projection, and constraints. Use explicit phase contracts for discovery, request shaping, admission, and result observation. An experiment should replace a policy component without silently changing unrelated session behavior.

This fits the existing generation-lease direction better than a large mutable middleware chain. Pure policy functions can remain in the deterministic reducer boundary; external work runs under supervision. Do not manufacture a GenServer for a transformation that only needs a function.

**Acceptance scenario:** activate a changed policy while an older tool call is running. Its leased execution semantics remain identifiable, new calls use the new policy, and replay can explain both decisions. Rust should display the effective policy and the source of a decision, not merely a settings toggle.

### 8. Run lifecycle observers concurrently, commit decisions deterministically

Deep Agents Code's hook engine captures an immutable hook snapshot, executes matching handlers concurrently with independent timeouts, and reduces their results in configuration order. A test intentionally reverses completion order and checks the stable result. The reducer assigns permission precedence and caps repeated stop continuations at eight. [Engine][d-hook-engine], [ordering test][d-hook-tests], [permission ranking and limit][d-hook-rank], [continuation bound][d-hook-reducer]

The server hook protocol also derives stable invocation identity from thread, snapshot, prompt, event, and logical event identity. Resumption can reuse an answered invocation; tests cover replay and a later turn reusing a tool-call ID. Snapshot and invocation mismatches are distinct from malformed response shapes, which currently degrade to a neutral decision. [Identity and resume path][d-hook-resume], [replay tests][d-hook-replay-tests]

Grok provides a useful contrasting policy: its pre-tool gates execute sequentially, explicit denial short-circuits, and ordinary hook failures fail open. Its runner binds hooks to a process scope and timeout. Neither repository should be read as providing a universal security boundary merely by exposing hooks. [Grok gate semantics][g-hooks], [hook process lifetime][g-hook-runner]

**Elara experiment:** use supervised tasks for independent observations and collect typed results into one deterministic decision reducer. Record invocation ID, capability epoch, deadline, handler outcomes, and final decision. Separate advisory observers from required authorization decisions; define failure handling for each category. Hook outputs that affect authority become recorded inputs rather than invisible callbacks.

**Acceptance scenario:** reverse handler completion order, crash one observer, reconnect the TUI, and replay a delivered decision. The committed decision must remain explainable, an already fulfilled invocation must not run again accidentally, and a stale epoch's response must not authorize a new operation. Concurrent handler side effects remain nondeterministic unless independently constrained; stable result reduction alone does not solve that.

## Suggested experiment order

Start with context projections and durable artifact handles: they exploit existing evidence and handoff machinery with observable benefits. Add one speculative advisory worker, including stale-result rejection, before expanding parallel activity. Then prototype deterministic lifecycle decisions pinned to a capability epoch. Treat broader workspace rewind as a separate later investigation.

The architectural opportunity across both repositories is a session that survives while its context views, helper processes, clients, and policy generations evolve. Elara can explore that with authoritative Elixir state and Rust views showing the real lifecycle. Adding more agents or more widgets is not sufficient evidence that the runtime has improved the harness.

[g-overview]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/README.md#L31-L112
[g-revision]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/SOURCE_REV#L1
[g-prefire-launch]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-shell/src/session/acp_session_impl/turn.rs#L2513-L2524
[g-prefire]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-shell/src/session/compaction.rs#L242-L401
[g-prefire-tests]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-shell/src/session/compaction_two_pass_prefire_helper_tests.rs#L4-L38
[g-admission]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-shell/src/agent/subagent/attempt_runner.rs#L6-L39
[g-admission-tests]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-shell/src/agent/subagent/attempt_runner.rs#L359-L388
[g-child-cleanup]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-shell/src/agent/subagent/mod.rs#L1858-L1903
[g-wake]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-shell/src/agent/subagent/spawn.rs#L360-L400
[g-rewind]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-workspace/src/session/checkpoint.rs#L367-L447
[g-rewind-flags]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-workspace/src/session/checkpoint.rs#L78-L102
[g-checkpoint-store]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-workspace/src/session/checkpoint_store.rs#L133-L189
[g-checkpoint-write]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-workspace/src/session/checkpoint_store.rs#L272-L296
[g-hooks]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-hooks/src/dispatcher.rs#L78-L334
[g-hook-runner]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-hooks/src/runner/command.rs#L170-L241
[d-assembly]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/deepagents/graph.py#L861-L978
[d-persistence]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/deepagents/graph.py#L553-L563
[d-projection]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/deepagents/middleware/summarization.py#L767-L848
[d-summarization]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/deepagents/middleware/summarization.py#L1345-L1484
[d-eviction]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/deepagents/middleware/_message_eviction.py#L25-L162
[d-offload-failure]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/tests/unit_tests/middleware/test_summarization_middleware.py#L1215-L1243
[d-routing]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/deepagents/backends/composite.py#L195-L291
[d-execute]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/deepagents/backends/composite.py#L814-L850
[d-routing-tests]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/tests/unit_tests/backends/test_composite_backend.py#L615-L708
[d-child-context]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/deepagents/middleware/subagents.py#L743-L794
[d-child-results]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/deepagents/middleware/subagents.py#L677-L714
[d-child-tests]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/tests/unit_tests/test_subagents.py#L332-L415
[d-remote-launch]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/deepagents/middleware/async_subagents.py#L245-L339
[d-remote-cancel]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/deepagents/middleware/async_subagents.py#L580-L656
[d-middleware]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/deepagents/deepagents/graph.py#L204-L255
[d-hook-engine]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/code/deepagents_code/hooks/engine.py#L33-L112
[d-hook-tests]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/code/tests/unit_tests/hooks/test_engine.py#L1019-L1100
[d-hook-rank]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/code/deepagents_code/hooks/reducer.py#L56-L57
[d-hook-reducer]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/code/deepagents_code/hooks/reducer.py#L267-L287
[d-hook-resume]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/code/deepagents_code/hooks/server_middleware.py#L893-L1106
[d-hook-replay-tests]: https://github.com/langchain-ai/deepagents/blob/07d2952d346d81d06bd181db8c560a77f2b51bc8/libs/code/tests/unit_tests/hooks/test_server_lifecycle.py#L640-L724
