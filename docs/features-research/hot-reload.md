# Hot reload and what the BEAM unlocks

> **Status:** exploration note, observed 2026-09-06 on Elixir 1.20.3 / OTP 29.0.5.
> This file records what live code reload does and does not do in Elara today,
> the evidence, and the capabilities it makes cheap. It is not a queue.
> `ROADMAP.md` holds status; nothing here is scheduled by being written down.

## 1. The question and the short answer

Can layouts, themes, plugins, skills, tools, and eventually MCP servers change
inside a live session without stopping it, and what else does that unlock?

- **Elixir authority: yes, and it is already used.** Plugin reload is a
  shipped product path (`/reload`, `session_reload` over protocol v2,
  `Elara.reload_plugins/1`). Whole-module reload of the harness itself works
  underneath a live session; §3 records the measurements.
- **Rust edges: no, by design.** The TUI and the execution stub are separate
  processes across a socket and a Port. They are *replaced*, not reloaded, and
  the session does not notice (§5).
- **Themes and layouts already switch live** inside the TUI (F3, Enter). That
  is Rust view state and has nothing to do with BEAM code loading. Adding a new
  theme or layout needs a Rust rebuild and a client restart.
- **The interesting unlocks are functional, not visual** (§6): the model
  extending its own tool set mid-session, skills discovered mid-session, MCP
  servers as supervised Ports, and patching the harness under a running
  conversation with a replay-based proof that no past decision changed.

## 2. What exists today

| Surface | Mechanism | Live in a session? | Boundary |
| --- | --- | --- | --- |
| Themes, layouts, diagnostics row | `native/elara-tui/src/appearance.rs`; slot colours resolved in the final paint pass | Yes: F3 picker, Enter applies, `s` saves defaults | Rust view state only; new variants need a rebuild |
| Plugins | `Elara.Plugin.Loader` compiles each revision into a content-addressed module; `Elara.Plugin.Server` swaps generations under a lease and migrates state | Yes: `/reload`; refused while a turn runs or a lease is held | Trusted local code, not a sandbox |
| Tool table | `Elara.Session.Core.replace_tools/2` | Only at `phase: :idle` | Tools are `%Tool{run: {module, function}}` MFA data, never closures |
| System prompt | `{:instruction_context, system}` fact; `sync_instruction_context/1` in the session shell | Yes, even mid-turn: nested `AGENTS.md` is re-rendered when a tool touches a path | Skills catalog is snapshotted at session start |
| Skills bodies | `skill` tool loads one `SKILL.md` on demand | Yes | Catalog discovery runs once, in `Elara.start_session/1` |
| Execution stub | `Elara.Exec` owns the Port; restarts the stub 100 ms after exit; in-flight jobs report `indeterminate` | Restart, not reload | `mix compile` copies in place and refuses with `etxtbsy` while a stub runs |
| TUI | Protocol v2 snapshot-on-attach plus sequenced patches; reconnect in `main.rs` | Reattach, not reload | Cursor in `~/.elara/tui/cursors.json` |
| Session process | `restart: :temporary` under `Elara.SessionSup`; JSONL store; `/resume` | n/a | A crashed session is resumed from disk, not resurrected |

Two conventions already in the codebase are what make code reload safe here:
tool `run` fields are MFA data, and Core is a pure reducer fed by recorded facts
so the flight recorder can replay a real session through new code.

## 3. Evidence

Three throwaway scripts ran under `mix run` from the repo root with the scripted
provider, `persist: false`, and `:sessions_root` pointed at a scratch directory.
No repo files changed. The scripts were not kept; §3.1 is a reproducible
condensation.

| Probe | Observed |
| --- | --- |
| Hot-load a patched `Elara.Tools` (read result prefixed) between turns | Loaded in 34 ms; the next turn of the same session returned the patched output |
| `Code.compile_file("lib/elara/session.ex")` under the live session | 1 650 ms; same pid, alive, 12 messages and 3 user turns intact |
| `Elara.replay(Elara.recording(id))` after both reloads | `:match` over 12 transitions |
| `:sys.get_state/1` on the session | `core.phase = :idle`; tool table lists the 10 built-ins; `read` still points at `{Elara.Tools, :read}` |
| Reload `Elara.Session.Core`, `Elara.Session`, and `Elara` twice each with *changed* code, session idle | Every session survived; `:erlang.check_process_code/2` reported no old-code references |
| Call the `handoff_fault_hook` fun the session had stored before `Elara` was reloaded twice | Raised `function #Function<...> is invalid, likely because it points to an old version of the code` |
| Reload `Elara.Session` twice with changed code while a 1.5 s tool task was running | Task finished, turn ended `{:completed, "turn done"}`, session alive |

