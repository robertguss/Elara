# BEAM runtime experiments 2–5: manual verification checklist

This checklist validates the user-visible behavior delivered by roadmap
experiments 2 through 5:

2. Detachable session server and replayable events
3. Remote capability-based tool executors
4. Multi-agent coordination
5. Deterministic replay and runtime observability

It intentionally does not retest experiment 1 except where plugin reload is an
input to the flight recorder.

## How to use this checklist

- Run commands from the Harness repository root unless a step says otherwise.
- Use a disposable directory for filesystem and worker tests.
- Check each box only after observing the stated result.
- Model-generated wording is nondeterministic. Validate the runtime state,
  result status, files, event ordering, and failure behavior rather than exact
  prose from a real provider.
- Sections marked **deterministic check** do not depend on model behavior.
- Keep secrets out of shell history where practical. Never commit a worker or
  provider token.

## 0. Prerequisites and baseline

### 0.1 Toolchain and dependencies

- [ ] Confirm the expected toolchain is active.

  ```bash
  elixir --version
  mix deps.get
  ```

  **Pass criteria:** Elixir reports 1.20.x, Erlang/OTP reports 29, and
  `mix deps.get` exits successfully.

### 0.2 Provider credentials

The detachable CLI and real-provider coordinator examples need valid provider
credentials. Use one of:

```bash
mix harness.login
```

or:

```bash
export HARNESS_API_KEY='...'
# XAI_API_KEY is also accepted, but HARNESS_API_KEY takes precedence.
```

- [ ] Confirm a basic provider call works.

  ```bash
  mix harness.ask "Reply with the single word ready"
  ```

  **Pass criteria:** the command prints an answer and exits with status 0.

### 0.3 Automated baseline

This is not a substitute for the manual checks below; it establishes that the
known deterministic proofs pass before manual testing.

- [ ] Run the focused acceptance suites.

  ```bash
  mix test \
    test/harness/server_test.exs \
    test/harness/executor_test.exs \
    test/harness/coordinator_test.exs \
    test/harness/flight_recorder_test.exs
  ```

  **Pass criteria:** 14 tests pass with no failures.

- [ ] Run all verification gates.

  ```bash
  mix format --check-formatted
  mix compile --warnings-as-errors
  mix test
  ```

  **Pass criteria at commit `3457990`:** formatting and compilation succeed,
  and all 174 tests pass. The logged `RuntimeError) boom` from
  `Harness.SessionTest.CrashTool` is an intentional crash-isolation test; the
  final test result must still be green.

---

## 1. Detachable session server and replayable events

### 1.1 Localhost-only server and configurable port

**Feature:** `mix harness.server` owns sessions independently of an attachment
and exposes the versioned JSON-line protocol only on loopback.

- [ ] In terminal A, start the default server.

  ```bash
  mix harness.server
  ```

  **Expected:** `Harness server listening on 127.0.0.1:4048`.

- [ ] In terminal B, verify the listening address.

  ```bash
  ss -ltn | grep ':4048'
  ```

  **Pass criteria:** the listener is `127.0.0.1:4048`, not `0.0.0.0:4048` or
  an externally routable address.

- [ ] Optionally verify a non-default port. Stop terminal A, then run:

  ```bash
  mix harness.server --port 14048
  ```

  Attach with:

  ```bash
  mix harness.attach new --port 14048
  ```

  **Pass criteria:** both commands use port 14048 successfully. Return to port
  4048 for the remaining examples.

### 1.2 Server-owned session and stable session ID

**Feature:** `mix harness.attach new` creates the first server-owned session and
receives a stable string ID rather than exposing a PID.

- [ ] With the server running in terminal A, run in terminal B:

  ```bash
  mix harness.attach new
  ```

  **Expected:** the first line resembles:

  ```text
  attached <SESSION_ID> (control); replay head 0
  ```

  Save `<SESSION_ID>` for later steps.

- [ ] Enter a simple prompt and wait for the answer.

  ```text
  Reply with the exact text detachable-ok
  ```

  **Pass criteria:** the turn completes in terminal B while the server remains
  running in terminal A. The ID printed at attachment does not change.

- [ ] At the attachment prompt, enter:

  ```text
  /inspect
  ```

  **Pass criteria:** one JSON status object is printed. It contains the same
  session `id`, an `incarnation`, an idle `phase`, `current_effect` of `nil`,
  mailbox/task/subscriber counts, event head/retention, recording path/count,
  and worker health.

### 1.3 Detach without terminating the session

**Feature:** closing an attachment does not terminate the server-owned session.

- [ ] In terminal B, enter `/quit`.

  **Expected:** the attachment exits but terminal A continues running.

- [ ] Reattach in terminal B using the saved ID.

  ```bash
  mix harness.attach <SESSION_ID>
  ```

  **Pass criteria:** the same session ID and incarnation are reported, and the
  attachment succeeds instead of creating a new conversation.

### 1.4 Disconnect during a tool and replay missed events exactly once

