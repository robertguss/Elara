use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};
use elara_tui::{
    ClientConnection, ConnectionState, InputAction, attached_model, fixture_model, handle_input,
};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::sync::mpsc;
use std::time::Duration;

fn attached(mode: &str, extensions: Value) -> elara_tui::Model {
    let fixture = fixture_model("idle");
    attached_model(
        &json!({
            "version": 2,
            "type": "attached",
            "session_id": fixture.session_id,
            "incarnation": fixture.projection.incarnation,
            "head": fixture.projection.head,
            "snapshot": fixture.projection.view,
            "extensions": extensions,
            "lifetime": "daemon"
        }),
        mode,
    )
    .unwrap()
}

fn key(model: &mut elara_tui::Model, code: KeyCode) -> InputAction {
    handle_input(
        model,
        Event::Key(KeyEvent::new(code, KeyModifiers::NONE)),
        80,
    )
}

#[test]
fn dropping_connection_shuts_down_the_cloned_reader_socket() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let (closed_tx, closed_rx) = mpsc::channel();

    let server = std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(socket.try_clone().unwrap());
        let mut request = String::new();
        reader.read_line(&mut request).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&request).unwrap()["command"],
            "list"
        );
        socket
            .write_all(b"{\"version\":2,\"type\":\"sessions\",\"sessions\":[]}\n")
            .unwrap();

        let mut trailing = String::new();
        let result = reader.read_line(&mut trailing);
        closed_tx.send((result, trailing)).unwrap();
    });

    let (connection, first) =
        ClientConnection::connect(port, json!({"version":2,"command":"list"})).unwrap();
    assert_eq!(first["type"], "sessions");
    drop(connection);

    let (read, trailing) = closed_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("server never observed EOF after ClientConnection was dropped");
    assert_eq!(read.unwrap(), 0);
    assert!(trailing.is_empty());
    server.join().unwrap();
}

#[test]
fn reconnect_preserves_editor_and_reingests_images_but_accepts_fresh_authority() {
    let mut model = attached("control", json!(["input_attachments_v1"]));
    model.editor.insert("draft é 界");
    key(&mut model, KeyCode::Left);
    let cursor = model.editor.cursor();

    let image = std::env::temp_dir().join(format!(
        "elara-session-lifecycle-{}.png",
        std::process::id()
    ));
    std::fs::write(&image, b"\x89PNG\r\n\x1a\n").unwrap();
    key(&mut model, KeyCode::F(9));
    handle_input(
        &mut model,
        Event::Paste(image.to_string_lossy().into_owned()),
        80,
    );
    let ingest = match key(&mut model, KeyCode::Enter) {
        InputAction::Attachment(request) => request,
        action => panic!("expected image ingestion request, got {action:?}"),
    };
    assert!(model.attachment_reply(&json!({
        "type":"ok", "command":"ingest_image", "request_id":ingest["request_id"],
        "attachment":{"id":"old-connection-id","kind":"image","name":"shot.png","mime_type":"image/png","bytes":3}
    })));

    let mut fresh = attached("observe", json!(["input_attachments_v1"]));
    fresh.projection.view["turn"]["state"] = json!("running");
    fresh.projection.head += 17;
    let authoritative_head = fresh.projection.head;
    model.mark_disconnected("test disconnect");
    model.reconnect_from(fresh);

    assert_eq!(model.editor.text(), "draft é 界");
    assert_eq!(model.editor.cursor(), cursor);
    assert_eq!(model.mode, "observe");
    assert_eq!(model.connection, ConnectionState::Connected);
    assert_eq!(model.projection.head, authoritative_head);
    assert_eq!(model.turn_state(), "running");
    assert!(
        model.prepare_submit().is_none(),
        "fresh observe authority must reject mutation"
    );

    let reingest = model
        .next_attachment_request()
        .expect("retained image was not re-ingested");
    assert_eq!(reingest["command"], "ingest_image");
    assert_eq!(reingest["name"], "shot.png");
    assert_ne!(reingest["request_id"], ingest["request_id"]);
    assert!(
        reingest["base64"]
            .as_str()
            .is_some_and(|data| !data.is_empty())
    );
    // A second switch before the first validation reply must retain both the
    // payload and its name, not enqueue an invalid empty-name image.
    model.reconnect_from(attached("control", json!(["input_attachments_v1"])));
    let retry = model.next_attachment_request().unwrap();
    assert_eq!(retry["name"], "shot.png");
    assert_eq!(retry["base64"], reingest["base64"]);
    std::fs::remove_file(image).unwrap();
}
