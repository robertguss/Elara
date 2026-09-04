# Amp threads: reference research for Elara

Researched 2026-09-04. This is a research note, not an implementation plan or a change to ROADMAP.md. Sources are official Amp documentation and dated announcements. Documentation was inspected on the research date; undated pages do not establish feature introduction dates. Product behavior was not tested.

## What Amp calls a thread

A thread is a persistent conversation and unit of work containing prompts, replies, tool calls, and file-change context. Its identity is separate from its execution location: the same thread can be viewed through several clients while running locally, on a runner, or in an orb. Threads can be referenced by URL/ID and found for reuse of relevant context. These are product conversations, not operating-system threads. [Threads](https://ampcode.com/docs/threads)

## Two distinct forms of delegation

**Specialist subagents** perform focused work in their own context windows. Current documentation says they receive instructions and selected context rather than the complete parent conversation; they cannot communicate with one another or receive mid-task guidance, and the parent gets a final summary rather than monitoring their detailed work. This is suitable for bounded searches, reviews, and other context-heavy subtasks. [Modes & Models](https://ampcode.com/docs/models-and-subagents)

**Agent to Agent** is the closer match for persistent communicating conversations. Amp documents starting another thread, continuing the original work, sending instructions, and having results reported back. An orb child gets a separate conversation, context window, working copy, and machine. Agents can operate across projects or runners. File transfer is explicit: messages do not automatically carry files, commits, or uncommitted edits. The guide recommends delegation for independent work and keeping tightly coupled edits in one thread. [Agent to Agent](https://ampcode.com/docs/orbs/agent-to-agent)

The public plugin API corroborates thread-level control. Its cross-thread example obtains a handle with `amp.threads.get(threadID)` and sends a message with `appendUserMessage(..., { steer: true })`; the prose describes steering as preferring the message when it queues behind active work. A custom-agent example uses `parentThreadID` to retain its relationship to the invoking conversation. Execution options distinguish local, orb, and runner locations. These are documented surfaces, not evidence for precise internal delivery or restart guarantees. [Plugin API](https://ampcode.com/docs/plugin-api)

Therefore, “Amp subagents cannot communicate” and “Amp agents can communicate across threads” are compatible statements about different product mechanisms. Elara should distinguish the two clearly in terminology and lifecycle behavior.

## Handoff and compaction: the references conflict

- **2025-10-23:** Amp announced replacing compaction with handoff. The user supplied a next goal, and Amp extracted a prompt plus relevant files into a new thread's editable draft. [Handoff (No More Compaction)](https://ampcode.com/news/handoff)
- **2026-05-06:** The Neo announcement reversed that decision: automatic compaction at 90% context use and removal of handoff, with thread references retained. This is an explicit dated change, not a reason to adopt the same default in Elara. [Amp, Rebuilt](https://ampcode.com/news/neo)
- **2026-07-02:** Amp described a revised thread reader that searches original messages, checks subsequent revisions or reversions, and uses compaction summaries for orientation rather than as authoritative evidence. It can retrieve from the current thread as well as other threads. [Read Bigger Threads](https://ampcode.com/news/read-bigger-threads)
- **Current undated documentation:** The Threads page still suggests asking for a handoff, and the context-management guide still describes handoff as available. This conflicts with the Neo announcement. It could reflect stale documentation or subsequent changes; these sources alone cannot establish which. Do not promise a currently available universal Amp handoff command without testing the relevant client/version. [Threads](https://ampcode.com/docs/threads), [Context Management](https://ampcode.com/guides/context-management)

The reusable ideas are durable source conversations, selective retrieval, explicit continuation relationships, and a reviewable next-task prompt. Whether to compact automatically is a separate product choice.

## Elara baseline from the accompanying code review

The parent review supplied the following source findings; this research subtask did not independently inspect or test those modules:

- `lib/elara/coordinator.ex:55` already configures a `DynamicSupervisor`, concurrency limits (default three), and budgets. The coordinator starts real sessions, monitors them, and asks asynchronously through its engine.
- The coordinator engine's child options disable persistence and plugins; coding children receive temporary detached worktrees at HEAD. Results are truncated to a configured bound, and coordinator termination stops children and removes worktrees.
- `lib/elara/tool.ex:66` exposes read/write/edit/bash built-ins, not model-callable thread spawning or messaging. `docs/detached-and-remote.md` distinguishes the embedded VM, which ends with the TUI, from a long-lived server that supports detachment.
- `lib/elara/session/store.ex:177` already persists a source session reference as `parent_session` when cloning. Some fork lineage therefore exists; durable coordination is still a separate requirement.

This is a useful batch-execution foundation. It does not yet establish durable, addressable, communicating child conversations.

## Recommendations for a local Elara implementation

These are proposed design implications, not claims about Amp internals or verified Elara capabilities. They require reconciliation with Elara's current code and roadmap before implementation.

1. Give each conversation a stable ID and durable transcript. Treat an active BEAM process as its runtime owner, not its identity. A conversation must remain addressable when idle or after restart.
2. Represent parent/child delegation, handoff continuation, and cross-thread references as different relationships. Finishing a child task should preserve its conversation and evidence for later inspection.
3. Use independent supervised session processes for concurrent work, with asynchronous provider/tool execution so one slow call cannot prevent queue, cancel, or status handling. Process isolation does not isolate filesystem edits or external command effects.
4. Route messages through explicit application delivery semantics: sender/recipient IDs, message IDs, queued/delivered status, and defined safe delivery boundaries. Persist delivery intent and deduplicate recovery. A BEAM mailbox alone is not a durable message queue, and a restarted process must not silently replay external edits or commands.
5. Reuse the user's requested queue and steer controls for communication. Child completion can appear as an inspectable notification/message; whether it immediately wakes an idle parent or interrupts ongoing work must be a deliberate policy. A completion report should identify changed files, verification evidence, failures, and remaining work.
6. Start local. Offer isolated Git worktrees for independent code-writing threads, with an explicit way to transfer selected uncommitted context and integrate results. Read-only research may share a checkout. Do not treat parallel processes as protection against concurrent writes to the same files.
7. Show children and their states in the TUI, with access to the child's transcript and provider-exposed reasoning summaries. Keep orchestration owned by Elixir so switching layouts cannot cancel or duplicate work.
8. Keep handoff independent of delegation: warn about approaching context limits,
   prepare a durable continuation record, link the successor to its source, and
   retain access to original evidence. Subsequent owner decisions settled the
   behavior: automatically create the handoff and continue without approval;
   explicit stop still takes precedence. Automatic compaction is not an implicit
   fallback.

The owner subsequently confirmed both persistent communicating threads and the
TUI as daily-driver prerequisites, and delegated sequencing. The reconciled
scope, workspace rules, recovery requirements, and acceptance criteria are in
[ROADMAP.md](../ROADMAP.md), including code-writing children. These are settled
Elara product decisions, not assertions about Amp's behavior.