**Feature:** the session and active tool survive client disconnect. Event
cursors persist under `~/.harness/attach/`, and reconnect replays only events
missed after the saved cursor.

- [ ] In the controlling attachment, ask the model to start a long tool:

  ```text
  Use the bash tool to run: sleep 15; printf detach-finished
  Do not simulate it or answer before running the tool.
  ```

- [ ] Confirm a `bash` tool-start line appears, then immediately press Ctrl-D
  or close only terminal B. Do **not** stop the server.

- [ ] Wait at least 16 seconds, then reconnect:

  ```bash
  mix harness.attach <SESSION_ID>
  ```

  **Pass criteria:**

  - The existing session is attached.
  - The missed tool result/final answer is replayed.
  - Events already rendered before disconnect are not rendered again.
  - Reconnecting a second time immediately does not duplicate those events.
  - `~/.harness/attach/<SESSION_ID>.json` contains a nonnegative `cursor` and
    the current `incarnation`.

### 1.5 Monotonic event cursor and replay status

**Feature:** events have monotonically increasing sequence numbers and a
bounded replay log.

- [ ] Run `/inspect` before and after another completed prompt.

  **Pass criteria:** `event_head` increases and never decreases;
  `event_retained` is positive and does not exceed 1000. A no-tool turn usually
  adds four events: turn started, user message appended, assistant message
  appended, and turn ended.

### 1.6 Multiple observers and explicit control ownership

**Feature:** one attachment controls ask/interrupt commands while multiple
read-only observers can receive events.

- [ ] Keep the controlling attachment open in terminal B. In terminal C run:

  ```bash
  mix harness.attach <SESSION_ID> --observe
  ```

  **Expected:** terminal C reports `(observe)` and does not present an input
  prompt.

- [ ] Ask a question from terminal B.

  **Pass criteria:** both B and C render the resulting events.

- [ ] While B still controls the session, try another controlling attachment
  in terminal D:

  ```bash
  mix harness.attach <SESSION_ID>
  ```

  **Expected:** attachment fails with `control_taken`. The existing controller
  and observer remain connected.

- [ ] Exit terminal B, then retry terminal D.

  **Pass criteria:** the new controlling attachment now succeeds, proving that
  control ownership is released on controller disconnect.

### 1.7 Interrupt semantics

**Feature:** the controller can interrupt a running provider/tool turn without
terminating the session.

- [ ] Start another `sleep 30` bash tool from the controller. After the tool
  starts, enter:

  ```text
  /interrupt
  ```

  **Pass criteria:** the turn ends as interrupted, the session returns to idle,
  `/inspect` shows no active current effect, and a subsequent normal prompt
  completes in the same session.

### 1.8 Protocol version rejection

**Feature:** incompatible clients are rejected rather than interpreted using an
ambiguous protocol.

- [ ] With `nc` installed, send an unsupported protocol version:

  ```bash
  printf '%s\n' '{"version":999,"command":"attach","session_id":"x"}' | nc 127.0.0.1 4048
  ```

  **Expected:** one JSON error response containing `unsupported_version`.

### Detachable server acceptance criteria

- [ ] Sessions are addressed by stable string IDs.
- [ ] The gateway binds only to loopback.
- [ ] Detaching does not kill the session or current tool.
- [ ] Reconnection replays missed events once, in cursor order.
- [ ] Multiple observers receive events while only one controller can mutate.
- [ ] Interrupt leaves the session alive and usable.
- [ ] Inspect exposes phase, current effect, mailbox/tasks, event and worker
  state, plus recorder information.

---

## 2. Remote capability-based tool executors

The direct router checks below avoid model nondeterminism. Use three terminals:

- terminal W: worker process
- terminal I: `iex -S mix` brain process
- terminal S: optional second/replacement worker

### 2.1 Prepare an isolated remote workspace

- [ ] Create a worker directory and fixture.

  ```bash
  rm -rf /tmp/harness-worker-manual
  mkdir -p /tmp/harness-worker-manual
  printf 'remote-only-content' >/tmp/harness-worker-manual/remote.txt
  ```

- [ ] In terminal W start an authenticated, loopback-only worker:

  ```bash
  HARNESS_WORKER_TOKEN=manual-secret \
    mix harness.worker manual-workspace \
    --cwd /tmp/harness-worker-manual \
    --port 14049
  ```

  **Expected:** it reports loopback address `127.0.0.1:14049`, workspace
  `manual-workspace`, and the default capabilities `filesystem:read`,
  `filesystem:write`, and `shell`.

- [ ] Verify the bind address:

  ```bash
  ss -ltn | grep ':14049'
  ```

  **Pass criteria:** it binds `127.0.0.1`, not all interfaces. `--public` is the
  explicit opt-in for `0.0.0.0` and should only be tested on a protected
  network.

### 2.2 Register the worker and inspect advertised state

- [ ] In terminal I start the brain VM:

  ```bash
  iex -S mix
  ```

