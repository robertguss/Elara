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
discovery, session scope, and the optional `AGENTS.md` appended to the system
prompt.

## Authenticate

### OpenAI Codex subscription

An eligible ChatGPT Plus/Pro Codex subscription can provide the model while
Elara keeps ownership of its own session, tools, execution, and agent loop:

```bash
mix elara.login openai
export ELARA_PROVIDER='openai-codex'

# Optional; this is the current default:
export ELARA_MODEL='gpt-5.3-codex'
```

Open the printed OpenAI URL, enter the device code, and wait for Elara to save
the tokens under `~/.elara/openai-codex-auth.json` with mode `0600`. Elara uses
the subscription-backed Codex Responses stream and identifies itself as
`originator=elara`; it does not read credentials from Codex, Pi, or another
harness. `ELARA_PROVIDER` must be set in the process that owns the session—for
detached use, that is `mix elara.server`.

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

Drafts stay editable while the session streams. Busy/rejected submissions retain
the draft. Only the corresponding server acceptance clears an unchanged draft;
edits made while waiting survive. A lost or delayed acknowledgement is shown as
uncertain and repeat submission is blocked. Inspect the session before retrying
from a new attachment; this is not a durable queue or reconnect deduplication.
Ctrl-X interrupts; Ctrl-C detaches. Esc closes search/help or returns transcript
focus to the prompt before detaching. Drafts live in this client window and are
not saved after it exits. Local history recalls up to 200 canonical prompts that
fit the editor limit; it does not change persisted conversation history.

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

## Built-in tools

- `read` reads a file.
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
