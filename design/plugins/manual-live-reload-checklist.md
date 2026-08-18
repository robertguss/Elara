# Manual live-plugin reload checklist

This checklist verifies plugin discovery, real xAI tool invocation, state
continuity, state migration, reload rollback, per-session revision isolation,
safe reload boundaries, and the `/reload` CLI path.

Run it from the Harness repository on the `feature/live-plugin-reload` branch.
The plugin is trusted local code and runs with the same operating-system access
as Harness.

## 1. Preflight

- [ ] Check out the feature branch and verify the baseline:

  ```bash
  git switch feature/live-plugin-reload
  mix deps.get
  mix format --check-formatted
  mix compile --warnings-as-errors
  mix test
  ```

  Expected: compilation succeeds and all tests pass. The crash-recovery test
  intentionally logs a `RuntimeError: boom` line.

- [ ] Confirm xAI authentication without printing a credential:

  ```bash
  if [ -n "${HARNESS_API_KEY:-${XAI_API_KEY:-}}" ] || [ -f "$HOME/.harness/auth.json" ]; then
    echo "xAI credentials available"
  else
    echo "Run: mix harness.login"
  fi
  ```

- [ ] Check for existing plugins. Do not remove or overwrite them:

  ```bash
  find .harness/plugins -maxdepth 1 -type f 2>/dev/null || true
  ```

  The test plugin uses the unique ID `manual-counter` and tool name
  `manual_counter`. If either already exists, change both consistently in the
  snippets below.

- [ ] Create the plugin directory and clear only this checklist's old files:

  ```bash
  mkdir -p .harness/plugins
  rm -f .harness/plugins/manual_counter.exs \
    .harness/plugins/manual_counter.exs.good \
    .harness/manual-plugin-audit.log
  ```

## 2. Install revision 1

- [ ] Create `.harness/plugins/manual_counter.exs`:

  ```bash
  cat > .harness/plugins/manual_counter.exs <<'ELIXIR'
  defmodule ManualCounterPlugin do
    @behaviour Harness.Plugin

    alias Harness.Plugin.ToolSpec

    @impl true
    def metadata, do: %{id: "manual-counter", version: "1"}

    @impl true
    def tools do
      [
        %ToolSpec{
          name: "manual_counter",
          description: "Increment a stateful test counter, optionally after a delay.",
          parameters: %{
            "type" => "object",
            "properties" => %{
              "delay_ms" => %{
                "type" => "integer",
                "minimum" => 0,
                "maximum" => 10_000
              }
            },
            "additionalProperties" => false
          }
        }
      ]
    end

    @impl true
    def init(_ctx) do
      instance = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      {:ok, %{count: 0, instance: instance}}
    end

    @impl true
    def handle_tool("manual_counter", args, ctx, state) do
      Process.sleep(Map.get(args, "delay_ms", 0))
      next = state.count + 1
      output = "v1 count=#{next} instance=#{state.instance}"
      File.write!(Path.join(ctx.cwd, ".harness/manual-plugin-audit.log"), output <> "\n", [:append])
      {{:ok, output}, %{state | count: next}}
    end
  end
  ELIXIR
  ```

- [ ] Start live chat A:

  ```bash
  # Terminal A
  mix harness.chat --name plugin-manual-a
  ```

  Expected: the chat starts normally. A plugin compile, contract, or discovery
  failure would prevent startup.

- [ ] In terminal A, send:

  ```text
  You must call the manual_counter tool exactly once with {"delay_ms": 0}. After it returns, reply with the tool's exact output and nothing else.
  ```

- [ ] Confirm a `manual_counter` tool line appears and the assistant reports
  `v1 count=1 instance=...`. Record the instance value as **A's instance**.

  If the model does not call the tool, repeat the imperative prompt. That is a
  model-compliance failure, not evidence that reload failed.

- [ ] Send the same prompt once more in terminal A.

  Expected: A reports `v1 count=2` with the same instance as its first call.
  This verifies state is held outside individual tool tasks.

## 3. Reload revision 2 with a state migration

