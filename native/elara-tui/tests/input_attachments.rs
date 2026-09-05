use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};
use elara_tui::{
    Cursor, InputAction, Model, attach_request, attached_model, fixture_model, handle_input,
    render_frame,
};
use serde_json::{Value, json};

fn model() -> Model {
    let fixture = fixture_model("idle");
    attached_model(&json!({"version":2,"type":"attached","session_id":fixture.session_id,"incarnation":fixture.projection.incarnation,"head":fixture.projection.head,"snapshot":fixture.projection.view,"extensions":["input_attachments_v1"]}), "control").unwrap()
}
fn key(model: &mut Model, code: KeyCode) -> InputAction {
    handle_input(
        model,
        Event::Key(KeyEvent::new(code, KeyModifiers::NONE)),
        80,
    )
}
fn request(action: InputAction) -> Value {
    if let InputAction::Attachment(request) = action {
        request
    } else {
        panic!("expected attachment request, got {action:?}");
    }
}
fn file(model: &mut Model, path: &str) {
    let request = request(key(model, KeyCode::F(8)));
    assert!(model.attachment_reply(&json!({"type":"ok","command":"discover_files","request_id":request["request_id"],"files":[{"path":path,"bytes":42}],"truncated":false})));
    key(model, KeyCode::Enter);
}
#[test]
fn attachment_extension_is_requested_and_picker_never_submits_draft() {
    let attach = attach_request("new", "control", &Cursor::default());
    assert!(
        attach["extensions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v == "input_attachments_v1")
    );
    let mut model = model();
    model.editor.insert("keep this draft");
    let query = request(key(&mut model, KeyCode::F(8)));
    assert_eq!(query["command"], "discover_files");
    assert_eq!(model.editor.text(), "keep this draft");
    key(&mut model, KeyCode::Esc);
    assert_eq!(model.editor.text(), "keep this draft");
}
#[test]
fn explicit_files_preserve_unicode_cursor_and_selection_and_submit_paths() {
    let mut model = model();
    model.editor.insert("hello 界 world");
    handle_input(
        &mut model,
        Event::Key(KeyEvent::new(KeyCode::Left, KeyModifiers::SHIFT)),
        80,
    );
    let cursor = model.editor.cursor();
    let selection = model.editor.selection();
    file(&mut model, "docs/日本 語.md");
    assert_eq!(model.editor.cursor(), cursor);
    assert_eq!(model.editor.selection(), selection);
    assert!(
        render_frame(&model, 100, 24)
            .unwrap()
            .contains("@docs/日 本  語 .md")
    );
    let ask = model.prepare_submit().unwrap();
    assert_eq!(ask["references"], json!(["docs/日本 語.md"]));
    assert_eq!(ask["prompt"], "hello 界 world");
    model.command_reply(Some("busy"));
    assert_eq!(
        model.prepare_submit().unwrap()["references"],
        ask["references"]
    );
}
#[test]
fn stale_discovery_and_attachment_replies_never_consume_ask_acceptance() {
    let mut model = model();
    model.editor.insert("draft");
    let old = request(key(&mut model, KeyCode::F(8)));
    assert_eq!(key(&mut model, KeyCode::Char('界')), InputAction::None);
    model.attachment_reply(&json!({"type":"ok","command":"discover_files","request_id":old["request_id"],"files":[{"path":"stale","bytes":0}]}));
    let current = model.next_attachment_request().unwrap();
    assert_eq!(current["query"], "界");
    key(&mut model, KeyCode::Enter);
    assert!(render_frame(&model, 80, 24).unwrap().contains("Searching"));
    model.attachment_reply(&json!({"type":"ok","command":"discover_files","request_id":current["request_id"],"files":[{"path":"界.md","bytes":1}],"truncated":true}));
    assert!(render_frame(&model, 80, 24).unwrap().contains("truncated"));
    key(&mut model, KeyCode::Enter);
    model.prepare_submit().unwrap();
    model.attachment_reply(&json!({"type":"error","command":"discover_files","request_id":old["request_id"],"error":"old"}));
    assert_eq!(model.editor.text(), "draft");
    model.editor.insert(" newer");
    model.command_reply(None);
    assert_eq!(model.editor.text(), "draft newer");
    assert_eq!(
        model.prepare_submit().unwrap()["references"],
        json!(["界.md"])
    );
}
#[test]
fn ordinary_email_and_cancelled_at_prose_never_attach() {
    let mut model = model();
    for c in "a@b.com ".chars() {
        assert_eq!(key(&mut model, KeyCode::Char(c)), InputAction::None);
    }
    request(key(&mut model, KeyCode::Char('@')));
    for c in "some prose".chars() {
        assert_eq!(key(&mut model, KeyCode::Char(c)), InputAction::None);
    }
    key(&mut model, KeyCode::Esc);
    assert_eq!(model.editor.text(), "a@b.com @some prose");
    assert!(model.prepare_submit().unwrap().get("references").is_none());
}
#[test]
fn four_selection_limit_removal_and_accepted_revision() {
    let mut model = model();
    for path in ["a", "b", "c", "d", "e"] {
        file(&mut model, path);
    }
    assert!(
        render_frame(&model, 100, 24)
            .unwrap()
            .contains("Four selections")
    );
    key(&mut model, KeyCode::F(10));
    key(&mut model, KeyCode::Delete);
    key(&mut model, KeyCode::Esc);
    let ask = model.prepare_submit().unwrap();
    assert_eq!(ask["references"], json!(["b", "c", "d"]));
    model.command_reply(None);
    assert!(model.prepare_submit().is_none());
}

fn image_request(model: &mut Model, path: &std::path::Path) -> Value {
    key(model, KeyCode::F(9));
    handle_input(model, Event::Paste(path.to_str().unwrap().into()), 80);
    request(key(model, KeyCode::Enter))
}
fn image_reply(model: &mut Model, request: &Value, id: &str) {
    assert!(model.attachment_reply(&json!({"type":"ok","command":"ingest_image","request_id":request["request_id"],"attachment":{"id":id,"kind":"image","name":"local image.png","mime_type":"image/png","bytes":8}})));
}
fn temp_path(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("elara-native-input-{}-{name}", std::process::id()))
}
#[test]
fn image_bytes_are_uploaded_once_and_cleanup_does_not_consume_ask_reply() {
    use base64::Engine;
    let path = temp_path("immutable.png");
    let original = b"\x89PNG\r\n\x1a\n";
    std::fs::write(&path, original).unwrap();
    let mut model = model();
    model.editor.insert("describe");
    let upload = image_request(&mut model, &path);
    assert_eq!(
        base64::engine::general_purpose::STANDARD
            .decode(upload["base64"].as_str().unwrap())
            .unwrap(),
        original
    );
    assert!(upload.get("path").is_none());
    std::fs::write(&path, b"changed").unwrap();
    assert!(model.prepare_submit().is_none());
    image_reply(&mut model, &upload, "img-1");
    let ask = model.prepare_submit().unwrap();
    assert_eq!(ask["attachment_ids"], json!(["img-1"]));
    assert!(ask.get("base64").is_none());
    key(&mut model, KeyCode::F(10));
    let discard = request(key(&mut model, KeyCode::Delete));
    assert_eq!(discard["command"], "discard_attachment");
    key(&mut model, KeyCode::Esc);
    model.attachment_reply(
        &json!({"type":"ok","command":"discard_attachment","request_id":discard["request_id"]}),
    );
    model.command_reply(None);
    assert_eq!(model.editor.text(), "describe"); // attachment revision changed while ask pending
    assert!(
        model
            .prepare_submit()
            .unwrap()
            .get("attachment_ids")
            .is_none()
    );
    std::fs::remove_file(path).unwrap();
}
#[test]
fn accepted_images_discard_cache_and_cancelled_ingestion_never_adds_late_image() {
    let path = temp_path("cancel.png");
    std::fs::write(&path, b"\x89PNG\r\n\x1a\n").unwrap();
    let mut model = model();
    let upload = image_request(&mut model, &path);
    key(&mut model, KeyCode::Esc);
    image_reply(&mut model, &upload, "cancelled");
    assert_eq!(
        model.next_attachment_request().unwrap()["attachment_id"],
        "cancelled"
    );
    assert!(model.prepare_submit().is_none());
    let upload = image_request(&mut model, &path);
    image_reply(&mut model, &upload, "accepted");
    model.prepare_submit().unwrap();
    model.command_reply(None);
    assert_eq!(
        model.next_attachment_request().unwrap()["attachment_id"],
        "accepted"
    );
    assert!(model.prepare_submit().is_none());
    std::fs::remove_file(path).unwrap();
}
#[test]
fn image_errors_disconnect_and_safe_paste_preserve_draft() {
    let mut model = model();
    model.editor.insert("draft 界");
    let path = temp_path("errors.png");
    for (bytes, expected) in [
        (b"JPEG".to_vec(), "Unsupported image"),
        (vec![1; 2 * 1024 * 1024 + 1], "exceeds 2 MiB"),
    ] {
        std::fs::write(&path, bytes).unwrap();
        key(&mut model, KeyCode::F(9));
        handle_input(&mut model, Event::Paste(path.to_str().unwrap().into()), 80);
        assert_eq!(key(&mut model, KeyCode::Enter), InputAction::None);
        assert!(render_frame(&model, 100, 24).unwrap().contains(expected));
        key(&mut model, KeyCode::Esc);
        assert_eq!(model.editor.text(), "draft 界");
    }
    std::fs::remove_file(&path).unwrap();
    key(&mut model, KeyCode::F(9));
    handle_input(&mut model, Event::Paste(path.to_str().unwrap().into()), 80);
    key(&mut model, KeyCode::Enter);
    assert!(
        render_frame(&model, 100, 24)
            .unwrap()
            .contains("Cannot read image")
    );
    key(&mut model, KeyCode::F(2));
    assert!(model.safe_paste);
    assert_eq!(key(&mut model, KeyCode::F(8)), InputAction::None);
    key(&mut model, KeyCode::F(2));
    std::fs::write(&path, b"\x89PNG\r\n\x1a\n").unwrap();
    let upload = image_request(&mut model, &path);
    image_reply(&mut model, &upload, "kept");
    model.mark_disconnected("test disconnect");
    assert!(model.prepare_submit().is_none());
    assert_eq!(model.editor.text(), "draft 界");
    assert!(
        render_frame(&model, 100, 24)
            .unwrap()
            .contains("local image.png")
    );
    std::fs::remove_file(path).unwrap();
}
#[test]
fn file_picker_mouse_and_error_empty_states_work_in_every_layout() {
    use crossterm::event::{MouseButton, MouseEvent, MouseEventKind};
    for layout in elara_tui::ViewLayout::ALL {
        let mut model = model();
        model.appearance.layout = *layout;
        let discover = request(key(&mut model, KeyCode::F(8)));
        model.attachment_reply(&json!({"type":"error","command":"discover_files","request_id":discover["request_id"],"error":"unreadable"}));
        assert!(
            render_frame(&model, 80, 24)
                .unwrap()
                .contains("Discovery failed")
        );
        let discover = request(key(&mut model, KeyCode::Char('x')));
        model.attachment_reply(&json!({"type":"ok","command":"discover_files","request_id":discover["request_id"],"files":[],"truncated":false}));
        assert!(
            render_frame(&model, 80, 24)
                .unwrap()
                .contains("No matching files")
        );
        let discover = request(key(&mut model, KeyCode::Backspace));
        model.attachment_reply(&json!({"type":"ok","command":"discover_files","request_id":discover["request_id"],"files":[{"path":"clicked.md","bytes":2}]}));
        render_frame(&model, 80, 24).unwrap();
        handle_input(
            &mut model,
            Event::Mouse(MouseEvent {
                kind: MouseEventKind::Down(MouseButton::Left),
                column: 5,
                row: 4,
                modifiers: KeyModifiers::NONE,
            }),
            80,
        );
        assert_eq!(
            model.prepare_submit().unwrap()["references"],
            json!(["clicked.md"])
        );
    }
}