- [ ] Register the worker:

  ```elixir
  alias Harness.Executor.{Remote, Request, Router}

  :ok = Harness.register_worker(
    id: "manual-worker",
    executor: {Remote, %{host: {127, 0, 0, 1}, port: 14049, token: "manual-secret"}},
    capabilities: ["filesystem:read", "filesystem:write", "shell"],
    workspaces: ["manual-workspace"]
  )

  Harness.workers()
  ```

  **Pass criteria:** output contains the always-present `local` executor and a
  healthy `manual-worker` with placement `:remote`, load 0, the advertised
  capabilities, and the expected workspace.

### 2.3 Serializable request and remote filesystem identity

**Feature:** tool requests carry stable identity, deadline, cancellation,
capability, placement, and workspace data instead of a brain filesystem path.

- [ ] In IEx build and inspect a request:

  ```elixir
  read =
    Harness.Tool.builtins()
    |> Enum.find(&(&1.name == "read"))
    |> Map.put(:placement, :remote)

  request = %Request{
    tool_call_id: "manual-read-1",
    session_id: "manual-session",
    tool_name: "read",
    tool_version: "1",
    arguments: %{"path" => "remote.txt"},
    workspace_id: "manual-workspace",
    deadline_ms: System.system_time(:millisecond) + 10_000,
    cancellation_id: "manual-cancel-1",
    required_capabilities: ["filesystem:read"],
    placement: :remote,
    mutating: false
  }

  encoded = Request.to_map(request)
  {Map.has_key?(encoded, "cwd"), Request.from_map(encoded), JSON.encode!(encoded)}
  ```

  **Pass criteria:** the tuple starts with `false`, round-trips as
  `{:ok, ^request}`, and JSON encoding succeeds. The map contains all request
  identities and `workspace_id`, but no `cwd`.

### 2.4 Remote read execution

- [ ] Execute the request from the brain VM:

  ```elixir
  Router.execute(Router, request, read, File.cwd!())
  ```

  **Expected:** `{:ok, "remote-only-content"}`.

  **Pass criteria:** the result comes from `/tmp/harness-worker-manual`, even
  though the brain VM's current directory is the Harness repository.

### 2.5 Remote mutation executes only in the mapped workspace

- [ ] In IEx execute a remote write:

  ```elixir
  write =
    Harness.Tool.builtins()
    |> Enum.find(&(&1.name == "write"))
    |> Map.put(:placement, :remote)

  write_request = %Request{
    tool_call_id: "manual-write-1",
    session_id: "manual-session",
    tool_name: "write",
    tool_version: "1",
    arguments: %{"path" => "made.txt", "content" => "made remotely"},
    workspace_id: "manual-workspace",
    deadline_ms: System.system_time(:millisecond) + 10_000,
    cancellation_id: "manual-cancel-2",
    required_capabilities: ["filesystem:write"],
    placement: :remote,
    mutating: true
  }

  Router.execute(Router, write_request, write, File.cwd!())
  ```

  **Expected:** `{:ok, ...}`.

- [ ] In a shell verify placement:

  ```bash
  cat /tmp/harness-worker-manual/made.txt
  test ! -e ./made.txt
  ```

  **Pass criteria:** the worker file contains `made remotely`; no `made.txt`
  was created in the brain checkout.

### 2.6 Authentication rejection

**Feature:** the worker rejects requests without the shared token.

- [ ] Register a second logical endpoint with a wrong token and ensure it is
  selected by giving it a unique workspace:

  ```elixir
  :ok = Router.register(Router,
    id: "wrong-token",
    executor: {Remote, %{port: 14049, token: "wrong"}},
    capabilities: ["filesystem:read"],
    workspaces: ["claimed-workspace"]
  )

  denied = %{request |
    tool_call_id: "auth-denied",
    workspace_id: "claimed-workspace",
    deadline_ms: System.system_time(:millisecond) + 10_000
  }

  Router.execute(Router, denied, read, File.cwd!())
  ```

  **Expected:** `{:error, "executor rejected request: unauthorized"}`. No tool
  runs on the worker.

### 2.7 Workspace and capability enforcement

**Feature:** routing and the worker independently enforce workspace and
capability declarations.

- [ ] Ask for an unregistered workspace:

  ```elixir
  unknown_workspace = %{request |
    tool_call_id: "unknown-workspace",
    workspace_id: "not-registered",
    deadline_ms: System.system_time(:millisecond) + 10_000
  }

  Router.execute(Router, unknown_workspace, read, File.cwd!())
  ```

  **Expected:** `{:error, "no healthy executor satisfies the tool placement and capabilities"}`.

- [ ] Start a capability-limited worker in terminal S:

  ```bash
  HARNESS_WORKER_TOKEN=manual-secret \
    mix harness.worker limited-workspace \
    --cwd /tmp/harness-worker-manual \
    --port 14050 \
    --capability filesystem:read
  ```