- [ ] Replace the plugin with revision 2 from a third shell:

  ```bash
  cat > .harness/plugins/manual_counter.exs <<'ELIXIR'
  defmodule ManualCounterPlugin do
    @behaviour Harness.Plugin

    alias Harness.Plugin.ToolSpec

    @impl true
    def metadata, do: %{id: "manual-counter", version: "2"}

    @impl true
    def tools do
      [
        %ToolSpec{
          name: "manual_counter",
          description: "Increment a stateful test counter, optionally after a delay.",
          parameters: %{
            "type" => "object",
            "properties" => %{
              "delay_ms" => %{
                "type" => "integer",
                "minimum" => 0,
                "maximum" => 10_000
              }
            },
            "additionalProperties" => false
          }
        }
      ]
    end

    @impl true
    def init(_ctx) do
      instance = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      {:ok, %{counter: 0, instance: instance, migrated_from: nil}}
    end

    @impl true
    def handle_tool("manual_counter", args, ctx, state) do
      Process.sleep(Map.get(args, "delay_ms", 0))
      next = state.counter + 1
      output = "v2 count=#{next} instance=#{state.instance} migrated_from=#{state.migrated_from}"
      File.write!(Path.join(ctx.cwd, ".harness/manual-plugin-audit.log"), output <> "\n", [:append])
      {{:ok, output}, %{state | counter: next}}
    end

    @impl true
    def migrate(%{count: count, instance: instance}, %{version: "1"}) do
      {:ok, %{counter: count, instance: instance, migrated_from: "1"}}
    end

    def migrate(state, _metadata), do: {:ok, state}
  end
  ELIXIR

  cp .harness/plugins/manual_counter.exs \
    .harness/plugins/manual_counter.exs.good
  ```

- [ ] Before reloading A, start live chat B in a second terminal:

  ```bash
  # Terminal B
  mix harness.chat --name plugin-manual-b
  ```

- [ ] In terminal B, call `manual_counter` once with the imperative prompt.

  Expected: B reports `v2 count=1 instance=... migrated_from=`. The value after
  `migrated_from=` is empty because a newly started session calls revision 2's
  `init/1`; it has no revision 1 state to migrate. Record **B's instance** and
  confirm it differs from A's.

- [ ] In terminal A, call `manual_counter` once before reloading.

  Expected: A reports `v1 count=3` with A's instance even though the source on
  disk and the newly started B session use revision 2. Existing sessions remain
  pinned until explicitly reloaded.

- [ ] In terminal A, enter:

  ```text
  /reload
  ```

  Expected:

  ```text
  reloaded manual-counter 2 (generation 2)
  ```

- [ ] In terminal A, call `manual_counter` once with the imperative prompt.

  Expected: `v2 count=4`, the same A instance, and `migrated_from=1`. This
  proves new code is active while revision 1 state survived and changed shape.

- [ ] In terminal B, call the tool again without running `/reload`.

  Expected: B reports `v2 count=2`, B's instance, and an empty
  `migrated_from=` value. A and B have independent state processes.

## 4. Verify invalid-source rollback

Continue in terminal A.

- [ ] Replace the source with invalid Elixir:

  ```bash
  printf '%s\n' 'defmodule BrokenPlugin do' > \
    .harness/plugins/manual_counter.exs
  ```

- [ ] In terminal A, run `/reload`.

  Expected: `reload failed` with a `parse_error`. The session stays alive.

- [ ] Call `manual_counter` again in terminal A.

  Expected: it still reports `v2`, the count increments from 4 to 5, and the
  instance remains unchanged. This proves invalid source did not replace code
  or reset state.

- [ ] Restore the valid source and reload:

  ```bash
  cp .harness/plugins/manual_counter.exs.good \
    .harness/plugins/manual_counter.exs
  ```

  ```text
  /reload
  ```

  Expected: revision 2 remains active. Because the content is unchanged, its
  generation remains 2.

## 5. Verify invalid-contract rollback

- [ ] Replace the source with a valid module that omits required
  `handle_tool/4`:

  ```bash
  cat > .harness/plugins/manual_counter.exs <<'ELIXIR'
  defmodule ManualCounterPlugin do
    @behaviour Harness.Plugin

    alias Harness.Plugin.ToolSpec

    @impl true
    def metadata, do: %{id: "manual-counter", version: "invalid-contract"}

    @impl true
    def tools do
      [
        %ToolSpec{
          name: "manual_counter",
          description: "This candidate must never activate.",
          parameters: %{"type" => "object", "properties" => %{}}
        }
      ]
    end

    @impl true
    def init(_ctx), do: {:ok, :unused}
  end
  ELIXIR
  ```

