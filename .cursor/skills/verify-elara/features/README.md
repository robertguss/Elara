# Elara verification map

This directory is the maintained source for verifying the user-facing behavior of Elara. Read the index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- Run `.cursor/skills/verify-elara/bin/launch` from the Elara repo root.
- Export `ELARA_VERIFY_STATE` to the printed `state.env`.
- Run `.cursor/skills/verify-elara/bin/doctor` and require `instance is safe to drive`.
- Isolated `HOME` is `$VERIFY_ROOT/home`. Never use the user's `~/.elara`.
- Mix tasks run in `$WORKTREE`. API/scripted drives use `$WORKSPACE` as `cwd:`.
- `ELARA_SERVER_PORT` is this run's port. Do not attach to 4048 unless we started it.
- Never drive an instance that was not started by this verification run.

## Driving conventions

- Start every recipe from the baseline state unless its preconditions say otherwise.
- Prefer the prompt strings, Mix flags, slash commands, and TUI flags in the feature file.
- Treat every command as literal. Keep quoted names and flags unchanged.
- Run Mix and scripted drives through `.cursor/skills/verify-elara/bin/drive`.
- Restore scratch files after a mutation. Do not remove proof artifacts during cleanup.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final line.
- Mix proof includes the command, stdout, stderr, and exit code.
- Chat proof includes the banner, the `> ` prompt, the command or prompt, and the reply or help text.
- Mutation proof includes a second read of the file or session JSONL.
- Record the feature ID and entry point used with every artifact.
- Report an unreachable path with the attempted command and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.
- `mix test` passing is not a user-path proof.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with verify-elara` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map. Name only user paths, stable handles, required state, commands, and observable proof.

## Features

- [One-shot ask](./ask.md) covers `mix elara.ask`, the usage and login gates, and a scripted successful turn.
- [Persistent chat](./chat.md) covers the banner, idle prompt, slash commands, and a scripted turn.
- [Rust TUI](./tui.md) covers `mix elara.tui new --headless`, list, and attach-by-id.
- [Sessions](./sessions.md) covers persist, `--continue`, `/resume`, `/name`, `/tree`, `/fork`, and `/clone`.
- [Built-in tools](./tools.md) covers `read`, `write`, `edit`, and `bash` as a user sees them through a turn.