- [ ] In IEx deliberately advertise `shell` to the router even though the
  worker itself does not grant it, then call bash:

  ```elixir
  :ok = Router.register(Router,
    id: "limited-worker",
    executor: {Remote, %{port: 14050, token: "manual-secret"}},
    capabilities: ["shell"],
    workspaces: ["limited-workspace"]
  )

  bash =
    Harness.Tool.builtins()
    |> Enum.find(&(&1.name == "bash"))
    |> Map.put(:placement, :remote)

  shell_request = %Request{
    tool_call_id: "denied-shell",
    session_id: "manual-session",
    tool_name: "bash",
    tool_version: "1",
    arguments: %{"command" => "touch should-not-exist"},
    workspace_id: "limited-workspace",
    deadline_ms: System.system_time(:millisecond) + 10_000,
    cancellation_id: "manual-cancel-3",
    required_capabilities: ["shell"],
    placement: :remote,
    mutating: true
  }

  Router.execute(Router, shell_request, bash, File.cwd!())
  ```

  **Expected:** an executor-rejected `capability_denied` error, and
  `/tmp/harness-worker-manual/should-not-exist` does not exist.

### 2.8 Session-level permission denial before routing

**Feature:** `allowed_capabilities:` is an enforcement boundary, not prompt
advice.

- [ ] Run the deterministic focused proof:

  ```bash
  mix test test/harness/executor_test.exs:254
  ```

  **Pass criteria:** the test passes; the transcript contains a permission
  denial tool result and no file is created. This uses a scripted provider so
  the exact prohibited call is deterministic.

### 2.9 Read-only transport retry and health tracking

**Feature:** a read-only request retries another eligible worker after a
transport failure. The failed worker becomes unhealthy.

- [ ] Keep the healthy worker on port 14049. Register a dead endpoint whose ID
  sorts first, plus the healthy endpoint:

  ```elixir
  :ok = Router.unregister(Router, "manual-worker")

  :ok = Router.register(Router,
    id: "a-dead",
    executor: {Remote, %{port: 14999, token: "manual-secret"}},
    capabilities: ["filesystem:read"],
    workspaces: ["manual-workspace"]
  )

  :ok = Router.register(Router,
    id: "b-healthy",
    executor: {Remote, %{port: 14049, token: "manual-secret"}},
    capabilities: ["filesystem:read"],
    workspaces: ["manual-workspace"]
  )

  retry_request = %{request |
    tool_call_id: "retry-read",
    deadline_ms: System.system_time(:millisecond) + 10_000
  }

  Router.execute(Router, retry_request, read, File.cwd!())
  Router.workers(Router)
  ```

  **Pass criteria:** the read still returns `remote-only-content`; `a-dead` is
  marked `healthy?: false`; `b-healthy` remains healthy. Only one terminal
  result is returned.

### 2.10 Mutating transport loss is indeterminate and never blindly retried

**Feature:** after a mutating request may have started, transport loss yields
one `:indeterminate` result. The router does not run the mutation again on a
replacement worker.

- [ ] Remove prior remote registrations, restore the live worker registration,
  and prepare a long mutating bash request:

  ```elixir
  Enum.each(["a-dead", "b-healthy", "wrong-token", "limited-worker"],
    &Router.unregister(Router, &1))

  :ok = Router.register(Router,
    id: "manual-worker",
    executor: {Remote, %{port: 14049, token: "manual-secret"}},
    capabilities: ["filesystem:read", "filesystem:write", "shell"],
    workspaces: ["manual-workspace"]
  )

  mutation = %{shell_request |
    tool_call_id: "mutation-loss",
    workspace_id: "manual-workspace",
    arguments: %{"command" => "printf once > mutation-marker; sleep 30"},
    deadline_ms: System.system_time(:millisecond) + 60_000,
    cancellation_id: "manual-cancel-4"
  }

  mutation_task = Task.async(fn ->
    Router.execute(Router, mutation, bash, File.cwd!())
  end)
  ```

- [ ] Wait until this shell command succeeds, proving the side effect started:

  ```bash
  test -f /tmp/harness-worker-manual/mutation-marker
  ```

- [ ] Stop terminal W with Ctrl-C, then in IEx run:

  ```elixir
  Task.await(mutation_task, 10_000)
  ```

  **Expected:** `{:indeterminate, "remote outcome unknown: ..."}`.

  **Pass criteria:** exactly one outcome is returned, the marker contains
  `once`, no replacement worker receives an automatic retry, and
  `manual-worker` becomes unhealthy.

### 2.11 Replacement worker and session continuity

- [ ] Restart terminal W on port 14049, then re-register `manual-worker` using
  the same registration shown in section 2.2.

- [ ] Re-run a remote read with a fresh deadline.

  **Pass criteria:** it succeeds and the newly registered worker is healthy.

- [ ] Run the deterministic end-to-end session proof:

  ```bash
  mix test test/harness/executor_test.exs:177
  ```

  **Pass criteria:** the test proves the session actor stays alive, records
  exactly one indeterminate result for the interrupted mutation, and completes
  another turn through the replacement worker.

### Remote executor acceptance criteria

- [ ] Requests serialize without a host `cwd` and include all identity,
  deadline, cancellation, capability, workspace, and placement fields.
- [ ] Authentication, workspace, and capability boundaries reject invalid
  requests.
