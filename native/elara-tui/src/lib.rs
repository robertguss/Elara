use std::collections::BTreeMap;
use std::fs;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph, Wrap};
use serde_json::{Value, json};
use tui_markdown::{ImageFallback, Options as MarkdownOptions, StyleSheet};

pub const DEFAULT_PORT: u16 = 4_048;
const MAX_LINE_BYTES: usize = 16 * 1_024 * 1_024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ingest {
    Applied,
    Ignored,
    Resnapshot,
}

#[derive(Clone, Debug)]
pub struct Projection {
    pub view: Value,
    pub incarnation: String,
    pub head: u64,
    awaiting_snapshot: bool,
}

impl Projection {
    pub fn new(view: Value, incarnation: String, head: u64) -> Result<Self, String> {
        validate_snapshot(&view)?;
        let session = view["session"]["id"].as_str().expect("validated session");
        validate_snapshot_identity(&view, session, &incarnation)?;
        Ok(Self {
            view,
            incarnation,
            head,
            awaiting_snapshot: false,
        })
    }

    pub fn install_snapshot(
        &mut self,
        view: Value,
        incarnation: String,
        head: u64,
    ) -> Result<(), String> {
        validate_snapshot(&view)?;
        let session = self.view["session"]["id"]
            .as_str()
            .expect("validated session");
        validate_snapshot_identity(&view, session, &incarnation)?;
        self.view = view;
        self.incarnation = incarnation;
        self.head = head;
        self.awaiting_snapshot = false;
        Ok(())
    }

    pub fn ingest_patch(&mut self, incarnation: &str, seq: u64, ops: &Value) -> Ingest {
        if self.awaiting_snapshot {
            return Ingest::Ignored;
        }

        if incarnation != self.incarnation || seq != self.head.saturating_add(1) {
            if seq <= self.head && incarnation == self.incarnation {
                return Ingest::Ignored;
            }
            self.awaiting_snapshot = true;
            return Ingest::Resnapshot;
        }

        let Some(ops) = ops.as_array() else {
            self.awaiting_snapshot = true;
            return Ingest::Resnapshot;
        };

        match apply_patch(&self.view, ops) {
            Ok(view) => {
                self.view = view;
                self.head = seq;
                Ingest::Applied
            }
            Err(_) => {
                self.awaiting_snapshot = true;
                Ingest::Resnapshot
            }
        }
    }

