# Elara

Elara is a BEAM-native coding agent for a local working directory. It can
inspect and edit files, run shell commands, keep persistent conversations, load
local tools, and move tool execution to a separate worker. It emphasizes
durable, causally explainable work rather than feature-for-feature parity with
existing agents.

> [!WARNING] The built-in `write`, `edit`, and `bash` tools can change files and
> run any command available to the Elara process. Use Elara only in a checkout
> you are prepared to modify. Local tools are not sandboxed.

## Run from source

Elara currently runs from this Mix project; it does not install a standalone
`elara` executable. You need Elixir 1.20, Erlang/OTP 29, Rust 1.88 or newer with
Cargo, rustfmt, and Clippy, plus the `flock` command. The Rust components can be
installed with `rustup component add rustfmt clippy`; distribution-provided Rust
1.85 is too old for the TUI dependencies. Mix builds the Rust execution stub
automatically and builds the Rust TUI on first use; a missing Cargo installation
fails with setup instructions.

```bash
git clone https://github.com/robertguss/elixir-harness.git
cd elixir-harness
mix deps.get
```

The `mix elara.ask` and `mix elara.chat` commands use the Mix process's current
directory as the session working directory. With the commands above, that is the
Elara checkout itself. Those commands do not currently accept a `--cwd` option.
To target another directory, use the [Elixir API](docs/elixir-api.md) and pass
an absolute `cwd:`.

The working directory controls relative tool paths, shell commands, local plugin
discovery, session scope, project instructions, and Agent Skills discovery.

## Project instructions and Agent Skills

Elara loads `AGENTS.md` from the working directory and its ancestors, ordered
outermost first. Each file applies only to its directory and descendants;
nearest guidance specializes its parents, and explicit user directions take
precedence over project instructions and skills. Instruction paths and scopes
are included in the model context.

The session also discovers ancestor guidance for paths passed to the built-in
`read`, `write`, and `edit` tools. A call encountering new or changed guidance
is **not executed** until the model has received it and reconsidered the call.
Unreadable guidance blocks these tools with a diagnostic. Loaded scopes refresh
at the next user turn. Paths use lexical absolute directory scope; this is not a
filesystem security boundary. Shell strings and arbitrary plugin/remote
operations cannot be analyzed for target paths: the model is instructed to read
applicable guidance before using them.

Skills follow the [Agent Skills format](https://agentskills.io/specification): a
directory named for the skill containing `SKILL.md` with YAML `name` and
`description`. Discovery loads metadata into context, not every instruction
body. Ask explicitly, for example, “Use the reviewing-code skill to review this
change.” The model uses the `skill` tool to load that skill by name; its output
includes the absolute base directory for relative references and scripts.

Duplicate names resolve in this order (first wins):

1. Explicit directories in `ELARA_SKILL_PATHS` (colon-separated on Unix), or API
   `skill_paths: [...]`, in list order. Each can be one skill or a directory
   containing skills; existing symlinks work without copying files.
2. `.agents/skills` in the working directory, then each ancestor up to and
   including the nearest Git root (`.git` file or directory). Without a Git
   root, search continues to the filesystem root.
3. `~/.config/agents/skills`, then `~/.agents/skills`.

Malformed skills and shadowed sources produce diagnostics. Compatibility text is
surfaced for dependency checks, not treated as a promise of vendor tools.
Experimental `allowed-tools` and vendor-specific fields never grant capabilities
or start plugins/MCP servers. Scripts run through ordinary `bash`, with its
existing limits and outcome reporting; missing dependencies fail normally.
Restart a session to rediscover metadata; selected files are reread and
validated when loaded. Existing coordinator children rediscover in their own
working directory and inherit explicitly configured skill paths and capability
limits.

For diagnostics from the [Elixir API](docs/elixir-api.md), inspect
`Elara.status(session).instructions` and `.skills`. A custom `tools:` list must
include `Elara.Skills.tool()` to expose selective loading. This adds no approval
UI and does not sandbox local scripts.

## Authenticate

### OpenAI Codex subscription

An eligible ChatGPT Plus/Pro Codex subscription can provide the model while
Elara keeps ownership of its own session, tools, execution, and agent loop:

```bash
mix elara.login openai
export ELARA_PROVIDER='openai-codex'

# Optional; these are the Codex provider defaults:
export ELARA_MODEL='gpt-5.5'
export ELARA_REASONING_EFFORT='low'
```

Open the printed OpenAI URL, enter the device code, and wait for Elara to save
the tokens under `~/.elara/openai-codex-auth.json` with mode `0600`. Elara uses
the subscription-backed Codex Responses stream and identifies itself as
`originator=elara`. Alternatively, explicitly reuse an existing Codex login:

```bash
export ELARA_PROVIDER='openai-codex'
export ELARA_CODEX_AUTH_SOURCE='codex'
mix elara.tui new
```

This reads `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`) without copying,
refreshing, or rotating its credentials. If the login needs refreshing, Elara
asks you to refresh it in Codex. Omit `ELARA_CODEX_AUTH_SOURCE`, or set it to
`elara`, to use Elara's own login. Set these variables in the process that owns
the session—for detached use, that is `mix elara.server`.