- [ ] In terminal A, run `/reload`.

  Expected: `reload failed` with
  `{:missing_callback, {:handle_tool, 4}}`. A compiler warning about the
  missing behaviour callback is also expected.

- [ ] Call `manual_counter` once.

  Expected: revision 2 still runs, its count increments by one, and A's
  instance remains unchanged.

- [ ] Restore revision 2 without reloading:

  ```bash
  cp .harness/plugins/manual_counter.exs.good \
    .harness/plugins/manual_counter.exs
  ```

## 6. Verify failed-migration rollback

- [ ] Create revision 3 with a migration that deliberately rejects revision 2
  state:

  ```bash
  sed \
    -e '0,/version: "2"/s//version: "migration-failure"/' \
    -e 's/def migrate(state, _metadata), do: {:ok, state}/def migrate(_state, _metadata), do: {:error, :manual_failure}/' \
    .harness/plugins/manual_counter.exs.good > \
    .harness/plugins/manual_counter.exs
  ```

- [ ] In terminal A, run `/reload`.

  Expected: `reload failed` with `{:migration_failed, :manual_failure}`.

- [ ] Call `manual_counter` once.

  Expected: revision 2 still runs, its count increments by one, and A's
  instance remains unchanged. The rejected candidate changed neither code,
  generation, nor state.

- [ ] Restore revision 2 without reloading:

  ```bash
  cp .harness/plugins/manual_counter.exs.good \
    .harness/plugins/manual_counter.exs
  ```

## 7. Verify tool-registry collision rollback

- [ ] Create a valid candidate that collides with the built-in `read` tool:

  ```bash
  sed \
    -e '0,/version: "2"/s//version: "collision"/' \
    -e '0,/name: "manual_counter"/s//name: "read"/' \
    .harness/plugins/manual_counter.exs.good > \
    .harness/plugins/manual_counter.exs
  ```

- [ ] In terminal A, run `/reload`.

  Expected: `reload failed` and `duplicate tool name: read`.

- [ ] Call `manual_counter` again.

  Expected: revision 2 still runs, its count increments by one, and A's
  instance remains unchanged.

- [ ] Restore revision 2:

  ```bash
  cp .harness/plugins/manual_counter.exs.good \
    .harness/plugins/manual_counter.exs
  ```

## 8. Verify safe reload around an interrupted invocation

- [ ] Prepare revision 3, but do not reload it yet:

  ```bash
  sed \
    -e '0,/version: "2"/s//version: "3"/' \
    -e 's/v2 count=/v3 count=/' \
    .harness/plugins/manual_counter.exs.good > \
    .harness/plugins/manual_counter.exs
  ```

- [ ] In terminal A, request a long revision 2 call:

  ```text
  You must call the manual_counter tool exactly once with {"delay_ms": 8000}. After it returns, reply with the tool's exact output and nothing else.
  ```

- [ ] As soon as the `manual_counter` tool line appears, enter `/reload`.

  Expected: `in a turn. /interrupt to cancel.` The CLI does not reload during
  an active turn.

- [ ] Enter `/interrupt`. Wait for `interrupted` and the next `>` prompt, then
  immediately enter `/reload`.

  Expected: reload reports `plugins are busy`. Although the core is idle, the
  revision 2 invocation still owns the plugin-state lease.

- [ ] Wait until at least eight seconds after the tool started, then run
  `/reload` again.

  Expected:

  ```text
  reloaded manual-counter 3 (generation 3)
  ```

- [ ] Call `manual_counter` with `delay_ms: 0`.

  Expected: revision 3 runs with the same A instance and a continuing count.
  The delayed revision 2 invocation completes under revision 2 before revision
  3 activates; it is not switched mid-call.

- [ ] Inspect the actual execution audit from a shell:

  ```bash
  tail -n 8 .harness/manual-plugin-audit.log
  ```

  Expected: entries before activation are labeled `v2`; entries after the
  successful generation-3 reload are labeled `v3`. No single invocation
  changes versions.

## 9. Verify conversation continuity