    pub fn awaiting_snapshot(&self) -> bool {
        self.awaiting_snapshot
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConnectionState {
    Connected,
    Resynchronizing,
    Detached,
}

#[derive(Clone, Debug, Default)]
pub struct Metrics {
    pub ask_to_active_ms: Option<f64>,
    pub ask_to_first_delta_ms: Option<f64>,
}

#[derive(Clone, Debug)]
pub struct Model {
    pub session_id: String,
    pub mode: String,
    pub projection: Projection,
    pub connection: ConnectionState,
    pub input: String,
    pub last_outcome: Option<String>,
    pub notice: Option<String>,
    pub metrics: Metrics,
    ask_sent_at: Option<Instant>,
}

impl Model {
    pub fn new(session_id: String, mode: String, projection: Projection) -> Self {
        Self {
            session_id,
            mode,
            projection,
            connection: ConnectionState::Connected,
            input: String::new(),
            last_outcome: None,
            notice: None,
            metrics: Metrics::default(),
            ask_sent_at: None,
        }
    }

    pub fn mark_ask_sent(&mut self) {
        self.ask_sent_at = Some(Instant::now());
        self.last_outcome = None;
        self.notice = None;
        self.metrics = Metrics::default();
    }

    pub fn apply_patch_frame(&mut self, frame: &Value) -> Result<Ingest, String> {
        let incarnation = string_field(frame, "incarnation")?;
        let seq = u64_field(frame, "seq")?;
        let ops = frame
            .get("ops")
            .ok_or_else(|| "patch is missing ops".to_string())?;

        let ingest = self.projection.ingest_patch(incarnation, seq, ops);
        match ingest {
            Ingest::Applied => {
                self.connection = ConnectionState::Connected;
                self.observe_ops(ops);
            }
            Ingest::Ignored => {}
            Ingest::Resnapshot => self.connection = ConnectionState::Resynchronizing,
        }
        Ok(ingest)
    }

    pub fn install_snapshot_frame(&mut self, frame: &Value) -> Result<(), String> {
        if string_field(frame, "session_id")? != self.session_id {
            return Err("snapshot frame changed session identity".to_string());
        }
        let incarnation = string_field(frame, "incarnation")?.to_string();
        let head = u64_field(frame, "head")?;
        let snapshot = frame
            .get("snapshot")
            .cloned()
            .ok_or_else(|| "snapshot frame is missing snapshot".to_string())?;
        validate_snapshot_identity(&snapshot, &self.session_id, &incarnation)?;
        self.projection
            .install_snapshot(snapshot, incarnation, head)?;
        self.connection = ConnectionState::Connected;
        Ok(())
    }

    pub fn turn_state(&self) -> &str {
        self.projection.view["turn"]["state"]
            .as_str()
            .unwrap_or("invalid")
    }

    fn observe_ops(&mut self, ops: &Value) {
        let Some(ops) = ops.as_array() else {
            return;
        };

        for op in ops {
            match op.get("op").and_then(Value::as_str) {
                Some("set_turn_state") => {
                    let turn = &op["turn"];
                    if turn["state"].as_str() != Some("idle")
                        && self.metrics.ask_to_active_ms.is_none()
                        && let Some(started) = self.ask_sent_at
                    {
                        self.metrics.ask_to_active_ms =
                            Some(started.elapsed().as_secs_f64() * 1_000.0);
                    }
                    if let Some(kind) = turn["outcome"]["kind"].as_str() {
                        self.last_outcome = Some(kind.to_string());
                        self.ask_sent_at = None;
                    }
                }
                Some("append_content_delta") => {
                    if self.metrics.ask_to_first_delta_ms.is_none()
                        && let Some(started) = self.ask_sent_at
                    {
                        self.metrics.ask_to_first_delta_ms =
                            Some(started.elapsed().as_secs_f64() * 1_000.0);
                    }
                }
                _ => {}
            }
        }
    }
}

pub struct ClientConnection {
    writer: TcpStream,
    receiver: Receiver<Result<Value, String>>,
}

impl ClientConnection {
    pub fn connect(port: u16, request: Value) -> Result<(Self, Value), String> {
        let stream = TcpStream::connect(("127.0.0.1", port))
            .map_err(|error| format!("cannot connect to 127.0.0.1:{port}: {error}"))?;
        stream
            .set_nodelay(true)
            .map_err(|error| format!("cannot configure connection: {error}"))?;

        let reader = stream
            .try_clone()
            .map_err(|error| format!("cannot clone connection: {error}"))?;
        let (tx, receiver) = mpsc::channel();
        std::thread::spawn(move || read_frames(reader, tx));

        let mut connection = Self {
            writer: stream,
            receiver,
        };
        connection.send(&request)?;
        let first = connection.recv_timeout(Duration::from_secs(30))?;
        Ok((connection, first))
    }

    pub fn send(&mut self, message: &Value) -> Result<(), String> {
        let mut encoded = serde_json::to_vec(message)
            .map_err(|error| format!("cannot encode command: {error}"))?;
        encoded.push(b'\n');
        self.writer
            .write_all(&encoded)
            .map_err(|error| format!("cannot send command: {error}"))
    }

    pub fn recv_timeout(&self, timeout: Duration) -> Result<Value, String> {
        self.receiver
            .recv_timeout(timeout)
            .map_err(|error| format!("connection receive failed: {error}"))?
    }

    pub fn try_recv(&self) -> Result<Option<Value>, String> {
        match self.receiver.try_recv() {
            Ok(frame) => frame.map(Some),
            Err(mpsc::TryRecvError::Empty) => Ok(None),
            Err(mpsc::TryRecvError::Disconnected) => Err("server disconnected".to_string()),
        }
    }
}

fn read_frames(mut stream: TcpStream, sender: mpsc::Sender<Result<Value, String>>) {
    let mut pending = Vec::new();
    let mut bytes = [0_u8; 8_192];

    loop {
        match stream.read(&mut bytes) {
            Ok(0) => {
                let _ = sender.send(Err("server disconnected".to_string()));
                return;
            }
            Ok(count) => {
                pending.extend_from_slice(&bytes[..count]);
                while let Some(newline) = pending.iter().position(|byte| *byte == b'\n') {
                    if newline + 1 > MAX_LINE_BYTES {
                        let _ = sender.send(Err("server message exceeds 16 MiB".to_string()));
                        return;
                    }
                    let line: Vec<_> = pending.drain(..=newline).collect();
                    let decoded = serde_json::from_slice::<Value>(&line)
                        .map_err(|error| format!("invalid server JSON: {error}"))
                        .and_then(|value| {
                            if value.is_object() {
                                Ok(value)
                            } else {
                                Err("server frame is not an object".to_string())
                            }
                        });
                    if decoded.is_err() || sender.send(decoded).is_err() {
                        return;
                    }
                }
                if pending.len() > MAX_LINE_BYTES {
                    let _ = sender.send(Err("server message exceeds 16 MiB".to_string()));
                    return;
                }
            }
            Err(error) => {
                let _ = sender.send(Err(format!("connection read failed: {error}")));
                return;
            }
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Cursor {
    pub cursor: u64,
    pub incarnation: Option<String>,
}

pub struct CursorStore {
    path: PathBuf,
}

impl CursorStore {
    pub fn from_environment() -> Self {
        let root = std::env::var_os("ELARA_TUI_STATE_DIR")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME")
                    .map(PathBuf::from)
                    .map(|home| home.join(".elara/tui"))
            })
            .unwrap_or_else(|| PathBuf::from(".elara/tui"));
        Self {
            path: root.join("cursors.json"),
        }
    }

    pub fn load(&self, session: &str) -> Cursor {
        let Ok(raw) = fs::read(&self.path) else {
            return Cursor::default();
        };
        let Ok(value) = serde_json::from_slice::<Value>(&raw) else {
            return Cursor::default();
        };
        let Some(cursor) = value.get(session) else {
            return Cursor::default();
        };
        Cursor {
            cursor: cursor["cursor"].as_u64().unwrap_or(0),
            incarnation: cursor["incarnation"].as_str().map(str::to_string),
        }
    }

    pub fn save(&self, session: &str, incarnation: &str, cursor: u64) -> Result<(), String> {
        let mut cursors = fs::read(&self.path)
            .ok()
            .and_then(|raw| serde_json::from_slice::<Value>(&raw).ok())
            .and_then(|value| value.as_object().cloned())
            .unwrap_or_default();
        cursors.insert(
            session.to_string(),
            json!({"cursor": cursor, "incarnation": incarnation}),
        );

        let parent = self.path.parent().unwrap_or_else(|| Path::new("."));
        fs::create_dir_all(parent)
            .map_err(|error| format!("cannot create cursor directory: {error}"))?;
        let temporary = self.path.with_extension("json.tmp");
        fs::write(
            &temporary,
            serde_json::to_vec(&Value::Object(cursors))
                .map_err(|error| format!("cannot encode cursor: {error}"))?,
        )
        .map_err(|error| format!("cannot write cursor: {error}"))?;
        fs::rename(&temporary, &self.path)
            .map_err(|error| format!("cannot install cursor: {error}"))
    }
}

pub fn attached_model(frame: &Value, mode: &str) -> Result<Model, String> {
    if frame["type"].as_str() == Some("error") {
        return Err(format!(
            "attach failed: {}",
            frame["error"].as_str().unwrap_or("unknown server error")
        ));
    }
    if frame["type"].as_str() != Some("attached") || frame["version"].as_u64() != Some(2) {
        return Err("server did not return a protocol v2 attachment".to_string());
    }

    let session = string_field(frame, "session_id")?.to_string();
    let incarnation = string_field(frame, "incarnation")?.to_string();
    let head = u64_field(frame, "head")?;
    let snapshot = frame
        .get("snapshot")
        .cloned()
        .ok_or_else(|| "attached frame is missing snapshot".to_string())?;
    validate_snapshot_identity(&snapshot, &session, &incarnation)?;
    let projection = Projection::new(snapshot, incarnation, head)?;
    Ok(Model::new(session, mode.to_string(), projection))
}

pub fn attach_request(target: &str, mode: &str, cursor: &Cursor) -> Value {
    if target == "new" {
        json!({
            "version": 2,
            "command": "create",
            "mode": mode,
            "cwd": std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")).to_string_lossy()
        })
    } else {
        json!({
            "version": 2,
            "command": "attach",
            "session_id": target,
            "mode": mode,
            "cursor": cursor.cursor,
            "incarnation": cursor.incarnation
        })
    }
}

pub fn command(name: &str) -> Value {
    json!({"version": 2, "command": name})
}

pub fn ask_command(prompt: &str) -> Value {
    json!({"version": 2, "command": "ask", "prompt": prompt})
}

pub fn render_frame(model: &Model, width: u16, height: u16) -> Result<String, String> {
    let backend = TestBackend::new(width, height);
    let mut terminal = Terminal::new(backend).map_err(|error| format!("render failed: {error}"))?;
    terminal
        .draw(|frame| draw_model(frame, model))
        .map_err(|error| format!("render failed: {error}"))?;
    let buffer = terminal.backend().buffer();
    let mut rows = Vec::with_capacity(height as usize);
    for y in 0..height {
        let mut row = String::new();
        for x in 0..width {
            row.push_str(buffer[(x, y)].symbol());
        }
        rows.push(row.trim_end().to_string());
    }
    while rows.last().is_some_and(String::is_empty) {
        rows.pop();
    }
    Ok(format!("{}\n", rows.join("\n")))
}

pub fn draw_model(frame: &mut ratatui::Frame<'_>, model: &Model) {
    let area = frame.area();
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(4),
            Constraint::Length(3),
            Constraint::Length(1),
        ])
        .split(area);

    let lines = transcript_lines(model);
    let visible_height = chunks[0].height.saturating_sub(2) as usize;
    let first = lines.len().saturating_sub(visible_height);
    let transcript = Paragraph::new(lines[first..].to_vec())
        .wrap(Wrap { trim: false })
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(" transcript · protocol v2 projection "),
        );
    frame.render_widget(transcript, chunks[0]);

