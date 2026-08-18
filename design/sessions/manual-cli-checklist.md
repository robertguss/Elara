# Manual CLI feature checklist

Use this checklist to smoke-test the three session-persistence slices with the
real `mix harness.chat` interface.

## Before you start

- [ ] Run from the repository root.
- [ ] Confirm `mix harness.chat` can reach a provider. Set `HARNESS_API_KEY` or
      `XAI_API_KEY`, or run `mix harness.login`.
- [ ] Run `mix test` and confirm the suite passes before manual testing.
- [ ] Note the current session files so new files are easy to identify:

  ```bash
  find ~/.harness/sessions -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -n
  ```

- [ ] Use unique tokens such as `ALPHA-4821` in the prompts below. This makes it
      clear which branch history reached the provider.

## Common chat behavior

Start a new, named session:

```bash
mix harness.chat --name "manual-primary"
```

- [ ] The banner and `> ` prompt appear.
- [ ] `/help` lists `/resume`, `/tree`, `/fork`, `/clone`, `/name`,
      `/interrupt`, and `/quit`.
- [ ] Plain text starts a turn and the CLI returns to `> ` after the answer.
- [ ] `/name manual-primary-renamed` prints `session named`.
- [ ] `/quit` exits successfully.

## Slice 1: persist and resume

### Create and persist a session

Start a fresh session:

```bash
mix harness.chat --name "manual-resume-source"
```

- [ ] Ask: `Remember the exact token RESUME-4821 for this conversation.`
- [ ] Ask: `What exact token did I ask you to remember?`
- [ ] The answer contains `RESUME-4821`.
- [ ] A new `.jsonl` file exists under `~/.harness/sessions/<cwd-key>/` before
      the process exits.
- [ ] The file mode is `600`:

  ```bash
  find ~/.harness/sessions -type f -name '*.jsonl' -printf '%m %T@ %p\n' | sort -n | tail
  ```

- [ ] The first JSONL line contains `version`, `id`, `cwd`, `leaf`, and the
      session name.
- [ ] Later lines contain message records with `id`, `parentId`, and
      `timestamp`.
- [ ] Run `/quit`.

### Continue in a new process

```bash
mix harness.chat --continue
```

- [ ] The prior transcript is printed on startup.
- [ ] Ask this:

  > What exact token are you retaining from before this process started?

- [ ] The answer contains `RESUME-4821` without restating it in the new prompt.
- [ ] Run `/quit` and start `mix harness.chat --continue` once more.
- [ ] The newest turn is also present, proving that the resumed session kept
      persisting.

### List and switch sessions in one process

Create another session, then stay in the chat:

```bash
mix harness.chat --name "manual-resume-target"
```

- [ ] `/resume` prints `saved sessions` with newest sessions first.
- [ ] Named rows show `manual-resume-target` and `manual-resume-source` (or its
      renamed value).
- [ ] `/resume 99999` prints `no saved session at index 99999` and stays usable.
- [ ] `/resume N`, using the source session's displayed number, switches the
      current chat and prints its transcript.
- [ ] Asking for `RESUME-4821` succeeds after the in-process switch.
- [ ] `/resume 0` and `/resume nope` print the `/resume` usage message.

### Current-working-directory isolation

- [ ] From another checkout or copy of the repository, run `/resume`.
- [ ] Sessions created in this checkout are absent from that list.
- [ ] Return to this checkout and confirm they are still listed.

## Slice 2: branch in one file with `/tree`

Start a clean source session:

```bash
mix harness.chat --name "manual-tree-source"
```

- [ ] First turn: `Remember the branch token ALPHA-4821.`
- [ ] Second turn: `Also remember the later token BETA-7394.`
- [ ] `/tree` prints both user turns as a numbered list and tells you to choose
      with `/tree N`.