- [ ] Remote reads/writes happen in the worker-mapped workspace.
- [ ] Selection considers placement, capabilities, workspace, health, load,
  and workspace affinity.
- [ ] Read-only transport failures can retry another healthy worker.
- [ ] Mutating transport failures return one explicit indeterminate result and
  are not blindly retried.
- [ ] Worker death does not kill the owning session; a replacement can continue.

---

## 3. Multi-agent coordination

These checks use a real provider in `iex -S mix`. Exact answers can vary; the
runtime result shapes and process/worktree behavior are the acceptance target.

### 3.1 Parent session and coordinator actor

- [ ] Start IEx and create a parent with one completed turn:

  ```bash
  iex -S mix
  ```

  ```elixir
  {:ok, parent} = Harness.start_session(persist: false, plugins: [], tools: [])
  {:ok, _} = Harness.ask(parent, "Remember the marker parent-history-marker.")
  parent_history = Harness.transcript(parent)

  {:ok, coordinator} = Harness.start_coordinator(parent,
    max_concurrency: 3,
    token_budget: 20_000,
    time_budget_ms: 120_000
  )

  status = Harness.Coordinator.status(coordinator)
  ```

  **Pass criteria:** `status.parent_session_id == parent`,
  `status.child_supervisor` is a live PID, `status.run == nil`, and worker
  health is present.

### 3.2 Parallel investigation

**Feature:** independent child sessions execute concurrently outside the parent
session loop and return compact results.

- [ ] Run two independent investigators:

  ```elixir
  {:ok, parallel} = Harness.Coordinator.run(coordinator, :parallel, [
    %{id: "runtime", role: :debugging, prompt: "In one sentence, explain BEAM process isolation."},
    %{id: "tests", role: :tests, prompt: "In one sentence, explain deterministic tests."}
  ])
  ```

  **Pass criteria:**

  - `parallel.pattern == :parallel`.
  - There are two results with IDs `runtime` and `tests`.
  - Successful rows have `status: :completed`, a compact `answer`, a stable
    `session_id`, and `duration_ms`.
  - Result structs do not contain a `transcript` field.
  - `parallel.token_estimate`, `elapsed_ms`, and `worker_health` are populated.
  - `Harness.transcript(parent) == parent_history`; child work did not mutate
    the parent history.

### 3.3 Specialist roles

- [ ] Run the specialist pattern:

  ```elixir
  {:ok, specialists} = Harness.Coordinator.run(coordinator, :specialists, [
    %{id: "debugger", role: :debugging, prompt: "List one debugging risk."},
    %{id: "security", role: :security, prompt: "List one security risk."},
    %{id: "docs", role: :documentation, prompt: "Write one documentation check."}
  ])
  ```

  **Pass criteria:** three compact result rows preserve the requested IDs and
  roles. One child failure, if a provider call fails, is collected in
  `specialists.failures` rather than crashing the parent/coordinator.

### 3.4 Candidate generation, judge, and isolated coding worktrees

**Feature:** coding children receive distinct detached git worktrees. A judge
receives compact candidate results and selects an ID.

- [ ] Start the candidate run asynchronously so status can be inspected:

  ```elixir
  candidate_task = Task.async(fn ->
    Harness.Coordinator.run(coordinator, :candidates, [
      %{id: "a", role: :coding, prompt: "Propose candidate A. Do not edit files."},
      %{id: "b", role: :coding, prompt: "Propose candidate B. Do not edit files."},
      %{id: "c", role: :coding, prompt: "Propose candidate C. Do not edit files."}
    ],
      judge: %{
        id: "judge",
        role: :judge,
        prompt: "Choose the best candidate. Return exactly one ID: a, b, or c."
      }
    )
  end)

  live =
    Stream.repeatedly(fn ->
      Process.sleep(20)
      Harness.Coordinator.status(coordinator)
    end)
    |> Enum.find(&(Enum.count(&1.children, fn child -> child.role == :coding end) == 3))

  coding_children = Enum.filter(live.children, &(&1.role == :coding))
  worktrees = Enum.map(coding_children, & &1.worktree)
  ```

  **Pass criteria while running:**

  - `live.run.id` is a stable string.
  - `live.run.pattern == :candidates`.
  - Every child row has matching `run_id` and `parent_session_id`, plus live
    session/task PIDs and a stable child session ID.
  - `live.run.budgets` reports token estimate used/limit/remaining,
    elapsed/limit/remaining time, active/limit concurrency, queued count, and
    completed count.
  - All three worktree paths are distinct existing git worktrees:

    ```elixir
    Enum.map(worktrees, &{&1, File.dir?(&1), System.cmd("git", ["rev-parse", "--is-inside-work-tree"], cd: &1)})
    ```

- [ ] Await the result:

  ```elixir
  {:ok, candidates} = Task.await(candidate_task, 180_000)
  ```

  **Pass criteria:** `candidates.selected` is `"a"`, `"b"`, or `"c"`;
  `candidates.judge.role == :judge`; candidate and judge rows are present; the
  parent session remains alive and its transcript still equals
  `parent_history`.