    let input = Paragraph::new(model.input.as_str()).block(
        Block::default()
            .borders(Borders::ALL)
            .title(" ask · Enter send · Ctrl-X interrupt · Esc detach "),
    );
    frame.render_widget(input, chunks[1]);

    let connection = match model.connection {
        ConnectionState::Connected => "connected",
        ConnectionState::Resynchronizing => "resynchronizing",
        ConnectionState::Detached => "detached",
    };
    let outcome = model.last_outcome.as_deref().unwrap_or("-");
    let status = format!(
        " {} · {} · {} · head {} · {} · outcome {} ",
        model.session_id,
        model.mode,
        connection,
        model.projection.head,
        model.turn_state(),
        outcome
    );
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            status,
            Style::default().bg(Color::DarkGray).fg(Color::White),
        ))),
        chunks[2],
    );
}

fn transcript_lines(model: &Model) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    let view = &model.projection.view;
    let statuses = view["tool_calls"]
        .as_array()
        .map(|calls| {
            calls
                .iter()
                .filter_map(|call| Some((call["id"].as_str()?, call)))
                .collect::<BTreeMap<_, _>>()
        })
        .unwrap_or_default();

    if let Some(messages) = view["messages"].as_array() {
        for message in messages {
            match message["role"].as_str() {
                Some("user") => lines.push(prefixed_line(
                    "you ",
                    Color::Cyan,
                    message["text"].as_str().unwrap_or_default(),
                )),
                Some("assistant") => {
                    if let Some(text) = message["text"].as_str()
                        && !text.is_empty()
                    {
                        lines.extend(assistant_markdown_lines(text, false));
                    }
                    if let Some(calls) = message["tool_calls"].as_array() {
                        for call in calls {
                            let id = call["id"].as_str().unwrap_or("?");
                            let name = call["name"].as_str().unwrap_or("?");
                            let status = statuses
                                .get(id)
                                .and_then(|view| view["status"].as_str())
                                .unwrap_or("pending");
                            let color = match status {
                                "succeeded" => Color::Blue,
                                "failed" | "indeterminate" => Color::Red,
                                "running" => Color::Yellow,
                                _ => Color::DarkGray,
                            };
                            lines.push(Line::from(Span::styled(
                                format!("    {name} · {status}"),
                                Style::default().fg(color),
                            )));
                        }
                    }
                }
                Some("tool") => {
                    let name = message["name"].as_str().unwrap_or("?");
                    let (kind, text) = outcome(&message["outcome"]);
                    lines.push(Line::from(Span::styled(
                        format!("    {name} · {kind}"),
                        Style::default().fg(if kind == "ok" {
                            Color::Blue
                        } else {
                            Color::Red
                        }),
                    )));
                    for line in text.lines().take(6) {
                        lines.push(Line::from(Span::styled(
                            format!("      {line}"),
                            Style::default().fg(Color::DarkGray),
                        )));
                    }
                }
                _ => {}
            }
        }
    }

    if let Some(deltas) = view["content_deltas"].as_object() {
        for text in deltas.values().filter_map(Value::as_str) {
            lines.extend(assistant_markdown_lines(text, true));
        }
    }

    if let Some(notice) = &model.notice {
        lines.push(Line::from(Span::styled(
            notice.clone(),
            Style::default().fg(Color::Red),
        )));
    }
    if lines.is_empty() {
        lines.push(Line::from(Span::styled(
            "No messages yet.",
            Style::default().fg(Color::DarkGray),
        )));
    }
    lines
}

