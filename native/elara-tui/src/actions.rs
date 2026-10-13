use crossterm::event::{KeyCode, KeyEvent, KeyModifiers as M};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Action {
    Appearance,
    Files,
    Image,
    Attachments,
    ProviderSettings,
    Thinking,
    ThinkingView,
    Turns,
    Focus,
    ToggleTool,
    ToolViewer,
    Up,
    Down,
    PageUp,
    PageDown,
    Home,
    Tail,
    PreviousTurn,
    NextTurn,
    Search,
    NextMatch,
    PreviousMatch,
    Copy,
    CopyEntry,
    Help,
    Paste,
    ExternalEditor,
    Submit,
    Newline,
    Interrupt,
    Escape,
    ClearOrQuit,
    Sessions,
    Queue,
    Steer,
}
pub(crate) const SLASH_ACTIONS: &[(&str, &str, bool)] = &[
    ("delegate", "coding|research TASK: persistent child", true),
    (
        "delegate-fork",
        "coding|research TASK: include history",
        true,
    ),
    ("children", "inspect/open/resume children (limit 4)", false),
    ("threads", "parent/children and unread reports", false),
    ("return", "open parent without changing control mode", false),
    ("open", "THREAD_ID: open known thread", false),
    (
        "integrate",
        "CHILD_ID: apply result to clean parent index",
        true,
    ),
    (
        "review-child",
        "CHILD_ID: export exact uncertain patch evidence",
        true,
    ),
    (
        "ack-child",
        "CHILD_ID SHA256 JSON_STRING_ARRAY: acknowledge evidence",
        true,
    ),
    (
        "cleanup-child",
        "CHILD_ID: remove integrated workspace",
        true,
    ),
    (
        "stop-subtree",
        "interrupt this session and descendants",
        true,
    ),
    ("job", "JOB_ID: inspect retained job evidence", false),
    (
        "ack-job-stopped",
        "JOB_ID: confirm command and descendants stopped; release capacity",
        true,
    ),
    ("queue", "inspect/cancel pending input", false),
    ("steer", "prioritize this draft at a safe boundary", true),
    ("resume-inputs", "resume a paused queue", true),
    ("sessions", "find or switch session", false),
    ("new", "create a session", true),
    ("name", "name current session", true),
    ("tree", "choose a branch point", false),
    ("fork", "choose and fork a branch point", true),
    ("clone", "clone current path", true),
    ("reload", "refresh the session snapshot", true),
    (
        "plugins",
        "reload trusted local plugins: /plugins reload",
        true,
    ),
    ("why", "inspect latest event", false),
    ("interrupt", "stop current turn", true),
    ("detach", "leave the session", false),
    ("quit", "quit; confirm if live sessions will end", false),
    ("clear", "clear the prompt", false),
    ("help", "show all controls", false),
    ("editor", "edit the prompt in $VISUAL or $EDITOR", false),
    (
        "notifications",
        "on|off: save terminal notification preference",
        false,
    ),
    (
        "paste",
        "paste text/image; safe: protected terminal paste",
        false,
    ),
    ("files", "choose file references", true),
    ("image", "choose an image", true),
    ("attachments", "inspect/remove draft selections", true),
    ("appearance", "choose layout/theme", false),
    ("thinking", "hide/show thinking", false),
    ("thinking-view", "open full thinking view", false),
    ("turns", "navigate user turns", false),
    ("diagnostics", "toggle the diagnostic status row", false),
    ("model", "choose model/effort", true),
    ("effort", "choose model/effort", true),
];
struct Binding {
    key: KeyCode,
    modifiers: M,
    transcript: bool,
    action: Action,
    hint: &'static str,
}
const fn binding(
    key: KeyCode,
    modifiers: M,
    transcript: bool,
    action: Action,
    hint: &'static str,
) -> Binding {
    Binding {
        key,
        modifiers,
        transcript,
        action,
        hint,
    }
}
static BINDINGS: &[Binding] = &[
    binding(
        KeyCode::Char('q'),
        M::CONTROL,
        false,
        Action::Queue,
        "Ctrl-Q queue",
    ),
    binding(
        KeyCode::Char('s'),
        M::CONTROL,
        false,
        Action::Steer,
        "Ctrl-S steer",
    ),
    binding(
        KeyCode::Char('o'),
        M::CONTROL,
        false,
        Action::Sessions,
        "Ctrl-O sessions",
    ),
    binding(
        KeyCode::Char('f'),
        M::CONTROL,
        false,
        Action::Files,
        "Ctrl-F @files",
    ),
    binding(
        KeyCode::Char('p'),
        M::CONTROL,
        false,
        Action::ProviderSettings,
        "Ctrl-P model/effort",
    ),
    binding(
        KeyCode::Char('t'),
        M::CONTROL,
        false,
        Action::Thinking,
        "Ctrl-T thinking hide/show",
    ),
    binding(
        KeyCode::Char('r'),
        M::CONTROL,
        false,
        Action::Turns,
        "Ctrl-R turns",
    ),
    binding(
        KeyCode::Char(' '),
        M::NONE,
        true,
        Action::ToggleTool,
        "Space fold tool",
    ),
    binding(
        KeyCode::Char('f'),
        M::NONE,
        true,
        Action::ToolViewer,
        "f tool viewer",
    ),
    binding(
        KeyCode::Tab,
        M::NONE,
        false,
        Action::Focus,
        "Tab prompt/transcript",
    ),
    binding(
        KeyCode::Char('?'),
        M::NONE,
        false,
        Action::Help,
        "? empty prompt: help",
    ),
    binding(
        KeyCode::Char('g'),
        M::CONTROL,
        false,
        Action::ExternalEditor,
        "Ctrl-G external editor",
    ),
    binding(
        KeyCode::Char('v'),
        M::CONTROL,
        false,
        Action::Paste,
        "Ctrl-V paste text/image",
    ),
    binding(
        KeyCode::Esc,
        M::NONE,
        false,
        Action::Escape,
        "Esc close/interrupt",
    ),
    binding(
        KeyCode::Char('c'),
        M::CONTROL,
        false,
        Action::ClearOrQuit,
        "Ctrl-C clear; twice quit",
    ),
    binding(KeyCode::Enter, M::NONE, false, Action::Submit, "Enter send"),
    binding(
        KeyCode::Char('j'),
        M::CONTROL,
        false,
        Action::Newline,
        "Ctrl-J newline",
    ),
    binding(
        KeyCode::Enter,
        M::ALT,
        false,
        Action::Newline,
        "Alt-Enter newline if mapped",
    ),
    binding(
        KeyCode::Enter,
        M::SHIFT,
        false,
        Action::Newline,
        "Shift-Enter newline with enhanced keys",
    ),
    binding(KeyCode::Up, M::NONE, true, Action::Up, "↑/↓ line"),
    binding(KeyCode::Down, M::NONE, true, Action::Down, ""),
    binding(
        KeyCode::PageUp,
        M::NONE,
        true,
        Action::PageUp,
        "PgUp/PgDn page",
    ),
    binding(KeyCode::PageDown, M::NONE, true, Action::PageDown, ""),
    binding(KeyCode::Home, M::NONE, true, Action::Home, "Home top"),
    binding(KeyCode::End, M::NONE, true, Action::Tail, "End follow tail"),
    binding(
        KeyCode::Up,
        M::ALT,
        true,
        Action::PreviousTurn,
        "Alt-↑/↓ user turn",
    ),
    binding(KeyCode::Down, M::ALT, true, Action::NextTurn, ""),
    binding(
        KeyCode::Char('/'),
        M::NONE,
        true,
        Action::Search,
        "/ search",
    ),
    binding(
        KeyCode::Char('n'),
        M::NONE,
        true,
        Action::NextMatch,
        "n/N next/previous match",
    ),
    binding(
        KeyCode::Char('N'),
        M::SHIFT,
        true,
        Action::PreviousMatch,
        "",
    ),
    binding(KeyCode::Char('N'), M::NONE, true, Action::PreviousMatch, ""),
    binding(
        KeyCode::Char('c'),
        M::NONE,
        true,
        Action::Copy,
        "c copy selection",
    ),
    binding(
        KeyCode::Char('y'),
        M::NONE,
        true,
        Action::CopyEntry,
        "y copy entry",
    ),
];
pub(crate) const SLASH_ONLY: &[(Action, &str)] = &[
    (Action::Appearance, "appearance"),
    (Action::Attachments, "attachments"),
    (Action::ThinkingView, "thinking-view"),
    (Action::Image, "image"),
    (Action::Interrupt, "interrupt"),
];
pub(crate) fn lookup(key: KeyEvent, transcript: bool) -> Option<Action> {
    BINDINGS
        .iter()
        .find(|b| {
            b.key == key.code && b.modifiers == key.modifiers && (!b.transcript || transcript)
        })
        .map(|b| b.action)
}
pub(crate) fn hints(transcript: bool) -> String {
    BINDINGS
        .iter()
        .filter(|b| b.transcript == transcript && !b.hint.is_empty())
        .map(|b| b.hint)
        .collect::<Vec<_>>()
        .join(" · ")
}
pub(crate) fn prompt_title() -> String {
    let labels = [Action::Submit, Action::Paste, Action::Sessions].map(|action| {
        BINDINGS
            .iter()
            .find(|b| b.action == action)
            .expect("registered action")
            .hint
    });
    format!(" ask · {} · ? help ", labels.join(" · "))
}
pub(crate) fn help() -> Vec<ratatui::text::Line<'static>> {
    let hints = BINDINGS
        .iter()
        .filter(|b| !b.hint.is_empty())
        .map(|b| b.hint)
        .collect::<Vec<_>>();
    let mut lines: Vec<_> = hints
        .chunks(3)
        .map(|chunk| ratatui::text::Line::from(chunk.join(" · ")))
        .collect();
    lines.push(ratatui::text::Line::from(format!(
        "Slash-only: {}",
        SLASH_ONLY
            .iter()
            .map(|(_, name)| format!("/{name}"))
            .collect::<Vec<_>>()
            .join(" · ")
    )));
    lines.push(ratatui::text::Line::from("Slash actions:"));
    lines.extend(SLASH_ACTIONS.chunks(3).map(|chunk| {
        ratatui::text::Line::from(
            chunk
                .iter()
                .map(|(name, description, control)| {
                    format!(
                        "/{name} {description}{}",
                        if *control { " [control]" } else { "" }
                    )
                })
                .collect::<Vec<_>>()
                .join(" · "),
        )
    }));
    lines
}
