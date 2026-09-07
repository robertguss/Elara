# Live plugins

Plugins add stateful tools to an Elara session. On startup, Elara discovers
`.ex` and `.exs` files under `.elara/plugins/` in the session working directory.

> [!WARNING] Plugins are trusted local code. They are compiled and executed
> inside the Elara VM with the same filesystem, network, and operating-system
> access as Elara. They are not a sandbox or a package-security boundary.

## Create a plugin

Each plugin file must define exactly one module implementing `Elara.Plugin`:

```elixir
defmodule CounterPlugin do
  @behaviour Elara.Plugin

  alias Elara.Plugin.ToolSpec

  @impl true
  def metadata, do: %{id: "counter", version: "1"}

  @impl true
  def tools do
    [
      %ToolSpec{
        name: "counter",
        description: "Increment a session-local counter.",
        parameters: %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def init(_ctx), do: {:ok, 0}

  @impl true
  def handle_tool("counter", _args, _ctx, count) do
    next = count + 1
    {{:ok, "count=#{next}"}, next}
  end
end
```

Callbacks:

- `metadata/0` returns exactly `%{id: String.t(), version: String.t()}`.
- `tools/0` returns tool names, descriptions, and JSON Schemas.
- `init/1` returns `{:ok, initial_state}` or `{:error, reason}`.
- `handle_tool/4` returns `{outcome, new_state}`, where an outcome is
  `{:ok, text}`, `{:error, text}`, or `{:indeterminate, text}`.
- Optional `migrate/2` converts existing state when a new revision is loaded.

Tool names must be unique across built-ins and all plugins. A plugin file may
not define nested modules. Use `__MODULE__` rather than the source module's
literal name for self-references inside the plugin.

Start a chat after creating the file, or explicitly reload an existing session
as described below. The plugin tool is then available to the model alongside
`read`, `write`, `edit`, and `bash`.

## Reload without restarting chat

Add or edit a plugin file, wait for the current turn to finish, and enter this
command in the Rust TUI:

```text
/plugins reload
```

In `mix elara.chat`, use `/reload`. In the TUI, `/reload` continues to refresh
the session snapshot. TUI plugin reload requires a controlling attachment and
a server that negotiates `plugin_reload_v1`; observers cannot activate code.

Default-discovery sessions rescan `.elara/plugins/` when explicitly reloaded.
Sessions created with an explicit `plugins: [...]` selection only reload those
paths; `plugins: []` remains disabled. Removing or renaming a loaded file makes
reload fail; it does not unload the active plugin. Restore the path or start a
new session to use a different selection.

New automatic handoffs retain both the active path selection and the discovery
policy, including after a saved successor is resumed. A handoff does not
activate newly added files; they still require explicit reload. Handoffs saved
before discovery-policy tracking retain their saved fixed path selection.

Each session stays on its loaded plugin revision until that session reloads. On
success, new calls use the new code while the plugin's process and state
survive. Reload is refused during a turn and while an interrupted plugin call
still holds its state lease.

The controlling TUI connection waits for compilation and migration to finish,
including callbacks longer than five seconds, then reports success or failure.

Parsing, compilation, contract validation, tool-name collision, initialization,
or migration failures leave the previous revision and state active. Newly
started plugin processes are stopped if any candidate fails; prepared changes
to existing plugins are discarded. Plugin callbacks can have external side
effects, which cannot be rolled back. This is validation rollback, not a
crash-atomic transaction across plugins.

## Focused test, fix, and rerun

The repository's `.elara/plugins/elixir_project.exs` exposes project inspection,
format/compile checks, focused tests, `elixir_last_run`, and `elixir_rerun_last`.
The last tool repeats the previous Mix invocation using current workspace
files. It retains the exact test target, increments the run count, and replaces
the recorded status. Asking for `elixir_last_run` does not change that state.

To exercise live capability addition in a disposable Mix project:

1. From the Elara checkout, run `iex -S mix`. Start a session before adding a
   plugin with `{:ok, id} = Elara.start_session(cwd: "/absolute/path/to/project")`
   and a server in that same VM with `Elara.Server.start(port: 4048)`. In another
   terminal in the Elara checkout, attach with `mix elara.tui SESSION_ID`, using
   the returned ID. Keep IEx running during the exercise.
2. Copy `test/support/fixtures/elixir_project_v1.exs` from this repository into
   that project's `.elara/plugins/elixir_project.exs`, then `/plugins reload`.
3. Ask Elara to run a failing test with `elixir_test` and a file or `path:line`
   target, then fix the project code.
4. Replace that plugin with the repository's current version and `/plugins reload`.
5. Ask for `elixir_last_run`, then `elixir_rerun_last`. The new tool uses the
   target and run count retained from version 1 in the same session/process.
6. Introduce a syntax error in the plugin and try `/plugins reload`. The error
   leaves the working version available; `elixir_rerun_last` still works.

Version 2 stores structured tool arguments and migrates version 1's command
labels. The old `test:all` label is interpreted as a full-suite invocation;
version 1 could not distinguish that from a literal test target named `all`.
Version 2 retains that distinction for new invocations.

Version 3 adds `evidence_paths` to checks/tests and captures immutable source
and output excerpts for [check diagnosis](check-diagnosis.md). Version 2's
remembered invocations remain usable; they acquire evidence when rerun. The
last completed capture belongs to the session store and survives persistence;
plugin reload does not replace it or invent evidence for an earlier run.

The offline acceptance test runs real Mix commands and a built-in edit through
the public session API with a scripted provider:
`mix test test/elara/elixir_project_plugin_test.exs`. It verifies the runtime
workflow; it does not measure how reliably a live model chooses these tools.

## Change the state shape

When a revision changes its state representation, add `migrate/2`:

```elixir
@impl true
def migrate(%{count: count}, %{version: "1"}) do
  {:ok, %{counter: count, migrated_from: "1"}}
end

def migrate(state, _old_metadata), do: {:ok, state}
```

Without `migrate/2`, Elara preserves the old state term as-is. Keep plugin state
as plain data: do not store functions or structs defined by the reloadable
module. Migration should transform state only, without external side effects.

## Select plugins through the API

Discovery is the default. To choose files explicitly or disable plugins:

```elixir
{:ok, selected} =
  Elara.start_session(
    cwd: "/absolute/path/to/project",
    plugins: ["/absolute/path/to/counter.exs"]
  )

{:ok, without_plugins} = Elara.start_session(plugins: [])
```

Inspect and reload the active session with:

```elixir
Elara.plugins(selected)
Elara.reload_plugins(selected)
```

Plugin state belongs to its live session and stops when that session stops; it
is not restored from saved transcripts. Successful compiled generations remain
in the VM, with no retirement policy or generation cap. Use bounded experiments
and restart the runtime to reclaim them. Recorder replay checks recorded
transitions; it does not re-execute plugins or archive their source code.

## TUI protocol extension

A protocol v2 client requests `plugin_reload_v1` in its attachment's
`extensions` list. After the server echoes it, the controller may send:

```json
{"version":2,"extension":"plugin_reload_v1","command":"plugins_reload"}
```

Success returns `plugins_reloaded` with a `plugins` array of objects containing
`id`, `version`, and `generation`. Failure returns `session_error` with command
`plugins_reload` and an `error` string, including `busy`, `not_controller`,
`unsupported_extension`, or a plugin load failure. No source is activated by a
snapshot refresh or by typing an ordinary prompt.
