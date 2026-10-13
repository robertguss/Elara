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

The TUI is Elara's primary interactive interface. The `bin/elara` launcher runs
it from this source checkout while working in your current project. It is not
a standalone release: keep the checkout and toolchain installed.
You need Elixir 1.20, Erlang/OTP 29, Rust 1.88 or newer with
Cargo, rustfmt, and Clippy, plus the `flock` command. The Rust components can be
installed with `rustup component add rustfmt clippy`; distribution-provided Rust
1.85 is too old for the TUI dependencies. Mix builds the Rust execution stub
automatically and builds the Rust TUI on first use; a missing Cargo installation
fails with setup instructions.

```bash
git clone https://github.com/robertguss/Elara.git
cd Elara
mix deps.get
export PATH="$PWD/bin:$PATH"
```

For future terminals, add that **absolute checkout path** to your shell's PATH
(for example, `export PATH="$HOME/code/Elara/bin:$PATH"` in `~/.zshrc`). Add the
directory to PATH rather than copying or symlinking the script elsewhere.
[Configure a provider](#authenticate) from the Elara checkout, then:

```bash
cd /path/to/your/project
elara                         # new TUI session here; does not auto-resume
elara list                    # live and saved sessions for this workspace
elara SESSION_ID              # reopen a listed session
elara -- -SESSION_ID          # IDs beginning with a hyphen
elara --cwd ../other-project  # relative to the directory you invoke it from
```

Existing provider/model/reasoning settings and login files are reused. Relative
`CODEX_HOME`, `ELARA_TUI_STATE_DIR`, and `ELARA_TUI_APPEARANCE_FILE` paths stay
relative to the invoking directory, even with `--cwd`. Session history, tools,
instructions, and skill discovery use the selected workspace instead.
The launcher builds in the Elara checkout; it does not evaluate your project's
`mix.exs` or place build artifacts there. It does not install dependencies or
update itself. An embedded server lives only as long as the launcher; use
`mix elara.server` from the Elara checkout with a shared `ELARA_SERVER_TOKEN`
when sessions need to outlive the TUI.

The Elixir API and one-shot commands remain supported. Line-oriented chat is
retained for compatibility, but new interactive work focuses on the TUI.
The `mix elara.ask`, `mix elara.chat`, and `mix elara.tui` commands use the Mix process's current
directory by default. To target another existing directory while running from
the Elara checkout, pass `--cwd DIR`; relative directories resolve against the
invoking directory without changing it:

```bash
mix elara.ask --cwd /path/to/project "summarize this repository"
mix elara.chat --cwd /path/to/project --continue
mix elara.tui --cwd /path/to/project new
mix elara.ask --cwd /path/to/project -- "--literal prompt text"
```

The [Elixir API](docs/elixir-api.md) also accepts an absolute `cwd:`.
TUI listing and saved-session reopening use the selected workspace; attaching
to an already-live session retains that session's original workspace.

The working directory controls relative tool paths, shell commands, local plugin
discovery, session scope, project instructions, and Agent Skills discovery.

### Stable daily build

Use the separate daily build when building Elara with Elara. It has its own
source, dependencies, `_build`, and native binaries, so agents can run
`mix compile` and `bin/check` in the development checkout without replacing a
running session's command runner.

```bash
# From the development checkout; fetch and build the latest origin/main:
bin/elara-update
# Or choose a specific commit already merged into main:
bin/elara-update COMMIT

cd /path/to/your/project
elara-stable                    # same arguments as elara
```

Updates are explicit, not automatic. Each successful update switches future
launches; existing sessions keep their original build. Failed updates leave the
previous build selected. Builds live under `~/.elara/daily` (override with an
absolute `ELARA_STABLE_DIR` for both commands). Old builds are retained; do not
remove one while a session uses it. This is a source build, not an installer or
release; it still needs the toolchain. Provider login and session files are
shared with the ordinary launcher. Use a separate server port when running both
builds at once, since attaching to an existing server uses that server's build:
`elara-stable --port 4050`.

For a small practice project, use [the shipping example](examples/shipping/README.md).
Its Mac guide creates disposable workspaces and includes chat/TUI tasks with
independent checks. The baseline needs no dependencies or network.

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
validated when loaded. Delegated children rediscover in their own
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

### Transient provider failures

Every provider shares one retry policy. A rate limit, an overload, a 5xx, or a
connection dropped before the attempt published anything is retried with
jittered exponential backoff; a server `Retry-After` is waited out exactly.
Authentication, invalid requests, context limits and malformed responses are
not retried. Once an attempt has streamed text or a typed part, its failure is
surfaced instead of replayed, so nothing is duplicated. Interrupting the turn
abandons a pending wait at once, and `mix elara.ask`/`mix elara.chat` print a
`[retry]` line while the TUI status row shows the attempt.

```bash
# Optional; these are the defaults. 1 attempt turns retries off.
export ELARA_PROVIDER_RETRY_ATTEMPTS='4'
export ELARA_PROVIDER_RETRY_MAX_WAIT_MS='60000'
```

The Elixir API takes `provider_retry:` with a policy or policy options
(`Elara.start_session(provider_retry: [max_attempts: 2])`), which children and
handoff successors inherit.

Flight recordings now use format 2 to include retry state. Format 1 recordings
are preserved but report `unsupported_format` in this build rather than false
replay divergence; replay them with the
[last format 1 build](https://github.com/robertguss/Elara/commit/daa06f281368d0a532721695c6a656ec12ec14a5).
Session JSONL history is unchanged and remains reopenable.

### Provider usage and estimated cost

OpenAI-compatible, Grok OAuth and Codex responses retain provider-reported
input, cached-input and output tokens, plus the actual response model.
Cached-input tokens are included in input tokens, not extra tokens.
Missing counters remain unknown. Streaming usage frames replace cumulative
counters instead of counting the same request twice.

The authoritative `Elara.materialized_view(session)` snapshot exposes:

- `provider_view.usage.last_request`: the latest reported counters, or `null`.
- `provider_view.usage.session_totals`: sums of reported counters along the
  current history path. Top-level `usage` contains the same totals.
- `provider_view.usage.cost`: `estimated_usd_nanos`, `priced_records`,
  `subscription_records`, `unpriced_records`, `complete`, and `models`.
  Each model row has those totals plus `provider`, `billing`, `model`, and `tokens`.
- Assistant messages carry `response_model`, `usage`, and an optional
  `billing_receipt`. The receipt records authentication provenance and the
  price source, version and rates used for that response.

Costs use integer billionths of a US dollar. An estimate sums only priced API
responses. `complete: false` means that some responses cannot be priced, so
the sum is partial. No priced responses means `estimated_usd_nanos: null`,
not $0. Codex and Grok OAuth are subscription usage, with token counts only;
Elara does not turn those tokens into API spend or estimate a subscription bill.

The TUI footer shows session input, cached-input and output tokens. `cached(in)`
names the subset already included in input, and `?` marks an unreported counter.
An API estimate appears as `~$0.0489`; `(partial)` marks a sum with unpriced
responses. No price means no dollar value, including subscription-only usage.
Positive estimates below $0.0001 appear as `~<$0.0001`, not zero.
The `Ctx ~used/window` meter reads `inbox.context`, not cumulative session tokens.
It labels low confidence, near-limit warnings and required handoffs. Fields wrap
on narrow terminals and remain visible in tool inspection and appearance views.

Standard prices are pinned for OpenAI `gpt-4.1` and its `2025-04-14` snapshot,
and xAI `grok-4.6` and `grok-4.7`. xAI prices double at 200K input tokens for
the whole request. Rates are saved with each response and survive reopening,
copying and replay without repricing old history.
The sources are [OpenAI's GPT-4.1 prices](https://developers.openai.com/api/docs/models/gpt-4.1)
and [xAI's pricing table](https://docs.x.ai/developers/pricing), checked on 2026-10-13.
Unknown models, custom endpoints, missing billing provenance, nonstandard
service tiers, incomplete counters and unpriced cache writes remain unpriced.
Nested tool usage has no billing receipt and is unpriced, not silently billed
as the main provider. Clearing tool results leaves the parent's usage evidence
unchanged; children of cleared parents retain C3's reset counters and may be unpriced.

## Command environment

Commands run by `bash`, search, jobs, and the shipped Elixir project plugin get
a strict build/cache environment, not the whole shell environment. The runner
clears inherited variables before supplying allowed values. Exact defaults are:

- `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `LANG`, `TERM`, `COLORTERM`,
  `NO_COLOR`, `SSH_AUTH_SOCK`, `TMPDIR`, `TMP`, `TEMP`, `TZ`;
- `CARGO_HOME`, `RUSTUP_HOME`, `RUSTUP_TOOLCHAIN`, `RUSTFLAGS`,
  `CARGO_TARGET_DIR`, `CARGO_BUILD_TARGET`;
- `CC`, `CXX`, `CFLAGS`, `CXXFLAGS`, `CPPFLAGS`, `LDFLAGS`, `PKG_CONFIG_PATH`,
  `PKG_CONFIG_LIBDIR`, `PKG_CONFIG_SYSROOT_DIR`, `RIPGREP_CONFIG_PATH`;
- `MIX_ENV`, `MIX_TARGET`, `MIX_HOME`, `HEX_HOME`, `MIX_ARCHIVES`, `MIX_PATH`,
  `MIX_BUILD_PATH`, `MIX_DEPS_PATH`, `ERL_LIBS`, `ERL_FLAGS`, `ERL_AFLAGS`,
  `ELIXIR_ERL_OPTIONS`.

Defaults also match `LC_*`, `MISE_*`, `ASDF_*`, `HOMEBREW_*`, `MIX_*`,
`HEX_*`, `ERL_*`, and `ELIXIR_*`, **except prefix-matched names containing
`TOKEN`, `API_KEY`, `KEY`, `PASSWORD`, `SECRET`, `AUTH`, or `CREDENTIAL`**.
Name those explicitly to forward them, for example `HEX_API_KEY` or
`HOMEBREW_GITHUB_API_TOKEN`. This exclusion does not apply to exact defaults:
`SSH_AUTH_SOCK` always passes. Version-manager shims remain available via
`PATH`. Internal git and session-lock subprocesses are unchanged.

To pass your app's variables through, name them in **operator startup config**.
For example, after your shell or direnv has exported the app's values:

```bash
export ELARA_COMMAND_ENV='DATABASE_URL,SECRET_KEY_BASE,PORT'
mix elara.env                     # forwarded and withheld names; never values
bin/elara --cwd /path/to/phoenix-app
```

The comma-separated list selects existing values; it does not set them. Keep
this list in your own shell/startup configuration, not an agent-editable
project file. Restart an existing Elara server after changing its environment.
Tool arguments cannot add names. Elara currently has no user-level command
environment config file.

**Elara's own credentials never pass through, even when named:** provider keys,
Exa, server and worker tokens, and Codex/Grok auth variables. The `ELARA_`,
`XAI_`, `EXA_`, `OPENAI_`, `CODEX_`, `GROK_`, and `ANTHROPIC_` namespaces and
`CLAUDE_CODE_OAUTH_TOKEN` stay withheld. **Project credentials you explicitly
name do pass through**, including `DATABASE_URL` and `SECRET_KEY_BASE`; only
name values you intend the model's commands to use.

Run `mix elara.env` with the same startup environment to diagnose a missing
variable. It lists forwarded and withheld names without exposing values.
Environment scrubbing is **not an OS sandbox**: commands and trusted local
plugins can still read credential files through ordinary filesystem access.

## File-tool fence

The model's `read`, `write`, `edit`, `grep`, and `glob` tools stay inside the
session workspace and any extra folders you name in the startup environment.
To allow another checkout or shared source directory, use existing absolute folder paths:

```bash
export ELARA_FILE_ROOTS='/Users/robert/shared:/Users/robert/other-app'
bin/elara --cwd /Users/robert/phoenix-app
```

The colon-separated list belongs in operator configuration, not a project
file or tool argument. Restart an existing server to change its environment.
Symlinks are resolved: links inside allowed roots work, including
`CLAUDE.md → AGENTS.md`; escaping links are refused unless the destination is
in an explicitly allowed root. Writes change the resolved destination, not
the link. Receipt-backed writes pin that destination and check it again
before execution or recovery; a changed or newly forbidden target returns
an ordinary tool error instead of freezing the session. Remote workers
retain their stricter relative-path, no-symlink policy.

**Protected paths always win**, even inside the workspace or an extra root:
`~/.elara/**`, `~/.codex/auth.json`, `~/.ssh/**`, configured session and plugin
trust storage, `.git/config`, `.git/hooks/**`, shell startup files (including
`.profile`, `.bashrc`, `.bash_profile`, `.zshrc`, `.zshenv`, and
`fish/config.fish`), `.envrc`, and `.iex.exs`. Protected names apply at any
depth, and aliases to protected destinations are refused too.
Older coding children whose saved worktrees are inside `~/.elara` can still
reopen with retained evidence, but their model file tools refuse those paths.
Start a new coding child to work in the unprotected worktree root; existing
worktrees are not moved or deleted.

This fence does **not** wrap Elara's internal skill, session, or plugin reads.
It is **not an OS sandbox**: `bash`, search, other tools, and trusted plugins
are not granted filesystem isolation by it.

## Command rules and approval

Every model `bash` call checks command-text rules before execution. A deny
match returns a tool error. An ask match waits for the controlling TUI to
approve that exact call. The approval view shows the command and the matching
rule. Esc closes the view, then `/approve` confirms the displayed request.
`/approve REQUEST_ID` selects an explicit request. There is no default key.
The `approve` action can be bound in `keymap.json`; that key approves the exact
pending request even from the inspection view, without clearing the draft.
Observers cannot approve. Esc outside a panel interrupts the waiting turn
without running its pending calls.

The base rules deny `MIX_ENV=prod` and ask for force pushes (`--force`, `-f`,
`--force-with-lease`), `git reset --hard`, `git clean -fdx`, and `mix ecto.drop`.
Common Git flag placements, reordered or split clean flags, and `-C`/`-c`
prefixes match the same base rule. Ordinary pushes and `git clean -fd` do not.

Project rules live in `.elara/command-rules.json`:

```json
{"deny": ["printf forbidden"], "ask": ["printf inspect-first"]}
```

These are literal, case-sensitive substrings, not regular expressions.
Deny/ask lists match the raw text and a quote-stripped, whitespace-normalized
copy, plus the common Git aliases above. They do not evaluate the shell.
Deny wins over ask. Rules apply to the whole command string, including compound
commands. Invalid or oversized files fail closed. Files are limited to 64 KiB.
The session captures project rules before the model starts and rereads them
before each command. Adding restrictions takes effect immediately. Removing
a restriction or changing deny to ask requires approval of the exact new file
bytes. Deleting the file also requires approval. Until then, previous
restrictions remain. Approving a rule change does not approve a command that
still matches an ask rule.

`ELARA_COMMAND_RULES` accepts the same JSON object from the operator's startup
environment. These rules can only add to or tighten the base rules. A repository
cannot remove them. Changing a running server's environment does not replace them.
Saved sessions, copies, children, and handoff successors retain project
restrictions, but never inherit pending approvals. Restarting a waiting session
never executes its unapproved call. Approval rereads the rules and still checks
read-only mode and the session's capability grants. Blocks and approvals are
recorded with their transcript positions and replay facts.

`mix elara.ask` refuses an ask-matched call without execution and tells the model
and operator to use the TUI. The turn can continue with other tools. If its last
tool result still requires approval, the command exits with status 1.
Line chat also refuses the call and points to the TUI, then returns to its
prompt. A refusal does not change chat's exit status. Reopened sessions use
the opening client's approval mode, not a saved client's mode.

Command rules are **text matching, not an OS sandbox or a shell parser**.
Alternate spellings, scripts, interpreters, and trusted plugins can bypass
text matches. The file-tool fence and read-only mode remain separate checks.

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

In terminals supporting bracketed paste (including WezTerm), chat holds a
multiline paste as one draft until you press Enter. Pasted slash commands are
literal prompt text; type `/quit` or `/interrupt` to execute those commands.
Pipes and terminals without bracketed paste remain line-oriented: use a single
line there, or use the TUI for multiline editing.

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

Long-lived servers require the same `ELARA_SERVER_TOKEN` (32–512 bytes) in
the server and client terminals. The embedded Mix TUI creates a random token
when none is configured. Before loading repository plugins, review their
source and run `mix elara.trust WORKSPACE` from the Elara checkout. Approval
covers exact file bytes; changed or new plugins need approval again.

Press **Ctrl-O** or enter `/sessions` to find live and saved sessions in the
current workspace. Type a fuzzy name/ID filter, use arrows to select, and Enter
to switch. `/new` creates and opens another session; `/name TEXT` names the
current one. Switching preserves each session's unsent draft, attachments, and
transcript view. Observers stay read-only when switching. Delete asks for
confirmation bound to the selected ID; switch away from the current session
before deleting it, and stop running work first. Another controller must detach
before deletion.

`/tree` and `/fork` show branch points (Enter creates and opens a fork);
`/clone` copies the current path without changing its source. `/reload`
refreshes the authoritative snapshot; `/plugins reload` discovers and reloads
trusted local plugins between turns. `/why` opens scrollable transition
diagnostics. `/help`, `/appearance`, `/model`, `/effort`, `/interrupt`, and
`/detach` expose the other controls. Type `/` for matching actions, or `//` for
a literal slash.

Saved startup also works without a running server:
`mix elara.tui -- SESSION_ID`. The footer explicitly identifies an embedded
server (exits with the TUI) versus a long-lived server. Ctrl-O retries attachment
after a disconnect; press it again after reconnecting to open the picker.

Choose appearance before attaching with `mix elara.tui new --appearance`, or
enter `/appearance` during a session. Left/Right chooses the layout (Ember inline,
Observatory side pane, Workbench turn rail and strip); Up/Down chooses one of
four independent themes (Ember, Observatory, Workbench, Forest). Enter applies;
**s** applies and saves defaults to `~/.elara/tui-appearance.json`; Esc cancels.
`--layout workbench --theme forest` overrides defaults for one launch.
`ELARA_TUI_APPEARANCE_FILE` selects a separate preferences file.

### Custom keys

The controls described here are defaults. Put a JSON object in
`~/.elara/tui/keymap.json` (or `$ELARA_TUI_STATE_DIR/keymap.json`):

```json
{
  "provider_settings": "ctrl+k",
  "submit": "f3",
  "newline": "f2",
  "read_only": "alt+a"
}
```

Each entry replaces all shortcuts for that action with one key. Restart the
TUI to load changes; reconnecting or switching sessions keeps its map. `/help` and
on-screen hints show the effective keys. Slash commands do not change. Actions
without a default shortcut, including `read_only` and `undo`, can be bound.

Action names are `appearance`, `files`, `image`, `attachments`,
`provider_settings`, `thinking`, `thinking_view`, `turns`, `focus`, `toggle_tool`,
`tool_viewer`, `up`, `down`, `page_up`, `page_down`, `home`, `tail`, `previous_turn`,
`next_turn`, `search`, `next_match`, `previous_match`, `copy`, `copy_entry`, `help`,
`paste`, `external_editor`, `submit`, `newline`, `interrupt`, `escape`,
`clear_or_quit`, `sessions`, `queue`, `steer`, `read_only`, `undo` and `select_all`.
Their scope stays the same: transcript-only actions remain transcript-only;
help opens on an empty prompt; observer restrictions still apply.

Use `ctrl+`, `alt+` and `shift+` prefixes, a character, `f1` through `f24`, or
`enter`, `esc`, `tab`, `space`, `up`, `down`, `left`, `right`, `home`, `end`,
`pageup`, `pagedown`, `backspace` or `delete`. Modifier names are case-insensitive.
The terminal must report that combination; older terminals cannot distinguish
all modified keys. Plus itself cannot be bound with this notation.

Panel confirmation/navigation and letter controls, and low-level editing
(cursor movement, selection, word deletion and prompt history) stay fixed.
For example, rebinding `submit` does not rebind a confirmation panel's Enter.
Arrows, Home/End, PageUp/PageDown, deletion keys, Enter/Esc/Tab, panel letters
`l/t/d/n/s/r`, inline `@` file discovery (also Shift-@), and legacy Ctrl-H/I/M/[
aliases are reserved. Help labels the
fixed controls. A collision with another action (including its default key)
rejects the entry, retaining its default. Duplicate custom keys reject both
entries; key swaps through reserved defaults are not supported. An action can
retain one of its own defaults, even when that key is also fixed in panels.

Missing files use defaults silently. Malformed/unreadable files use defaults
with a startup notice; invalid entries are ignored individually, without
discarding valid ones. `/help` retains the error details. Safe terminal paste
still treats Enter, Ctrl-J and Tab as text, not configurable commands; the
effective `paste` shortcut finishes it without sending.

`/diff` opens the latest turn's workspace diff; `/diff session` shows the net
diff from the first turn's baseline. The panel refreshes during a running turn;
**r** refreshes it manually, arrows/PageUp/PageDown scroll, and Esc closes it.
Both include changes made through `bash`. Scope is the repository root's
Git-visible files (tracked and non-ignored untracked); ignored files are not
shown. Submodules are gitlink-only summaries. Binary files and files over
128 KiB are summarized, and each report section is capped at 256 KiB.
Changes observed between turns or after the latest endpoint appear separately
as **Changed outside Elara**. Private, ref-rooted snapshots live under Elara's
session state, without changing the workspace's index or HEAD. A non-Git
workspace, missing baseline, or failed capture reports unavailable rather than
a guessed diff. A live or interrupted turn has an explicitly unsealed endpoint.
Diff inspection follows the active handoff owner. Until chain-spanning reports
land, `/diff session` explicitly labels the successor-only view as unavailable
before successor start. Fork and clone start a fresh copy-time baseline and
say so in `/diff session`; inherited turns are not attributed to the copy.

`/undo` previews the latest closed turn's changed files; `/undo TURN_ID` selects
an older turn on the current path. Enter confirms, and Esc cancels without
restoring anything. Undo includes `bash` changes and leaves files the turn did
not touch alone. It refuses the whole operation, naming the files, if a touched
file changed since the endpoint or the turn changed a submodule gitlink.
Interrupt an active turn first. Undo follows the active handoff owner; missing
or inherited pre-copy snapshots are unavailable, never replaced with HEAD.

Undo cannot reverse migrations that ran, ignored folders such as `deps/` and
`_build/`, or pushes. It restores Git-visible bytes, symlinks, and executable
status, not ownership, timestamps, or full permission metadata. Existing file
read/write permissions remain; recreated files start private. A persisted
**SYSTEM** notice names the turn and files in the transcript and model context.
Handoff indexes retain those notices with references to the original entries.
Filesystem errors or concurrent edits during restoration can leave a partial
undo, which the notice reports. Reopening after an interrupted attempt records
uncertainty and never replays filesystem writes. Corrupt recovery records block
new turns rather than guessing.

**Ctrl-T** hides/shows thinking and retains that choice through layout switches.
`/thinking-view` opens its full view; **Ctrl-R** opens turn navigation. Esc closes either view
and restores focus. Turn navigation shows short summaries; the transcript
retains each full prompt. Optional side panes collapse on narrow terminals;
these keys keep them accessible. Thinking identifies the inspected historical turn
or live-following turn. The Codex provider displays public reasoning summaries,
commentary, and final answers separately; missing summaries are labeled
unavailable. `--preview-reasoning` explicitly shows a labeled, synthetic
presentation fixture; it is not saved in preferences or conversation history.

**Ctrl-P** opens Codex model and reasoning-effort controls. Up/Down chooses a model;
Left/Right chooses effort; Enter accepts and Esc cancels. Accepted settings apply
to the next provider request, including the next tool-loop iteration. The view
distinguishes the active request from next-request settings, which survive resume
and are inherited by children. Available choices are pinned to the observed
subscription catalog; advertised choices may still be rejected by the provider.
Sessions saved with provider settings require a build with provider-visibility
support; older builds reject the expanded session header.

Ctrl-P also shows provider-reported request usage and session totals when available.
Context size is a labeled conservative byte estimate, with an advertised model
limit; it is not exact tokenizer occupancy. See the [subscription evidence](docs/subscription-capability-preflight.md)
for tested capabilities and limitations.

Use **Ctrl-F** to find workspace text files, `/image` to attach a PNG from a local disk
path, and `/attachments` to inspect or remove draft selections. Typing `@` at a word
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
visible. Ctrl-O reconnects and revalidates retained images without resending
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
as plain Enter. Press **? on an empty prompt**, or enter `/help`, for all bindings, including word movement/deletion,
Home/End, Shift-selection, and Alt-Up/Down history. Returning past the newest
history prompt restores your original draft, cursor, and selection.

**Ctrl-G** (or `/editor` on an empty draft) opens `$VISUAL`, falling back to
`$EDITOR`, with a private temporary Markdown file containing the draft. Editor
commands may include arguments, for example `EDITOR='code --wait'`. Elara
suspends its terminal modes while the editor runs, then restores the composer.
A successful save replaces the draft, never sends it; a failed editor, invalid
UTF-8, or text above the 64 KiB limit leaves the original draft intact. Temporary
draft files are removed when the editor returns.

When a turn completes or ends with a provider error or turn limit, the TUI sends
a terminal bell and an OSC 777 desktop notification (supported by WezTerm).
Notifications are suppressed while the terminal reports focus; terminals that
do not report focus notify by default. Notification text is fixed and contains
no prompts, answers, or error details. `/notifications off` disables both bell
and desktop notifications; `/notifications on` enables them. These commands
save the local preference. The appearance picker also has an `n` toggle; use
`s` there to save it as the default. Reattaching does not notify for old turns.

**Ctrl-V** (or `/paste`) inserts local clipboard text or attaches a clipboard PNG,
never sends it. macOS uses `pbpaste` and AppleScript; Linux uses `wl-paste`,
`xclip`, or `xsel`. PNGs use the existing 2 MiB limit and server validation.
Clipboard access is bounded; an unavailable clipboard enables protected terminal
paste instead. `/image` remains available for PNGs from disk.

Bracketed terminal paste preserves newlines without sending. Before unframed
paste, enter `/paste safe`: Enter inserts a newline and application commands
are disabled. Ctrl-V exits that mode without sending.
In safe mode adjacent Enter/Ctrl-J events normalize CRLF to one newline.
Review the draft, then Enter to send. Unframed pasted Enter is indistinguishable
from typed Enter, so this mode must be enabled in advance. This fallback handles
text, not arbitrary terminal key escape sequences. Tabs remain tabs (displayed
at four-column stops), CRLF/CR become LF, and other C0/C1 controls are removed.
An insert over the 64 KiB draft limit is rejected as a whole.

Drafts stay editable while the session streams. **Enter** durably queues normal
follow-ups FIFO. **Ctrl-Q** (or `/queue`) opens the inbox; Delete cancels the
selected pending entry. **Ctrl-S** (or `/steer TEXT`) prioritizes an instruction
at the next safe boundary: an active provider request is interrupted, but an
already-started tool settles before steering and unstarted sibling calls are
suppressed. **Esc** stops and pauses queue draining without deleting pending
inputs. Resume with **r** in the inbox, `/resume-inputs`, or a new normal
submission. The inbox shows effective execution capabilities. Command ask rules
also require approval in trusted local sessions. Observers can inspect the
inbox but cannot mutate it.

Use **`/read-only`** to toggle the session's model tools, or `/read-only on|off`
to choose explicitly. The footer always labels read-only sessions. You can still
ask questions: `read`, `grep`, and `glob` remain available; `write`, `edit`, `bash`,
delegation and other mutating tools return permission refusals. The change takes
effect at the next tool call, including within the current turn. A running call
is not undone or stopped: **Esc stops the running one**. Turning it off restores
tools within the session's original capability grants, never expanding them.
This is distinct from attaching as an observer, which cannot control the session.
There is no default shortcut (D22); the action can be bound by the keymap feature.

Mode and transition positions are saved in the transcript's context metadata
and flight recording. Reopen, handoff, copies and newly created children retain
the mode; existing children are independent. Copies of a mode-bearing session
return a new session ID and leave the source intact. Copies made through a
handoff source use its delivery owner's current mode. If that owner is
unavailable, the copy starts read-only with a notice; `/read-only off` lifts it.
Trusted plugins must declare
`capabilities` and `mutating: false` to run in read-only mode; undeclared tools
are mutating. Plugin declarations are trusted code, not an OS sandbox.

Only authoritative acceptance clears an unchanged draft; edits made while
waiting survive. Pending submission IDs and image payloads are saved privately
under the TUI state directory. Reconnect queries the original ID rather than
resending; an unknown ID retains the draft for explicit submission. Accepted
inputs and immutable attachments persist with the session. Consumed means
delivered once, not that a tool effect succeeded. Unsettled durable executor
receipts block subsequent queued work, including after restart, until a durable
terminal exists. A live callback timeout does not remove this barrier. This does
not make external commands exactly-once. Legacy servers without `input_queue_v1`
retain the earlier non-queued ask behavior.

**Esc** closes the current panel or search; with no panel open, it interrupts a
running turn. Idle Esc returns to the prompt and never detaches. **Ctrl-C**
clears the prompt; press it twice consecutively to quit. If quitting can end
live sessions on an embedded server, a confirmation asks for Enter to quit or
Esc to cancel. On a long-lived server, quitting leaves sessions running.
`/clear` clears the prompt; `/quit` and `/detach` use the same quit confirmation.
Unsubmitted drafts live in this client window; only submissions awaiting
acceptance are saved after exit. Local history recalls up to 200 canonical
prompts that fit the editor limit; it does not change persisted history.

The picker and presentation actions also have slash commands: `/files`,
`/image`, `/attachments`, `/model`, `/effort`, `/thinking`, `/thinking-view`,
`/turns`, `/appearance`, `/help`, `/sessions` and `/queue`. `/paste` reads the
clipboard; `/paste safe` enters protected terminal paste, and Ctrl-V finishes
that mode without sending.

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
`?` on an empty prompt and `/help` list the current action bindings. Arrow and
page keys scroll help. All former F-key actions have slash commands: `/help`,
`/paste`, `/appearance`, `/thinking`, `/thinking-view`, `/turns`, `/model`,
`/files`, `/image`, `/attachments`, `/sessions`, and `/queue`. `/effort` is an
alias for `/model`. F-keys are unbound. Ctrl-K, Ctrl-D, and Ctrl-L are also
unbound; Ctrl-A selects the draft, Ctrl-J inserts a newline, Ctrl-S steers,
and Ctrl-G opens the external editor.

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

The `read` tool accepts optional positive integer `offset` and `limit` fields,
plus an optional boolean `line_numbers` field that defaults to `false`. For
example, `{"path":"lib/elara/tools.ex","offset":10,"limit":20}` returns up
to 20 lines starting at line 10. If either range field is supplied, omitted
values default to `offset: 1` and `limit: 200`; omitting both retains whole-file
reads. With `line_numbers: true`, each selected logical line is prefixed with
its original one-based number and `: `; without a range, the entire file is
numbered. Selected content preserves line endings and a final unterminated line.
An offset past EOF returns empty content. The existing tool-output budget still
applies; range reads do not impose a file-size or memory-allocation limit.
The read tool is version 3; remote controllers and workers must both support
that version. A version mismatch is rejected instead of silently ignoring range
or line-number options.

## Persistent delegated children

Use a long-lived `mix elara.server` for work that must continue after detaching
the TUI. `/delegate coding TASK` starts an independent persisted session on a
managed Git branch/worktree at the parent's committed HEAD.
New coding worktrees live under
`~/.elara-worktrees/<repo-name>-<short-hash>/<token>`, separate from protected
Elara state. Set `ELARA_WORKTREES_ROOT` in operator startup configuration to
choose another root, for example `export ELARA_WORKTREES_ROOT=/Volumes/Code/elara-worktrees`.
Restart an existing server after changing it. Records and receipts remain
under `~/.elara`; existing children use their recorded workspace location,
including the old location inside session storage. No worktree is relocated
or deleted automatically.
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
no invented aggregate subscription accounting. Ctrl-O remains ordinary workspace
session discovery. Observers can inspect/open but cannot delegate, integrate,
clean up or stop work.

Parent stop/detach and sibling failure do not stop children.
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
Integration is refused while the child's history contains any `indeterminate`
tool result, for example a command killed by a timeout or the output cap. Its
changes might be partial and could reach outside the worktree. A later
successful turn does not clear this. The worktree is preserved for manual
review. `/review-child CHILD_ID` exports an immutable evidence patch and shows
its SHA-256 digest plus every retained uncertain call occurrence. After
reviewing those exact bytes, `/ack-child CHILD_ID SHA256 JSON_STRING_ARRAY`
records a durable receipt; the JSON array must contain the exact call-ID
multiset, including duplicates and opaque whitespace. This does not reconcile,
replay or claim an effect outcome. Integration recaptures and applies the child
bytes, never the exported review file, and fails closed if the patch or retained
occurrences changed. Review and acknowledgement require the live original child
and are controller-only; neither action integrates or cleans up automatically.
`/cleanup-child CHILD_ID` is separate: it requires integration of the exact
current tree, no ignored files, and a clean child worktree (commit the child's
integrated changes first). It never uses forced removal. The child branch,
transcript and integration patches remain; a cleaned workspace cannot resume.

Metadata/workspaces live under `~/.elara/sessions/_threads/` (or the configured
Store root). Programmatic entry points are
`Elara.Threads.start_child(parent_id, assignment, coding: true)`, `list/1`,
`resume/2`, `review_child/2`, `acknowledge_child/4`, `integrate/2`, `cleanup/2`,
and `stop_subtree/1`. Generic
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
the ordinary transcript, tool inspector, Ctrl-Q queue, Ctrl-P model/effort and
reasoning views. Switching retains each thread's draft and local view state and
preserves control versus observation. An observer never gains control by
navigating.

Unread **UI notifications** are distinct from model delivery receipts: opening
or inspecting a listed thread acknowledges its notifications locally, not its
model inbox. Those acknowledgements survive reattachment and thread switching
within the TUI process; a new TUI process may show the notifications again.
Reading, listing, reattaching and resnapshotting never generate model turns.

Models can use `thread_send`, `thread_read`, `thread_status`, and `thread_wait`,
or `completion_wait` with `source: "thread"` and `thread_id`.
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

The TUI's `/job JOB_ID` opens its retained evidence in Inspection. A controller
can use `/ack-job-stopped JOB_ID` after confirming that the command and its
descendants have stopped. This releases held capacity for an indeterminate job;
it preserves the uncertain result and original completion, and never retries
the command. Known pending execution still rejects acknowledgment. Observers
can inspect but cannot acknowledge. Use a JSON string for an opaque ID with
exact whitespace, for example `/job " opaque id "`.

`completion_wait` also waits for an owned job with `source: "job"` and `job_id`.
`thread_wait` is an alias of its related-thread path. Both wait on the retained
inbox completion without model polling or an ordinary tool deadline. A live
model wait saves its ToolResult and consumes the matching input atomically, so
that report cannot trigger a second turn. An external API observer reads the
completion without consuming it. Results include `awaited`, `already_consumed`,
correlation, input receipt state and a bounded untrusted preview; original
evidence remains available. Automatically delivered reports are marked
`awaited=false` in provider context. New thread turns have distinct identities;
handoffs carry the same identity. Legacy bodies and agent provenance remain
unchanged. Cancelled input returns an error; previously failed processing
retains its receipt and error. Interrupt cancels waiting without cancelling a
job. Caller, target or transport loss retires subscriptions; VM restart never
replays uncertain tools.
Eight consecutive automatic agent/report turns exhaust a durable wake budget;
Ctrl-Q then `r`, `/resume-inputs`, or a new owner submission resets it. Empty sends
are rejected, report responses do not generate ancestor reports, pending
transport is limited to 64 entries per recipient, and delegation depth is
limited to three (in addition to four concurrently running children).

The additive `thread_communication_v1` extension exposes agent/report inbox
kinds. Older queue clients see only their supported ordinary/steer entries;
agent provenance remains explicit in transcript text. Saved agent provenance and
wake-budget headers require this build for resume. This is trusted local thread
communication, not hosted sharing or an OS sandbox.

### Automatic context handoff

Sessions check an estimated context budget before every model request. The
meter uses the last main-provider input plus output token count, then UTF-8
bytes ÷ 4 for newer messages. Without reported usage, it estimates the system,
history, tool schemas, and framing at bytes ÷ 4. Tool/submodel usage does not
reset the meter. Unreported images retain a 32K allowance per image because
their preprocessing cost is unknown; encoded image blobs are not counted as
text tokens.

The selected model's window is looked up before each request (128K fallback
when unknown). Warning starts at 80%; context recovery starts at 90%, leaving
one 10% headroom allocation rather than stacked output, handoff, tool, and
uncertainty reserves. The authoritative meter is exposed in the session
snapshot as `inbox.context`, including `estimate_tokens`, `limit`, `confidence`,
and `basis`. It is an **estimate**, not exact tokenizer occupancy, and is
independent of the 16 MiB protocol and attachment/snapshot admission limits.

Before handing off, Elara clears old tool-result bodies from model context,
oldest first, including results from the running turn. It protects the last
five results and at least the newest approximately 20K tokens of tool output
(UTF-8 bytes ÷ 4), whichever retains more. Results from the current provider
response that the model has not seen yet are never cleared. Configure these
positive limits with `ELARA_CONTEXT_KEEP_RESULTS` and
`ELARA_CONTEXT_KEEP_TOKENS`, the `:elara` application config keys
`:context_keep_results` and `:context_keep_tokens`, or session options with
the same names (session options take precedence). Children and successors
inherit the limits.

Each placeholder names the tool, original byte size, exact transcript entry,
and a `thread_read` call to page the original. Transcript views and stored
messages keep the full bodies, including error and unknown outcomes; reopening,
forking and cloning preserve the clearing metadata and retrieval paths.
Clearing drops the old usage anchor: the meter estimates the smaller request
at low confidence until fresh main-provider usage arrives. A child that copies
history from a cleared parent keeps the full evidence but drops inherited
assistant usage, then budgets and clears its own first request. The parent's
history and usage stay unchanged. Clearing facts
record entries and bytes freed for deterministic replay. The offline fixed-cutoff
census excludes clearing gates as unknown rather than pretending to simulate
clearing under a different cutoff.

Only if clearing cannot free enough space, Elara freezes the source at a safe
boundary and continues in a linked fresh session. Original messages and durable
attachments remain available through `thread_read`. The handoff is an
assistant-authored, extractive evidence index, not a claim that every obligation
has been summarized: it points to the
goal, recent owner decisions, tool/test outcomes, unresolved work, attachments,
queued inputs, and children. The successor is instructed to retrieve originals;
later owner corrections override earlier requests. Tool and child text do not
gain owner authority. Execution settings/capabilities transfer separately from
the index; current workspace instructions and skill discovery are reloaded.

The controlling TUI explicitly attaches the successor and retains the unsent
draft, attachments, layout, and theme. Observers see a link without gaining
control. A failed attach keeps the draft and offers `/sessions` for retry.
Paused inputs stay paused; explicit stop prevents automatic continuation. Queue
IDs and late child reports follow the current delivery owner without rewriting
historical parentage. Durable stages recover the same successor and logical
continuation after restart. A consumed continuation interrupted by VM loss is
reported failed and paused, not blindly replayed. This is **not** a generic
exactly-once model-request or external-effect guarantee.

Generation/validation failures before ownership transfers return the source to
local use, including after reopening; the failure notice and original evidence
are retained. After transfer, input sent to the source routes to its successor,
and the TUI shows `input routed to <session>`. Interrupting the source stops and
pauses the successor without taking back delivery ownership. Reopening the
source also reopens that successor. Fork and clone remain available from the
source's retained evidence; they start independent sessions, not new delivery
owners for the original chain.

For a context-bearing session (cleared results or a handoff), the public
`Elara.fork/2` and `Elara.clone_session/1` APIs return
`{:ok, copied_session_id, prompt, history}`.
Use the returned session ID to continue the copy. `prompt` is `nil` for a clone.
Ordinary sessions keep the existing three-element result and in-place history
switch. The chat commands switch to the copy automatically.

A fresh context that cannot fit is rejected; automatic chains are bounded to
eight handoffs. Reaching the cap reports a turn error, not a frozen session:
fork before an earlier turn to start a fresh chain, or select a model with a
larger window. Nonpersistent sessions cannot hand off. The legacy synchronous
`Elara.ask/2` call returns `:interrupted` when its source hands off; automatic
continuation is delivered through the successor's session/events, not that old
call. Saved handoff headers require this build for resume.

## Built-in tools

- `read` reads a file.
- `start_child` starts persistent delegated work as described above.
- `write` atomically writes a workspace-relative regular file and creates parent
  directories. It records durable controller intent and executor receipts before
  and after mutation.
- `edit` replaces exactly one occurrence of `old_text` with `new_text`, or every
  non-overlapping literal occurrence when `replace_all: true`.
- `bash` runs a local shell command with stdout and stderr merged. A supervised Rust
  stub runs each command in its own process group and kills the group on
  interruption, timeout, or the 128 MiB retained-output cap. A killed command, or one lost with
  the stub, reports an `indeterminate` outcome because it may have partially
  changed the workspace. Commands that exit on their own report success or
  their exit status.
- `output_read` pages or searches retained output by an opaque, session-owned
  handle. It accepts a line range or a literal pattern, never a path or regex.
- `grep` searches workspace file contents for a regular expression and returns
  `path:line:text` per match.
- `glob` lists workspace files whose path matches a glob pattern, one per line.

## Workspace search

`grep` and `glob` are read-only and rooted at the session working directory, so
basic navigation does not need `bash`. Both delegate to
[ripgrep](https://github.com/BurntSushi/ripgrep); a missing `rg` is a tool error
naming the install rather than a different built-in matcher, so the same call
cannot answer differently on two hosts. Both tools are always advertised, so the
roster does not vary with the host.

They honour `.gitignore` (whether or not the directory is a Git checkout) and
always skip `.git`, `.hg`, `.svn`, `_build`, `deps`, `node_modules`, and
`target`; those exclusions are applied last, so they override the requested
pattern. Ripgrep applies the requested glob with higher precedence than ignore
files, so a pattern naming an ignored file does match it; an ignored directory
stays pruned unless the pattern matches that directory's own path. Results are
sorted by path, so repeated calls agree. An optional `path` scopes the search to a
file or directory inside the workspace or an operator-approved extra root.
Both tools use the [file-tool fence](#file-tool-fence): explicit protected or
escaping scopes are refused, including resolved symlinks. Recursive searches
skip protected files before reading contents. Search results name resolved
targets, with absolute paths for files outside the cwd. Recursive traversal
does not follow directory symlinks; an explicit allowed alias works.

Elara first enumerates filenames with ripgrep, then authorizes each target
through the same policy as `read`. The filename list is bounded at 8 MiB;
exceeding it returns an error asking for a narrower path, never a partial list
presented as complete. Content searches use bounded batches with one shared
timeout and output byte budget. A permitted filename that is not valid UTF-8
also returns a narrower-path error, rather than crashing the command runner or
substituting a different filename. The fence is not an OS sandbox.

`grep` returns at most 100 matching lines and `glob` at most 200 paths, each
overridable up to 1000 with `limit`. Long lines are clipped and the session's
output byte cap still applies; a bounded result ends with one bracketed
truncation notice. `grep` also takes an optional `glob` filter and
`case_insensitive`. No match is reported as `no matches` or `no files`. When
ripgrep cannot complete a search, including an unusable pattern or an unreadable
file in scope, its diagnostic is returned as an error rather than presenting a
partial scan as complete. These tools never mutate, so an interrupted, timed-out
or lost search is an ordinary error, never `indeterminate`. Indexed and semantic
search are out of scope.

Any running mutating tool (`bash`, `write`, `edit`) that is interrupted, times
out or crashes before returning its own result is likewise `indeterminate`.
Calls that had not started when a turn stopped report an ordinary error.
When a session reopens after dying mid-turn, the one call that may have been
running is `indeterminate` whatever its tool, because today's tool
configuration cannot prove what that call did. The calls after it report an
ordinary error. Receipt-backed `write` recovery is described in
[docs/sessions.md](docs/sessions.md).

For example, `{"path":"config.exs","old_text":"old_name","new_text":"new_name","replace_all":true}`
replaces all exact occurrences in that file. Omitting `replace_all` or passing
`false` keeps the unique-match requirement. The flag must be a boolean and
`old_text` must be nonempty; invalid values, missing matches and ambiguous
single-match requests return errors without changing the file. Empty `new_text`
deletes matched text. Replacement is literal and nonrecursive, preserving
surrounding bytes and line endings. This is a whole-file read/write operation,
not an atomic edit or a concurrent-writer protection mechanism. Edit is tool
version 2; mismatched workers reject the call. Restart existing processes to
load the updated built-in tool.

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
The executor runs each callback in a linked worker while keeping one serial
ledger writer. If the callback worker stops while that writer survives, it
records an indeterminate terminal and never invokes the job again. Under R7,
startup records an indeterminate terminal for an orphaned attempt with an
incarnation only under exclusive writer and callback locks plus durable
VM/writer/callback identity proving the old owners are dead. A different live
VM refuses takeover, naming its OS PID, node and start time: stop it first.
No callback is replayed, and workspace bytes still
cannot prove causal completion.

Schema 3 migrates schema 1 and 2 ledgers in place. Legacy attempts retain
`attempt_incarnation: nil` and never auto-terminalize. A session blocked by such
an attempt stays idle and refuses a new turn for missing proof. Use `/clone` or
`/fork` to continue in a new session without changing the original receipt.
See [interrupted-write recovery](docs/sessions.md#recover-an-interrupted-write).

Each turn allows 100 model calls by default. Tools have a 10-minute default
timeout; the model may give `bash` a per-call `timeout_ms` up to a 60-minute
ceiling. A timed-out command is reported as unknown, with guidance to inspect
partial changes before rerunning with a longer timeout. Interrupt still cancels
a running command; raising the timeout does not prevent interruption.

Set `ELARA_MAX_ITERATIONS`, `ELARA_TOOL_TIMEOUT_MS`, and
`ELARA_MAX_TOOL_TIMEOUT_MS` to positive integers to override these limits.
Application config uses `:elara` keys `:max_iterations`, `:tool_timeout_ms`,
and `:max_tool_timeout_ms`; explicit session options win over environment, then
application config, then defaults. The default timeout must not exceed its
ceiling. Invalid settings fail session creation rather than silently falling
back. Children and handoff successors inherit the session's limits.

In the TUI, `/limits` shows the authoritative next-turn limits and their source
(`config` or `set this session`). Use `/limits calls 150` or
`/limits timeout 20m`; timeout accepts whole seconds, minutes or hours (`s`,
`m`, `h`). The aliases `max_iterations` and `tool_timeout_ms` accept integers.
Changes during a turn apply from the next turn, without changing any remaining
call or command in the running turn. The config ceiling cannot be raised from
the TUI. Session overrides survive detach/reattach and pass to children and
handoff successors, but reopening after a session/server restart restores
startup config. Help shows the same effective limits; observe mode can read
them but cannot change them.

Local shell output is retained in private session files, up to 128 MiB per
object. The model gets an envelope of at most 16 KiB, with about 6 KiB of head
and 10 KiB of tail, the total bytes and lines, and an `out_…` handle. Crossing
the preview budget does not kill the command. At the retained-output cap,
Elara stops and reaps the process group and reports an unknown result with
an explicit partial-output handle. Timeout and interruption also remain unknown.

`output_read` accepts `handle`, one-based line `offset` (default 1), and `limit`
(default 100, maximum 200). An optional `pattern` matches literal UTF-8 text,
up to 4096 bytes. Results stay within the preview budget and give the next line
offset. Long lines carry a clipping notice; a literal search can show a matching
snippet beyond the clipped prefix. Displayed text replaces invalid UTF-8, but
the retained file preserves the original bytes. Retention requires a preview
budget of at least 1024 bytes; smaller configured budgets refuse capture before
the command starts.

Handles cannot read another session's output. Forks, clones and history-copying
children inherit only the handles in their copied tool evidence. Handoff
successors inherit handles from trusted source history. Clearing old tool results
and rewinding do not delete retained evidence. Objects are immutable and never
evicted; session deletion does not yet remove them.

Retained `bash` and `output_read` run locally. Explicit remote overrides keep
the worker's older unretained, kill-at-cap behavior. Remote retained-output
transport is deferred to Phase 5.

Trusted tools reuse `Elara.Output.capture(ctx, {:content, kind, chunks})`, where
`kind` is `:ok`, `:error`, or `:indeterminate` and `chunks` is an enumerable of
binaries. Command capture uses `{:command, argv, opts}`. Both return an ordinary
tool outcome. `Elara.Output.read(ctx, handle, {:range, offset, limit})` and
`{:literal, pattern, offset, limit}` use the same retrieval path. Ownership
comes from the trusted execution context, never tool arguments.

Consecutive calls with identical tool names and arguments in one model response
are rejected as duplicates. An intervening call or a later model response can
repeat the same arguments, allowing read → edit → read and test → fix → test
workflows, as well as fresh observations of external state. The iteration limit
bounds repeated model requests; this guard is not a tool-result cache or an
exactly-once execution guarantee.

The project plugin adds `check_evidence` to inspect captured output/source and
`diagnose_check` to diagnose one captured failure with one additional model
request and validated references. These tools require the plugin; see
[captured check diagnosis](docs/check-diagnosis.md) for setup, limits,
cancellation and the Rust inspector.

## More user guides

- [Harness experiments](docs/harness-experiments.md): what we tried, what we
  learned, and which functionality the experiments added.
- [Supervised test jobs](docs/test-jobs.md): run a focused Mix test between model
  turns and receive completion through the inbox without polling.
- [Sessions and chat](docs/sessions.md): resume, branch, clone, and inspect why
  an event occurred.
- [Live plugins](docs/plugins.md): add trusted, stateful local tools and reload
  them without restarting a session.
- [Detached sessions and remote workers](docs/detached-and-remote.md): keep a
  session alive after a client disconnects and execute tools elsewhere.
- [Elixir API](docs/elixir-api.md): target another directory, subscribe to
  events, configure sessions, replay recordings, and coordinate child sessions.
- [Elara in Notion](https://app.notion.com/p/3f5700320c45817a9782f7e2e62bf2a1):
  the sole current planning and status source; [Roadmap](ROADMAP.md) links the
  Product Brief, Roadmap and Working Agreement. Linear's history is archived in
  [docs/archive/linear](docs/archive/linear/README.md).

## Develop

`bin/check` runs every check a change must pass before it is pushed, and stops
at the first failure:

The full suite creates hundreds of isolated workspaces. Each workspace keeps a
supervised effect executor, SQLite ledger and writer lock until the VM stops;
closing its session does not release that workspace's executor. `bin/check`
raises its own soft file-descriptor limit to at least 4096 and prints the limit.
It fails before running checks if the inherited hard limit prevents that raise.
This is a development-suite requirement, not a change to the daily launcher;
it also avoids macOS's lower default soft limit. To run `mix test` directly,
first use `ulimit -S -n 4096` in that shell.

```bash
mix compile --warnings-as-errors
mix format --check-formatted
(cd native/exec-stub && cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings && cargo test --locked)
(cd native/elara-tui && cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings && cargo test --locked)
mix test
```

The interactive TUI tests also require Python 3 and a Unix PTY. Tests use
`Elara.Provider.Scripted` and do not call external networks. One
crash-recovery test intentionally logs a `RuntimeError) boom` error; the final
test result determines whether the run passed.

Run Rust TUI tests from `native/elara-tui`, as above: its Cargo runner gives
each test executable a fresh TUI state directory and appearance file, overriding
developer settings, and removes them on exit (including test failures). This
isolates integration tests as well as unit tests from the real pending inbox.
Ordinary `cargo run` keeps the user's state. Cargo does not discover this local
runner when invoked from the repo root with only `--manifest-path`.

Tests that are not exercising discovery should supply a fixture `home` and
`skill_paths: []` when starting sessions, so local user skills cannot change
request size or trigger a context handoff. Large-history protocol fixtures use
an explicit `context_limit`; production context safeguards remain enabled.
Queued input consumption is not completion: await the assistant result when
asserting that the provider has finished.

The research lab is a separate Mix project in `lab/` that depends on this app
by path; the app does not ship it, and neither `mix test` nor `bin/check` runs
it. Run its checks with `cd lab && mix deps.get && mix test`;
[docs/lab](docs/lab/README.md) explains its experiments and `mix elara.lab`.
