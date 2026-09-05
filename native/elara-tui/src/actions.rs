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
    SafePaste,
    Submit,
    Newline,
    Interrupt,
    Escape,
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
        "cleanup-child",
        "CHILD_ID: remove integrated workspace",
        true,
    ),
    (
        "stop-subtree",
        "interrupt this session and descendants",
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
    ("reload", "reload this session", true),
    ("why", "inspect latest event", false),
    ("interrupt", "stop current turn", true),
    ("detach", "leave the session", false),
    ("help", "show all controls", false),
    ("appearance", "choose layout/theme", false),
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
    binding(KeyCode::F(12), M::NONE, false, Action::Queue, "F12 queue"),
    binding(
        KeyCode::Char('s'),
        M::CONTROL,
        false,
        Action::Steer,
        "Ctrl-S steer",
    ),
    binding(
        KeyCode::F(11),
        M::NONE,
        false,
        Action::Sessions,
        "F11 sessions",
    ),
    binding(KeyCode::F(8), M::NONE, false, Action::Files, "F8 @files"),
    binding(KeyCode::F(9), M::NONE, false, Action::Image, "F9 image"),
    binding(
        KeyCode::F(10),
        M::NONE,
        false,
        Action::Attachments,
        "F10 attachments/remove",
    ),
    binding(
        KeyCode::F(7),
        M::NONE,
        false,
        Action::ProviderSettings,
        "F7 model/effort",
    ),
    binding(
        KeyCode::F(3),
        M::NONE,
        false,
        Action::Appearance,
        "F3 appearance",
    ),
    binding(
        KeyCode::F(4),
        M::NONE,
        false,
        Action::Thinking,
        "F4 thinking hide/show",
    ),
    binding(
        KeyCode::F(5),
        M::NONE,
        false,
        Action::ThinkingView,
        "F5 thinking view",
    ),
    binding(KeyCode::F(6), M::NONE, false, Action::Turns, "F6 turns"),
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
    binding(KeyCode::F(1), M::NONE, false, Action::Help, "F1 help"),
    binding(
        KeyCode::F(2),
        M::NONE,
        false,
        Action::SafePaste,
        "F2 safe paste",
    ),
    binding(
        KeyCode::Esc,
        M::NONE,
        false,
        Action::Escape,
        "Esc back/detach",
    ),
    binding(
        KeyCode::Char('c'),
        M::CONTROL,
        false,
        Action::Escape,
        "Ctrl-C detach",
    ),
    binding(
        KeyCode::Char('x'),
        M::CONTROL,
        false,
        Action::Interrupt,
        "Ctrl-X interrupt",
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
    let labels = [
        Action::Submit,
        Action::Help,
        Action::SafePaste,
        Action::Sessions,
    ]
    .map(|action| {
        BINDINGS
            .iter()
            .find(|b| b.action == action)
            .expect("registered action")
            .hint
    });
    format!(" ask · {} ", labels.join(" · "))
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
