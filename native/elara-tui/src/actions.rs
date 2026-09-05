use crossterm::event::{KeyCode, KeyEvent, KeyModifiers as M};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Action {
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
}
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
    let labels = [Action::Submit, Action::Help, Action::SafePaste].map(|action| {
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
    hints
        .chunks(3)
        .map(|chunk| ratatui::text::Line::from(chunk.join(" · ")))
        .collect()
}