This path uses ChatGPT plan limits. It is separate from OpenAI Platform API-key
billing below.

### Grok login

```bash
mix elara.login
```

Open the printed URL and enter the device code. Elara stores tokens in
`~/.elara/auth.json` with mode `0600` and refreshes them when needed. If that
file does not exist but `~/.grok/auth.json` does, Elara imports it.

If a successful login is followed by HTTP 403, the account is not entitled to
use the API. Logging in again will not fix it; use an API key instead.

### API key

`ELARA_API_KEY` takes precedence over `XAI_API_KEY`. Either selects the
OpenAI-compatible provider.

```bash
export ELARA_API_KEY='...'
# Optional; these are the defaults:
export ELARA_MODEL='grok-4'
export ELARA_BASE_URL='https://api.x.ai/v1'
```

`XAI_MODEL` is accepted when `ELARA_MODEL` is unset. Model and base URL
environment variables apply to API-key authentication; saved Grok login uses the
xAI endpoint and `grok-4`.

## Ask or chat

Run one turn and exit:

```bash
mix elara.ask "summarize this repository"
```

The command prints tool activity and the answer. It exits with status 1 on a
provider error, interruption, timeout waiting for the turn, or turn limit. This
one-shot command does not persist its session. A tool's 30-second timeout is
reported to the model as a tool error; if the model then completes the turn,
`mix elara.ask` exits 0. This differs from the CLI timing out while waiting for
the turn itself.

Start a persistent conversation:

```bash
mix elara.chat
mix elara.chat "what starts this application?"
mix elara.chat --name "runtime investigation"
mix elara.chat --continue
```

`--continue` resumes the newest usable session for the current working
directory. Provider errors end only the current turn and return to the prompt.

Common chat commands:

| Command                           | Result                                                          |
| --------------------------------- | --------------------------------------------------------------- |
| `/help`                           | Show all commands.                                              |
| `/interrupt` or `/stop`           | Cancel the active turn.                                         |
| `/resume` / `/resume N`           | List or resume a saved session for this working directory.      |
| `/tree` / `/tree N`               | List user turns or branch from one in the current session file. |
| `/fork` / `/fork N`               | List user turns or branch into a new session file.              |
| `/clone`                          | Copy the current history path into a new session.               |
| `/name TEXT`                      | Name the current session.                                       |
| `/reload`                         | Reload this session's local plugins.                            |
| `/why` / `/why N`                 | Explain the transition behind the latest event or event N.      |
| `/quit`, `/exit`, `/q`, or Ctrl-D | Exit; during a turn, interrupt first.                           |

Prefix a prompt with `//` to send text beginning with `/`. Commands that change
session state are refused during a turn; interrupt the turn first.

See [Sessions and chat](docs/sessions.md) for persistence, branching, and the
full command behavior.

## Rust TUI

Start a new TUI session with one command:

```bash
mix elara.tui new
```

When no server is listening, the Mix task starts one inside the same VM before
launching the Rust client. That embedded server and its live sessions end when
the command exits. To let turns continue while the TUI is closed and reattach
later, run `mix elara.server` separately; the TUI automatically uses it. See
[Detached sessions and remote workers](docs/detached-and-remote.md) for the
long-lived mode. Assistant responses and in-progress content render as terminal
Markdown, including styled headings, emphasis, code, lists, quotes, links, and
tables. User prompts and tool output remain literal.

Press **F11** or enter `/sessions` to find live and saved sessions in the
current workspace. Type a fuzzy name/ID filter, use arrows to select, and Enter
to switch. `/new` creates and opens another session; `/name TEXT` names the
current one. Switching preserves each session's unsent draft, attachments, and
transcript view. Observers stay read-only when switching. Delete asks for
confirmation bound to the selected ID; switch away from the current session
before deleting it, and stop running work first. Another controller must detach
before deletion.

`/tree` and `/fork` show branch points (Enter creates and opens a fork);
`/clone` copies the current path without changing its source. `/reload`
refreshes the authoritative snapshot; `/why` opens scrollable transition
diagnostics. `/help`, `/appearance`, `/model`, `/effort`, `/interrupt`, and
`/detach` expose the other controls. Type `/` for matching actions, or `//` for
a literal slash.

Saved startup also works without a running server:
`mix elara.tui -- SESSION_ID`. The footer explicitly identifies an embedded
server (exits with the TUI) versus a long-lived server. F11 retries attachment
after a disconnect; press it again after reconnecting to open the picker.

Choose appearance before attaching with `mix elara.tui new --appearance`, or
press **F3** during a session. Left/Right chooses the layout (Ember inline,
Observatory side pane, Workbench turn rail and strip); Up/Down chooses one of
four independent themes (Ember, Observatory, Workbench, Forest). Enter applies;
**s** applies and saves defaults to `~/.elara/tui-appearance.json`; Esc cancels.
`--layout workbench --theme forest` overrides defaults for one launch.
`ELARA_TUI_APPEARANCE_FILE` selects a separate preferences file.

**F4** hides/shows thinking and retains that choice through layout switches.
**F5** opens its full view; **F6** opens turn navigation. Esc closes either view
and restores focus. Turn navigation shows short summaries; the transcript
retains each full prompt. Optional side panes collapse on narrow terminals;
these keys keep them accessible. Thinking identifies the inspected historical turn
or live-following turn. The Codex provider displays public reasoning summaries,
commentary, and final answers separately; missing summaries are labeled
unavailable. `--preview-reasoning` explicitly shows a labeled, synthetic
presentation fixture; it is not saved in preferences or conversation history.

**F7** opens Codex model and reasoning-effort controls. Up/Down chooses a model;
Left/Right chooses effort; Enter accepts and Esc cancels. Accepted settings apply
to the next provider request, including the next tool-loop iteration. The view
distinguishes the active request from next-request settings, which survive resume
and are inherited by children. Available choices are pinned to the observed
subscription catalog; advertised choices may still be rejected by the provider.
Sessions saved with provider settings require a build with provider-visibility
support; older builds reject the expanded session header.

F7 also shows provider-reported request usage and session totals when available.
Context size is a labeled conservative byte estimate, with an advertised model
limit; it is not exact tokenizer occupancy. See the [subscription evidence](docs/subscription-capability-preflight.md)
for tested capabilities and limitations.

Use **F8** to find workspace text files, **F9** to attach a PNG from a local disk
path, and **F10** to inspect or remove draft selections. Typing `@` at a word
boundary also offers file discovery; Enter or a mouse click explicitly selects
a reference. Esc keeps literal `@query` text. Ordinary mentions and pasted `@`
text do not cause file reads. File discovery supports fuzzy matching, spaces,
and Unicode; narrow the query when results are truncated.

