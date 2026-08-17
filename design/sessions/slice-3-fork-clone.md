# Slice 3. /fork, /clone, /name

Back: [overview.md](overview.md)

**Status.** Blocked on slice 2. Open a fresh session. Read the overview, then this file.

## Goal

Split work into another file when the user wants a separate conversation. Name sessions so `/resume` is readable.

## Changes

- Log. Creating a file from a chosen leaf copies the root-to-leaf path into a new JSONL. Header may record `parentSession`. `/clone` copies the current leaf path. `/fork` copies the path to a chosen user message, same selection rule as `/tree`.
- Chat. `/name` writes a display name on the header. `/resume` shows that name. Mix may take `--name` on a new chat.
- README. Document `/fork`, `/clone`, `/name`.
- Tests. Fork produces a second file. Original file is unchanged. Resume of the new file has only the copied path.

Do not add compaction, share, HTML export, or gist upload.

## Data structures

Same entries. New header fields: `name` (optional), `parentSession` (optional path).

## Verification

**Static.** `mix test` and `mix format --check-formatted`.

**Runtime.** `control-cli`. `/clone` or `/fork`, `/quit`, open the new file, confirm it is a separate conversation. `/resume` lists the name.

## Done when

- `/fork` and `/clone` create a new file under the same cwd key.
- `/name` is visible in `/resume`.
- The source file still has its full tree.
