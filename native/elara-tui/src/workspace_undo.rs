use crate::{InputAction, Model};
use crossterm::event::{Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::{
    layout::Rect,
    widgets::{Block, Borders, Clear, Paragraph, Wrap},
};
use serde_json::{Value, json};

#[derive(Clone, Debug)]
pub(crate) struct Panel {
    token: Option<String>,
    text: String,
    scroll: u16,
    applying: bool,
}

pub(crate) fn command(model: &mut Model, target: &str) -> InputAction {
    if model.mode != "control" {
        model.notice = Some("Undo requires control mode.".into());
        return InputAction::None;
    }
    if !target.is_empty() && (target.len() > 128 || target.chars().any(char::is_whitespace)) {
        model.notice = Some("Use /undo or /undo TURN_ID.".into());
        return InputAction::None;
    }
    model.workspace_undo = Some(Panel {
        token: None,
        text: "Checking closed turn and touched files…".into(),
        scroll: 0,
        applying: false,
    });
    InputAction::Session(
        json!({"version":2,"command":"workspace_undo","action":"preview",
        "target":if target.is_empty() {"latest"} else {target}}),
    )
}

pub(crate) fn reply(model: &mut Model, frame: &Value) -> bool {
    if frame["version"] != 2
        || !(frame["type"] == "workspace_undo"
            || (frame["type"] == "session_error" && frame["command"] == "workspace_undo"))
    {
        return false;
    }
    if frame["type"] == "session_error" {
        model.workspace_undo = None;
        model.notice = Some(frame["error"].as_str().unwrap_or("Undo refused.").into());
    } else if frame["action"] == "preview" {
        if let Some(panel) = &mut model.workspace_undo {
            let result = &frame["result"];
            let valid = result["token"]
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= 128);
            let files = result["files"]
                .as_array()
                .filter(|files| !files.is_empty() && files.iter().all(Value::is_string));
            if let (Some(token), Some(files), Some(turn), Some(notice)) = (
                valid,
                files,
                result["turn_id"].as_str(),
                result["notice"].as_str(),
            ) {
                panel.token = Some(token.into());
                panel.text = format!(
                    "Undo turn {turn}?\n\nRestore only these {} git-visible paths (including bash changes):\n{}\n\n{notice}\n\nFiles changed since this turn ended will refuse the entire undo.",
                    files.len(),
                    files
                        .iter()
                        .map(|f| format!("  {}", f))
                        .collect::<Vec<_>>()
                        .join("\n")
                );
            } else {
                model.workspace_undo = None;
                model.notice = Some("Undo unavailable: invalid server preview.".into());
            }
        }
    } else if frame["action"] == "apply" {
        model.workspace_undo = None;
        model.notice = Some(
            frame["result"]["text"]
                .as_str()
                .unwrap_or("Undo result unavailable; inspect the transcript.")
                .into(),
        );
    }
    true
}

pub(crate) fn input(model: &mut Model, event: &Event) -> Option<InputAction> {
    let panel = model.workspace_undo.as_mut()?;
    if let Event::Key(key) = event
        && key.kind == KeyEventKind::Press
        && key.modifiers == KeyModifiers::NONE
    {
        match key.code {
            KeyCode::Esc if !panel.applying => {
                let token = panel.token.clone();
                model.workspace_undo = None;
                model.notice = Some("Undo cancelled; no files restored.".into());
                return Some(token.map_or(InputAction::None, |token| InputAction::Session(
                    json!({"version":2,"command":"workspace_undo","action":"cancel","token":token})
                )));
            }
            KeyCode::Enter if !panel.applying => {
                if let Some(token) = &panel.token {
                    panel.applying = true;
                    return Some(InputAction::Session(
                        json!({"version":2,"command":"workspace_undo","action":"apply","token":token}),
                    ));
                }
            }
            KeyCode::Up => panel.scroll = panel.scroll.saturating_sub(1),
            KeyCode::Down => panel.scroll = panel.scroll.saturating_add(1),
            KeyCode::PageUp => panel.scroll = panel.scroll.saturating_sub(10),
            KeyCode::PageDown => panel.scroll = panel.scroll.saturating_add(10),
            KeyCode::Home => panel.scroll = 0,
            _ => {}
        }
    }
    Some(InputAction::None)
}

pub(crate) fn draw(frame: &mut ratatui::Frame<'_>, model: &Model) {
    let Some(panel) = &model.workspace_undo else {
        return;
    };
    let area = frame.area();
    let rect = Rect::new(
        area.x + area.width / 20,
        area.y + area.height / 12,
        area.width * 9 / 10,
        area.height * 5 / 6,
    );
    let title = if panel.applying {
        " Undo · restoring; wait for result "
    } else {
        " Undo · Enter confirms · Esc cancels · ↑/↓ scroll "
    };
    frame.render_widget(Clear, rect);
    frame.render_widget(
        Paragraph::new(panel.text.clone())
            .wrap(Wrap { trim: false })
            .scroll((panel.scroll, 0))
            .block(Block::default().borders(Borders::ALL).title(title)),
        rect,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{fixture_model, handle_input, render_frame};
    use crossterm::event::KeyEvent;

    #[test]
    fn undo_requires_preview_and_confirmation_or_cancel() {
        let mut model = fixture_model("idle");
        model.editor.insert("/undo");
        assert_eq!(
            crate::sessions::palette_command(&mut model),
            Some(InputAction::Session(
                json!({"version":2,"command":"workspace_undo","action":"preview","target":"latest"})
            ))
        );
        let key = |code| Event::Key(KeyEvent::new(code, KeyModifiers::NONE));
        assert_eq!(
            handle_input(&mut model, key(KeyCode::Enter), 98),
            InputAction::None
        );
        let preview = json!({"type":"workspace_undo","version":2,"action":"preview","result":{
            "token":"confirmation-token","turn_id":"turn-1","files":["lib/demo.ex","created by bash.txt"],
            "notice":"Cannot reverse migrations that ran, ignored folders such as deps/ and _build/, or pushes. Submodules are gitlink-only."
        }});
        assert!(model.session_reply(&preview));
        let actual = render_frame(&model, 100, 28).unwrap();
        assert!(actual.contains("lib/demo.ex"));
        assert!(actual.contains("Cannot reverse migrations"));
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/goldens/workspace-undo.txt");
        if std::env::var_os("ELARA_UPDATE_GOLDENS").is_some() {
            std::fs::write(&path, &actual).unwrap();
        }
        assert_eq!(actual, std::fs::read_to_string(path).unwrap());
        assert_eq!(
            handle_input(&mut model, key(KeyCode::Esc), 98),
            InputAction::Session(
                json!({"version":2,"command":"workspace_undo","action":"cancel","token":"confirmation-token"})
            )
        );
        assert!(model.workspace_undo.is_none());
        command(&mut model, "turn-1");
        assert!(model.session_reply(&preview));
        assert_eq!(
            handle_input(&mut model, key(KeyCode::Enter), 98),
            InputAction::Session(
                json!({"version":2,"command":"workspace_undo","action":"apply","token":"confirmation-token"})
            )
        );
        assert_eq!(
            handle_input(&mut model, key(KeyCode::Enter), 98),
            InputAction::None
        );
        model.session_reply(&json!({"type":"session_error","version":2,"command":"workspace_undo","error":"Undo refused: changed lib/demo.ex"}));
        assert!(model.workspace_undo.is_none());
        assert!(model.notice.as_ref().unwrap().contains("lib/demo.ex"));
    }
}