Up to four files/images can accompany a prompt. Text references are read when
the prompt is submitted, with at most 64 KiB of UTF-8 content per file;
submitted metadata labels clipping and included bytes. PNG images may be outside
the workspace and are limited to 2 MiB, 4096 pixels per dimension, and 16M
pixels. Supported PNGs are 8-bit, non-interlaced grayscale, RGB, gray-alpha, or
RGBA. Invalid, missing, or oversized inputs leave the draft intact. Selecting
images requires a connected controlling client; disconnected drafts remain
visible. F11 reconnects and revalidates retained images without resending
prompts.

Accepted content is immutable in the saved conversation, so moving or editing
the original file does not change later requests. The transcript shows attachment
metadata, including included/original text sizes; image bytes stay out of screen
snapshots and diagnostic recordings. Context estimates are shown as unknown when
images are present, because encoded image bytes do not measure model token usage.
PNG delivery requires the Codex provider;
other providers explicitly reject image input. Text references remain available
through the existing OpenAI-compatible provider. Programmatic callers can use
`Elara.Attachment.ingest_image(name, base64)` and
`Elara.ask_input(session, prompt, references, images)`.

The composer edits multiline text with a visible cursor and keyboard selection.
Enter sends when idle; **Ctrl-J** inserts a newline in both legacy and enhanced
keyboard modes. Alt-Enter works when the terminal transmits it distinctly
(for example, Escape followed by Enter). Shift-Enter works with enhanced keys;
the client probes support and shows the bindings it can advertise. Ghostty and
WezTerm settings can change what modified keys send: use Ctrl-J if they arrive
as plain Enter. Press F1 for all bindings, including word movement/deletion,
Home/End, Shift-selection, and Alt-Up/Down history. Returning past the newest
history prompt restores your original draft, cursor, and selection.

Bracketed clipboard paste preserves newlines without sending. If paste framing
is unavailable, press **F2 before pasting**: safe paste mode inserts Enter as a
newline and disables application commands; F2 exits that mode without sending.
In safe mode adjacent Enter/Ctrl-J events normalize CRLF to one newline.
Review the draft, then Enter to send. Unframed pasted Enter is indistinguishable
from typed Enter, so this mode must be enabled in advance. This fallback handles
text, not arbitrary terminal key escape sequences. Tabs remain tabs (displayed
at four-column stops), CRLF/CR become LF, and other C0/C1 controls are removed.
An insert over the 64 KiB draft limit is rejected as a whole.

Drafts stay editable while the session streams. **Enter** durably queues normal
follow-ups FIFO. **F12** (or `/queue`) opens the inbox; Delete cancels the
selected pending entry. **Ctrl-S** (or `/steer TEXT`) prioritizes an instruction
at the next safe boundary: an active provider request is interrupted, but an
already-started tool settles before steering and unstarted sibling calls are
suppressed. **Ctrl-X** stops and pauses queue draining without deleting pending
inputs. Resume with **r** in the inbox, `/resume-inputs`, or a new normal
submission. The inbox shows effective execution capabilities; trusted local
execution adds no approval prompts. Observers can inspect the inbox but cannot
mutate it.

Only authoritative acceptance clears an unchanged draft; edits made while
waiting survive. Pending submission IDs and image payloads are saved privately
under the TUI state directory. Reconnect queries the original ID rather than
resending; an unknown ID retains the draft for explicit submission. Accepted
inputs and immutable attachments persist with the session. Consumed means
delivered once, not that a tool effect succeeded. Unsettled durable executor
receipts block subsequent queued work, including after restart. This does not
make external commands exactly-once. Legacy servers without `input_queue_v1`
retain the earlier non-queued ask behavior.

Ctrl-C detaches. Esc closes search/help or returns transcript focus to the
prompt before detaching. Unsubmitted drafts live in this client window; only
submissions awaiting acceptance are saved after exit. Local history recalls up
to 200 canonical prompts that fit the editor limit; it does not change persisted
history.