### 3.1 Reproduce the core result

```elixir
# hot_reload_probe.exs — run with: mix run hot_reload_probe.exs
scratch = Path.join(System.tmp_dir!(), "elara-hot-reload")
Application.put_env(:elara, :sessions_root, Path.join(scratch, "sessions"))
cwd = Path.join(scratch, "work")
File.mkdir_p!(cwd)
File.write!(Path.join(cwd, "hello.txt"), "hello from disk\n")

alias Elara.Message
alias Elara.Message.ToolCall
read = fn id -> %ToolCall{id: id, name: "read", args: {:ok, %{"path" => "hello.txt"}}} end

replies =
  for n <- 1..2,
      reply <- [
        {:ok, %Message.Assistant{tool_calls: [read.("r#{n}")]}},
        {:ok, %Message.Assistant{text: "turn #{n} done"}}
      ],
      do: reply

{:ok, agent} = Agent.start_link(fn -> replies end)

{:ok, id} =
  Elara.start_session(provider: {Elara.Provider.Scripted, agent}, cwd: cwd, persist: false)

last_read = fn ->
  Elara.transcript(id)
  |> Enum.filter(&match?(%Message.ToolResult{name: "read"}, &1))
  |> List.last()
  |> Map.fetch!(:outcome)
end

{:ok, _} = Elara.ask(id, "read hello.txt")
IO.inspect(last_read.(), label: "before reload")

source = File.read!("lib/elara/tools.ex")
patched = String.replace(source, "{:ok, content} -> {:ok, content}",
  ~s({:ok, content} -> {:ok, "[HOT] " <> content}))
true = patched != source
Code.put_compiler_option(:ignore_module_conflict, true)
Code.compile_string(patched, "hot/tools.ex")

{:ok, _} = Elara.ask(id, "read again")
IO.inspect(last_read.(), label: "after reload")

{:ok, report} = Elara.replay(Elara.recording(id))
IO.inspect({report.status, report.transitions}, label: "replay through current code")
```

Expected output: `before reload: {:ok, "hello from disk\n"}`, then
`after reload: {:ok, "[HOT] hello from disk\n"}`, then `{:match, 8}`.

## 4. How BEAM code loading behaves here, and the two real hazards

The VM keeps at most two versions of a module: *current* and *old*. Loading a
new version makes the previous current version old and purges whatever was old
before. Fully qualified calls such as `Core.step/2` always reach the current
version, which is why a GenServer picks up new code on its next message and why
the session shell survived a reload of its own module.

**Hazard 1: stale anonymous funs.** On OTP 29 a process is *not* killed for
holding an anonymous fun from a purged module version. The fun fails later, when
called. The session shell stores two such funs from `lib/elara.ex`,
`handoff_fault_hook` and `effect_fault_hook`, both defaulting to
`fn _ -> :ok end`, and invokes them during handoff stages. Reloading `Elara`
twice with changes therefore plants a crash at the next handoff of every live
session. The fix is to carry these hooks as MFA tuples or external captures,
which is the rule tools already follow. Do this before relying on reload for
anything beyond plugins.

**Hazard 2: reload while executing.** A process running old code on its stack is
killed when that version is purged. The in-flight tool task in §3 survived,
most likely because its closure tail-calls into another module, but that is a
property of the call shape and not a guarantee. Plugin reload already refuses
unless Core is idle and no plugin lease is held; any harness reload should use
the same gate. If a tool task is killed anyway, the session receives `:DOWN`,
records a tool crash, and the turn continues. The JSONL store and `/resume` are
the backstop for a botched reload.

Two further limits. A reload takes effect for the life of the VM only; the
source on disk stays the truth, and a module compiled from a patched string
diverges from it until the file is edited. And `recompile()` from a remote shell
runs the full Mix compile, including the exec-stub compiler, which is a no-op
when the Rust bytes are unchanged and otherwise refuses with `etxtbsy`.

## 5. What is not reloadable, and why that is fine

Rust cannot be hot-loaded, and the split decision does not want it to be.

- **TUI.** Quit, rebuild, relaunch, reattach. The attachment receives a fresh
  snapshot and the session never observes the client change. The appearance
  file survives. If file-defined themes are ever wanted, `Tokens` is fifteen
  colours and could be read from JSON next to the existing preferences file.
  Layouts are widget code and should stay compiled.