#[test]
fn repeated_identical_image_is_deduplicated_and_pending_ingest_defers_discard() {
    let path = temp_path("duplicate.png");
    std::fs::write(&path, b"\x89PNG\r\n\x1a\n").unwrap();
    let mut model = model();
    let first = image_request(&mut model, &path);
    image_reply(&mut model, &first, "same");
    let second = image_request(&mut model, &path);
    image_reply(&mut model, &second, "same");
    key(&mut model, KeyCode::Esc);
    let ask = model.prepare_submit().unwrap();
    assert_eq!(ask["attachment_ids"], json!(["same"]));
    model.command_reply(Some("busy"));
    let third = image_request(&mut model, &path);
    key(&mut model, KeyCode::F(10));
    assert_eq!(key(&mut model, KeyCode::Delete), InputAction::None);
    image_reply(&mut model, &third, "same");
    assert!(model.next_attachment_request().is_none());
    key(&mut model, KeyCode::Esc);
    assert_eq!(
        model.prepare_submit().unwrap()["attachment_ids"],
        json!(["same"])
    );
    std::fs::remove_file(path).unwrap();
}
#[test]
fn submitted_attachment_metadata_is_visible_without_content_blobs() {
    let mut model = model();
    model.projection.view["messages"][0]["attachments"] = json!([
      {"id":"t","kind":"text","name":"clipped.md","bytes":100000,"included_bytes":65536,"clipped":true},
      {"id":"i","kind":"image","name":"cat.png","mime_type":"image/png","bytes":100}
    ]);
    let frame = render_frame(&model, 100, 24).unwrap();
    assert!(frame.contains("clipped.md"));
    assert!(frame.contains("65536/100000 bytes · clipped"));
    assert!(frame.contains("cat.png · image/png · 100 bytes"));
}

