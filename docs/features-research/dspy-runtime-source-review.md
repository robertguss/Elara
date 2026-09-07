# DSPy runtime mechanisms for Elara

Research date: 2026-09-06. Source inspected in the shared shallow clone at [`f70d08a5b934400d236078143e3704934f2d5dd1`](https://github.com/stanfordnlp/dspy/tree/f70d08a5b934400d236078143e3704934f2d5dd1), dated September 5. This is a development snapshot; the package's `3.3.1` version does not establish that every inspected behavior shipped in that release.

**My strongest recommendation is a small interpreter-backed analysis operation with an explicit lifetime and typed outcomes.** DSPy's interfaces provide useful examples; Elara's experiment should keep scheduling, authority, admission, and durable state in its existing BEAM owner. The proposals below are our designs, not features DSPy demonstrates or commitments to change Elara's roadmap.

## Five mechanisms and their boundaries

### 1. RLM separates an invocation's computation from its conversation

Experimental `dspy.RLM` builds action and fallback-extraction predictors. Its defaults are twenty iterations, fifty sub-LM calls, and ten thousand displayed output characters. `llm_query` invokes an LM directly; `llm_query_batched` reserves the whole batch against a locked invocation counter before dispatching up to eight worker threads, preserving result order. This implementation does not automatically construct nested child RLMs. [Construction](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/predict/rlm.py#L115-L180), [subcalls](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/predict/rlm.py#L261-L325)

Factory-created interpreters are closed in `finally`; caller-owned interpreters remain open for sequential reuse. Each invocation receives fresh call-counting tools. `SUBMIT` results are checked against output fields; repairable execution/type errors return to the loop, while interpreter failures propagate. Root action and fallback requests are outside `max_llm_calls`; this is not a total token, cost, or deadline budget. Even `aforward` calls interpreter execution synchronously. [Ownership](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/predict/rlm.py#L486-L562), [results and loops](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/predict/rlm.py#L564-L825)

The previously inspected author implementation can spawn child RLMs with separate environments. Its default local REPL executes inside the host Python process. DSPy's default instead delegates to Deno/Pyodide. These are substantive implementation differences; the shared RLM name does not imply equivalent execution or isolation. [Author recursion](https://github.com/alexzhang13/rlm/blob/854e688fbba9d8f8989e3da9989812e4b6dfe270/rlm/core/rlm.py#L706-L849), [author local execution](https://github.com/alexzhang13/rlm/blob/854e688fbba9d8f8989e3da9989812e4b6dfe270/rlm/environments/local_repl.py#L547-L583)

### 2. A lost interpreter is a different outcome from bad generated code

The `CodeInterpreter` protocol distinguishes repairable `CodeExecutionError`, terminal interpreter failure, and `FinalOutput`. It specifies start/execute/shutdown and rejects silent replacement of a dead stateful session. [Protocol](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/primitives/code_interpreter.py#L18-L154)

`PythonInterpreter` enforces single-thread ownership and rejects tool callbacks reentering the same interpreter. Request IDs bind responses to requests; process death or protocol mismatch ends the session. Default Deno permissions constrain host access; explicit read/write paths, environment variables, network destinations, and host tools expand it. Execution reads and shutdown waits have no per-execution timeout here. A custom Deno command also changes the assumptions. [Permissions and ownership](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/primitives/python_interpreter.py#L243-L393), [execution and shutdown](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/primitives/python_interpreter.py#L768-L896)

The runner revokes its startup cache-read permission after loading Pyodide. File writeback is a separate notification whose errors are suppressed; successful Python execution therefore does not prove successful host-file persistence. [Runner startup](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/primitives/runner.js#L143-L155), [writeback](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/primitives/runner.js#L252-L264)

Callbacks expose interpreter startup, execution, host-tool invocation, and shutdown, preserving parent call identity and reporting exceptions on completion. Callback failures are logged rather than made authoritative execution failures. This is observability plumbing, not a durable workflow log. [Callbacks](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/utils/callback.py#L264-L400)

### 3. Structured completion reveals why an agent stopped

Experimental `ReActV2` uses `ToolCalls`, structured history, a typed `submit` tool, and `termination_reason`. Original inputs enter history once; continuation can reuse that history. An exhausted loop, parse/context error, or empty action list triggers a further forced-submit model request. Failure can return history and a reason without the requested output fields. [Loop](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/predict/react_v2.py#L28-L215)

Its tool batch runs sequentially. A successful `submit` does not stop later calls in that batch, and “parallel tool calls” in provider configuration does not mean parallel tool execution. These details matter before using final-output tools around mutations. [Batch execution](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/predict/react_v2.py#L139-L159)

Older `ReAct` instead runs one selected tool per step, then uses a separate extraction predictor. Context overflow retries delete the oldest four trajectory fields in place; the returned trajectory also loses that step. [Older loop and truncation](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/predict/react.py#L95-L199)

### 4. Keep full evidence separate from prompt presentation

`REPLHistory.append` returns a new container, and entries retain full reasoning/code/output. Formatting selects head/tail output excerpts with true lengths and omitted-character counts. `REPLVariable` similarly supplies type, description, constraints, length, and a preview. This is a request projection, not an interpreter-memory or stored-history cap; the number of entries still grows. [REPL types](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/primitives/repl_types.py#L27-L162)

For Elara, the interesting distinction is explicit omission with recoverable evidence. A compact model view should not be mistaken for a complete accounting of everything stored or executed.

### 5. Concurrency controls have different scopes

`ParallelExecutor` limits worker threads but submits all input items. Near the tail, its timeout can submit an additional attempt for a slow item. It accepts the first stored outcome and shuts the executor down with `wait=False`; original work may continue. Cancellation uses a cooperative event checked before work, not interruption of arbitrary running functions. This is speculative repetition, not a strict deadline or an effect-safe retry protocol. [Executor](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/utils/parallelizer.py#L49-L230)

`asyncify` propagates configuration into a capacity-limited worker thread but explicitly uses `abandon_on_cancel=True`. Abandoning the caller does not establish termination of the underlying computation. [Async wrapper](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/utils/asyncify.py#L13-L65)

Async streaming uses a sixteen-item channel and distinguishes chunks/status from final `Prediction`. The synchronous bridge instead drains into an unbounded `Queue` in a daemon thread, with no explicit early-consumer-stop cleanup. Boundedness at one adapter does not extend automatically through the next. [Streaming and bridge](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/streaming/streamify.py#L161-L266)

## Three proposed Elara experiments

### A. A supervised interpreter operation with explicit session loss

Build one read-only corpus-analysis operation over immutable artifact handles. Give it a BEAM owner, an interpreter incarnation, an invocation ID, and a fixed capability set. A Rust-managed worker hosts a separately isolated interpreter; generated Elixir never runs inside the authority VM. A transport Port alone does not provide the isolation policy.

Model the outcomes as ordinary output, typed final output, repairable code failure, lost interpreter, cancellation, and budget exhaustion. A crash must not silently substitute an empty interpreter under an old identity. Resumption either restores a supported checkpoint or starts a new incarnation with an explicit account of lost intermediate state.

Add causal events for startup, code execution, brokered tool calls, and shutdown to Elara's existing recorder/UI projection. Keep full code/output in bounded artifacts, while the Rust TUI shows phase, duration, ownership, and excerpt references.

**Acceptance:** kill the interpreter after it creates an intermediate value. The session remains responsive, reports state loss, and rejects late output from the old incarnation. A generated syntax error remains repairable in the healthy incarnation. No automatic replay of a host-side effect occurs.

### B. Treat final answers as a checked transition

Define a small output contract for the analysis operation: findings, exact evidence references, uncovered scope, and completion status. Validate proposed terminal actions before executing the tool batch. Make submission exclusive or define an explicit ordering rule; no later mutation should slip through after the runtime has accepted completion.

An iteration limit should return a structured partial result unless the central budget owner explicitly admits another extraction request. Distinguish “the loop stopped” from “the task's evidence requirements were satisfied.” This can strengthen Elara's existing pure reducer without adopting DSPy's whole agent loop.

**Acceptance:** a provider proposes `submit`, followed by a write, in one response. The runtime rejects or resolves that batch under its declared ordering rule before effects begin. A missing evidence field produces a validation failure, while exhausted budget produces a visible partial result.

### C. Make concurrency policy depend on the work

Extend admission across root, leaf, verification, and extraction requests. Reserve capacity before a batch starts; track attempts separately from logical jobs. Set limits on pending work, provider requests, output bytes, artifact storage, and wall time. A waiting parent should not retain the provider slot its child needs.

Initially disable speculative repetition for tools. Later, try hedging one pure, read-only inference operation with a separate allowance. The first accepted result wins; every losing attempt remains accounted for until terminated or completed. A logical cancellation should fence late results and retain uncertain provider charges.

Apply bounded queues and coalesced progress through the entire Rust display path. Final outcomes need reliable delivery; intermediate animation updates can be replaced by a newer snapshot.

**Acceptance:** simultaneous children contend for the final request allowance, one provider stalls, and the TUI subscriber pauses. Admission stays bounded, no duplicate mutation occurs, and final state remains inspectable after the subscriber resumes. These are focused scenarios, not a request to start the owner's deferred benchmark program.

## Evidence and non-transferable assumptions

Selected test bodies cover [counter/context and interpreter ownership](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/tests/predict/test_rlm.py#L368-L542), [terminal process/protocol failure](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/tests/primitives/test_python_interpreter.py#L781-L894), [causal callback nesting](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/tests/callback/test_interpreter_callback.py#L185-L232), and [provider tool-call identity](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/tests/predict/test_react_v2.py#L280-L328). They were inspected, not executed.

DSPy's Python objects, threads, callbacks, and history values are library mechanisms. Elara still needs explicit persistence, authority checks, attempt fencing, and resource enforcement; supervision alone supplies none of those contracts. Current Elara capabilities and limits are recorded in the [existing source inventory](harness-ideas-beam-2026-09-06.md#what-elara-already-has).

Current source warns that `CodeAct` and `ProgramOfThought` are deprecated in favor of RLM, with removal planned for 3.5. Their docstrings label deprecation “3.4”; this review does not smooth that development-version discrepancy into a release guarantee. [CodeAct](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/predict/code_act.py#L17-L58), [ProgramOfThought](https://github.com/stanfordnlp/dspy/blob/f70d08a5b934400d236078143e3704934f2d5dd1/dspy/predict/program_of_thought.py#L25-L63)

No dependencies, downloaded programs, interpreter sessions, or paid model calls were run. Only this research document was added for this assignment.
