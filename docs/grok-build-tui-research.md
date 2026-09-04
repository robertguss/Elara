# Grok Build TUI: source reference for Elara

Research date: 2026-09-04. Scope: interaction contracts and implementation ideas for Elara's daily-driver TUI. This note does not change the roadmap or claim that Elara already supports these behaviors.

## Reference version and method

Inspected official `xai-org/grok-build` at Git commit **72a61251fcffb464bcc687aeb5a998e5a98ec0c9**, dated **2026-09-01**, subject “Synced from monorepo.” Its `SOURCE_REV` identifies monorepo revision **a549186d9d39311f2d3ee4208db62af8c65aa476**. The repository is periodically synchronized, so this source snapshot is not proof of the exact behavior in the user's installed 1.0.13 binary. [Pinned source revision][revision]

The reference was shallow-cloned into `/tmp/elara-grok-build-tui-research-20260904`, outside Elara, and indexed with codebase-memory-mcp. Graph search and snippets located implementation evidence; bounded file reads covered shipped guides and surrounding source. No Grok build, live credentialed session, or tests were run. A test source establishes intended coverage, not a passing result.

## Interaction findings

### Prompt editing and draft survival

The shipped guide specifies multiline input, character/word/row selection, normal selection replacement on typing or paste, history, and draft stashing. PageUp/PageDown can scroll the transcript while the prompt retains focus and its draft; active dropdowns claim those keys instead. Escape during a running turn normally cancels while preserving the draft. Ctrl+C has different clear-first behavior. [Keyboard contract][keys]

The dedicated `xai-ratatui-textarea` editor distinguishes grapheme, word, logical-line, and visual-row movement, with an explicit selection-collapse edge. That is a useful implementation boundary: screen cells, Unicode graphemes, and source offsets must not be treated as interchangeable. [Editor movement source][editor]

**Borrow:** draft-preserving navigation, real multiline editing, selection replacement, attachment-aware drafts. **Adapt:** keep Elara's cancel behavior discoverable and consistent; do not copy every context-dependent shortcut or stash feature merely for parity.

### Queue, steer, send-now, cancel

During work, Enter queues by default. A send-now action cancels the foreground turn and runs the selected message next; other queued messages and background agents/tasks remain. The queue can expose selected-row send-now. Grok also supports a different setting called `steer`, which injects queued material at a safe tool/model gap. Its docs therefore distinguish non-interruptive delivery from cancel-and-send. [Active-turn behavior][active]

The shell, rather than only the TUI, owns queue requests and delivery. `QueueInputRequest` carries content blocks and identity, `commit_queued_delivery` updates pending inputs and broadcasts queue changes, and `queue_input` reports whether the caller must cancel. [Queue source][queue]

**Borrow:** Elixir-owned queue, visible pending rows, deletion, explicit “Send now” action, preserved attachments. **Adapt:** use the user's meaning of “steer now” (interrupt and send) in Elara; avoid importing Grok's extra terminology ambiguity. Double-Enter promotion and editing queued messages are optional, not requirements. Specify behavior during tool cancellation and waiting on children before coding.

### Transcript, copy, and mouse

Grok separates entry selection from viewport scrolling, provides turn navigation, expandable blocks, raw Markdown, full-content viewing, and copy-content versus copy-metadata actions. Mouse selection, scroll, and focus are first-class. Manual folds can be pinned so streaming/finish events do not reset them; reading an expanded block can stop tail-following. [Keyboard and folding contract][keys]

Appearance settings include fold anchoring, follow indicators, sticky prompt headers, and independent scrollbar configuration. A scripted scenario drives a mouse selection through the TUI and checks actual OSC 52 clipboard output. The terminal guide distinguishes native clipboard, tmux, and OSC 52 routes rather than assuming every write reaches the user's clipboard. [Scroll behavior][appearance], [Copy test source][copy-test], [Terminal support][terminal]

**Borrow:** explicit follow state, stable anchors while streaming/folding/resizing, copy the underlying selected text, and a real clipboard integration test. **Adapt:** verify Ghostty and WezTerm directly with the user's intended shortcuts, rather than promising identical terminal-level Cmd behavior. Do not report a confirmed copy when only an unverified escape-sequence delivery occurred.

### File references and disk images

The `@` picker supports fuzzy file search, directories, line ranges, and an explicit hidden-file search convention. Its state lazily creates a background matcher and rejects stale result generations, preventing old query matches from flickering into the current list. [File reference guide][files], [Picker state][file-state]

Disk image paths can become image chips. The implementation parses dropped paths and preserves ordinary prose as plain text if the candidate path tokens fail to resolve. Its shared image model separates original encoded bytes, terminal-display bytes, MIME type, dimensions, and deferred viewer loading. [Disk-path parser][image-paths], [Image representation][images]

**Borrow:** attachment chips with remove/inspect actions, robust paths containing spaces, asynchronous lookup, stale-result protection, and real image payload delivery. **Adapt:** disk attachment is required; clipboard image capture is explicitly outside the user's initial scope. A terminal thumbnail is an optional presentation detail and must not determine whether the model receives the image.

### Model and effort controls