- **Execution stub.** Write the new binary to a temporary path and rename it
  over the old one, then stop the running stub. `Elara.Exec` restarts on the new
  inode and reports in-flight jobs `indeterminate`. The custom compiler in
  `mix.exs` copies in place today, which is why it collides with running
  servers; a write-then-rename would remove that collision.

## 6. What it unlocks, ranked by how much functionality changes

Each entry states what exists, the delta, and why the BEAM matters for it. None
of them claim exactly-once external effects or a sandbox; plugins and reloaded
code remain trusted local code with Elara's full OS access.

1. **The self-extending agent.** *Exists:* plugin compile in-VM, generations and
   leases, state migration, per-session revisions, idle-only reload, failed
   compiles leave the previous revision active. *Delta:* discover *new* plugin
   files on reload (today only already-loaded paths are re-read, so a new file
   needs a new chat), and expose reload as a tool or run it at the next idle
   boundary. *Why BEAM:* compile in milliseconds, a crashing plugin call kills a
   monitored task rather than the session, and a bad revision is rejected before
   it becomes current. The model can write a tool, load it, and use it in the
   same session.
2. **Skills discovered mid-session.** *Exists:* the `instruction_context` fact
   already re-renders the system prompt when nested `AGENTS.md` files apply.
   *Delta:* re-run `Elara.Skills.discover/2` on reload and call
   `sync_instruction_context/1`. *Why BEAM:* nothing exotic; it is small because
   prompt composition is already a fact fed to Core rather than a startup value.
3. **Harness self-patching with a regression oracle.** *Exists:* Elara runs from
   source; the flight recorder records every fact and `Elara.replay/2` reports
   `:match` or `:diverged` and accepts a candidate `step:` function and an
   `inject:` option for counterfactuals. *Delta:* run the server as a named node
   and use a remote shell, plus the hook fix from §4.

   ```bash
   elixir --sname elara -S mix elara.server
   iex --sname dev --remsh elara      # then: recompile()
   ```

   Every attached TUI stays connected because the wire contract is unchanged.
   Replaying the live session's recording afterwards answers "did my change
   alter any past decision in this conversation" deterministically for Core.
   Provider output is recorded as a fact, so replay does not call a model. Most
   harnesses cannot offer this because their loops are not pure reducers.
4. **MCP servers as supervised Ports.** *Exists:* both halves of the pattern.
   `Elara.Exec` supervises a stdio Port with restart and truthful
   `indeterminate` on loss; `Elara.Plugin.Server` owns a tool table with
   generation and lease semantics. *Delta:* one GenServer per MCP server that
   speaks JSON-RPC `initialize`, `tools/list`, and `tools/call` over the Port and
   exposes `%Tool{run: {Elara.MCP, :call}}` entries, attached at an idle boundary
   through `replace_tools/2`. *Why BEAM:* a crashed MCP server becomes an
   `indeterminate` tool result and a supervised restart, not a dead session, and
   one server process can serve many sessions through a registry. The roadmap
   keeps MCP out of the daily-driver trial, so this is post-checkpoint work.
5. **Two views, one truth.** *Exists:* control and observe attachments,
   snapshot-on-attach, per-session cursors. *Delta:* none. Open one session in
   two terminals with different layouts and themes, or observe a child thread
   over ssh. It is the honest demonstration that presentation is not state.
6. **Replace-not-reload for the Rust edges** (§5). Small, mechanical, and it
   removes the `etxtbsy` collision between `mix compile` and running servers.

## 7. Relationship to SPLIT-5

`docs/rust-elixir-split.md` §9 lists "plugin hot reload, detached sessions,
remote workers and durable recovery are simply unused" as a reversal signal.
Exercising reload and multi-attach during the checkpoint period is therefore
evidence the checkpoint asks for, not a diversion from it.

Recommended order, subject to the roadmap's one-executable-item rule: keep the
queue as it is; use the SPLIT-5 period to exercise plugin `/reload` and
two-terminal attachment for real; make the two fault hooks MFA data as a small
hardening; then, after the go/no-go, consider items 1 and 3 as bounded vertical
slices and item 4 as a separate design.

## 8. Provenance

Verified by running code: every row in §3, on this checkout at `9f92a4c`.
Verified by reading code: the mechanisms in §2, the TUI reconnect path, the
exec-stub restart path, the in-place copy in `mix.exs`, and the `session_reload`
command. Not verified: the tail-call explanation for the surviving tool task,
and any behaviour on OTP versions other than 29.0.5.
