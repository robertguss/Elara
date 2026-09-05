//! Durable submission identity and the queue projection. Never replay on a lost reply.
use super::{ConnectionState, InputAction, Model};
use crossterm::event::{Event, KeyCode, KeyEventKind};
use ratatui::{
    layout::Rect,
    text::Line,
    widgets::{Block, Borders, Clear, Paragraph},
};
use serde_json::{Value, json};
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::{fs, io::Write, path::PathBuf};

pub(crate) const EXTENSION: &str = "input_queue_v1";

#[derive(Clone, Debug, Default)]
pub(crate) struct Inbox {
    pub supported: bool,
    pub pending: Option<Value>,
    pub blocked: bool,
    pub selected: Option<usize>,
}

fn path(session: &str) -> PathBuf {
    let root = std::env::var_os("ELARA_TUI_STATE_DIR")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".elara/tui")))
        .unwrap_or_else(|| PathBuf::from(".elara/tui"));
    let encoded: String = session.bytes().map(|b| format!("{b:02x}")).collect();
    root.join("pending").join(format!("{encoded}.json"))
}

fn persist(session: &str, pending: &Value) -> Result<(), String> {
    let path = path(session);
    fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
    let temp = path.with_extension(format!("tmp-{}", std::process::id()));
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options.open(&temp).map_err(|e| e.to_string())?;
    file.write_all(&serde_json::to_vec(pending).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    fs::rename(temp, path).map_err(|e| e.to_string())
}

fn forget(model: &mut Model) -> Result<(), String> {
    match fs::remove_file(path(&model.session_id)) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.to_string()),
    }
    model.inbox.pending = None;
    Ok(())
}