#[derive(Clone, Copy)]
struct TranscriptMarkdown;

impl StyleSheet for TranscriptMarkdown {
    fn heading_marker(&self, _level: u8) -> &str {
        ""
    }

    fn code_block_fence(&self) -> &str {
        ""
    }
}

fn assistant_markdown_lines(text: &str, streaming: bool) -> Vec<Line<'static>> {
    let options =
        MarkdownOptions::new(TranscriptMarkdown).image_fallback(ImageFallback::AltTextAndUrl);
    let rendered = tui_markdown::from_str_with_options(text, &options);
    let mut lines: Vec<Line<'static>> = rendered.lines.into_iter().map(owned_line).collect();

    if lines.is_empty() {
        lines.push(Line::default());
    }

    for (index, line) in lines.iter_mut().enumerate() {
        let prefix = if index == 0 { "ai  " } else { "    " };
        line.spans.insert(
            0,
            Span::styled(
                prefix,
                Style::default()
                    .fg(Color::Green)
                    .add_modifier(Modifier::BOLD),
            ),
        );
    }

    if streaming {
        lines
            .last_mut()
            .expect("assistant markdown always has one line")
            .spans
            .push(Span::raw("▌"));
    }

    lines
}

fn owned_line(line: Line<'_>) -> Line<'static> {
    Line {
        style: line.style,
        alignment: line.alignment,
        spans: line
            .spans
            .into_iter()
            .map(|span| Span::styled(span.content.into_owned(), span.style))
            .collect(),
    }
}

fn prefixed_line(prefix: &'static str, color: Color, text: &str) -> Line<'static> {
    Line::from(vec![
        Span::styled(
            prefix,
            Style::default().fg(color).add_modifier(Modifier::BOLD),
        ),
        Span::raw(text.to_string()),
    ])
}

fn outcome(value: &Value) -> (&str, &str) {
    for kind in ["ok", "error", "indeterminate"] {
        if let Some(text) = value[kind].as_str() {
            return (kind, text);
        }
    }
    ("unknown", "")
}

fn string_field<'a>(value: &'a Value, field: &str) -> Result<&'a str, String> {
    value[field]
        .as_str()
        .ok_or_else(|| format!("server frame has invalid {field}"))
}

