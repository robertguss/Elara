# Elara feature and manual test checklist

This is an inventory and verification worksheet for functionality that is
currently shipped. It is not a roadmap or a status source;
[`ROADMAP.md`](ROADMAP.md) is the sole source for those. In particular, this
file does not mark SPLIT-5 complete.

Use this during the SPLIT-5 daily-driver period to distinguish features that
work in real use from features that only have automated coverage.

## How to use this checklist

- `[ ]` means not yet verified. Change it to `[x]` only after observing the
  expected result through the command or public API described here.
- Add failures and surprises to the issue log at the end. Do not check an item
  merely because its automated test passes.
- Tests marked **credentials** make provider requests and consume account/API
  quota. Tests marked **multi-terminal** need the long-lived server or worker.
- Tests marked **destructive** intentionally interrupt or kill a process. Run
  them only in the disposable checkout described below.
- Model-selected tool calls are probabilistic. If the model does not follow a
  request to use a particular tool, record that as a usability observation; do
  not infer that the tool itself failed.

## Safe test setup

The built-in `write`, `edit`, and `bash` tools can modify files or run arbitrary
commands. Local plugins have the same OS access as Elara. Use a clean clone or a
disposable worktree, not a checkout with uncommitted work.

`mix elara.ask`, `mix elara.chat`, and a newly created TUI session use the Mix
process's current directory as the agent working directory. They do not have a
`--cwd` option. The public Elixir API accepts an absolute `cwd:` when embedding
Elara elsewhere.

```bash
# Run from a clean Elara checkout.
git worktree add /tmp/elara-manual-test HEAD
cd /tmp/elara-manual-test
mix deps.get
export PATH="$HOME/.cargo/bin:$PATH"
```

- [ ] I am testing in a disposable clean checkout (`git status --short` is empty
      before testing).
- [ ] Elixir 1.20, Erlang/OTP 29, Cargo, Rust, and `flock` are available.
- [ ] I will not paste tokens into this file, logs, prompts, or issue reports.

Cleanup after testing:

```bash
cd /path/to/the/original/elixir-harness
git worktree remove --force /tmp/elara-manual-test
```

## 1. Build and automated baseline

These checks are deterministic and credential-free. The first Mix compile builds
`native/exec-stub`; the first TUI invocation builds `native/elara-tui`. A
missing Cargo executable must fail with actionable setup guidance rather than
silently omitting either Rust program.

- [ ] `mix deps.get` succeeds.
- [ ] `mix format --check-formatted` exits 0.
- [ ] `mix compile --warnings-as-errors` exits 0 and produces the Rust exec stub
      under the Mix application build.
- [ ] `cargo fmt --check --manifest-path native/exec-stub/Cargo.toml` exits 0.
- [ ] `cargo clippy --all-targets --manifest-path native/exec-stub/Cargo.toml -- -D warnings`
      exits 0.
- [ ] `cargo test --manifest-path native/exec-stub/Cargo.toml` passes 3 tests.
- [ ] `cargo fmt --check --manifest-path native/elara-tui/Cargo.toml` exits 0.
- [ ] `cargo clippy --all-targets --manifest-path native/elara-tui/Cargo.toml -- -D warnings`
      exits 0.
- [ ] `cargo test --manifest-path native/elara-tui/Cargo.toml` passes 5 tests
      plus the empty binary/doc targets.
- [ ] `mix test` passes. The intentional `Elara.SessionTest.CrashTool`
      `RuntimeError: boom` log is expected; the final ExUnit result is
      authoritative.
- [ ] `rg 'System\.shell' lib/` prints no matches.

Baseline notes (commit, OS/terminal, command output, duration):

>

## 2. Authentication and providers

### ChatGPT/Codex subscription (**credentials**)

```bash
mix elara.login openai
export ELARA_PROVIDER=openai-codex
# Optional override; current default is gpt-5.3-codex.
export ELARA_MODEL=gpt-5.3-codex
mix elara.ask "Reply with exactly: codex provider works"
```

- [ ] Device login prints an OpenAI URL and code, waits for authorization, and
      saves `~/.elara/openai-codex-auth.json`.
- [ ] `stat -c '%a %n' ~/.elara/openai-codex-auth.json` reports mode `600`.
- [ ] An eligible ChatGPT Plus/Pro Codex subscription completes a real turn when
      `ELARA_PROVIDER=openai-codex` is set.