pub(crate) fn restore(model: &mut Model) {
    match fs::read(path(&model.session_id)) {
        Ok(raw) => match serde_json::from_slice::<Value>(&raw) {
            Ok(pending) if pending["id"].is_string() && pending["text"].is_string() => {
                if model.editor.text().is_empty() {
                    model.editor.insert(pending["text"].as_str().unwrap());
                    model.attachments.restore_pending(&pending["attachments"]);
                }
                model.inbox.pending = Some(pending);
            }
            _ => {
                model.inbox.blocked = true;
                model.notice =
                    Some("Cannot read pending input identity; do not resubmit blindly.".into())
            }
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => {
            model.inbox.blocked = true;
            model.notice = Some(format!("Cannot read pending input: {e}"));
        }
    }
}

pub(crate) fn status_request(model: &Model) -> Option<Value> {
    if !model.inbox.supported {
        return None;
    }
    model.inbox.pending.as_ref().map(|p| json!({"version":2,"extension":EXTENSION,"command":"input_status","submission_id":p["id"]}))
}

pub(crate) fn submit(model: &mut Model, steer: bool) -> Option<Value> {
    if model.inbox.blocked {
        model.notice = Some("Pending identity unreadable; resolve it before submitting.".into());
        return None;
    }
    if model.connection != ConnectionState::Connected || model.mode != "control" {
        model.notice = Some("Detached or read-only; draft retained.".into());
        return None;
    }
    if model.inbox.pending.is_some() {
        model.notice = Some("Checking the original submission ID; never blindly resending.".into());
        return status_request(model);
    }
    if model.editor.text().trim().is_empty() && model.attachments.selections.is_empty() {
        return None;
    }
    let mut request = json!({"version":2,"command":"submit_input","prompt":model.editor.text(),"kind":if steer {"steer"} else {"normal"}});
    if let Err(error) = model.attachments.augment(&mut request) {
        model.notice = Some(error.into());
        return None;
    }
    let mut random = [0_u8; 24];
    use std::io::Read;
    if let Err(e) = fs::File::open("/dev/urandom").and_then(|mut file| file.read_exact(&mut random))
    {
        model.notice = Some(format!("Cannot allocate submission identity: {e}"));
        return None;
    }
    let id: String = random.iter().map(|b| format!("{b:02x}")).collect();
    let pending = json!({"id":id,"text":model.editor.text(),"attachments":model.attachments.pending_payload()});
    if let Err(e) = persist(&model.session_id, &pending) {
        model.notice = Some(format!(
            "Cannot persist submission identity: {e}; nothing sent."
        ));
        return None;
    }
    request["extension"] = json!(EXTENSION);
    request["submission_id"] = json!(id);
    request["sender_id"] = json!(format!("tui-{id}"));
    model.inbox.pending = Some(pending);
    model.mark_ask_sent();
    model.notice = Some("Awaiting durable acceptance; draft retained. Enter checks status.".into());
    Some(request)
}

pub(crate) fn receipt(model: &mut Model, frame: &Value) -> bool {
    if frame["type"] != "input_receipt" || frame["version"] != 2 {
        return false;
    }
    if !frame["entry"].is_null()
        && (frame["entry"]["id"] != frame["submission_id"]
            || validate(
                &json!({"entries":[frame["entry"]], "paused":false, "execution":{}}),
                &model.session_id,
            )
            .is_err())
    {
        return false;
    }
    let matches = model
        .inbox
        .pending
        .as_ref()
        .is_some_and(|p| p["id"] == frame["submission_id"]);
    if let Some(error) = frame["error"].as_str() {
        // A rejected submit is definitive. A failed status query is not.
        if matches
            && frame["command"] == "submit_input"
            && let Err(e) = forget(model)
        {
            model.notice = Some(format!("Cannot clear rejected identity: {e}"));
            return true;
        }
        model.notice = Some(format!("Input rejected: {error}; draft retained."));
        return true;
    }
    if matches {
        let pending = model.inbox.pending.as_ref().unwrap();
        let accepted = frame["entry"].is_object();
        let unchanged = pending["text"].as_str() == Some(model.editor.text())
            && pending["attachments"] == model.attachments.pending_payload();
        if let Err(e) = forget(model) {
            model.notice = Some(format!("Cannot settle submission identity: {e}"));
            return true;
        }
        if accepted && unchanged {
            model.editor.clear();
            model.attachments.clear_accepted();
        }
        model.notice = (!accepted).then(|| {
            "Original ID was not accepted; draft retained. Enter submits explicitly.".into()
        });
    } else {
        model.notice = Some(format!(
            "{}: {}",
            frame["command"].as_str().unwrap_or("input"),
            frame["entry"]["state"].as_str().unwrap_or("ok")
        ));
    }
    true
}

pub(crate) fn validate(inbox: &Value, session: &str) -> Result<(), String> {
    let entries = inbox["entries"].as_array().ok_or("invalid inbox entries")?;
    if !inbox["paused"].is_boolean() || !inbox["execution"].is_object() {
        return Err("invalid inbox state".into());
    }
    let mut ids = std::collections::HashSet::new();
    for entry in entries {
        if !entry["id"].is_string()
            || !ids.insert(entry["id"].as_str().unwrap())
            || entry["session_id"] != session
            || !entry["sender_id"].is_string()
            || !matches!(entry["kind"].as_str(), Some("normal" | "steer"))
            || !matches!(
                entry["state"].as_str(),
                Some("queued" | "accepted" | "consumed" | "cancelled" | "failed")
            )
            || !entry["text"].is_string()
            || !entry["attachments"].is_array()
        {
            return Err("invalid inbox entry".into());
        }
    }
    Ok(())
}

pub(crate) fn open(model: &mut Model) -> InputAction {
    if model.inbox.supported {
        model.inbox.selected = Some(0);
    } else {
        model.notice = Some("Queue extension unavailable on this server.".into());
    }
    InputAction::None
}

pub(crate) fn input(model: &mut Model, event: &Event) -> Option<InputAction> {
    let selected = model.inbox.selected.as_mut()?;
    let Event::Key(key) = event else {
        return Some(InputAction::None);
    };
    if key.kind != KeyEventKind::Press {
        return Some(InputAction::None);
    }
    match super::actions::lookup(*key, false) {
        Some(super::actions::Action::Interrupt) => return Some(InputAction::Interrupt),
        Some(super::actions::Action::Steer) => return Some(InputAction::Steer),
        Some(super::actions::Action::Escape) if key.code != KeyCode::Esc => {
            return Some(InputAction::Detach);
        }
        _ => {}
    }
    let entries = model.projection.view["inbox"]["entries"].as_array();
    let len = entries.map_or(0, Vec::len);
    match key.code {
        KeyCode::Esc => model.inbox.selected = None,
        KeyCode::Up => *selected = selected.saturating_sub(1),
        KeyCode::Down => *selected = (*selected + 1).min(len.saturating_sub(1)),
        KeyCode::Delete if model.mode == "control" => {
            if let Some(entry) = entries.and_then(|e| e.get(*selected)) {
                return Some(InputAction::Session(
                    json!({"version":2,"extension":EXTENSION,"command":"cancel_input","submission_id":entry["id"]}),
                ));
            }
        }
        KeyCode::Char('r') if model.mode == "control" => {
            return Some(InputAction::Session(
                json!({"version":2,"extension":EXTENSION,"command":"resume_inputs"}),
            ));
        }
        _ => {}
    }
    Some(InputAction::None)
}

pub(crate) fn summary(model: &Model) -> String {
    let view = &model.projection.view["inbox"];
    let count = view["entries"].as_array().map_or(0, |entries| {
        entries
            .iter()
            .filter(|e| matches!(e["state"].as_str(), Some("queued" | "accepted")))
            .count()
    });
    format!(
        "{count} queued{} · F12 queue · Ctrl-S steer · Ctrl-X stop",
        if view["paused"] == true {
            " (paused)"
        } else {
            ""
        }
    )
}

pub(crate) fn draw(frame: &mut ratatui::Frame<'_>, model: &Model) {
    let Some(selected) = model.inbox.selected else {
        return;
    };
    let area = frame.area();
    let rect = Rect::new(
        area.x + 2,
        area.y + 2,
        area.width.saturating_sub(4),
        area.height.saturating_sub(4),
    );
    let view = &model.projection.view["inbox"];
    let mut lines = vec![
        Line::from(summary(model)),
        Line::from(format!(
            "Execution: {} · capabilities: {}",
            view["execution"]["mode"], view["execution"]["allowed_capabilities"]
        )),
    ];
    if let Some(entries) = view["entries"].as_array() {
        if entries.is_empty() {
            lines.push(Line::from("No submitted inputs."));
        }
        let rows = rect.height.saturating_sub(4) as usize;
        for (i, entry) in entries
            .iter()
            .enumerate()
            .skip(selected.saturating_sub(rows.saturating_sub(1)))
            .take(rows)
        {
            let text: String = entry["text"]
                .as_str()
                .unwrap_or("")
                .chars()
                .map(|c| if c.is_control() { ' ' } else { c })
                .collect();
            lines.push(Line::from(format!(
                "{} {} · {} · {}{}",
                if i == selected { ">" } else { " " },
                entry["kind"].as_str().unwrap_or("?"),
                entry["state"].as_str().unwrap_or("?"),
                text,
                entry["error"]
                    .as_str()
                    .map(|e| format!(" · {e}"))
                    .unwrap_or_default()
            )));
        }
    }
    frame.render_widget(Clear, rect);
    frame.render_widget(
        Paragraph::new(lines).block(Block::default().borders(Borders::ALL).title(
            if model.mode == "control" {
                " Inbox · Delete cancel selected · r resume · Esc close "
            } else {
                " Inbox · read-only · Esc close "
            },
        )),
        rect,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn model() -> Model {
        static SERIAL: AtomicUsize = AtomicUsize::new(0);
        let mut model = crate::fixture_model("idle");
        model.session_id = format!(
            "queue-test-{}-{}",
            std::process::id(),
            SERIAL.fetch_add(1, Ordering::Relaxed)
        );
        model.inbox.supported = true;
        model.editor.insert("follow up");
        model
    }

    fn accepted(model: &Model, id: &Value) -> Value {
        json!({"type":"input_receipt", "version":2, "command":"input_status", "submission_id":id,
            "entry":{"id":id,"session_id":model.session_id,"sender_id":"tui","kind":"normal","state":"queued","text":"follow up","attachments":[]}})
    }

    #[test]
    fn uncertain_submission_restores_and_queries_original_identity() {
        let mut original = model();
        let request = submit(&mut original, false).unwrap();
        let mut restored = model();
        restored.session_id = original.session_id.clone();
        restored.editor.clear();
        restore(&mut restored);
        assert_eq!(restored.editor.text(), "follow up");
        assert_eq!(
            submit(&mut restored, false).unwrap()["submission_id"],
            request["submission_id"]
        );
        let reply = accepted(&restored, &request["submission_id"]);
        assert!(receipt(&mut restored, &reply));
        assert!(restored.editor.text().is_empty());
        assert!(restored.inbox.pending.is_none());
        assert!(!path(&restored.session_id).exists());
    }

    #[test]
    fn edited_draft_survives_and_malformed_receipt_does_not_settle() {
        let mut model = model();
        let request = submit(&mut model, true).unwrap();
        assert_eq!(request["kind"], "steer");
        let mut reply = accepted(&model, &request["submission_id"]);
        reply["entry"]["session_id"] = json!("foreign");
        assert!(!receipt(&mut model, &reply));
        assert!(model.inbox.pending.is_some());
        model.editor.insert(" edited");
        reply["entry"]["session_id"] = json!(model.session_id);
        assert!(receipt(&mut model, &reply));
        assert_eq!(model.editor.text(), "follow up edited");
    }

    #[test]
    fn unknown_id_retains_draft_and_downgrade_or_corruption_blocks_resend() {
        let mut model = model();
        let request = submit(&mut model, false).unwrap();
        model.inbox.supported = false;
        assert!(model.prepare_submit().is_none());
        model.inbox.supported = true;
        assert!(receipt(
            &mut model,
            &json!({"type":"input_receipt","version":2,"command":"input_status","submission_id":request["submission_id"],"entry":null})
        ));
        assert_eq!(model.editor.text(), "follow up");
        persist(&model.session_id, &json!({"corrupt":true})).unwrap();
        restore(&mut model);
        assert!(model.prepare_submit().is_none());
        forget(&mut model).unwrap();
    }

    #[test]
    fn accepted_restored_images_do_not_reappear_after_ingestion() {
        let mut model = model();
        model.attachments.supported = true;
        let payload =
            json!([{"name":"one.png","base64":"AQID"},{"name":"two.png","base64":"BAUG"}]);
        model.attachments.restore_pending(&payload);
        let pending = json!({"id":"image-input","text":model.editor.text(),"attachments":model.attachments.pending_payload()});
        persist(&model.session_id, &pending).unwrap();
        model.inbox.pending = Some(pending);
        let ingestion = model.attachments.outbox.pop_front().unwrap();
        let reply = accepted(&model, &json!("image-input"));
        assert!(receipt(&mut model, &reply));
        assert!(crate::attachments::reply(
            &mut model,
            &json!({"type":"attachment","command":"ingest_image","request_id":ingestion["request_id"],"attachment":{"id":"image-1"}})
        ));
        assert!(model.attachments.selections.is_empty());
        assert_eq!(model.attachments.pending_payload(), json!([]));
    }

    #[test]
    fn observer_cannot_submit() {
        let mut model = model();
        model.mode = "observe".into();
        assert!(submit(&mut model, true).is_none());
        assert_eq!(model.editor.text(), "follow up");
        model.inbox.selected = Some(0);
        let stop = Event::Key(crossterm::event::KeyEvent::new(
            KeyCode::Char('x'),
            crossterm::event::KeyModifiers::CONTROL,
        ));
        assert!(matches!(
            input(&mut model, &stop),
            Some(InputAction::Interrupt)
        ));
        assert!(!model.track_interrupt());
        model.mode = "control".into();
        assert!(matches!(
            input(&mut model, &stop),
            Some(InputAction::Interrupt)
        ));
        assert!(model.track_interrupt());
    }
}