fn u64_field(value: &Value, field: &str) -> Result<u64, String> {
    value[field]
        .as_u64()
        .ok_or_else(|| format!("server frame has invalid {field}"))
}

fn validate_snapshot(view: &Value) -> Result<(), String> {
    let object = view
        .as_object()
        .ok_or_else(|| "snapshot is not an object".to_string())?;
    let session = object
        .get("session")
        .and_then(Value::as_object)
        .ok_or_else(|| "snapshot has invalid session".to_string())?;
    if session.get("id").and_then(Value::as_str).is_none()
        || session.get("incarnation").and_then(Value::as_str).is_none()
    {
        return Err("snapshot has invalid session identity".to_string());
    }
    let messages = object
        .get("messages")
        .and_then(Value::as_array)
        .ok_or_else(|| "snapshot has invalid messages".to_string())?;
    for message in messages {
        validate_message(message)?;
    }
    let calls = object
        .get("tool_calls")
        .and_then(Value::as_array)
        .ok_or_else(|| "snapshot has invalid tool_calls".to_string())?;
    for call in calls {
        validate_tool_view(call)?;
    }
    validate_turn(
        object
            .get("turn")
            .ok_or_else(|| "snapshot has no turn".to_string())?,
    )?;
    if !matches!(object.get("usage"), Some(Value::Null | Value::Object(_))) {
        return Err("snapshot has invalid usage".to_string());
    }
    let deltas = object
        .get("content_deltas")
        .and_then(Value::as_object)
        .ok_or_else(|| "snapshot has invalid content_deltas".to_string())?;
    if !deltas.values().all(Value::is_string) {
        return Err("snapshot has invalid content delta".to_string());
    }
    Ok(())
}

fn validate_snapshot_identity(
    view: &Value,
    session: &str,
    incarnation: &str,
) -> Result<(), String> {
    if view["session"]["id"].as_str() == Some(session)
        && view["session"]["incarnation"].as_str() == Some(incarnation)
    {
        Ok(())
    } else {
        Err("snapshot identity does not match its frame".to_string())
    }
}

fn validate_message(message: &Value) -> Result<(), String> {
    match message["role"].as_str() {
        Some("user") if message["text"].is_string() => Ok(()),
        Some("assistant")
            if (message["text"].is_string() || message["text"].is_null())
                && message["tool_calls"].is_array() =>
        {
            for call in message["tool_calls"].as_array().expect("checked array") {
                validate_call(call)?;
            }
            Ok(())
        }
        Some("tool")
            if message["call_id"].is_string()
                && message["name"].is_string()
                && valid_outcome(&message["outcome"]) =>
        {
            Ok(())
        }
        _ => Err("snapshot has invalid message".to_string()),
    }
}

fn validate_call(call: &Value) -> Result<(), String> {
    if call["id"].is_string()
        && call["name"].is_string()
        && (call["args"]["ok"].is_object() || call["args"]["malformed"].is_string())
    {
        Ok(())
    } else {
        Err("snapshot has invalid tool call".to_string())
    }
}

fn validate_tool_view(call: &Value) -> Result<(), String> {
    validate_call(call)?;
    match call["status"].as_str() {
        Some("pending" | "running") if call["outcome"].is_null() => Ok(()),
        Some("succeeded" | "failed" | "indeterminate") if valid_outcome(&call["outcome"]) => Ok(()),
        _ => Err("snapshot has invalid tool status".to_string()),
    }
}

fn valid_outcome(outcome: &Value) -> bool {
    ["ok", "error", "indeterminate"]
        .iter()
        .filter(|kind| outcome[**kind].is_string())
        .count()
        == 1
}

fn validate_turn(turn: &Value) -> Result<(), String> {
    match turn["state"].as_str() {
        Some("idle" | "calling_provider" | "running_tool") => Ok(()),
        _ => Err("snapshot has invalid turn".to_string()),
    }
}