- [ ] Assistant text streams rather than appearing only at the end.
- [ ] A multi-turn session that uses a tool can continue afterward, proving
      provider-native call IDs/reasoning state survive the tool round trip.
- [ ] After exiting and running `mix elara.chat --continue`, another turn works.
- [ ] The Rust TUI does not display provider-private encrypted reasoning or
      native provider metadata.
- [ ] `ELARA_MODEL` successfully selects another entitled Codex model, if an
      override is needed.

This uses ChatGPT plan limits, not OpenAI Platform API-key billing. Elara stores
and refreshes its own OAuth tokens; it does not import credentials from Codex,
Pi, or another harness.

### Grok device login (**credentials**)

```bash
unset ELARA_PROVIDER ELARA_API_KEY XAI_API_KEY
mix elara.login                 # `mix elara.login grok` is equivalent
mix elara.ask "Reply with exactly: grok login works"
```

- [ ] Device login succeeds and saves `~/.elara/auth.json` with mode `600`.
- [ ] A real turn succeeds with saved Grok credentials.
- [ ] If no Elara auth file exists but `~/.grok/auth.json` does, Elara imports
      it successfully.
- [ ] Token refresh works when the saved access token expires.

An HTTP 403 after successful Grok login means the account lacks API entitlement;
repeating login is not expected to fix it.

### API key / OpenAI-compatible endpoint (**credentials**)

```bash
unset ELARA_PROVIDER
export ELARA_API_KEY='...'
# Optional overrides:
export ELARA_BASE_URL='https://api.x.ai/v1'
export ELARA_MODEL='grok-4'
mix elara.ask "Reply with exactly: api key works"
```

- [ ] `ELARA_API_KEY` authenticates successfully.
- [ ] `XAI_API_KEY` works when `ELARA_API_KEY` is unset.
- [ ] When both exist, `ELARA_API_KEY` takes precedence.
- [ ] `ELARA_BASE_URL` and `ELARA_MODEL` select the intended compatible endpoint
      and model; `XAI_MODEL` is used only when `ELARA_MODEL` is unset.
- [ ] `ELARA_PROVIDER=grok` explicitly selects saved Grok login instead of an
      API key.
- [ ] An unknown `ELARA_PROVIDER` fails with a clear configuration error.

Provider/account/model tested:

## 3. Quick daily-driver smoke test (**credentials**)

This is the short check to repeat during normal use.

```bash
export ELARA_PROVIDER=openai-codex   # or configure another provider above
mix elara.tui new
```

- [ ] One command starts both an embedded Elixir server and the Rust TUI when
      port 4048 is free.
- [ ] The TUI shows a stable session ID and the correct working directory.
- [ ] Typing a prompt and pressing Enter starts a turn.
- [ ] Assistant content streams live and settles without duplicated text.
- [ ] Tool activity and its `pending`/`running`/terminal state are visible.
- [ ] Ask Elara to read `README.md`; it reads and accurately summarizes it.
- [ ] Ask Elara to write `.elara-manual/nested.txt`; parent directories are
      created and the bytes on disk are correct.
- [ ] Ask Elara to replace one unique string in that file with `edit`; exactly
      that occurrence changes.
- [ ] Ask Elara to run `printf stdout; printf stderr >&2; exit 3`; merged output
      is visible and the tool reports nonzero exit 3 as an error.
- [ ] A second ordinary prompt works in the same session.
- [ ] Pressing Escape or Ctrl-C exits the TUI cleanly.
- [ ] `git status --short` shows only changes intentionally requested during the
      test.

Daily smoke notes (date, task, terminal, latency, friction):

>

## 4. One-shot and persistent line clients (**credentials**)

### `mix elara.ask`

- [ ] `mix elara.ask "summarize this repository"` prints tool activity and a
      final answer, then exits 0.
- [ ] A provider error, explicit interruption, wait timeout, or 12-iteration
      turn limit exits nonzero rather than reporting success.
- [ ] The one-shot conversation is not offered by a later `--continue`.

### `mix elara.chat`

```bash
mix elara.chat
mix elara.chat "what starts this application?"
mix elara.chat --name "manual verification" "summarize README.md"
mix elara.chat --continue
mix elara.chat --continue "continue with one concise observation"
```

