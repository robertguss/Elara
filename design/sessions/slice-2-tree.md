# Slice 2. In-file /tree

Back: [overview.md](overview.md)

**Status.** Blocked on slice 1. Open a fresh session. Read the overview, then this file. Do not start until slice 1's runtime resume check is on the branch you are extending.

## Goal

Jump to an earlier user turn in the same file and continue from there. Alternatives stay in one JSONL. The model sees only the path from the new leaf to the root.

## Changes

- Log. `leaf` can point at an older entry. Append attaches to the current leaf, so a second child of an old node is a branch. Walk-to-root becomes the only way to build `Core` history.
- Session. A public call sets the leaf (only while idle), rebuilds `history` from that path, and stays idle.
- Chat. `/tree` prints a numbered list of user-message entries on the active file. Picking one sets the leaf to that node's parent (or null at root) and puts the user text back as the next prompt, matching Pi's "re-submit this user turn" feel. A later pick that is not a user message is out of scope.
- README. Document `/tree`. Keep the list UI. Do not add a pane.
- Tests. Two branches in one file. Hydrate from each leaf. Provider sees only that path.

Do not add `/fork`, `/clone`, `/name`, or LLM branch summaries.

## Data structures

Same `Log.Entry` as slice 1. `leaf` is now a movable pointer. Context is `walk(leaf) -> [Message]`.

## Verification

**Static.** `mix test` and `mix format --check-formatted`.

**Runtime.** `control-cli`. One session, two user turns, `/tree`, pick the first user turn, send a different follow-up. The JSONL must contain both children of that node. The live history must not include the abandoned turn.

## Done when

- `/tree` can move the leaf and the next `ask` continues from that path.
- The file is still one JSONL. No second file.
- Abandoned turns remain on disk and stay off the provider path.
- Slice 3 is still unbuilt.