fn apply_patch(view: &Value, ops: &[Value]) -> Result<Value, String> {
    let mut next = view.clone();
    for op in ops {
        apply_op(&mut next, op)?;
    }
    validate_snapshot(&next)?;
    Ok(next)
}

fn apply_op(view: &mut Value, op: &Value) -> Result<(), String> {
    match op["op"].as_str() {
        Some("append_message") => append_message(view, op),
        Some("set_tool_status") => set_tool_status(view, op),
        Some("set_turn_state") => set_turn_state(view, op),
        Some("set_usage") => set_usage(view, op),
        Some("append_content_delta") => append_content_delta(view, op),
        _ => Err("invalid patch operation".to_string()),
    }
}

fn append_message(view: &mut Value, op: &Value) -> Result<(), String> {
    let index = op["index"]
        .as_u64()
        .and_then(|value| usize::try_from(value).ok())
        .ok_or_else(|| "append_message has invalid index".to_string())?;
    let message = op
        .get("message")
        .ok_or_else(|| "append_message has no message".to_string())?;
    validate_message(message)?;

    let messages = view["messages"]
        .as_array_mut()
        .ok_or_else(|| "view has invalid messages".to_string())?;
    if index < messages.len() {
        if messages[index] != *message {
            return Err("append_message conflicts with existing message".to_string());
        }
    } else if index == messages.len() {
        messages.push(message.clone());
        if message["role"].as_str() == Some("assistant") {
            let calls = message["tool_calls"].as_array().expect("validated calls");
            let tool_views = view["tool_calls"]
                .as_array_mut()
                .ok_or_else(|| "view has invalid tool_calls".to_string())?;
            for call in calls {
                let mut tool_view = call.as_object().expect("validated call").clone();
                tool_view.insert("status".to_string(), Value::String("pending".to_string()));
                tool_view.insert("outcome".to_string(), Value::Null);
                tool_views.push(Value::Object(tool_view));
            }
        }
    } else {
        return Err("append_message has an index gap".to_string());
    }
    clear_superseded(view, op.get("supersedes"))
}

fn set_tool_status(view: &mut Value, op: &Value) -> Result<(), String> {
    let id = op["id"]
        .as_str()
        .ok_or_else(|| "set_tool_status has invalid id".to_string())?;
    let status = op["status"]
        .as_str()
        .ok_or_else(|| "set_tool_status has invalid status".to_string())?;
    if !matches!(
        status,
        "pending" | "running" | "succeeded" | "failed" | "indeterminate"
    ) {
        return Err("set_tool_status has invalid status".to_string());
    }
    let outcome = op
        .get("outcome")
        .ok_or_else(|| "set_tool_status has no outcome".to_string())?;
    if matches!(status, "pending" | "running") && !outcome.is_null() {
        return Err("non-terminal tool status has an outcome".to_string());
    }
    if matches!(status, "succeeded" | "failed" | "indeterminate") && !valid_outcome(outcome) {
        return Err("terminal tool status has invalid outcome".to_string());
    }

    let calls = view["tool_calls"]
        .as_array_mut()
        .ok_or_else(|| "view has invalid tool_calls".to_string())?;
    let Some(call) = calls
        .iter_mut()
        .find(|call| call["id"].as_str() == Some(id))
    else {
        return Err("set_tool_status references an unknown call".to_string());
    };
    let call = call.as_object_mut().expect("validated tool view");
    call.insert("status".to_string(), Value::String(status.to_string()));
    call.insert("outcome".to_string(), outcome.clone());
    Ok(())
}

fn set_turn_state(view: &mut Value, op: &Value) -> Result<(), String> {
    let mut turn = op["turn"]
        .as_object()
        .cloned()
        .ok_or_else(|| "set_turn_state has invalid turn".to_string())?;
    validate_turn(&Value::Object(turn.clone()))?;
    turn.remove("prompt");
    turn.remove("outcome");
    turn.remove("streamed");
    view["turn"] = Value::Object(turn);
    clear_superseded(view, op.get("supersedes"))
}

fn set_usage(view: &mut Value, op: &Value) -> Result<(), String> {
    let usage = op
        .get("usage")
        .ok_or_else(|| "set_usage has no usage".to_string())?;
    if !usage.is_null() && !usage.is_object() {
        return Err("set_usage has invalid usage".to_string());
    }
    view["usage"] = usage.clone();
    Ok(())
}