- [ ] Plain `mix elara.chat` creates a new persisted session rather than
      silently continuing an old one.
- [ ] An optional first prompt starts immediately.
- [ ] `--name TEXT` creates a named session.
- [ ] `--continue` resumes the newest usable session scoped to this working
      directory and prints its transcript.
- [ ] `--continue` with a prompt resumes and starts that prompt.
- [ ] `--continue` fails instead of creating a session when this working
      directory has no saved session.
- [ ] A provider error ends only the current turn and returns to the `> `
      prompt.
- [ ] Submitting another prompt while a turn is active reports busy/refused.
- [ ] Session files under `~/.elara/sessions/<cwd-key>/` are mode `600`.
- [ ] **Multi-terminal:** a second process cannot concurrently take the same
      persisted session lock.

### Chat command matrix

- [ ] `/help`, `/h`, and `/?` show help while idle and during a turn.
- [ ] `/interrupt` and `/stop` are idle no-ops and cancel an active turn.
- [ ] `/resume` lists cwd-scoped sessions newest first; `/resume N` switches to
      the selected session and prints its transcript.
- [ ] `/tree` lists user turns; `/tree N` branches before that turn in the same
      session file and re-submits it.
- [ ] `/fork` lists user turns; `/fork N` branches into a new session file and
      re-submits the selected turn without changing the source file.
- [ ] `/clone` copies the complete active history path into a new session file
      without re-submitting a prompt.
- [ ] `/name TEXT` updates the current session's display name.
- [ ] `/reload` reloads this session's local plugins while idle.
- [ ] `/why` explains the latest emitted event; `/why N` selects event sequence
      N and shows the transition, triggering fact, and causal chain.
- [ ] `/quit`, `/exit`, `/q`, and Ctrl-D exit while idle.
- [ ] During a turn, the first quit interrupts and waits to exit; a second quit
      exits immediately.
- [ ] Prefixing `//` sends text beginning with `/` as a normal prompt.
- [ ] Commands that mutate session/history/plugin state are refused during an
      active turn.

## 5. Rust TUI and detachable sessions (**credentials**)

### Embedded one-command mode

- [ ] `mix elara.tui new` starts an embedded server only for `new` when the
      selected port is free.
- [ ] Leaving this TUI ends its embedded server and live sessions; reattachment
      is not promised in this mode.
- [ ] If a non-Elara process occupies the port, the client fails closed with a
      protocol/connection error and does not replace that process.

### Long-lived server mode (**multi-terminal**)

Terminal A:

```bash
ELARA_PROVIDER=openai-codex elixir --erl "+Bc" -S mix elara.server
```

Terminal B:

```bash
mix elara.tui new
# Save SESSION_ID from the status bar.
mix elara.tui list
mix elara.tui SESSION_ID
mix elara.tui SESSION_ID --observe
```

- [ ] A running server is reused; `new` does not start a competing server.
- [ ] `list` shows each live session's ID, state, head, and working directory.
- [ ] Escape/Ctrl-C detaches without interrupting an active turn.
- [ ] Work continues with no TUI attached, and attaching by `SESSION_ID` shows
      the exact settled history once, with no missing or duplicated text.
- [ ] Reattaching does not change the session working directory.
- [ ] Only one controlling attachment can ask or interrupt.
- [ ] A second `--observe` attachment receives the same live projection but an
      attempt to mutate is rejected as `not_controller`.
- [ ] Ctrl-X explicitly interrupts an active provider or tool turn; every
      attached client converges on the interrupted state.
- [ ] Cursor/incarnation data is persisted in `~/.elara/tui/cursors.json` and a
      later attachment converges from an atomic snapshot.
- [ ] Stopping the server VM ends live sessions. This is detachability, not
      automatic resurrection after server failure.

The server owns provider configuration. Set `ELARA_PROVIDER` and related
variables on Terminal A; changing them only for a TUI process does not
reconfigure an existing server.

### Port and diagnostic modes

```bash
mix elara.server --port 14048
mix elara.tui new --port 14048
ELARA_SERVER_PORT=14048 mix elara.tui list
mix elara.tui SESSION_ID --headless --event-dump \
  --width 100 --height 24 --ask "reply briefly"
mix elara.tui SESSION_ID --headless --ask "run sleep 30" \
  --interrupt-after-ms 250 --timeout-ms 5000
```

