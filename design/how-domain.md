# How a coding harness works

Greenfield. There is no in-repo subsystem to walk. This is the domain a newcomer needs before we write Elixir.

## Overview

A coding harness is the deterministic runtime around a stateless model. The model proposes. The harness loops, dispatches tools, keeps session history, and decides when to stop. Claude Code, OpenCode, Pi, and Aider all share that loop. They differ in who owns state, how clients attach, and how tools get swapped.

Jose Valim's claim is that BEAM already has the three hard parts other languages rebuild. Hot code swap for live plugins. Actors for a client-server split. Distribution for brains versus hands. v1 should prove the loop on one node. The types should leave those three experiments unblocked.

## Key concepts

**Session.** The durable conversation. History, config, and the current turn live here. One writer.

**Turn.** One user request. A ReAct loop inside the session. Assemble context, call the model, run tools, append results, repeat until the model stops or a budget fires.

**Message.** A tagged fact in history. User text, assistant text, tool call, or tool result. Not a bag of optional fields.

**Tool.** Name, JSON schema the model sees, execute function the runtime runs. Built-ins in v1 are read, write, edit, and bash. A registry is the extension point. Pi reloads that registry without dropping the session.

**Event.** A fact the session publishes. Message appended, tool started, token streamed, turn ended. OpenCode's HTTP clients are subscribers. On BEAM a subscriber is another process.

**Provider.** The LLM boundary. HTTP and vendor JSON die here. Inside the app we only see domain messages and tool calls.

**Permission.** Allow, ask, or deny before a tool runs. Plan mode is a missing write tool, not a prompt that says "don't write."

**Brains and hands.** The session plus model is the brain. Sandbox plus tools are the hands. Livebook already coordinates remote runtimes this way. Distribution makes that a node, not a rewrite.

## How it works

The user types a prompt. The CLI starts or attaches to a Session process. The session appends a user message and enters a turn.

Each turn iteration asks the provider for the next assistant step, given history and the current tool list. If the model returns text and no tool calls, the turn ends. If it returns tool calls, the harness validates arguments, checks permission, runs each tool, appends results, and loops.

OpenCode puts that loop in `SessionPrompt.loop` and fans events over a bus to a TUI in another thread. Claude Code uses one `queryLoop` for CLI, SDK, and IDE. Aider keeps a tighter loop. Propose a diff, apply it, commit. Pi keeps a small system prompt and hot-reloads extensions with `/reload` while the session process stays up.

Stop conditions the model does not get to vote on. Turn limit. Repeated identical tool calls. User interrupt. Cost budget can wait.

Persistence is a later experiment. v1 can keep history in the Session process. Crash recovery is a file or DETS write after each appended message, not a database.

## Where things live in v1

One Mix app. Not an umbrella. Not Phoenix.

- `lib/harness.ex` is the public start and prompt API.
- `lib/harness/session.ex` is the GenServer and the state machine.
- `lib/harness/turn.ex` is the pure loop given a session snapshot and a provider.
- `lib/harness/message.ex` is the sum type.
- `lib/harness/tool.ex` is the behaviour and registry.
- `lib/harness/provider.ex` is the LLM boundary.
- `lib/harness/cli.ex` is a Mix task that subscribes to events and prints them.

Hot-swap, a second client, and a remote tool node are later apps of the same types. They are not v1 modules.

## Gotchas

Other harnesses bury the loop in framework SDKs. If we wrap Req calls in a 200-line adapter, we will not feel BEAM. The loop and the Session actor are the product.

Client-server is not an HTTP project. It is "the session is a process, the CLI is a process." HTTP can sit on that later.

Hot code swap reloads modules. It does not reload process state. Plugin state has to live in the Session or in a table the new module can read. Pi learned this. Reload at a safe boundary, not mid-tool.

Distribution isolates failures. A tool node dying should not kill the session. That only works if tools are already behind a behaviour and the session never calls `File` or `System.cmd` itself.

Do not start with MCP, compaction, LSP, or subagents. Those are experiments on a working loop.
