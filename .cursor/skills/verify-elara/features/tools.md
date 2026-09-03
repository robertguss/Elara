# Built-in tools

A turn can read a file, write a workspace-relative file, replace one string, or run a shell command. The user sees tool lines on ask/chat and the bytes on disk afterward.

## Sub-features

- `tool-read` returns file contents through a turn.
- `tool-write` creates parent directories and writes the exact bytes.
- `tool-edit` replaces exactly one occurrence.
- `tool-bash` runs `/bin/sh -c` in the session cwd with stdout and stderr merged.
- `tool-write-reject` rejects absolute paths, `..`, and non-file write targets.

## How to get to it (user POV)

- Ask `mix elara.ask` or chat to read, write, edit, or run a command.
- Observe `  -> read:` / `  -> write:` / `  -> edit:` / `  -> bash:` and a following `  <- ok` or `  <- error:`.

## Driving it with verify-elara

Preconditions:

- `bin/doctor` reports the instance is safe to drive.
- Drive tools against `$WORKSPACE` or `$WORKTREE`, never the user's checkout.
- Isolated HOME is in use.

- **Write.** Run `.cursor/skills/verify-elara/bin/drive scripted-ask --feature tools --prompt "write the note" --tool write --path nested/note.txt --content hello --reply "wrote it"`. Exit code `0`. `render.txt` contains `  -> write:` and `  <- ok`. `$WORKSPACE/nested/note.txt` contains `hello`.
- **Read.** Run `.cursor/skills/verify-elara/bin/drive scripted-ask --feature tools --prompt "read the note" --tool read --path nested/note.txt --reply "the note says hello"`. Exit code `0`. Render contains `  -> read:` and `  <- ok`.
- **Bash.** Run `.cursor/skills/verify-elara/bin/drive scripted-ask --feature tools --prompt "print hi" --tool bash --content "printf hi" --reply "hi"`. Exit code `0`. Render contains `  -> bash:` and `  <- ok`.
- **Proof.** Keep `render.txt` and a copy of any written file under `artifacts/tools/<run-id>/`. A tool line without the file bytes is incomplete. A file write without the `  -> write:` line is incomplete.

## Gotchas

- `write` is workspace-relative. Absolute paths and `..` must fail. `read`, `edit`, and `bash` can reach outside the cwd; that is why drives use a disposable workspace.
- Default local `write` also records a durable ledger under `$HOME/.elara/sessions/_effect_executors/`. Proof of write is still the file bytes plus the tool lines.
- `edit` needs exactly one `old_text` match. Zero or many matches leave the file unchanged.
- Model-selected tools on a credentialed Mix drive are probabilistic. If the model ignores the request, record a usability miss; do not infer the tool is broken. Use scripted-ask to force the tool call.
- Shell output kept in history is capped at 16 KiB. A 30-second tool timeout is the default.
