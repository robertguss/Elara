# Choose the first plugin workflow and activation boundary

Parent: [Live plugin discovery and reload](../map.md)
Type: grilling
Labels: wayfinder:grilling
Status: resolved
Assignee: robertguss
Blocked by: none

## Question

What useful coding workflow should the first plugin support, and who should be
able to activate a new or revised plugin at what point in that workflow?

Resolve with a concrete user scenario, the reason a plugin is useful compared
with a script, and the first supported activation path. Distinguish owner-driven
activation between turns from agent-driven activation and activation between
provider requests within a turn. The latter two are not implied by discovery.

The initial recommendation is an explicitly invoked operation between turns,
using a useful project-specific plugin. Decide whether first delivery includes
addition, revision, and removal together or a narrower coherent slice, and name
the product surface through which the owner exercises it.

## Comments

### Proposed workflow: focused Elixir test, fix, and rerun (2026-09-06)

The existing [Elixir project plugin](../../../.elara/plugins/elixir_project.exs)
provides project inspection, format/compile checks, full or focused tests, and
`elixir_last_run`. Its state retains a run count and the latest command/status,
exit code, and duration; it does not retain full command output.

Use that plugin in a session started before its file is installed. Explicitly
discover and activate it between turns, then run a focused failing test. After
the code fix, revise the plugin to add a proposed `elixir_rerun_last` tool,
reload it, and use the new tool with the remembered test command. A rejected
revision should leave the previous usable revision and state available.

This proposal separates the new-file discovery feature from the existing
ability to add tool declarations to an already loaded plugin. The rerun helper
is a small practical demonstration of a new capability consuming preexisting
state; repeating a command through ordinary tools remains a viable alternative.
The owner subsequently accepted this workflow and authorized implementation.

## Answer

Accepted 2026-09-06: implement the six-step workflow above. Keep activation an
explicit owner operation between turns. Expose `/plugins reload` in the Rust
TUI, retain chat `/reload`, and use the public reload API for offline acceptance.
Include new-file discovery and revision changes. Defer removal and model-driven
activation. The new rerun tool demonstrates useful continuity over a stateful
plugin upgrade; it is not evidence that plugins outperform ordinary scripts.
