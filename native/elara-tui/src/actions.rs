use crossterm::event::{KeyCode, KeyEvent, KeyModifiers as M};
use std::{fs, path::Path};

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
    ReadOnly,
    Approve,
    Undo,
    SelectAll,
}
impl Action {
    fn name(self) -> &'static str {
        match self {
            Self::Appearance => "appearance",
            Self::Files => "files",
            Self::Image => "image",
            Self::Attachments => "attachments",
            Self::ProviderSettings => "provider_settings",
            Self::Thinking => "thinking",
            Self::ThinkingView => "thinking_view",
            Self::Turns => "turns",
            Self::Focus => "focus",
            Self::ToggleTool => "toggle_tool",
            Self::ToolViewer => "tool_viewer",
            Self::Up => "up",
            Self::Down => "down",
            Self::PageUp => "page_up",
            Self::PageDown => "page_down",
            Self::Home => "home",
            Self::Tail => "tail",
            Self::PreviousTurn => "previous_turn",
            Self::NextTurn => "next_turn",
            Self::Search => "search",
            Self::NextMatch => "next_match",
            Self::PreviousMatch => "previous_match",
            Self::Copy => "copy",
            Self::CopyEntry => "copy_entry",
            Self::Help => "help",
            Self::Paste => "paste",
            Self::ExternalEditor => "external_editor",
            Self::Submit => "submit",
            Self::Newline => "newline",
            Self::Interrupt => "interrupt",
            Self::Escape => "escape",
            Self::ClearOrQuit => "clear_or_quit",
            Self::Sessions => "sessions",
            Self::Queue => "queue",
            Self::Steer => "steer",
            Self::ReadOnly => "read_only",
            Self::Approve => "approve",
            Self::Undo => "undo",
            Self::SelectAll => "select_all",
        }
    }
}
pub(crate) const SLASH_ACTIONS: &[(&str, &str, bool)] = &[
    (
        "approve",
        "[ID]: approve the exact pending call or rule bytes",
        true,
    ),
    (
        "read-only",
        "on|off: deny mutations from the next tool call",
        true,
    ),
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
    (
        "diff",
        "latest turn; /diff session: session net changes",
        false,
    ),
    (
        "undo",
        "[TURN_ID]: confirm restoring a closed turn's files",
        true,
    ),
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
#[derive(Clone, Debug)]
struct Binding {
    key: KeyCode,
    modifiers: M,
    transcript: bool,
    action: Action,
}
const fn binding(key: KeyCode, modifiers: M, transcript: bool, action: Action) -> Binding {
    Binding {
        key,
        modifiers,
        transcript,
        action,
    }
}
static BINDINGS: &[Binding] = &[
    binding(KeyCode::Char('a'), M::CONTROL, false, Action::SelectAll),
    binding(KeyCode::Char('q'), M::CONTROL, false, Action::Queue),
    binding(KeyCode::Char('s'), M::CONTROL, false, Action::Steer),
    binding(KeyCode::Char('o'), M::CONTROL, false, Action::Sessions),
    binding(KeyCode::Char('f'), M::CONTROL, false, Action::Files),
    binding(
        KeyCode::Char('p'),
        M::CONTROL,
        false,
        Action::ProviderSettings,
    ),
    binding(KeyCode::Char('t'), M::CONTROL, false, Action::Thinking),
    binding(KeyCode::Char('r'), M::CONTROL, false, Action::Turns),
    binding(KeyCode::Char(' '), M::NONE, true, Action::ToggleTool),
    binding(KeyCode::Char('f'), M::NONE, true, Action::ToolViewer),
    binding(KeyCode::Tab, M::NONE, false, Action::Focus),
    binding(KeyCode::Char('?'), M::NONE, false, Action::Help),
    binding(
        KeyCode::Char('g'),
        M::CONTROL,
        false,
        Action::ExternalEditor,
    ),
    binding(KeyCode::Char('v'), M::CONTROL, false, Action::Paste),
    binding(KeyCode::Esc, M::NONE, false, Action::Escape),
    binding(KeyCode::Char('c'), M::CONTROL, false, Action::ClearOrQuit),
    binding(KeyCode::Enter, M::NONE, false, Action::Submit),
    binding(KeyCode::Char('j'), M::CONTROL, false, Action::Newline),
    binding(KeyCode::Enter, M::ALT, false, Action::Newline),
    binding(KeyCode::Enter, M::SHIFT, false, Action::Newline),
    binding(KeyCode::Up, M::NONE, true, Action::Up),
    binding(KeyCode::Down, M::NONE, true, Action::Down),
    binding(KeyCode::PageUp, M::NONE, true, Action::PageUp),
    binding(KeyCode::PageDown, M::NONE, true, Action::PageDown),
    binding(KeyCode::Home, M::NONE, true, Action::Home),
    binding(KeyCode::End, M::NONE, true, Action::Tail),
    binding(KeyCode::Up, M::ALT, true, Action::PreviousTurn),
    binding(KeyCode::Down, M::ALT, true, Action::NextTurn),
    binding(KeyCode::Char('/'), M::NONE, true, Action::Search),
    binding(KeyCode::Char('n'), M::NONE, true, Action::NextMatch),
    binding(KeyCode::Char('N'), M::SHIFT, true, Action::PreviousMatch),
    binding(KeyCode::Char('N'), M::NONE, true, Action::PreviousMatch),
    binding(KeyCode::Char('c'), M::NONE, true, Action::Copy),
    binding(KeyCode::Char('y'), M::NONE, true, Action::CopyEntry),
];
pub(crate) const SLASH_ONLY: &[(Action, &str)] = &[
    (Action::ReadOnly, "read-only"),
    (Action::Undo, "undo"),
    (Action::Approve, "approve"),
    (Action::Appearance, "appearance"),
    (Action::Attachments, "attachments"),
    (Action::ThinkingView, "thinking-view"),
    (Action::Image, "image"),
    (Action::Interrupt, "interrupt"),
];
#[derive(Clone, Debug)]
pub(crate) struct Keymap {
    bindings: Vec<Binding>,
    pub(crate) errors: Vec<String>,
}
impl Default for Keymap {
    fn default() -> Self {
        Self {
            bindings: BINDINGS.to_vec(),
            errors: Vec::new(),
        }
    }
}
impl Keymap {
    pub(crate) fn load(path: &Path) -> Self {
        let mut map = Self::default();
        match fs::read_to_string(path) {
            Ok(text) => map.configure(&text),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => map.errors.push(format!("cannot read keymap: {error}")),
        }
        map
    }
    fn configure(&mut self, text: &str) {
        let parsed = serde_json::from_str::<serde_json::Value>(text);
        let object = match &parsed {
            Ok(serde_json::Value::Object(object)) => object,
            _ => {
                self.errors
                    .push("keymap must be a JSON object; defaults retained".into());
                return;
            }
        };
        for (name, value) in object {
            let Some(action) = registered().find(|action| action.name() == name) else {
                self.errors
                    .push(format!("unknown action {name:?}; ignored"));
                continue;
            };
            let Some(key) = value.as_str().and_then(parse_key) else {
                self.errors
                    .push(format!("{name}: invalid key; default retained"));
                continue;
            };
            if fixed(key)
                && !BINDINGS.iter().any(|b| {
                    b.action == action && b.key == key.code && b.modifiers == key.modifiers
                })
            {
                self.errors.push(format!(
                    "{name}: {} is a fixed control; default retained",
                    key_label(key)
                ));
                continue;
            }
            // Defaults remain reserved even when their action is rebound, so
            // a bad entry cannot steal a fallback or depend on file order.
            if BINDINGS
                .iter()
                .chain(&self.bindings)
                .any(|b| b.action != action && b.key == key.code && b.modifiers == key.modifiers)
                || object.iter().any(|(other, value)| {
                    other != name
                        && registered().any(|a| a.name() == other)
                        && value
                            .as_str()
                            .and_then(parse_key)
                            .is_some_and(|other| other == key)
                })
            {
                self.errors.push(format!(
                    "{name}: {} collides with another action; default retained",
                    key_label(key)
                ));
                continue;
            }
            let transcript = BINDINGS
                .iter()
                .find(|b| b.action == action)
                .is_some_and(|b| b.transcript);
            self.bindings.retain(|b| b.action != action);
            self.bindings
                .push(binding(key.code, key.modifiers, transcript, action));
        }
    }
    pub(crate) fn lookup(&self, key: KeyEvent, transcript: bool) -> Option<Action> {
        self.bindings
            .iter()
            .find(|b| {
                b.key == key.code && b.modifiers == key.modifiers && (!b.transcript || transcript)
            })
            .map(|b| b.action)
    }
    pub(crate) fn keys(&self, action: Action) -> String {
        let keys = self
            .bindings
            .iter()
            .filter(|b| b.action == action)
            .map(|b| key_label(KeyEvent::new(b.key, b.modifiers)))
            .collect::<Vec<_>>();
        if keys.is_empty() {
            SLASH_ONLY
                .iter()
                .find(|(a, _)| *a == action)
                .map_or_else(|| "unbound".into(), |(_, name)| format!("/{name}"))
        } else {
            keys.join("/")
        }
    }
    pub(crate) fn first_key(&self, action: Action) -> String {
        self.bindings
            .iter()
            .find(|b| b.action == action)
            .map_or_else(
                || self.keys(action),
                |b| key_label(KeyEvent::new(b.key, b.modifiers)),
            )
    }
    pub(crate) fn hints(&self, transcript: bool) -> String {
        registered()
            .filter(|action| {
                self.bindings
                    .iter()
                    .any(|b| b.action == *action && b.transcript == transcript)
            })
            .map(|action| format!("{} {}", self.keys(action), action.name().replace('_', " ")))
            .collect::<Vec<_>>()
            .join(" · ")
    }
    pub(crate) fn prompt_title(&self) -> String {
        format!(
            " ask · {} send · {} paste text/image · {} sessions · {} help ",
            self.keys(Action::Submit),
            self.keys(Action::Paste),
            self.keys(Action::Sessions),
            self.keys(Action::Help)
        )
    }
    pub(crate) fn help(&self) -> Vec<ratatui::text::Line<'static>> {
        let hints: Vec<_> = registered()
            .map(|action| {
                let scope = if BINDINGS.iter().any(|b| b.action == action && b.transcript) {
                    " [T]"
                } else {
                    ""
                };
                format!(
                    "{} {}{scope}",
                    self.keys(action),
                    action.name().replace('_', " ")
                )
            })
            .collect();
        let mut lines: Vec<_> = hints
            .chunks(3)
            .map(|chunk| ratatui::text::Line::from(chunk.join(" · ")))
            .collect();
        lines.push(ratatui::text::Line::from(
            "[T] = transcript only; other actions keep their existing scope.",
        ));
        lines.push(ratatui::text::Line::from(
            "Fixed: panel Enter/Esc/Tab/arrows, PgUp/PgDn, Home/End, panel letters; inline @files.",
        ));
        lines.push(ratatui::text::Line::from("Fixed editing: arrows/Shift selection, Ctrl/Alt words/delete, Home/End, Alt-Up/Down history."));
        lines.extend(
            self.errors
                .iter()
                .map(|error| ratatui::text::Line::from(format!("Keymap: {error}"))),
        );
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
}
fn registered() -> impl Iterator<Item = Action> {
    let mut actions = Vec::new();
    for action in BINDINGS
        .iter()
        .map(|b| b.action)
        .chain(SLASH_ONLY.iter().map(|(a, _)| *a))
    {
        if !actions.contains(&action) {
            actions.push(action);
        }
    }
    actions.into_iter()
}
fn parse_key(text: &str) -> Option<KeyEvent> {
    let mut parts = text.split('+').peekable();
    let mut modifiers = M::NONE;
    while let Some(part) = parts.next() {
        if parts.peek().is_some() {
            let modifier = match part.to_ascii_lowercase().as_str() {
                "ctrl" => M::CONTROL,
                "alt" => M::ALT,
                "shift" => M::SHIFT,
                _ => return None,
            };
            if modifiers.contains(modifier) {
                return None;
            }
            modifiers |= modifier;
            continue;
        }
        let code = match part.to_ascii_lowercase().as_str() {
            "enter" => KeyCode::Enter,
            "esc" => KeyCode::Esc,
            "tab" if modifiers.contains(M::SHIFT) => KeyCode::BackTab,
            "tab" => KeyCode::Tab,
            "space" => KeyCode::Char(' '),
            "up" => KeyCode::Up,
            "down" => KeyCode::Down,
            "left" => KeyCode::Left,
            "right" => KeyCode::Right,
            "home" => KeyCode::Home,
            "end" => KeyCode::End,
            "pageup" => KeyCode::PageUp,
            "pagedown" => KeyCode::PageDown,
            "backspace" => KeyCode::Backspace,
            "delete" => KeyCode::Delete,
            key if key.starts_with('f') && key.len() > 1 => {
                let n = key[1..].parse::<u8>().ok()?;
                if !(1..=24).contains(&n) {
                    return None;
                }
                KeyCode::F(n)
            }
            _ => {
                let mut chars = part.chars();
                let c = chars.next()?;
                if chars.next().is_some() || c.is_control() {
                    return None;
                }
                KeyCode::Char(if modifiers.contains(M::SHIFT) {
                    c.to_ascii_uppercase()
                } else if modifiers.intersects(M::CONTROL | M::ALT) {
                    c.to_ascii_lowercase()
                } else {
                    c
                })
            }
        };
        return Some(KeyEvent::new(code, modifiers));
    }
    None
}
fn fixed(key: KeyEvent) -> bool {
    if key.modifiers == M::CONTROL && matches!(key.code, KeyCode::Char('h' | 'i' | 'm' | '[')) {
        return true;
    }
    match key.code {
        KeyCode::Left
        | KeyCode::Right
        | KeyCode::Up
        | KeyCode::Down
        | KeyCode::Home
        | KeyCode::End
        | KeyCode::PageUp
        | KeyCode::PageDown
        | KeyCode::Backspace
        | KeyCode::Delete
        | KeyCode::BackTab => true,
        KeyCode::Enter | KeyCode::Esc | KeyCode::Tab => true,
        KeyCode::Char('@') => !key.modifiers.intersects(M::CONTROL | M::ALT),
        KeyCode::Char('l' | 't' | 'd' | 'n' | 's' | 'r') => key.modifiers.is_empty(),
        _ => false,
    }
}
fn key_label(key: KeyEvent) -> String {
    let mut label = String::new();
    for (modifier, prefix) in [
        (M::CONTROL, "Ctrl-"),
        (M::ALT, "Alt-"),
        (M::SHIFT, "Shift-"),
    ] {
        if key.modifiers.contains(modifier) {
            label.push_str(prefix);
        }
    }
    label.push_str(&match key.code {
        KeyCode::Char(' ') => "Space".into(),
        KeyCode::Char(c) => {
            if key.modifiers.is_empty() {
                c.to_string()
            } else {
                c.to_ascii_uppercase().to_string()
            }
        }
        KeyCode::Enter => "Enter".into(),
        KeyCode::Esc => "Esc".into(),
        KeyCode::Tab => "Tab".into(),
        KeyCode::Up => "↑".into(),
        KeyCode::Down => "↓".into(),
        KeyCode::Left => "←".into(),
        KeyCode::Right => "→".into(),
        KeyCode::PageUp => "PgUp".into(),
        KeyCode::PageDown => "PgDn".into(),
        KeyCode::Home => "Home".into(),
        KeyCode::End => "End".into(),
        KeyCode::F(n) => format!("F{n}"),
        other => format!("{other:?}"),
    });
    label
}
