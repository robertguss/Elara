# Live plugins

Plugins add stateful tools to a Harness session. On startup, Harness discovers
`.ex` and `.exs` files under `.harness/plugins/` in the session working
directory.

> [!WARNING] Plugins are trusted local code. They are compiled and executed
> inside the Harness VM with the same filesystem, network, and operating-system
> access as Harness. They are not a sandbox or a package-security boundary.

## Create a plugin

Each plugin file must define exactly one module implementing `Harness.Plugin`:

```elixir
defmodule CounterPlugin do
  @behaviour Harness.Plugin

  alias Harness.Plugin.ToolSpec

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

Start a new chat after creating the file. The plugin tool is then available to
the model alongside `read`, `write`, `edit`, and `bash`.

## Reload without restarting chat

Edit a loaded plugin and enter:

```text
/reload
```

Each session stays on its loaded plugin revision until that session reloads. On
success, new calls use the new code while the plugin's process and state
survive. Reload is refused during a turn and while an interrupted plugin call
still holds its state lease.

Parsing, compilation, contract validation, tool-name collision, initialization,
or migration failures leave the previous revision and state active.

## Change the state shape

When a revision changes its state representation, add `migrate/2`:

```elixir
@impl true
def migrate(%{count: count}, %{version: "1"}) do
  {:ok, %{counter: count, migrated_from: "1"}}
end

def migrate(state, _old_metadata), do: {:ok, state}
```

Without `migrate/2`, Harness preserves the old state term as-is. Keep plugin
state as plain data: do not store functions or structs defined by the reloadable
module. Migration should transform state only, without external side effects.

## Select plugins through the API

Discovery is the default. To choose files explicitly or disable plugins:

```elixir
{:ok, selected} =
  Harness.start_session(
    cwd: "/absolute/path/to/project",
    plugins: ["/absolute/path/to/counter.exs"]
  )

{:ok, without_plugins} = Harness.start_session(plugins: [])
```

Inspect and reload the active session with:

```elixir
Harness.plugins(selected)
Harness.reload_plugins(selected)
```

Plugin state belongs to its session and stops when that session stops.

For an end-to-end check against a live xAI session, follow the
[manual live-reload checklist](../design/plugins/manual-live-reload-checklist.md).
