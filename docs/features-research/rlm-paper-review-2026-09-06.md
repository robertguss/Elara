# RLM experiments for Elara

Reviewed as of 2026-09-06. **My recommendation is an optional, bounded corpus-analysis job whose work and evidence Elara can inspect.** This is a research proposal, not a roadmap change. The useful BEAM experiment is controlling the lifetime, authority, and resource consumption of recursive computation.

## Primary paper evidence

**Recursive Language Models**, Alex L. Zhang, Tim Kraska, Omar Khattab, arXiv:2512.24601. Versions: v1 2025-12-31; v2 2026-01-28; latest v3 2026-05-11. [Version history](https://arxiv.org/abs/2512.24601v3)

The root manipulates externally stored input through a persistent Python REPL, programmatically forms subcalls, and assembles answers from stored results. Root observations stay bounded. The distinctive combination is programmable context and intermediate state; retrieval/compaction can coexist. V3 tests depths 0–3. [Algorithm 1, §3.2](https://arxiv.org/html/2512.24601v3#S2)

Table 1 uses GPT-5 roots/GPT-5-mini subcalls. At depth 1:

- CodeQA, 23K–4.2M tokens: accuracy 62.0% versus base 24.0%; average API cost $0.11 versus $0.13. Base runs sometimes overflow.
- OOLONG-Pairs, 20 synthetic tasks at 32K tokens: F1 58.0% versus CodeAct-with-subcalls 28.4%; cost $0.33 versus $1.11.

[Table 1; §3.1](https://arxiv.org/pdf/2512.24601v3#page=6)

Deeper recursion is not consistently better. Appendices B/E/F show protocol mistakes, repeated verification, and expensive latency/cost tails. These results do not establish coding-agent reliability. [Paper](https://arxiv.org/pdf/2512.24601v3#page=16)

## What the current author implementation adds

The [official repository](https://github.com/alexzhang13/rlm/tree/854e688fbba9d8f8989e3da9989812e4b6dfe270) was shallow-cloned at `854e688fbba9d8f8989e3da9989812e4b6dfe270` (2026-08-25). It is a later implementation snapshot, not proof of the paper's precise experimental environment.

`RLM` defaults to a local environment, maximum depth one, and thirty iterations. Budget, timeout, and token limits default to unset. Children inherit custom tools unless explicitly overridden. [Constructor](https://github.com/alexzhang13/rlm/blob/854e688fbba9d8f8989e3da9989812e4b6dfe270/rlm/core/rlm.py#L49-L180)

The local REPL executes Python in the host process and preserves variables between cells; its `NonIsolatedEnv` ancestry is explicit. Its answer dictionary separates completion signaling from the generated answer text. [Environment](https://github.com/alexzhang13/rlm/blob/854e688fbba9d8f8989e3da9989812e4b6dfe270/rlm/environments/local_repl.py#L147-L242), [execution](https://github.com/alexzhang13/rlm/blob/854e688fbba9d8f8989e3da9989812e4b6dfe270/rlm/environments/local_repl.py#L547-L583)

Budget checks occur after an iteration. `_subcall` computes remaining budget for recursive children, but its maximum-depth plain-LM branch occurs before those checks. Timeout checks happen at iteration boundaries. These are not evidence of strict global admission or hard preemption. [Completion loop and limits](https://github.com/alexzhang13/rlm/blob/854e688fbba9d8f8989e3da9989812e4b6dfe270/rlm/core/rlm.py#L326-L585), [subcall](https://github.com/alexzhang13/rlm/blob/854e688fbba9d8f8989e3da9989812e4b6dfe270/rlm/core/rlm.py#L706-L849)

My interpretation: adding a named child-agent tool alone misses the interesting interface. The root needs addressable data, operations over that data, and retained intermediate values that do not require repeatedly narrating everything into its conversation.

## Two followups worth reading

**Think, But Don't Overthink: Reproducing Recursive Language Models**, Daren Wang, [arXiv:2603.02615v1](https://arxiv.org/abs/2603.02615v1), 2026-03-03; no later version listed by the cutoff. It compares direct inference and depths one/two using DeepSeek v3.2 and Kimi K2 on S-NIAH and OOLONG. Its simple retrieval cases illustrate expensive, unnecessary decomposition. However, the experiments use single runs on small samples, and the appendix identifies answer-formatting effects in the direct baseline. Read it as a warning about routing and stopping, not a universal depth law. [Methods, limitations, Appendix A](https://arxiv.org/html/2603.02615v1)

**The Y-Combinator for LLMs: Solving Long-Context Rot with λ-Calculus**, Amartya Roy, Rasul Tutunov, Xiaotong Ji, Matthieu Zimmer, Haitham Bou-Ammar, [arXiv:2603.20105v1](https://arxiv.org/abs/2603.20105v1), 2026-03-20; no later version listed. Its λ-RLM uses a task-specific, deterministic plan of typed split/map/filter/reduce operations, with model inference at bounded leaves. The paper acknowledges that fixed operators can lose useful freedom in repository navigation. [Method and comparisons](https://arxiv.org/html/2603.20105v1#S3)

The formal claims deserve caution. The accuracy argument's transition from Equation 8's all-leaf product to a power-law expression appears inconsistent; this review does not validate those guarantees. Termination also depends on shrinking partitions and terminating leaf calls. Harvest the explicit control structure, while independently specifying Elara's own resource and completion contracts. [Assumptions and Theorems 1–3](https://arxiv.org/html/2603.20105v1#S4)

These are focused followup readings, not an exhaustive literature survey. RLMOpt is covered by the accompanying GEPA investigation.

## Proposed Elara adaptation

Everything below is our design hypothesis. Elara already has persistent threads, a pure session reducer, durable communication, context handoff, a flight recorder, and Rust execution/TUI boundaries. The [current source inventory](harness-ideas-beam-2026-09-06.md#what-elara-already-has) establishes those starting points. The proposed job would build on that infrastructure and remain separately budgeted from ordinary conversation.

### 1. Give the computation an immutable corpus

Start with one question that needs coverage across many files: “Which modules can retry an external effect, and what evidence shows their idempotency assumptions?” A corpus manifest should identify exact file contents, instruction scope, content digests, and stable excerpt coordinates. The job receives handles and bounded reads. Root and leaf models receive the task and selected evidence; repository prose remains evidence rather than authority.

Intermediate outputs should be typed records such as `{claim, source_spans, unresolved_dependencies}`, stored as artifacts. The reducer consumes small references and completion facts. Large corpus values should not be copied through every process mailbox or Rust UI patch.

This makes a useful comparison possible: ordinary search/read, deterministic corpus partitioning, and one level of adaptive subcalls can all operate against the same inputs. An isolated answer is insufficient if its evidence omits relevant modules.

### 2. Make resource admission a tree-wide responsibility

Use one supervised job owner to track the task graph, active attempts, and aggregate budget. Each provider request must reserve capacity before dispatch, whether issued by a root, leaf, reducer, verification pass, or error recovery. Reconcile actual usage afterward; unknown provider cost is an unresolved liability, not zero spending.

Bound total requests, input/output tokens, recursion depth, concurrent requests, wall time, intermediate storage, and returned bytes. A parent waiting on children should release its provider slot. Reserve from one shared balance so simultaneous siblings cannot each spend the same remaining allowance. Conservative token limits and provider output caps can bound requested work; actual billing uncertainty must stay visible.

Start with one allowed recursive level and a small fan-out. Depth should be an explicit admission decision, not something a child raises through generated instructions. A simple lookup can finish through existing search/read without entering this job at all.

### 3. Keep authority in Elixir and computation constrained

The first experiment can use a small declarative operator set interpreted by trusted Elixir code: partition a manifest, request bounded semantic extraction, and merge evidence records. Models propose operation values; they do not define new runtime functions. This gives the pure reducer meaningful transitions to record.

If free-form Python becomes necessary, run it in an explicitly isolated external environment managed through a Rust protocol. Provide read-only corpus access, bounded scratch storage, and brokered inference requests. Keep credentials and network access outside that environment. Every child receives a smaller or equal capability set, with no implicit inheritance of session tools.

The existing Rust command Port supplies a useful transport/process-control boundary; it is not automatically an OS sandbox. Arbitrary generated Elixir must never be evaluated inside Elara's authority VM. BEAM supervision contains process failures, not hostile native code or unrestricted file/network effects.

### 4. Give cancellation and recovery observable semantics

Persist accepted job transitions, corpus identity, completed artifact references, and attempt identities. On recovery, restore those facts explicitly. Restarting an actor is not enough to recover its lost computation. Already completed evidence can be reused; an interrupted provider request remains indeterminate until reconciled or deliberately retried.

Monitor workers and fence results by job/attempt identity. Cancel stops further admission, interrupts owned execution, and rejects late completions. It cannot undo billed inference. Keep the first experiment read-only; Elara's receipt-backed `write` does not make future shell, plugin, or remote effects safe to replay.

In the Rust TUI, show the task tree, the reason each node is waiting, spent/reserved budget, evidence coverage, and unresolved nodes. Coalesce progress updates. A process-per-operation display would be noisy; the useful view is the logical computation and its causal events.

### 5. Use small acceptance scenarios to decide whether to continue

- **Coverage:** include a cross-module retry path and a contradictory leaf answer. The final output retains both source trails or reports uncertainty; it cannot silently merge disagreement into confidence.
- **Budget:** siblings race for the final request allowance. Only admissible work starts, and exhausted verification returns a partial result with explicit gaps.
- **Interruption:** cancel while leaves run, then resume from saved state. No late result changes the canceled attempt; completed artifacts remain inspectable.
- **Input drift:** change a source file between analysis and presentation. The result identifies its original corpus and cannot claim to describe the new file.
- **Utility:** compare one simple lookup and one aggregation question with today's search/read workflow. Record evidence completeness, owner-visible latency, and total inference use. Keep the simpler path when recursion adds no value.

The recorder and scripted provider can exercise lifecycle and accounting contracts. Evidence quality, coverage, and actual inference use require real task feedback; canned responses cannot establish an RLM benefit. These are bounded acceptance exercises, not a request to start the owner's deferred evaluation program.

## Inspection record

Read the full RLM v3 PDF, including methods, prompts, negative results, trajectories, and cost appendices; cross-checked its main results table visually. Followups were read through their primary HTML, with focused method/limitation checks. Inspected the author repository's constructor, completion/budget logic, recursive dispatch, and local execution implementation. Downloaded artifacts are under `/tmp/elara-paper-research-2026-09-06/`.

No downloaded programs or model experiments were executed; dependencies were not installed. Reported results are the authors' results. Only this research note was added for this assignment.