- [ ] Inspect one child history before cleanup:

  ```elixir
  child = Enum.find(candidates.results, &(&1.role == :coding))
  child_history = Harness.transcript(child.session_id)
  Enum.take(child_history, length(parent_history)) == parent_history
  ```

  **Expected:** `true`, proving default history cloning.

### 3.5 Child failure isolation and sibling survival

**Feature:** killing one child produces a compact failure while siblings and the
parent survive.

- [ ] Start another candidate run as above, but use IDs `one`, `dead`, and
  `two`. Wait until all three children appear, then run:

  ```elixir
  :ok = Harness.Coordinator.kill_child(coordinator, "dead")
  ```

- [ ] Await the run.

  **Pass criteria:**

  - The returned run has one failure row with `id == "dead"` and
    `status == :failed`.
  - Remaining candidates and the judge can complete.
  - `Harness.session_pid(parent)` returns a live PID.
  - Parent history remains unchanged.

  If a real provider finishes all children before the kill, repeat with longer
  prompts or use the deterministic proof:

  ```bash
  mix test test/harness/coordinator_test.exs:79
  ```

### 3.6 Shared concurrency budget and live admission status

- [ ] Start a fresh coordinator with `max_concurrency: 1`, then asynchronously
  run three parallel prompts.

  **Pass criteria while running:** coordinator status reports concurrency
  `active: 1, limit: 1`; remaining children are queued rather than all running
  simultaneously. As rows finish, completed increases and queued decreases.

### 3.7 Estimated-token budget

- [ ] Start a coordinator with a deliberately tiny budget:

  ```elixir
  {:ok, token_coordinator} = Harness.start_coordinator(parent,
    token_budget: 1,
    time_budget_ms: 10_000
  )

  {:ok, token_limited} = Harness.Coordinator.run(token_coordinator, :specialists, [
    %{id: "too-large", role: :security, prompt: "This prompt exceeds one estimated token."}
  ])
  ```

  **Pass criteria:** no provider work starts for that child; its result and
  failure status are `:budget_exceeded`. The counter is explicitly an estimate,
  not provider-reported billing usage.

### 3.8 Wall-clock budget

- [ ] Start a coordinator with `time_budget_ms: 10` and run a provider-backed
  child.

  **Pass criteria:** the run returns promptly with the active child marked
  `:cancelled` and error `time_budget_exceeded`; parent remains alive.

### 3.9 Early selection and cancellation

- [ ] Run with `max_concurrency: 1` and this selector:

  ```elixir
  select_first = fn results ->
    case Enum.find(results, &(&1.status == :completed)) do
      nil -> nil
      result -> result.id
    end
  end
  ```

  Pass it as `select: select_first` to a `:parallel` run of at least two specs.

  **Pass criteria:** the first completed result becomes `run.selected`; queued
  or active remaining rows are returned with `status: :cancelled` and
  `not_selected`; no unconstrained work continues after selection.

### 3.10 Map/reduce with compact intermediate results

- [ ] Run:

  ```elixir
  {:ok, reduced} = Harness.Coordinator.run(coordinator, :map_reduce, [
    %{id: "map-a", prompt: "Return exactly A."},
    %{id: "map-b", prompt: "Return exactly B."}
  ],
    reducer: %{
      id: "reduce",
      role: :reducer,
      prompt: "Combine the structured child results into one short answer."
    }
  )
  ```

  **Pass criteria:** map rows and a reducer row are present; `reduced.selected`
  equals the reducer answer; the reducer received structured compact child
  fields rather than full transcripts.

### 3.11 Fork history before a selected user turn

- [ ] List the parent user turns and select one ID:

  ```elixir
  [%{id: user_id} | _] = Harness.user_entries(parent)
  ```

- [ ] Run a parallel or map/reduce operation with:

  ```elixir
  history: {:fork, user_id}
  ```

- [ ] Inspect a returned child transcript.

  **Pass criteria:** the selected parent user turn and everything after it are
  absent from the child's seed history; the child's own prompt is present.

### 3.12 Coordinator cleanup

- [ ] Stop the coordinator used for coding children:

  ```elixir
  GenServer.stop(coordinator)
  Enum.map(worktrees, &File.exists?/1)
  ```

  **Expected:** all values are `false`. Child sessions/tasks terminate and
  temporary worktrees are removed; the parent remains alive.

### Multi-agent acceptance criteria

- [ ] Coordinator state is outside the parent session loop and has its own
  supervised child-session boundary.
- [ ] Parallel, specialist, candidate/judge, and map/reduce patterns work.
- [ ] Child histories clone or fork at the requested boundary.
- [ ] Coding children use distinct detached worktrees.
- [ ] Child failure does not lose parent/sibling sessions.
- [ ] Concurrency, estimated-token, wall-clock, and early-selection limits are
  enforced and observable.
- [ ] Results are compact structured rows; full transcripts stay in children.
- [ ] Stopping the coordinator removes child worktrees and processes.

---

## 4. Deterministic flight recorder and observability

### 4.1 Record every pure-core transition

