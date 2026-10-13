use crate::{InputAction, Model, appearance::slot};
use crossterm::event::{Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::{
    layout::Rect,
    style::Style,
    text::{Line, Span},
    widgets::{Block, Borders, Clear, Paragraph, Wrap},
};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

#[derive(Clone, Debug)]
pub(crate) struct Panel {
    scope: &'static str,
    text: String,
    scroll: u16,
    pending: bool,
    requested: Instant,
    head: u64,
}

impl Panel {
    fn request(&mut self, head: u64) -> Value {
        self.pending = true;
        self.requested = Instant::now();
        self.head = head;
        json!({"version":2,"command":"workspace_diff","scope":self.scope})
    }
}

pub(crate) fn command(model: &mut Model, argument: &str) -> InputAction {
    let scope = match argument {
        "" => "turn",
        "session" => "session",
        _ => {
            model.notice = Some("Use /diff or /diff session.".into());
            return InputAction::None;
        }
    };
    let mut panel = Panel {
        scope,
        text: "Capturing workspace…".into(),
        scroll: 0,
        pending: false,
        requested: Instant::now(),
        head: model.projection.head,
    };
    let request = panel.request(model.projection.head);
    model.workspace_diff = Some(panel);
    InputAction::Session(request)
}

pub(crate) fn reply(model: &mut Model, frame: &Value) -> bool {
    if frame["version"] != 2 {
        return false;
    }
    let error = frame["type"] == "session_error" && frame["command"] == "workspace_diff";
    if frame["type"] != "workspace_diff" && !error {
        return false;
    }
    if let Some(panel) = &mut model.workspace_diff {
        panel.pending = false;
        panel.text = frame[if error { "error" } else { "text" }]
            .as_str()
            .unwrap_or("Workspace diff unavailable: invalid server response.")
            .chars()
            .filter(|c| !c.is_control() || *c == '\n' || *c == '\t')
            .collect();
    }
    true
}

pub(crate) fn poll(model: &mut Model) -> Option<Value> {
    let active = model.turn_state() != "idle";
    let head = model.projection.head;
    let panel = model.workspace_diff.as_mut()?;
    if (active || head != panel.head)
        && !panel.pending
        && panel.requested.elapsed() >= Duration::from_secs(1)
    {
        Some(panel.request(head))
    } else {
        None
    }
}

pub(crate) fn input(model: &mut Model, event: &Event) -> Option<InputAction> {
    let head = model.projection.head;
    let panel = model.workspace_diff.as_mut()?;
    if let Event::Key(key) = event
        && key.kind == KeyEventKind::Press
        && key.modifiers == KeyModifiers::NONE
    {
        match key.code {
            KeyCode::Esc => model.workspace_diff = None,
            KeyCode::Up => panel.scroll = panel.scroll.saturating_sub(1),
            KeyCode::Down => panel.scroll = panel.scroll.saturating_add(1),
            KeyCode::PageUp => panel.scroll = panel.scroll.saturating_sub(10),
            KeyCode::PageDown => panel.scroll = panel.scroll.saturating_add(10),
            KeyCode::Home => panel.scroll = 0,
            KeyCode::Char('r') if !panel.pending => {
                return Some(InputAction::Session(panel.request(head)));
            }
            _ => {}
        }
    }
    Some(InputAction::None)
}

pub(crate) fn draw(frame: &mut ratatui::Frame<'_>, model: &Model) {
    let Some(panel) = &model.workspace_diff else {
        return;
    };
    let area = frame.area();
    let rect = Rect::new(
        area.x + area.width / 20,
        area.y + area.height / 12,
        area.width * 9 / 10,
        area.height * 5 / 6,
    );
    let lines: Vec<_> = panel
        .text
        .lines()
        .map(|line| {
            let color = if line.starts_with('+') && !line.starts_with("+++") {
                slot::ADDED
            } else if line.starts_with('-') && !line.starts_with("---") {
                slot::REMOVED
            } else if line.starts_with("@@") || line.starts_with("diff --git") {
                slot::ACCENT
            } else {
                slot::TEXT
            };
            Line::from(Span::styled(line.to_owned(), Style::default().fg(color)))
        })
        .collect();
    frame.render_widget(Clear, rect);
    frame.render_widget(
        Paragraph::new(lines)
            .wrap(Wrap { trim: false })
            .scroll((panel.scroll, 0))
            .block(Block::default().borders(Borders::ALL).title(format!(
                " Diff · {} · ↑/↓ scroll · r refresh · Esc closes ",
                panel.scope
            ))),
        rect,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{fixture_model, handle_input, render_frame};
    use crossterm::event::{KeyEvent, KeyModifiers};

    #[test]
    fn slash_panel_renders_diff_scrolls_refreshes_and_closes_without_interrupting() {
        let mut model = fixture_model("tool-running");
        model.mode = "observe".into();
        model.editor.insert("/diff session");
        let request = json!({"version":2,"command":"workspace_diff","scope":"session"});
        assert_eq!(
            crate::sessions::palette_command(&mut model),
            Some(InputAction::Session(request.clone()))
        );
        let text = "Scope: git-visible files; ignored files not shown. Submodules: gitlink-only.\nSession net diff · live workspace (endpoint not sealed)\ndiff --git tracked.ex tracked.ex\n--- tracked.ex\n+++ tracked.ex\n@@ -1 +1 @@\n-before\n+after\ndiff --git created.txt created.txt\n+created by bash\n\"binary.bin\": binary file (contents not shown)\n\"large.txt\": large file (contents not shown)\n\nChanged outside Elara (observed between turns):\n+outside edit\n";
        assert!(model.session_reply(&json!({"type":"workspace_diff","version":2,"text":text})));
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/goldens");
        let actual = render_frame(&model, 100, 32).unwrap();
        assert!(actual.contains("-before"));
        assert!(actual.contains("+created by bash"));
        let path = root.join("workspace-diff-session.txt");
        if std::env::var_os("ELARA_UPDATE_GOLDENS").is_some() {
            std::fs::write(&path, &actual).unwrap();
        }
        assert_eq!(actual, std::fs::read_to_string(path).unwrap());
        let key = |code| Event::Key(KeyEvent::new(code, KeyModifiers::NONE));
        assert_eq!(
            handle_input(&mut model, key(KeyCode::PageDown), 98),
            InputAction::None
        );
        assert!(!render_frame(&model, 100, 32).unwrap().contains("-before"));
        assert_eq!(
            handle_input(&mut model, key(KeyCode::Char('r')), 98),
            InputAction::Session(request)
        );
        assert!(model.next_workspace_diff_request().is_none());
        assert_eq!(
            handle_input(&mut model, key(KeyCode::Esc), 98),
            InputAction::None
        );
        assert!(
            !render_frame(&model, 100, 32)
                .unwrap()
                .contains("+created by bash")
        );
    }
}