#[test]
fn discovery_coalesces_edits_and_cancel_reopen_keeps_one_outstanding_request() {
    let mut model = model();
    let first = request(key(&mut model, KeyCode::F(8)));
    for c in "several edits".chars() {
        assert_eq!(key(&mut model, KeyCode::Char(c)), InputAction::None);
    }
    assert!(model.next_attachment_request().is_none());
    key(&mut model, KeyCode::Esc);
    assert_eq!(key(&mut model, KeyCode::F(8)), InputAction::None);
    assert_eq!(
        handle_input(&mut model, Event::Paste("new query".into()), 80),
        InputAction::None
    );
    model.attachment_reply(&json!({"type":"ok","command":"discover_files","request_id":first["request_id"],"files":[{"path":"stale.md","bytes":1}]}));
    let latest = model.next_attachment_request().unwrap();
    assert_eq!(latest["query"], "new query");
    assert!(model.next_attachment_request().is_none());
    key(&mut model, KeyCode::Enter);
    assert!(model.prepare_submit().is_none());
    // A duplicate old response cannot release the current request slot.
    model.attachment_reply(&json!({"type":"ok","command":"discover_files","request_id":first["request_id"],"files":[]}));
    assert!(model.next_attachment_request().is_none());
    key(&mut model, KeyCode::Esc);
    key(&mut model, KeyCode::F(9));
    model.attachment_reply(&json!({"type":"error","command":"discover_files","request_id":latest["request_id"],"error":"stale error"}));
    assert!(model.next_attachment_request().is_none());
    assert!(
        !render_frame(&model, 100, 24)
            .unwrap()
            .contains("stale error")
    );
    key(&mut model, KeyCode::Esc);
    let reopened = request(key(&mut model, KeyCode::F(8)));
    assert_eq!(reopened["query"], "");
}

#[test]
fn provider_and_attachment_pickers_have_exclusive_keyboard_ownership() {
    let mut model = model();
    model.projection.view["provider_view"] = json!({"catalog":[{"model":"test-model","efforts":["low","high"]}],"next_request":{"model":"test-model","effort":"low"}});
    key(&mut model, KeyCode::F(7));
    for code in [
        KeyCode::F(8),
        KeyCode::F(9),
        KeyCode::F(10),
        KeyCode::Char('@'),
    ] {
        assert_eq!(key(&mut model, code), InputAction::None);
    }
    assert_eq!(model.editor.text(), "");
    let action = key(&mut model, KeyCode::Enter);
    assert!(
        matches!(action, InputAction::ProviderSettings(_)),
        "{action:?}"
    );
    request(key(&mut model, KeyCode::F(8)));
    assert_eq!(key(&mut model, KeyCode::F(7)), InputAction::None);
    key(&mut model, KeyCode::Esc);
    model.editor.insert("ordinary draft");
    assert_eq!(key(&mut model, KeyCode::Enter), InputAction::Submit);
}