**Feature:** the session shell records every fact passed to `Session.Core` and
the resulting ordered effects and state projection before interpreting effects.

- [ ] In `iex -S mix`, create a persistent session and complete a simple no-tool
  turn:

  ```elixir
  {:ok, recorded_session} = Harness.start_session(plugins: [], tools: [])
  {:ok, _answer} = Harness.ask(recorded_session, "Reply with flight-ok")
  recording = Harness.recording(recorded_session)
  ```

  **Pass criteria:**

  ```elixir
  recording.header.format_version == 1
  recording.header.session_id == recorded_session
  Enum.map(recording.transitions, & &1.fact.kind)
  ```

  The first two facts are `[:ask, :provider_result]`. Each transition has a
  stable recording/sequence ID, segment number, causal link, normalized fact,
  pre/post fingerprints and projections, and ordered normalized effects.

### 4.2 Persistent framed recording and file permissions

- [ ] Inspect status and the file:

  ```elixir
  recorded_status = Harness.status(recorded_session)
  path = recorded_status.recording_path
  {path, File.exists?(path), Bitwise.band(File.stat!(path).mode, 0o777)}
  ```

  **Pass criteria:** the file exists beside the session JSONL, permissions equal
  decimal 384 (`0o600`), and `recorded_status.recorded_transitions == 2` for the
  no-tool turn. The filename is scoped to the session incarnation.

### 4.3 Offline replay without provider or tool calls

**Feature:** replay reconstructs inert tool descriptors and calls only the pure
core. It does not call providers, execute tools, or require original plugin
PIDs/MFAs.

- [ ] Replay the in-memory recording:

  ```elixir
  {:ok, replay} = Harness.replay(recording)
  {replay.status, replay.transitions, replay.divergence}
  ```

  **Expected:** `{:match, 2, nil}`. It should return much faster than a provider
  request and add nothing to the live session transcript.

- [ ] Load and replay from disk:

  ```elixir
  {:ok, loaded} = Harness.FlightRecorder.load(path)
  {:ok, disk_replay} = Harness.replay(path)
  {length(loaded.transitions), disk_replay.status}
  ```

  **Expected:** `{2, :match}`.

- [ ] Create and stop a separate session, then replay its path so the primary
  `recorded_session` remains available for later live checks:

  ```elixir
  {:ok, offline_session} = Harness.start_session(plugins: [], tools: [])
  {:ok, _} = Harness.ask(offline_session, "Reply with offline-ok")
  offline_path = Harness.status(offline_session).recording_path
  {:ok, offline_pid} = Harness.session_pid(offline_session)
  GenServer.stop(offline_pid)
  Harness.replay(offline_path)
  ```

  **Pass criteria:** replay still reports `:match`, proving it is offline and
  independent of the session/provider process.

### 4.4 Core-upgrade behavior comparison

**Feature:** replay reports the first transition where another pure step
implementation changes state or effects.

- [ ] Create another simple recording if the prior session was stopped, then
  compare a deliberately changed step function:

  ```elixir
  changed_step = fn state, fact ->
    {next, effects} = Harness.Session.Core.step(state, fact)
    changed = Enum.reject(effects, &match?({:emit, {:turn_started, _}}, &1))
    {next, changed}
  end

  {:ok, comparison} = Harness.replay(recording, step: changed_step)
  comparison.status
  comparison.divergence
  ```

  **Pass criteria:** status is `:diverged`; the first divergence identifies
  transition sequence 1 and field `:effects`, with expected and actual values.

### 4.5 Fault injection: replace, insert, and drop

**Feature:** replay can branch at any transition without executing effects.
Exact refs remain unchanged so stale-reply behavior can be tested.

- [ ] Replace the provider-result fact in a two-transition turn with interrupt:

  ```elixir
  {:ok, replaced} = Harness.replay(recording,
    inject: %{2 => {:replace, :interrupt}}
  )
  ```

  **Pass criteria:** status is `:injected`; the final state is idle and no
  provider/tool effect executes.

- [ ] Insert an interrupt before transition 2:

  ```elixir
  {:ok, inserted} = Harness.replay(recording,
    inject: %{2 => {:insert, :interrupt}}
  )
  ```

  **Pass criteria:** observations include the inserted fact followed by the
  original recorded fact; the original provider reply is stale after the
  interrupt and cannot restart the turn.

- [ ] Drop transition 2:

  ```elixir
  {:ok, dropped} = Harness.replay(recording, inject: %{2 => :drop})
  ```

  **Pass criteria:** status is `:injected`; the provider-result transition is
  not applied, leaving the replay state in its prior provider-calling phase.

### 4.6 Causal `/why` debugger

**Feature:** event sequences map to durable transition/effect IDs. Provider and
tool result facts link back to the effect that caused them and ultimately to an
external ask/interrupt.