- [ ] `--port` works for both server and TUI.
- [ ] `ELARA_SERVER_PORT` is used when `--port` is absent.
- [ ] `--headless` renders a deterministic off-screen terminal frame and exits
      after the optional ask settles.
- [ ] `--event-dump` emits each received JSON frame with arrival latency.
- [ ] The headless summary reports session/incarnation, saved cursor/head,
      ask-to-active latency, and ask-to-first-delta latency.
- [ ] `--interrupt-after-ms` interrupts an active headless turn.
- [ ] Frames smaller than 40×8 are rejected clearly.
- [ ] A forced sequence gap, malformed patch, or incarnation change triggers
      exactly one resnapshot while one is pending (deterministic coverage:
      `mix test test/elara/protocol_v2_test.exs test/elara/tui_test.exs`).
- [ ] Protocol frames/snapshots over the 16 MiB limit fail closed.

## 6. Built-in tools and execution safety

### Functional behavior (**credentials** for model-driven checks)

- [ ] `read` returns file contents or an actionable read error.
- [ ] Default local `write` creates parent directories and atomically writes a
      workspace-relative regular file.
- [ ] Default local `write` rejects absolute paths, `..`, symlink path
      components, and non-file targets.
- [ ] `edit` changes exactly one occurrence.
- [ ] `edit` rejects zero matches without changing the file.
- [ ] `edit` rejects multiple matches without changing the file.
- [ ] `bash` runs through `/bin/sh -c` in the session cwd with stdout/stderr
      merged, preserving successful output, nonzero exit codes, and signals.
- [ ] Tool output retained in model history is capped at 16 KiB by default.
- [ ] Every tool call times out after 30 seconds by default.
- [ ] A turn stops after 12 provider iterations by default.

`read` and `edit` expand paths and `bash` is unrestricted; unlike default local
`write`, they are not workspace confinement boundaries. There is no shell
approval layer or OS sandbox.

### Rust execution-stub guarantees (**destructive**)

The exact kill/flood/stub-loss checks use the public session API with a scripted
provider and disposable child processes:

```bash
mix test test/elara/exec_integration_test.exs
```

- [ ] Explicit `Elara.interrupt/1` kills the command and ordinary background
      descendants in its process group.
- [ ] Timeout kills the process group and reports `timed out`.
- [ ] A byte flood is killed at source, retains only the configured cap, and
      reports truthful `bytes_total`/`bytes_sent` accounting.
- [ ] Exec-stub death reports every in-flight job as `indeterminate`, guardian
      cleanup removes descendants, and a replacement stub accepts later jobs.
- [ ] Abrupt BEAM death closes the Port; stub EOF cleanup leaves no ordinary
      command descendants.
- [ ] A deliberately hostile process that escapes its group with `setsid` is
      understood to be outside the zero-descendant guarantee.

Do not manually kill the shared exec stub during valuable work: one supervised
stub serves the BEAM, so all concurrent in-flight shell outcomes become
indeterminate if it dies.

## 7. Durable local writes and recovery (**destructive/advanced**)

The production receipt path currently applies only to the exact default local
built-in `write`. It does not cover `edit`, `bash`, plugins, custom tools, or
remote mutations.

- [ ] A normal built-in write records durable controller intent, executor
      acceptance/callback evidence, and a terminal result.
- [ ] Executor ledgers exist under `~/.elara/sessions/_effect_executors/`; a
      persisted session's controller journal sits beside its JSONL session file.
- [ ] `mix elara.chat --continue` reconciles an unresolved write before
      accepting another prompt.
- [ ] A recorded terminal receipt is returned after resume without rewriting the
      file.
- [ ] Accepted work whose callback never started continues only under the same
      job and executor identity.
- [ ] A callback attempt with no durable terminal receipt becomes
      `indeterminate` and is not retried, even when current file bytes look
      right.
- [ ] Executor startup, identity, ledger, and reconciliation failures fail
      closed rather than silently running an unreceipted write.

The crash windows are timing-sensitive and unsafe to reproduce by hand. Their
deterministic public-session coverage is:

```bash
mix test test/elara/effect/production_write_test.exs
```

Record whether durable recovery occurred during real daily use, separately from
running that test: **yes / no**, details:

## 8. Session persistence and branching

- [ ] Persistence is scoped by absolute working directory.
- [ ] Session IDs remain stable across public API calls and process lookup.
- [ ] The active transcript is a message-tree path, not merely a flat log.
- [ ] Later messages on an old `/tree` branch remain in the same JSONL but are
      not sent on the new active path.
- [ ] `/fork` and `/clone` create distinct session files; `/tree` does not.
- [ ] Resume, tree, fork, clone, and naming require an idle session.
- [ ] Only one turn can run in a session at once; independent sessions can run
      in parallel.
- [ ] An interrupted tool call gets a matching interrupted tool result in
      history, so the next provider request has no unmatched call.
- [ ] Only final assistant messages are persisted; partial streamed text is not
      later presented as a complete answer.

## 9. Live plugins (**credentials**, trusted code)

Use the documented `CounterPlugin` from [`docs/plugins.md`](docs/plugins.md) in
`.elara/plugins/counter.exs`, then start a new chat.

- [ ] `.ex` and `.exs` files under `cwd/.elara/plugins/` are discovered in
      sorted order when a session starts.
- [ ] Exactly one module implementing `Elara.Plugin` is accepted per file.
- [ ] The plugin tool is advertised beside `read`, `write`, `edit`, and `bash`.
- [ ] Calling `counter` repeatedly proves state is session-local and retained.
- [ ] After changing implementation/version, `/reload` installs a new immutable
      generation without restarting chat and preserves the plugin process/state.
- [ ] A `migrate/2` callback converts old state to a new representation.
- [ ] Without `migrate/2`, plain-data state is preserved as-is.
- [ ] Parse, compile, contract, duplicate-tool, initialization, or migration
      failure leaves the prior generation and state active.
- [ ] Reload is refused during a turn and while an interrupted call still owns
      its state lease.
- [ ] Duplicate names across built-ins/plugins or between plugins are rejected.
- [ ] `Elara.start_session(plugins: [])` disables discovery; explicit absolute
      plugin paths select only those files.
- [ ] `Elara.plugins/1` reports active metadata and `Elara.reload_plugins/1`
      performs the same reload through the public API.

Plugins execute inside the Elara VM with Elara's filesystem, network, and OS
access. They are not sandboxed or a package-security boundary.

Record whether plugin reload was used during real daily work: **yes / no**,
details:

## 10. Remote workers (**multi-terminal**, **credentials**, advanced)

Terminal A starts a worker whose logical workspace `manual` maps to its own cwd:

```bash
ELARA_WORKER_TOKEN='replace-with-a-temporary-secret' \
  mix elara.worker manual --cwd "$PWD" --port 4049
```

Terminal B starts `iex -S mix`, then evaluates:

```elixir
:ok = Elara.register_worker(
  id: "manual-worker",
  executor:
    {Elara.Executor.Remote,
     %{host: {127, 0, 0, 1}, port: 4049,
       token: "replace-with-a-temporary-secret"}},
  capabilities: ["filesystem:read", "filesystem:write", "shell"],
  workspaces: ["manual"]
)

remote_tools = Enum.map(Elara.Tool.builtins(), &%{&1 | placement: :remote})

{:ok, remote_session} = Elara.start_session(
  cwd: File.cwd!(),
  workspace_id: "manual",
  tools: remote_tools
)

Elara.workers()
Elara.ask(remote_session, "Use read to summarize README.md")
```

- [ ] The default worker advertises `filesystem:read`, `filesystem:write`, and
      `shell`; repeated `--capability CAP` flags restrict that set.
- [ ] A wrong shared token is rejected.
- [ ] Registration appears in `Elara.workers/0` with health, capabilities, and
      workspace metadata.
- [ ] Routing matches both logical workspace ID and required capabilities.
- [ ] The worker uses its own workspace mapping, not the brain node's cwd.
- [ ] Remote `read`, `write`, and `edit` reject absolute paths, traversal, and
      symlink escapes.
- [ ] `allowed_capabilities: ["filesystem:read"]` permits remote reads and
      rejects write/edit/bash before routing.
- [ ] Read-only transport failure can retry another matching healthy worker.
- [ ] Mutating transport loss is never blindly retried and reports
      `indeterminate` because the side effect may have occurred.
