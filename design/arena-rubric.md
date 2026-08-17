# Arena rubric

Artifact. A design package in USAGE.md, SKETCH.md, and RATIONALE.md.

Updated after the invoker asked for a Pi-like core and Grok subscription OAuth.

1. A newcomer can run the harness from USAGE.md alone. Types in SKETCH.md are derived from that usage.
2. Session lifecycle is a state machine, or an equivalent structure, that cannot represent idle and an in-progress turn at the same time.
3. Tool and LLM wire formats are parsed at a boundary. Public modules do not expose HTTP or vendor JSON types.
4. The v1 public surface fits a Pi-like Mix app. Tiny system prompt. Tools are a data table. No baked-in plan mode, MCP, subagents, or plugin loader. It still names seams for hot-swap, a second client, and remote tool nodes.
5. Shared mutable state has a single writer. Concurrent tool calls do not write session history.
6. History stays wire-legal. Every tool call gets exactly one result, including interrupt.
7. Auth can be a Grok subscription login, not only an API key. A later `mix harness.login` and a token file must have a place to live. An OpenAI-compatible adapter remains for tests.