- [ ] In terminal A, ask:

  ```text
  Summarize what happened in this conversation, including the first counter result and the latest one. Do not call any tools.
  ```

  Expected: the model can reference messages from before and after both reloads.
  Reloading plugin code did not replace or truncate the session transcript.

- [ ] Optionally run `/tree` and confirm all user turns remain available.

## 10. Verify timeout cleanup and plugin lifecycle

The chat CLI intentionally uses a fixed 30-second tool timeout. Use the public
API for a short, practical timeout check while still calling the real xAI
provider. This session uses `persist: false`, so it does not conflict with A or
B's session files.

- [ ] Create and run a temporary live-session probe:

  ```bash
  cat > /tmp/harness-plugin-timeout-check.exs <<'ELIXIR'
  alias Harness.Message.ToolResult

  {:ok, session} =
    Harness.start_session(
      persist: false,
      tool_timeout_ms: 500
    )

  [%{pid: plugin_pid}] = Harness.plugins(session)
  plugin_monitor = Process.monitor(plugin_pid)

  try do
    first =
      Harness.ask(
        session,
        ~s|You must call the manual_counter tool exactly once with {"delay_ms": 2000}. After it returns, briefly report the result and do not call another tool.|
      )

    IO.inspect(first, label: "first turn")

    first_outcomes =
      session
      |> Harness.transcript()
      |> Enum.filter(&match?(%ToolResult{}, &1))
      |> Enum.map(& &1.outcome)

    IO.inspect(first_outcomes, label: "outcomes after timeout")

    second =
      Harness.ask(
        session,
        ~s|You must call the manual_counter tool exactly once with {"delay_ms": 0}. After it returns, briefly report the result and do not call another tool.|
      )

    IO.inspect(second, label: "second turn")

    latest_outcome =
      session
      |> Harness.transcript()
      |> Enum.filter(&match?(%ToolResult{}, &1))
      |> List.last()
      |> Map.fetch!(:outcome)

    IO.inspect(latest_outcome, label: "outcome after timeout")
  after
    GenServer.stop(session)
  end

  receive do
    {:DOWN, ^plugin_monitor, :process, ^plugin_pid, :normal} ->
      IO.puts("plugin stopped with session")
  after
    2_000 ->
      raise "plugin process outlived its session"
  end
  ELIXIR

  mix run /tmp/harness-plugin-timeout-check.exs
  rm /tmp/harness-plugin-timeout-check.exs
  ```

  Expected:

  - `outcomes after timeout` contains `{:error, "timed out"}`.
  - `outcome after timeout` is `{:ok, "v3 count=1 ..."}`. The timed-out call's
    state was not committed, and its lease no longer blocks the next call.
  - The final line is `plugin stopped with session`, proving the session-owned
    plugin process terminates with its session.

  If the model does not make exactly one requested tool call, delete the
  temporary script, recreate it, and rerun this step. Counts from a
  non-compliant run are not meaningful.

## 11. Cleanup

- [ ] Exit both chats with `/quit`.

- [ ] Remove only the manual test files:

  ```bash
  rm -f .harness/plugins/manual_counter.exs \
    .harness/plugins/manual_counter.exs.good \
    .harness/manual-plugin-audit.log
  rmdir .harness/plugins .harness 2>/dev/null || true
  ```

- [ ] Confirm no checklist files remain:

  ```bash
  git status --short
  ```

## Pass criteria

The manual pass is successful when all of the following are true:

- [ ] Plugins are discovered when each chat starts.
- [ ] Real xAI turns invoke the plugin through the normal tool loop.
- [ ] Counts and instance IDs persist across calls and successful reloads.
- [ ] Revision 1 state migrates to revision 2 without resetting.
- [ ] A new session loads the latest source while an existing session remains
  pinned until reload; state remains session-local.
- [ ] Invalid source, invalid contracts, failed migrations, and tool-name
  collisions leave old code and state active.
- [ ] Reload is refused during a turn and while an interrupted call still owns
  the plugin lease.
- [ ] A timed-out invocation releases its lease without committing state.
- [ ] The plugin process exits when its owning session exits.
- [ ] Revision labels in the audit prove invocations are pinned to one code
  revision.
- [ ] Conversation history remains intact across reloads.