- [ ] `--public` binds all interfaces only when explicitly selected.

The worker protocol is authenticated TCP without TLS. `--public` is suitable
only on a protected network or inside a secure tunnel. Capability/path checks
are not an OS sandbox; pre-existing hard links, concurrent path replacement, and
unrestricted `bash` require a real container/sandbox for untrusted work.

Record whether remote workers were used during real daily work: **yes / no**,
details:

## 11. Public Elixir API (**credentials**, advanced)

Use `iex -S mix` for these checks. See
[`docs/elixir-api.md`](docs/elixir-api.md) for complete examples.

### Sessions, events, and configuration

- [ ] `Application.ensure_all_started(:elara)` and
      `Elara.start_session(cwd: absolute_path)` return `{:ok, session_id}`.
- [ ] `Elara.ask/3` blocks and returns `{:ok, final_text}` or a typed busy,
      turn-limit, interrupted, or provider error.
- [ ] `Elara.subscribe/1` plus `Elara.ask_async/2` emits turn-start, message,
      tool, streaming, and turn-end events.
- [ ] `Elara.interrupt/1` cancels an asynchronous active turn.
- [ ] `Elara.transcript/1` returns the active message path.
- [ ] `Elara.status/1` exposes phase/effect, mailbox/task counts, subscribers,
      event range, worker health, and recording metadata.
- [ ] `Elara.materialized_view/1` exposes Elixir's current messages, tool
      statuses/outcomes, turn state, usage (`nil` today), and content deltas.
- [ ] `Elara.session_pid/1` resolves a live stable ID and rejects a missing one.
- [ ] `persist: false` keeps session/history recording in memory and cannot be
      combined with `resume:`.
- [ ] `provider:`, `tools:`, `plugins:`, `system:`, `max_iterations:`,
      `tool_timeout_ms:`, `max_tool_output_bytes:`, `persist:`, `resume:`,
      `name:`, `allowed_capabilities:`, `workspace_id:`, and `router:` alter
      only their documented session behavior.
- [ ] With no `system:` override, the built-in prompt includes `cwd/AGENTS.md`
      when that exact file exists.

### Persistence API

- [ ] `Elara.list_sessions/1`, `name_session/2`, and `user_entries/1` return
      cwd-scoped data.
- [ ] `Elara.resume/2` hydrates an idle live session from an allowed session
      path for the same cwd.
- [ ] `Elara.tree/2`, `fork/2`, and `clone_session/1` have the same branch/file
      semantics as the chat commands.

### Custom tools

- [ ] A custom `%Elara.Tool{}` with JSON Schema and an arity-2 MFA receives
      `(arguments, %Elara.Tool.Ctx{})` and can return `{:ok, text}`,
      `{:error, text}`, or `{:indeterminate, text}`.
- [ ] Tool version, capabilities, placement (`:local`, `:remote`, `:any`), and
      mutating metadata are honored.
- [ ] Duplicate tool names raise at session startup.

## 12. Flight recording, replay, and causal explanation (advanced)

```elixir
status = Elara.status(session)
recording = Elara.recording(session)
{:ok, report} = Elara.replay(recording)
{:ok, loaded} = Elara.FlightRecorder.load(status.recording_path)
{:ok, disk_report} = Elara.replay(status.recording_path)
{:ok, explanation} = Elara.why(session)
{:ok, selected} = Elara.why(session, status.event_head)
```

- [ ] Every persistent session writes a versioned `.flight` file beside its
      JSONL transcript; in-memory sessions expose an in-memory recording.
- [ ] Replay returns `status: :match` without calling the provider or executing
      tools.
- [ ] Loading and replaying the on-disk path reaches the same result.
- [ ] `why` identifies a transition/recording, triggering fact, effect, and
      causal chain for the latest or selected event.
- [ ] `step: &OtherCore.step/2` can detect and report a divergent reducer.
- [ ] `inject: %{sequence => {:insert, fact}}`,
      `inject: %{sequence => {:replace, fact}}`, or
      `inject: %{sequence => :drop}` performs counterfactual transition fault
      injection and reports an injected replay.
- [ ] Truncated tail records are ignored safely; genuinely incomplete recorded
      transitions are reported rather than treated as a match.

## 13. Coordinated child sessions (**credentials**, advanced/costly)