The guide offers a model picker plus `/model` and a separate `/effort` command, with effort applicable only to supporting models. [Model/effort guide][models]

**Borrow:** show the current model/effort near the composer and expose both through a searchable action. **Adapt:** populate valid combinations from Elara's ChatGPT provider capabilities. Do not copy Grok's model names or hard-code its effort list. Define whether changing a setting during work applies to the next request and show that truthfully.

### Thinking visibility

`ThinkingBlock` uses incremental Markdown and exposes collapsed, truncated, and expanded render modes. The source labels truncated as the default. Replay has distinct timing behavior so historical playback does not fabricate near-zero thinking duration. [Thinking source][thinking]

**Borrow:** a distinct inspectable content block and retained source text, with explicit visibility state. **Adapt:** Elara must deliberately differ: provider-exposed reasoning or summaries stay fully expanded after completion until the user hides them, and manual visibility survives streaming, layout switches, and resumption. Keep it readable rather than copying the very muted treatment. The provider determines what reasoning content exists; the UI must not imply access to hidden model reasoning.

### Themes and layout architecture

Grok's full TUI uses central semantic colors and runtime theme preview: movement previews, Enter applies/persists, Escape reverts. Theme slots cover background surfaces, text hierarchy, activity accents, borders, Markdown, selection, and diffs. Layout/spacing/block configuration is separate. Display application goes through `Theme::apply_kind`. [Theme guide][themes], [Theme application source][theme-source]

The inspected guide documents fullscreen/minimal modes and configurable spacing, not Elara's three proposed named layouts. This research does not establish a ready-made Ember/Observatory/Workbench equivalent. Minimal mode deliberately uses terminal-native colors and disables theme picking. [Theme guide][themes]

**Borrow:** semantic palette tokens, instant preview with cancel/revert, saved selection, and separate geometry from color. **Adapt:** implement three Elara layouts × four independent themes over one shared session/view state. Preserve draft/cursor, selection, expanded tools, thinking visibility, and a meaningful scroll anchor when switching. Narrow-terminal adaptations need explicit designs, not merely squashing three columns.

## Terminal-specific acceptance evidence to borrow

The reference documents that WezTerm's modified Enter handling needs `enable_kitty_keyboard = true`. The keyboard guide also treats Cmd+A specially in Ghostty and calls out host bindings that can consume keys before the TUI sees them. These are concrete reasons to test both actual terminals, including plain text paste, Unicode selection, multiline entry, send-now, click/fold, and clipboard copy. A settings toggle or alternate binding should keep essential actions reachable when the terminal intercepts a preferred chord. [Terminal support][terminal], [Keyboard contract][keys]

## Focused recommendation

Borrow interaction contracts and small, well-bounded implementation ideas before considering wholesale widget ports. Prioritize editor reliability, follow/selection stability, queue/cancel semantics, attachment fidelity, and visible thinking. Build the three layouts and four themes on those shared behaviors so each combination receives the same correctness fixes. Defer Grok's dashboards, broad terminal repair system, minimal renderer, voice, clipboard image capture, workflow automation, and exhaustive configuration surface unless an independent Elara requirement emerges.

For code reuse, the repository identifies first-party source as Apache-2.0 and retains separate licenses for third-party code. The license's redistribution section requires license inclusion, notices for changed files, and retention of applicable attribution/NOTICE material. `THIRD-PARTY-NOTICES` explicitly includes bundled themes and source ports; copying a theme or port requires tracing its own provenance rather than assuming every file is solely first-party Apache code. Record source revision and adapted files when importing. This research copied no product implementation. [License][license], [Repository license overview][license-readme], [Third-party notices][notices]

[revision]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/SOURCE_REV
[keys]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-pager/docs/user-guide/03-keyboard-shortcuts.md
[active]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-pager/docs/user-guide/03-keyboard-shortcuts.md#L279-L304
[editor]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-ratatui-textarea/src/editor.rs#L1-L91
[queue]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-shell/src/session/acp_session_impl/prompt_queue.rs#L20-L116
[appearance]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-pager/docs/user-guide/06-theming.md#L160-L210
[copy-test]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-pager/tests/scenarios/copy_selection.yaml
[terminal]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-pager/docs/user-guide/21-terminal-support.md
[files]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-pager/docs/user-guide/01-getting-started.md#L93-L108
[file-state]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-pager/src/views/file_search/state.rs#L54-L86
[image-paths]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-pager-render/src/prompt_images.rs#L1103-L1140
[images]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-pager-render/src/prompt_images.rs#L19-L81
[models]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-pager/docs/user-guide/04-slash-commands.md#L100-L116
[thinking]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-pager/src/scrollback/blocks/thinking.rs#L66-L148
[themes]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-pager/docs/user-guide/06-theming.md
[theme-source]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/crates/codegen/xai-grok-pager/src/app/dispatch/settings/setters.rs#L1258-L1265
[license]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/LICENSE#L90-L125
[license-readme]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/README.md#license
[notices]: https://github.com/xai-org/grok-build/blob/72a61251fcffb464bcc687aeb5a998e5a98ec0c9/THIRD-PARTY-NOTICES