- [ ] `/tree 99999` prints `no user turn at index 99999` without ending chat.
- [ ] Record the number of JSONL files for this cwd.
- [ ] Run `/tree N` for the original `ALPHA-4821` turn.
- [ ] The CLI prints `branched in current session`, reprints that user prompt,
      and automatically submits it.
- [ ] Ask this:

  > Which of ALPHA-4821 and BETA-7394 exists on your current history path?

- [ ] The answer includes `ALPHA-4821` and does not claim that `BETA-7394` is on
      the current path.
- [ ] No new JSONL file was created by `/tree`.
- [ ] The original `BETA-7394` records remain in the existing JSONL file.
- [ ] `/quit`, then `mix harness.chat --continue` preserves the selected branch
      rather than restoring the abandoned path.

## Slice 3: `/fork`, `/clone`, and `/name`

### Fork from an earlier user turn

Start a clean source session:

```bash
mix harness.chat --name "manual-fork-source"
```

- [ ] First turn: `Remember the base token BASE-4821.`
- [ ] Second turn: `Remember the fork token FORK-7394.`
- [ ] Third turn: `Remember the later source-only token SOURCE-9157.`
- [ ] `/fork` lists all three user turns and tells you to choose with `/fork N`.
- [ ] Record the current JSONL file count and the source file's size or
      checksum.
- [ ] Run `/fork N` for the `FORK-7394` turn.
- [ ] The CLI prints `forked session`, switches to a new session, reprints the
      chosen prompt, and automatically submits it.
- [ ] Exactly one new JSONL file was created.
- [ ] The source JSONL file's content is unchanged by the fork operation.
- [ ] Ask which test tokens are on the current path. `BASE-4821` and `FORK-7394`
      should be available; `SOURCE-9157` should not be on this path.
- [ ] `/name manual-fork-child` prints `session named`.
- [ ] `/resume` displays `manual-fork-child` and `manual-fork-source` as
      separate sessions.

### Clone the current path

While attached to `manual-fork-child`:

- [ ] Add one distinctive turn, then record the JSONL file count.
- [ ] `/clone` prints `cloned session` and switches to the clone.
- [ ] Exactly one new JSONL file was created.
- [ ] The current transcript is unchanged immediately after cloning.
- [ ] Ask about the distinctive turn; the clone retains it.
- [ ] `/name manual-clone-child` succeeds.
- [ ] `/resume` lists the source, fork child, and clone child separately.
- [ ] `/quit`, then `mix harness.chat --continue` opens the most recently used
      usable session.

### Name a session at startup

```bash
mix harness.chat --name "manual-startup-name"
```

- [ ] `/resume` shows `manual-startup-name`.
- [ ] `/name` with no text prints `usage: /name TEXT`.
- [ ] `/name a different readable name` updates the name shown by `/resume`.

## Busy-state and interruption checks

Start a turn likely to run long enough to enter another command, such as asking
for a detailed repository analysis.

- [ ] During the turn, `/resume`, `/tree`, `/fork`, `/clone`, and `/name test`
      each print `in a turn. /interrupt to cancel.` when attempted.
- [ ] A second plain-text prompt during the turn is refused with the same
      message.
- [ ] `/help` still prints help during a turn.
- [ ] `/interrupt` or `/stop` cancels the turn and prints `interrupted`.
- [ ] The CLI returns to `> ` and accepts another prompt after interruption.
- [ ] `/quit` during a turn interrupts and exits; a second `/quit` exits
      immediately if shutdown is still in progress.

## Final checks

- [ ] `mix harness.chat` without `--continue` still creates a new session.
- [ ] Provider errors return to `> ` instead of exiting chat.
- [ ] No session files were written inside the repository working tree.
- [ ] Every tested JSONL file remains parseable as one JSON object per line.
- [ ] `mix test` passes after manual testing.
- [ ] `mix format --check-formatted` passes.

Out of scope for these slices: restoring an in-flight tool after a crash,
compaction, branch summaries, Pi JSONL compatibility, sharing/export, and a
full-screen tree interface.