Start a parent session, then use `Elara.start_coordinator/2` and
`Elara.Coordinator.run/4` as shown in
[`docs/elixir-api.md`](docs/elixir-api.md). Use small prompts and budgets: every
child can make provider requests.

- [ ] `:parallel` runs independent bounded child specs.
- [ ] `:specialists` assigns distinct roles/prompts.
- [ ] `:candidates` runs candidates and a required `judge:` selects one.
- [ ] `:map_reduce` runs map children and a required `reducer:` combines them.
- [ ] Child specs require unique `id:` and `prompt:`; `role:` defaults to
      `:general`.
- [ ] `max_concurrency`, `token_budget`, `time_budget_ms`, and maximum result
      size bound a run; status reports used/remaining budgets and child
      progress.
- [ ] Child failures are isolated and represented in the structured result;
      compact results do not insert child transcripts into the parent.
- [ ] `Elara.Coordinator.kill_child/2` kills one child without stopping
      siblings.
- [ ] A `role: :coding` child receives a distinct detached Git worktree; this
      requires the parent cwd to be a Git checkout.
- [ ] Stopping the coordinator stops children and removes temporary coding
      worktrees.
- [ ] Coordinator status includes currently registered worker health.

## 14. Security boundaries and documented limits

- [ ] I understand local file/shell tools and plugins are trusted code, not
      sandboxed execution.
- [ ] I understand remote worker authentication/capabilities/path checks are
      enforcement layers, not an OS sandbox.
- [ ] I verified that new session cwd controls relative tools, shell cwd, plugin
      discovery, session scope, and the optional exact `cwd/AGENTS.md`.
- [ ] I observed or accepted the defaults: 12 model iterations, 30-second tool
      timeout, 16 KiB retained tool output, 1,000 retained v1 events, and 16 MiB
      maximum socket protocol message.
- [ ] I understand `usage` is currently `nil`, snapshots over 16 MiB fail
      closed, and the Rust binaries are built from source rather than
      distributed as prebuilt cross-platform releases.
- [ ] I understand exec-stub process-group behavior currently depends on Unix
      primitives and is not a promise of Windows portability.

## 15. SPLIT-5 daily-driver evidence

SPLIT-5 requires two weeks of daily use **or** the next five session/UI
features, whichever comes first. For each feature, record whether Rust needed to
duplicate Elixir session policy/transition logic and estimate boundary
protocol/DTO time as a share of total implementation time.

| Date | Session/UI feature or real task | Worked? | Rust duplicated policy/transition logic? | Total implementation time | Protocol/DTO time | Boundary share | Notes/issue |
| ---- | ------------------------------- | ------- | ---------------------------------------- | ------------------------- | ----------------- | -------------- | ----------- |
|      |                                 |         |                                          |                           |                   |                |             |
|      |                                 |         |                                          |                           |                   |                |             |
|      |                                 |         |                                          |                           |                   |                |             |
|      |                                 |         |                                          |                           |                   |                |             |
|      |                                 |         |                                          |                           |                   |                |             |

BEAM-specific feature usage during the period:

| Feature                | Actually used in real work? | Frequency / task | Useful, neutral, or friction? |
| ---------------------- | --------------------------- | ---------------- | ----------------------------- |
| Detached sessions      |                             |                  |                               |
| Plugin reload          |                             |                  |                               |
| Remote workers         |                             |                  |                               |
| Durable write recovery |                             |                  |                               |

Go/no-go calculation (record evidence in `ROADMAP.md` only when making the owner
decision):

- Features that duplicated policy: ___ / 5.
- Aggregate protocol/DTO time: ___ / ___ = ___%.
- Were BEAM-specific features actually used? ___
- Reverse to Rust-everything if 3 of 5 features duplicated policy, boundary work
  exceeded 30%, **or** the BEAM-specific features went unused. Otherwise keep
  the split and choose the next queue from the items currently blocked on
  SPLIT-5.

## Issue and usability log

Capture both correctness bugs and daily-driver friction (startup, key handling,
rendering, latency, provider behavior, unclear errors, excess token use).

| Date | Feature/check | Environment | Expected | Observed | Reproducible? | Severity / follow-up |
| ---- | ------------- | ----------- | -------- | -------- | ------------- | -------------------- |
|      |               |             |          |          |               |                      |