fn append_content_delta(view: &mut Value, op: &Value) -> Result<(), String> {
    let id = op["message_id"]
        .as_str()
        .ok_or_else(|| "append_content_delta has invalid message_id".to_string())?;
    let text = op["text"]
        .as_str()
        .ok_or_else(|| "append_content_delta has invalid text".to_string())?;
    let deltas = view["content_deltas"]
        .as_object_mut()
        .ok_or_else(|| "view has invalid content_deltas".to_string())?;
    let delta = deltas
        .entry(id.to_string())
        .or_insert_with(|| Value::String(String::new()));
    let Some(delta) = delta.as_str() else {
        return Err("view has invalid content delta".to_string());
    };
    let combined = format!("{delta}{text}");
    deltas.insert(id.to_string(), Value::String(combined));
    Ok(())
}

fn clear_superseded(view: &mut Value, supersedes: Option<&Value>) -> Result<(), String> {
    let Some(supersedes) = supersedes else {
        return Ok(());
    };
    let id = supersedes
        .as_str()
        .ok_or_else(|| "patch has invalid supersedes".to_string())?;
    let deltas = view["content_deltas"]
        .as_object_mut()
        .ok_or_else(|| "view has invalid content_deltas".to_string())?;
    deltas.remove(id);
    Ok(())
}

pub fn empty_snapshot(session: &str, incarnation: &str) -> Value {
    json!({
        "session": {"id": session, "incarnation": incarnation},
        "messages": [],
        "tool_calls": [],
        "turn": {"state": "idle"},
        "usage": null,
        "content_deltas": {}
    })
}