Press **Tab** to move between the prompt and transcript. With transcript focus,
Up/Down scroll by line, PageUp/PageDown by page, Home goes to the beginning, and
End returns to live following. Alt-Up/Down visits user turns. Scrolling away
pauses following: new output does not pull you away from what you are reading.
The transcript shows whether it is following or paused. Your prompt stays intact
while you navigate.

In the transcript, **/** opens case-insensitive search. Enter advances to the
next match, Shift-Enter goes to the previous match, and Esc closes search.
The match counter shows where you are. Drag with the left mouse button to select
text; **c** copies the selection and **y** copies the current entry. Copies omit
speaker labels and borders and do not add newlines at visual wraps. Real content
line breaks remain; crossing entries separates them with a newline.
Assistant Markdown copies as rendered plain text; user text retains literal
tabs. Anchors use semantic entry IDs. Stream completion maps to the final
assistant entry; if an entry disappears, navigation falls back to the nearest
surviving prior entry (earlier on a tie), then the first current entry. Text
offsets clamp to surviving grapheme boundaries when content changes.

The app sends clipboard text through `pbcopy` on macOS and available clipboard
utilities on Linux. A failed or unavailable clipboard command produces a notice;
the app does not claim success. Mouse reporting supports wheel scrolling and
selection. Terminal-native selection remains available through the terminal's
mouse-reporting bypass modifier (typically Shift; check your terminal settings).
F1 lists the current action bindings.

Tool calls appear as compact blocks with their canonical state, useful argument
summary, and result preview. Select a block and press **Space** to expand or
collapse it; **f** opens a fullscreen viewer. Click the block's left gutter to
toggle expansion, or right-click a block to inspect it fullscreen. Esc or
right-click closes the viewer and restores your transcript position. The draft
stays intact throughout inspection.

Expanded blocks and the fullscreen viewer expose all retained arguments as JSON
and retained result text. The viewer uses the same scrolling, search, selection,
and copy controls as the transcript. Whole-entry copy includes the currently
shown details: expand the block or open its viewer to copy the complete retained
arguments and result. Compact display folding is separate from upstream
truncation. Truncation markers found in result text are labeled as text evidence when their source
cannot be verified; discarded output cannot be recovered by expanding a block.
Terminal control characters are removed from displayed result text except tabs
and line breaks. Argument JSON retains escaped characters.

Bash, read, write, and edit blocks have tailored summaries; other tools retain a
generic argument/result view. Successful edits may show a replacement snippet
from the canonical old/new arguments. It is not a full-file diff or a fresh
filesystem comparison, and failed or indeterminate edits do not claim a
successful replacement.

## Persistent delegated children

Use a long-lived `mix elara.server` for work that must continue after detaching
the TUI. `/delegate coding TASK` starts an independent persisted session on a
managed Git branch/worktree at the parent's committed HEAD.
`/delegate research TASK` shares the checkout with only the parent's available
built-in `read` and `skill` tools and read capabilities. This is trusted-local
capability restriction, not an OS sandbox. Coding tools can still access paths
outside their checkout; the managed worktree isolates ordinary relative-path
edits, not hostile code.

The model has the same `start_child` tool (`assignment`, optional `coding` and
`history` booleans). The default context is just the selected assignment:
include needed excerpts or explicit file content there. Uncommitted parent files
are never silently copied. `/delegate-fork coding TASK` or
`/delegate-fork research TASK` explicitly includes the parent's current
transcript instead. Children load project instructions and skill metadata in
their actual cwd and retain the parent's explicit tool/capability limits and
effective provider/model/effort. No additional approval prompts are introduced.
Plugins are not auto-enabled.

`/children` lists direct children with a **four-active-child-turn limit per
VM**. Filter by assignment/ID; Enter opens or resumes the selected child, and
Tab opens scrollable metadata including full IDs, cwd, base revision,
capabilities and integration receipts. Open children use the existing
transcript, queue, model, reasoning and provider-reported usage views; there is
no invented aggregate subscription accounting. F11 remains ordinary workspace
session discovery. Observers can inspect/open but cannot delegate, integrate,
clean up or stop work.

Parent stop/detach, coordinator stop and sibling failure do not stop children.
`/stop-subtree` explicitly requests interruption of this session and
descendants; already-dispatched effects may still be settling. Stop never
removes a worktree. An embedded VM still exits with its TUI: saved recovery is
**not** uninterrupted background execution. On restart, open the child and
explicitly send a follow-up or resume its paused queue. Recorded effect outcomes
are reconciled; the original assignment is never automatically resubmitted.
Interrupted/indeterminate work is not reported as completed. A lost integration
acknowledgement leaves a durable `integrating` marker and patch;
inspect/reconcile it manually instead of replaying.

From the parent, `/integrate CHILD_ID` captures that child's committed and
non-ignored uncommitted changes as an immutable binary Git patch. Both live
sessions must be idle with settled effects, and **the entire parent checkout
must be clean**, including untracked files. Git checks for conflicts and applies
to the parent index/worktree; this does not commit, push or merge a branch.
Receipts retain the patch, tree and parent revision. Review and commit normally.
`/cleanup-child CHILD_ID` is separate: it requires integration of the exact
current tree, no ignored files, and a clean child worktree (commit the child's
integrated changes first). It never uses forced removal. The child branch,
transcript and integration patches remain; a cleaned workspace cannot resume.

Metadata/workspaces live under `~/.elara/sessions/_threads/` (or the configured
Store root). Programmatic entry points are
`Elara.Threads.start_child(parent_id, assignment, coding: true)`, `list/1`,
`resume/2`, `integrate/2`, `cleanup/2`, and `stop_subtree/1`. Generic
saved-session startup also enforces the recorded child configuration. In-place
hydrate and ordinary clone/fork of managed children are rejected rather than
losing identity or widening read-only limits; use independent open or explicit
delegation with history. Custom tool modules must be installed and loaded before
resuming; provider credentials are resolved afresh, never serialized into
delegation metadata. Do not resume managed children using older Elara builds
that do not enforce this metadata.

### Thread communication and navigation

`/threads` (also `/children`) opens the compact parent/child list in every
layout. Enter opens a thread, Tab inspects its full metadata, `/return` opens
the parent, and `/open THREAD_ID` opens a known session. Opening a child uses
the ordinary transcript, tool inspector, F12 queue, F7 model/effort and
reasoning views. Switching retains each thread's draft and local view state and
preserves control versus observation. An observer never gains control by
navigating.

Unread **UI notifications** are distinct from model delivery receipts: opening
or inspecting a listed thread acknowledges its notifications locally, not its
model inbox. Those acknowledgements survive reattachment and thread switching
within the TUI process; a new TUI process may show the notifications again.
Reading, listing, reattaching and resnapshotting never generate model turns.

Models can use `thread_send`, `thread_read`, `thread_status`, and `thread_wait`.
Send requires a related direct parent/child ID, a stable `message_id`, and
nonempty text (maximum 64 KiB). Retry the same ID/content after uncertain
acceptance: different content conflicts, and accepted order is authoritative,
not lexical ID order or retry arrival order. Follow-ups use the existing child;
they do not create another thread or replay its assignment. Research children
retain communication tools only when present in the parent's explicit tool set.
Sender identity comes from execution context, never tool arguments or text.
Assignments and delivered messages retain typed agent provenance, and provider
requests explicitly distinguish them from owner instructions.

Completion evidence retains the full result, workspace, original message IDs,
file-operation and tool/test references, and uncertainty. The inbox has an
explicitly labeled 2,000-character preview, not the only retained result.
`thread_read` returns 2,048-character pages: use `character_offset` to continue,
`offset` to select another matching original message, `query` for literal
search, or `source_message_id` for a known original. A completion's `message_id`
reads the full retained report in pages. Active-branch membership and later
source IDs identify revisions without treating summaries as truth. Private
provider continuation state and image bytes are excluded from evidence reads.
File-operation references are not a claim that a failed operation changed bytes;
consult the linked results. Shell/plugin and manual changes are not inferred.

Transport receipts and staged completion evidence live under
`~/.elara/sessions/_thread_messages/`. Durable acceptance precedes delivery to
the receiver's existing inbox. Duplicate deliveries use the same logical input
ID, preserving CTRL-1's atomic consumption and external-effect barriers. Busy
parents finish their current turn before receiving reports; no child completion
automatically interrupts them. Idle live parents can wake, but stopped/paused
inputs remain paused, including a stop made before any inbox entry exists.
Offline recipients retain pending delivery until explicitly opened/resumed.

`thread_wait` is a cancellable event wait, not repeated model polling or a
second execution loop. It has no ordinary tool deadline; explicit interrupt or
target process loss settles it. A VM restart interrupts waiting rather than
replaying uncertain tools. The report still follows the separate inbox path.
Eight consecutive automatic agent/report turns exhaust a durable wake budget;
F12 then `r`, `/resume-inputs`, or a new owner submission resets it. Empty sends
are rejected, report responses do not generate ancestor reports, pending
transport is limited to 64 entries per recipient, and delegation depth is
limited to three (in addition to four concurrently running children).

The additive `thread_communication_v1` extension exposes agent/report inbox
kinds. Older queue clients see only their supported ordinary/steer entries;
agent provenance remains explicit in transcript text. Saved agent provenance and
wake-budget headers require this build for resume. This is trusted local thread
communication, not hosted sharing or an OS sandbox. CTX-1 automatic handoff
remains separate work.

## Built-in tools

- `read` reads a file.
- `start_child` starts persistent delegated work as described above.
- `write` atomically writes a workspace-relative regular file and creates parent
  directories. It records durable controller intent and executor receipts before
  and after mutation.
- `edit` replaces exactly one occurrence of `old_text` with `new_text`.
- `bash` runs a shell command with stdout and stderr merged. A supervised Rust
  stub runs each command in its own process group and kills the group on
  interruption, timeout, or output overflow. Stub loss reports an
  `indeterminate` outcome rather than success.

Relative paths and shell commands use the session working directory. `write`
rejects absolute paths, `..`, symlink path components, and non-file targets so
its observed preimage and atomic replacement stay inside that workspace. `read`
and `edit` still call `Path.expand/2`, and `bash` is unrestricted, so those
tools can reach outside the working directory. Use a container or other OS
sandbox when the model or workspace is not trusted. This confinement belongs to
the default session's declarative-write path; the low-level
`Elara.Tools.write/2` helper is not itself a workspace-confinement boundary.

The local write executor stores its durable ledger under
`~/.elara/sessions/_effect_executors/`; persistent sessions keep their
controller journal beside the session JSONL. If a process stops after a write
starts, `mix elara.chat --continue` reconciles those records. It returns a
recorded terminal result without rewriting, continues only accepted work whose
callback never started, and reports `indeterminate` rather than retrying after a
callback started without durable terminal evidence.

Each turn allows 12 model iterations by default. Each tool has a 30-second
timeout. Shell output is capped at 16 KiB in the execution stub, and the session
keeps the same 16 KiB cap as a second line before output enters model history.

## More user guides

- [Sessions and chat](docs/sessions.md): resume, branch, clone, and inspect why
  an event occurred.
- [Live plugins](docs/plugins.md): add trusted, stateful local tools and reload
  them without restarting a session.
- [Detached sessions and remote workers](docs/detached-and-remote.md): keep a
  session alive after a client disconnects and execute tools elsewhere.
- [Elixir API](docs/elixir-api.md): target another directory, subscribe to
  events, configure sessions, replay recordings, and coordinate child sessions.
- [Roadmap](ROADMAP.md): the sole current implementation plan and status source.

## Develop

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
cd native/exec-stub && cargo fmt --check && cargo clippy && cargo test
cd ../elara-tui && cargo fmt --check && cargo clippy && cargo test
```

The interactive TUI tests also require Python 3 and a Unix PTY. Tests use
`Elara.Provider.Scripted` and do not call external networks. One
crash-recovery test intentionally logs a `RuntimeError) boom` error; the final
test result determines whether the run passed.
