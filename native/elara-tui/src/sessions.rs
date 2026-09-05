use super::{InputAction, Model};
use crossterm::event::{Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::{
    layout::Rect,
    text::Line,
    widgets::{Block, Borders, Clear, Paragraph},
};
use serde_json::{Value, json};

#[derive(Clone, Debug, Default)]
pub(super) struct Picker {
    pub query: String,
    pub selected: usize,
    pub sessions: Vec<Value>,
    pub loading: bool,
    pub error: Option<String>,
    pub delete_id: Option<String>,
    pub branch: bool,
}

fn matches(value: &Value, query: &str) -> bool {
    let haystack = format!(
        "{} {}",
        value["name"].as_str().unwrap_or(""),
        value["id"].as_str().unwrap_or("")
    )
    .to_lowercase();
    let query = query.to_lowercase();
    let mut chars = query.chars();
    let mut wanted = chars.next();
    for c in haystack.chars() {
        if Some(c) == wanted {
            wanted = chars.next();
        }
    }
    wanted.is_none()
}

pub(super) fn open(model: &mut Model) -> InputAction {
    if model.connection == super::ConnectionState::Detached {
        return InputAction::Reconnect(model.session_id.clone());
    }
    model.session_picker = Some(Picker {
        loading: true,
        ..Picker::default()
    });
    InputAction::Session(json!({"version":2,"command":"session_list"}))
}

pub(super) fn reply(model: &mut Model, frame: &Value) -> bool {
    match frame["type"].as_str() {
        Some("session_list") if frame["version"] == 2 => {
            if let Some(picker) = &mut model.session_picker {
                picker.loading = false;
                picker.sessions = frame["sessions"].as_array().cloned().unwrap_or_default();
                picker.error = None;
            }
            if let Some(lifetime) = frame["lifetime"].as_str() {
                model.lifetime = lifetime.into();
            }
            true
        }
        Some("session_error") if frame["version"] == 2 => {
            let error = friendly(
                frame["error"]
                    .as_str()
                    .unwrap_or("session operation failed"),
            );
            if let Some(picker) = &mut model.session_picker {
                picker.loading = false;
                picker.error = Some(error.clone());
            }
            model.notice = Some(error);
            true
        }
        Some("session_tree") if frame["version"] == 2 => {
            model.session_picker = Some(Picker {
                sessions: frame["entries"].as_array().cloned().unwrap_or_default(),
                branch: true,
                ..Picker::default()
            });
            true
        }
        Some("status") if frame["version"] == 2 => {
            model.session_detail = Some(format!(
                "{}\n\n{}",
                frame["why"].as_str().unwrap_or(""),
                pretty(&frame["status"])
            ));
            model.session_detail_scroll = 0;
            true
        }
        _ => false,
    }
}

pub(super) fn input(model: &mut Model, event: &Event) -> Option<InputAction> {
    let picker = model.session_picker.as_mut()?;
    let Event::Key(key) = event else {
        return Some(InputAction::None);
    };
    if key.kind == KeyEventKind::Release {
        return Some(InputAction::None);
    }
    let filtered: Vec<_> = picker
        .sessions
        .iter()
        .filter(|s| matches(s, &picker.query))
        .collect();
    picker.selected = picker.selected.min(filtered.len().saturating_sub(1));
    match key.code {
        KeyCode::Esc if picker.delete_id.is_some() => picker.delete_id = None,
        KeyCode::Esc => model.session_picker = None,
        KeyCode::Up => picker.selected = picker.selected.saturating_sub(1),
        KeyCode::Down => {
            picker.selected = (picker.selected + 1).min(filtered.len().saturating_sub(1))
        }
        KeyCode::Backspace if picker.delete_id.is_none() => {
            picker.query.pop();
            picker.selected = 0;
        }
        KeyCode::Char(c)
            if picker.delete_id.is_none()
                && !key
                    .modifiers
                    .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
        {
            picker.query.push(c);
            picker.selected = 0;
        }
        KeyCode::Delete
            if model.mode == "control" && picker.delete_id.is_none() && !picker.branch =>
        {
            picker.delete_id = filtered
                .get(picker.selected)
                .and_then(|s| s["id"].as_str())
                .map(str::to_owned);
        }
        KeyCode::Enter => {
            if let Some(id) = picker.delete_id.take() {
                return Some(InputAction::Session(
                    json!({"version":2,"command":"session_delete","session_id":id}),
                ));
            }
            if let Some(id) = filtered.get(picker.selected).and_then(|s| s["id"].as_str()) {
                if picker.branch {
                    if model.mode != "control" {
                        return Some(InputAction::None);
                    }
                    return Some(InputAction::Session(
                        json!({"version":2,"command":"session_fork","entry_id":id}),
                    ));
                }
                if id == model.session_id && model.connection == super::ConnectionState::Connected {
                    model.session_picker = None;
                    return Some(InputAction::None);
                }
                return Some(InputAction::Reconnect(id.to_owned()));
            }
        }
        _ => {}
    }
    Some(InputAction::None)
}

pub(super) fn draw(frame: &mut ratatui::Frame<'_>, model: &Model) {
    let Some(picker) = &model.session_picker else {
        if let Some(prefix) = model.editor.text().strip_prefix('/') {
            let name = prefix.split_whitespace().next().unwrap_or("");
            let choices = crate::actions::SLASH_ACTIONS
                .iter()
                .filter(|(action, _, control)| {
                    action.starts_with(name) && (!*control || model.mode == "control")
                })
                .take(5)
                .map(|(action, description, _)| format!("/{action} {description}"))
                .collect::<Vec<_>>()
                .join(" · ");
            if !choices.is_empty() {
                let area = frame.area();
                let rect = Rect::new(
                    area.x,
                    area.y + area.height.saturating_sub(4),
                    area.width,
                    1,
                );
                frame.render_widget(Paragraph::new(Line::from(choices)), rect);
            }
        }
        return;
    };
    let area = frame.area();
    let rect = Rect::new(
        area.x + area.width / 10,
        area.y + area.height / 8,
        area.width * 4 / 5,
        area.height * 3 / 4,
    );
    let filtered: Vec<_> = picker
        .sessions
        .iter()
        .filter(|s| matches(s, &picker.query))
        .collect();
    let mut lines = vec![Line::from(format!("Filter: {}", picker.query))];
    if picker.loading {
        lines.push(Line::from("Loading sessions…"));
    } else if let Some(error) = &picker.error {
        lines.push(Line::from(format!("Error: {error}")));
    } else if filtered.is_empty() {
        lines.push(Line::from("No matching sessions."));
    }
    let rows = rect.height.saturating_sub(6) as usize;
    let selected = picker.selected.min(filtered.len().saturating_sub(1));
    let start = selected.saturating_sub(rows.saturating_sub(1));
    for (i, s) in filtered.iter().enumerate().skip(start).take(rows) {
        lines.push(Line::from(format!(
            "{} {} · {} · {} · {}",
            if i == picker.selected { ">" } else { " " },
            display(
                s["name"]
                    .as_str()
                    .or_else(|| s["text"].as_str())
                    .unwrap_or("unnamed")
            ),
            s["id"].as_str().unwrap_or("?"),
            s["state"].as_str().unwrap_or("?"),
            s["model"].as_str().unwrap_or("unknown")
        )));
    }
    if !picker.branch
        && let Some(selected) = filtered.get(selected)
    {
        lines.push(Line::from(format!(
            "Workspace: {}",
            display(selected["cwd"].as_str().unwrap_or("unknown"))
        )));
        lines.push(Line::from(format!(
            "Updated: {} ms since epoch",
            selected["updated_at"]
        )));
    }
    if let Some(id) = &picker.delete_id {
        lines.insert(1, Line::from(format!("Delete {id}? Enter yes · Esc no")));
    }
    frame.render_widget(Clear, rect);
    frame.render_widget(
        Paragraph::new(lines).block(Block::default().borders(Borders::ALL).title(
            if picker.branch {
                if model.mode == "control" {
                    " Branch points · Enter fork · Esc close "
                } else {
                    " Branch points · read-only · Esc close "
                }
            } else if model.mode == "control" {
                " Sessions · F11 refresh · Enter switch · Delete remove "
            } else {
                " Sessions · F11 refresh · Enter observe · read-only "
            },
        )),
        rect,
    );
}

pub(super) fn palette_command(model: &mut Model) -> Option<InputAction> {
    let text = model.editor.text().trim().to_owned();
    if let Some(literal) = text.strip_prefix("//") {
        model.editor.clear();
        model.editor.insert(&format!("/{literal}"));
        return Some(InputAction::Submit);
    }
    let command = text.strip_prefix('/')?;
    let mut words = command.splitn(2, ' ');
    let name = words.next().unwrap_or("");
    let argument = words.next().unwrap_or("").trim();
    let control = model.mode == "control";
    let result = match name {
        "sessions" => {
            model.editor.clear();
            return Some(open(model));
        }
        "new" if control => InputAction::Session(json!({"version":2,"command":"session_create"})),
        "name" if control && !argument.is_empty() => {
            InputAction::Session(json!({"version":2,"command":"session_name","name":argument}))
        }
        "tree" => InputAction::Session(json!({"version":2,"command":"session_tree"})),
        "fork" if control && argument.is_empty() => {
            InputAction::Session(json!({"version":2,"command":"session_tree","fork":true}))
        }
        "fork" if control && !argument.is_empty() => {
            InputAction::Session(json!({"version":2,"command":"session_fork","entry_id":argument}))
        }
        "clone" if control => InputAction::Session(json!({"version":2,"command":"session_clone"})),
        "reload" if control => {
            InputAction::Session(json!({"version":2,"command":"session_reload"}))
        }
        "why" => InputAction::Session(json!({"version":2,"command":"inspect"})),
        "interrupt" if control => InputAction::Interrupt,
        "detach" => InputAction::Detach,
        "help" => {
            model.editor.clear();
            model.show_help = true;
            InputAction::None
        }
        "appearance" => {
            model.editor.clear();
            model.appearance_picker = Some(model.appearance);
            InputAction::None
        }
        "model" | "effort" if control => {
            model.editor.clear();
            model.provider_picker = Some((0, 0));
            InputAction::None
        }
        _ => {
            model.notice = Some(if !control {
                "Observe mode is read-only; switching remains observe.".into()
            } else {
                "Unknown or incomplete action; use /help.".into()
            });
            InputAction::None
        }
    };
    if !matches!(result, InputAction::None) {
        model.editor.clear();
    }
    Some(result)
}

fn pretty(value: &Value) -> String {
    serde_json::to_string_pretty(value)
        .unwrap_or_else(|_| "Inspection unavailable".into())
        .chars()
        .map(|c| {
            if c.is_control() && c != '\n' && c != '\t' {
                '�'
            } else {
                c
            }
        })
        .collect()
}

fn display(text: &str) -> String {
    text.chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect()
}

fn friendly(error: &str) -> String {
    match error {
        "active_stop_first" => {
            "The session is active; stop its current turn before continuing.".into()
        }
        "switch_first" => "Switch to another session before deleting the current session.".into(),
        other => other.replace('_', " "),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Projection, empty_snapshot};
    use crossterm::event::{KeyEvent, KeyModifiers};

    fn model(mode: &str) -> Model {
        Model::new(
            "current".into(),
            mode.into(),
            Projection::new(empty_snapshot("current", "i"), "i".into(), 0).unwrap(),
        )
    }

    #[test]
    fn fuzzy_picker_and_exact_delete_identity() {
        let mut model = model("control");
        open(&mut model);
        reply(
            &mut model,
            &json!({"type":"session_list","version":2,"sessions":[{"id":"id-alpha","name":"Release Work","state":"saved","model":"m"}]}),
        );
        for c in "rlsw".chars() {
            input(
                &mut model,
                &Event::Key(KeyEvent::new(KeyCode::Char(c), KeyModifiers::NONE)),
            );
        }
        input(
            &mut model,
            &Event::Key(KeyEvent::new(KeyCode::Delete, KeyModifiers::NONE)),
        );
        model.session_picker.as_mut().unwrap().query = "does-not-match".into();
        let action = input(
            &mut model,
            &Event::Key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)),
        )
        .unwrap();
        assert_eq!(
            action,
            InputAction::Session(
                json!({"version":2,"command":"session_delete","session_id":"id-alpha"})
            )
        );
    }

    #[test]
    fn observer_cannot_mutate_but_switch_is_observe_preserving() {
        let mut model = model("observe");
        model.editor.insert("/new");
        assert_eq!(palette_command(&mut model), Some(InputAction::None));
        assert!(model.editor.text().contains("/new"));
        assert!(model.notice.as_deref().unwrap().contains("read-only"));
    }

    #[test]
    fn reconnect_keeps_view_state_and_picker_handles_read_only_and_disconnect() {
        let mut current = model("control");
        current.editor.insert("draft");
        current.thinking_visible = false;
        current.expanded_tools.insert("tool-1".into());
        current.transcript.borrow_mut().query = "needle".into();
        current.transcript.borrow_mut().follow = false;
        current.transcript.borrow_mut().top = 7;
        current.reconnect_from(model("observe"));
        assert_eq!(current.editor.text(), "draft");
        assert!(!current.thinking_visible);
        assert!(current.expanded_tools.contains("tool-1"));
        assert_eq!(current.transcript.borrow().query, "needle");
        assert_eq!(current.transcript.borrow().top, 7);
        assert!(!current.transcript.borrow().follow);
        reply(
            &mut current,
            &json!({"type":"session_tree","version":2,"entries":[{"id":"branch","text":"question"}]}),
        );
        let enter = Event::Key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
        assert_eq!(input(&mut current, &enter), Some(InputAction::None));
        current.mark_disconnected("server restarted");
        assert_eq!(open(&mut current), InputAction::Reconnect("current".into()));
        assert_eq!(current.mode, "observe");
    }

    #[test]
    fn picker_renders_loading_empty_errors_and_scrolls_confirmation_into_view() {
        let mut current = model("control");
        current.editor.insert("separate draft");
        open(&mut current);
        assert!(
            crate::render_frame(&current, 80, 24)
                .unwrap()
                .contains("Loading sessions")
        );
        reply(
            &mut current,
            &json!({"type":"session_list","version":2,"sessions":[]}),
        );
        assert!(
            crate::render_frame(&current, 80, 24)
                .unwrap()
                .contains("No matching sessions")
        );
        reply(
            &mut current,
            &json!({"type":"session_error","version":2,"error":"active_stop_first"}),
        );
        assert!(
            crate::render_frame(&current, 120, 40)
                .unwrap()
                .contains("stop its current turn")
        );
        let sessions: Vec<_> = (0..30)
            .map(|i| json!({"id":format!("id-{i}"),"name":format!("Name {i}"),"state":"saved"}))
            .collect();
        reply(
            &mut current,
            &json!({"type":"session_list","version":2,"sessions":sessions}),
        );
        current.session_picker.as_mut().unwrap().selected = 29;
        input(
            &mut current,
            &Event::Key(KeyEvent::new(KeyCode::Delete, KeyModifiers::NONE)),
        );
        let frame = crate::render_frame(&current, 80, 24).unwrap();
        assert!(frame.contains("> Name 29"));
        assert!(frame.contains("Delete id-29? Enter yes"));
        assert!(frame.contains("separate draft"));
    }
}