- [ ] On a live completed session run:

  ```elixir
  {:ok, why_latest} = Harness.why(recorded_session)
  Enum.map(why_latest.chain, & &1.transition_id.sequence)
  ```

  **Pass criteria:** the explanation includes transition ID, effect index,
  normalized fact, pre/post projection, and an ordered causal chain beginning
  at the external ask. For a simple turn, the latest event belongs to transition
  2 and the chain is `[1, 2]`.

- [ ] Explain a selected event sequence from `Harness.status(session).event_head`:

  ```elixir
  head = Harness.status(recorded_session).event_head
  Harness.why(recorded_session, head)
  ```

  **Pass criteria:** it returns `{:ok, explanation}` for a retained live event;
  an unknown event returns `{:error, :not_found}`.

- [ ] Explain an offline transition directly:

  ```elixir
  Harness.FlightRecorder.why(loaded, {:transition, 2})
  ```

  **Expected:** an explanation for durable transition sequence 2.

- [ ] In `mix harness.chat`, complete a turn and enter:

  ```text
  /why
  ```

  Then optionally:

  ```text
  /why 4
  ```

  **Pass criteria:** chat prints the recording/transition ID, effect index,
  normalized fact, and causal transition chain. Invalid syntax such as
  `/why nope` prints usage rather than becoming a model prompt.

### 4.7 Segment after history rebase

**Feature:** out-of-band core changes start a replay segment instead of making
the original seed silently incorrect.

- [ ] In a live session with at least one user turn:

  ```elixir
  [%{id: first_user} | _] = Harness.user_entries(recorded_session)
  {:ok, _prompt, _history} = Harness.tree(recorded_session, first_user)
  rebased = Harness.recording(recorded_session)
  Enum.map(rebased.segments, & &1.reason)
  Harness.replay(rebased)
  ```

  **Pass criteria:** reasons include `:init` followed by `:history_rebased`, and
  replay still matches.

### 4.8 Segment and PID normalization after plugin reload

**Feature:** successful plugin replacement starts `:plugins_reloaded`; plugin
server PIDs are normalized into logical plugin descriptors so offline replay
does not depend on a live plugin process.

- [ ] Run the deterministic plugin/recorder proof:

  ```bash
  mix test test/harness/plugin_test.exs:146
  ```

  **Pass criteria:** the same plugin state process survives reload, recording
  segments are `[:init, :plugins_reloaded]`, and replay reports `:match` after
  calls made with both plugin generations.

### 4.9 Truncated final-frame recovery

**Feature:** the loader accepts a recording whose final frame was only partly
written, while rejecting invalid magic/version/oversized frames.

- [ ] Copy a valid recording and append an incomplete frame:

  ```elixir
  truncated_path = path <> ".truncated"
  File.write!(truncated_path, File.read!(path) <> <<0, 0, 0, 20, 1, 2, 3>>)
  Harness.FlightRecorder.load(truncated_path)
  ```

  **Pass criteria:** loading succeeds and all previously completed transitions
  remain available. Only the incomplete final frame is ignored.

### 4.10 Unified session observability

- [ ] During an active long-running tool, call `Harness.status(session)` from
  another process or use attachment `/inspect`.

  **Pass criteria:**

  - `phase` identifies provider or tool execution.
  - `current_effect` identifies its kind/ref and tool name when applicable.
  - `task_count` is positive while work is active.
  - `mailbox_length`, subscriber count, event head/retention, worker health,
    recording path, and recorded transition count are present.
  - After completion/interruption, phase returns to idle, current effect becomes
    nil, and task count returns to zero.

### 4.11 Coordinator observability

- [ ] Reuse a running coordinator from section 3 and inspect
  `Harness.Coordinator.status/1` repeatedly.

  **Pass criteria:** it exposes parent session ID, child supervisor, stable run
  ID/pattern, child session and task relationships, worker health, live active
  and queued counts, completed count, elapsed/remaining time, and estimated
  token used/remaining. Values move in the expected direction as children start
  and finish.

### Flight recorder and observability acceptance criteria

- [ ] Every core fact and resulting effect/state projection is recorded with a
  stable causal transition ID.
- [ ] Persistent recordings are versioned, framed, mode 0600, and load offline.
- [ ] Replay invokes no providers or tools and matches the current core.
- [ ] An intentionally changed core reports the first meaningful divergence.
- [ ] Insert/replace/drop fault injection produces a replay branch without side
  effects.
- [ ] `/why` explains live events and durable transitions through causal links.
- [ ] History rebase and plugin reload create independent replay segments.
- [ ] Plugin PIDs/executable references do not prevent offline replay.
- [ ] Session, worker, coordinator, budget, and child relationships are visible
  through status APIs.

---

## 5. Final sign-off record

Record the environment and results used for acceptance:

```text
Date:
Tester:
Commit:
Elixir version:
OTP version:
OS:

Detachable server: PASS / FAIL
Remote executors: PASS / FAIL
Multi-agent coordination: PASS / FAIL
Flight recorder/replay: PASS / FAIL
Observability: PASS / FAIL
Full automated suite: PASS / FAIL

Notes / failed step numbers:
```

The implementation is accepted only when every top-level acceptance criterion
is checked or an explicitly documented exception has been reviewed.