pub fn fixture_model(name: &str) -> Model {
    let mut snapshot = empty_snapshot("session-demo", "inc-demo");
    snapshot["messages"] = json!([
        {"role": "user", "text": "inspect the build"},
        {"role": "assistant", "text": "I’ll check it.", "tool_calls": []}
    ]);
    let projection = Projection::new(snapshot, "inc-demo".to_string(), 4).unwrap();
    let mut model = Model::new(
        "session-demo".to_string(),
        "control".to_string(),
        projection,
    );

    match name {
        "idle" => {}
        "streaming" => {
            model.projection.view["turn"] = json!({"state": "calling_provider", "iteration": 1});
            model.projection.view["content_deltas"] =
                json!({"assistant-3": "Streaming the answer"});
            model.projection.head = 7;
        }
        "tool-running" => {
            model.projection.view["messages"] = json!([
                {"role": "user", "text": "inspect the build"},
                {"role": "assistant", "text": null, "tool_calls": [
                    {"id": "call-1", "name": "bash", "args": {"ok": {"command": "mix test"}}}
                ]}
            ]);
            model.projection.view["tool_calls"] = json!([
                {"id": "call-1", "name": "bash", "args": {"ok": {"command": "mix test"}},
                 "status": "running", "outcome": null}
            ]);
            model.projection.view["turn"] =
                json!({"state": "running_tool", "iteration": 1, "tool_call_id": "call-1"});
            model.projection.head = 8;
        }
        "interrupted" => {
            model.last_outcome = Some("interrupted".to_string());
            model.projection.head = 9;
        }
        "detached" => {
            model.connection = ConnectionState::Detached;
            model.notice = Some("Detached; the server-owned session continues.".to_string());
        }
        "markdown" => {
            model.projection.view["messages"] = json!([
                {"role": "user", "text": "show **markdown**"},
                {"role": "assistant", "text": "## Result\n\n**Bold** and `code`\n\n- first\n- second", "tool_calls": []}
            ]);
            model.projection.head = 10;
        }
        other => panic!("unknown fixture {other}"),
    }
    model
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projection_applies_closed_patch_set_and_clears_stream() {
        let snapshot = empty_snapshot("s", "inc");
        let mut projection = Projection::new(snapshot, "inc".to_string(), 0).unwrap();
        let ops = json!([
            {"op": "append_message", "index": 0,
             "message": {"role": "user", "text": "go"}},
            {"op": "set_turn_state", "turn": {"state": "calling_provider", "iteration": 1}},
            {"op": "append_content_delta", "message_id": "assistant-1", "text": "hel"}
        ]);
        assert_eq!(projection.ingest_patch("inc", 1, &ops), Ingest::Applied);
        assert_eq!(projection.view["content_deltas"]["assistant-1"], "hel");

        let final_ops = json!([
            {"op": "append_message", "index": 1, "supersedes": "assistant-1",
             "message": {"role": "assistant", "text": "hello", "tool_calls": []}},
            {"op": "set_turn_state", "supersedes": "assistant-1", "turn": {
                "state": "idle", "outcome": {"kind": "completed", "text": "hello"},
                "streamed": true
            }}
        ]);
        assert_eq!(
            projection.ingest_patch("inc", 2, &final_ops),
            Ingest::Applied
        );
        assert_eq!(projection.view["messages"].as_array().unwrap().len(), 2);
        assert_eq!(projection.view["content_deltas"], json!({}));
    }

    #[test]
    fn gap_incarnation_and_invalid_patch_request_one_resnapshot() {
        let snapshot = empty_snapshot("s", "inc");
        let harmless = json!([{"op": "set_usage", "usage": null}]);
        let mut projection = Projection::new(snapshot.clone(), "inc".to_string(), 4).unwrap();

        assert_eq!(
            projection.ingest_patch("inc", 6, &harmless),
            Ingest::Resnapshot
        );
        assert!(projection.awaiting_snapshot());
        assert_eq!(
            projection.ingest_patch("inc", 7, &harmless),
            Ingest::Ignored
        );
        let changed_snapshot = empty_snapshot("s", "inc-2");
        projection
            .install_snapshot(changed_snapshot, "inc-2".to_string(), 9)
            .unwrap();
        assert_eq!(
            projection.ingest_patch("inc", 10, &harmless),
            Ingest::Resnapshot
        );
        assert_eq!(
            projection.ingest_patch("inc", 11, &harmless),
            Ingest::Ignored
        );
        projection
            .install_snapshot(snapshot, "inc".to_string(), 11)
            .unwrap();
        assert_eq!(
            projection.ingest_patch("inc", 12, &json!([{}])),
            Ingest::Resnapshot
        );
        assert_eq!(
            projection.ingest_patch("inc", 13, &json!([{}])),
            Ingest::Ignored
        );
    }

    #[test]
    fn duplicate_patch_is_ignored_without_changing_projection() {
        let snapshot = empty_snapshot("s", "inc");
        let mut projection = Projection::new(snapshot.clone(), "inc".to_string(), 3).unwrap();
        assert_eq!(
            projection.ingest_patch("inc", 3, &json!([{"op": "unknown"}])),
            Ingest::Ignored
        );
        assert_eq!(projection.view, snapshot);
        assert!(!projection.awaiting_snapshot());
    }

    #[test]
    fn invalid_patch_is_atomic() {
        let snapshot = empty_snapshot("s", "inc");
        let mut projection = Projection::new(snapshot.clone(), "inc".to_string(), 0).unwrap();
        let ops = json!([
            {"op": "append_message", "index": 0,
             "message": {"role": "user", "text": "would mutate"}},
            {"op": "append_message", "index": 4,
             "message": {"role": "user", "text": "gap"}}
        ]);
        assert_eq!(projection.ingest_patch("inc", 1, &ops), Ingest::Resnapshot);
        assert_eq!(projection.view, snapshot);
    }

    #[test]
    fn assistant_markdown_renders_blocks_and_inline_styles() {
        let markdown = "# Heading\n\n**Bold** and *italic* with `code`.\n\n- [x] done\n\n> quote\n\n[docs](https://example.com)\n\n| A | B |\n| - | - |\n| 1 | 2 |";
        let lines = assistant_markdown_lines(markdown, false);
        let rendered = lines
            .iter()
            .map(Line::to_string)
            .collect::<Vec<_>>()
            .join("\n");

        assert!(rendered.starts_with("ai  Heading"));
        assert!(rendered.contains("- [x] done"));
        assert!(rendered.contains("quote"));
        assert!(rendered.contains("docs (https://example.com)"));
        assert!(rendered.contains('┌') && rendered.contains('│'));
        assert!(!rendered.contains("**Bold**"));
        assert!(!rendered.contains("`code`"));

        assert!(lines.iter().flat_map(|line| &line.spans).any(|span| {
            span.content == "Bold" && span.style.add_modifier.contains(Modifier::BOLD)
        }));
        assert!(lines.iter().flat_map(|line| &line.spans).any(|span| {
            span.content == "italic" && span.style.add_modifier.contains(Modifier::ITALIC)
        }));
        assert!(
            lines
                .iter()
                .flat_map(|line| &line.spans)
                .any(|span| { span.content == "code" && span.style.bg == Some(Color::Black) })
        );
    }

    #[test]
    fn streaming_markdown_keeps_multiline_speaker_prefix_and_cursor() {
        let lines = assistant_markdown_lines("First paragraph\n\nSecond paragraph", true);

        assert_eq!(lines[0].spans[0].content, "ai  ");
        assert!(
            lines
                .iter()
                .skip(1)
                .all(|line| line.spans[0].content == "    ")
        );
        assert_eq!(lines.last().unwrap().spans.last().unwrap().content, "▌");
    }

    #[test]
    fn frame_dump_goldens_cover_required_states() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/goldens");
        for name in [
            "idle",
            "streaming",
            "tool-running",
            "interrupted",
            "detached",
            "markdown",
        ] {
            let actual = render_frame(&fixture_model(name), 88, 18).unwrap();
            let path = root.join(format!("{name}.txt"));
            if std::env::var_os("ELARA_UPDATE_GOLDENS").is_some() {
                fs::create_dir_all(&root).unwrap();
                fs::write(&path, &actual).unwrap();
            }
            let expected = fs::read_to_string(&path)
                .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
            assert_eq!(actual, expected, "frame golden {name}");
        }
    }
}
