use std::collections::{HashSet, VecDeque};

mod actions;
pub mod appearance;
mod attachments;
mod inbox;
mod presentation;
mod sessions;
pub use appearance::{Appearance, Theme, ViewLayout};
mod clipboard;
mod editor;
mod tools;
mod transcript;
pub use editor::Editor;
use std::cell::RefCell;
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
    snapshot_generation: u64,
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
            snapshot_generation: 0,
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
        self.snapshot_generation = self.snapshot_generation.wrapping_add(1);
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

#[derive(Clone, Debug, PartialEq, Eq)]
enum PendingReply {
    Ask,
    Interrupt,
    Snapshot,
    Settings,
}

#[derive(Clone, Debug)]
pub struct Model {
    pub session_id: String,
    pub cwd: Option<String>,
    pub mode: String,
    pub projection: Projection,
    pub connection: ConnectionState,
    pub editor: Editor,
    attachments: attachments::Draft,
    inbox: inbox::Inbox,
    pub safe_paste: bool,
    safe_paste_cr: bool,
    pub enhanced_keyboard: bool,
    pub show_help: bool,
    pub appearance: Appearance,
    pub appearance_picker: Option<Appearance>,
    provider_picker: Option<(usize, usize)>,
    pub thinking_visible: bool,
    pub preview_reasoning: bool,
    presentation_overlay: Option<presentation::Overlay>,
    overlay_scroll: usize,
    transcript: RefCell<transcript::Transcript>,
    expanded_tools: HashSet<String>,
    viewer: Option<(String, transcript::Transcript)>,
    pending_replies: VecDeque<PendingReply>,
    // Acceptance can remain uncertain after the turn's metrics have finished.
    pending_ask: Option<(u64, Instant)>,
    pub last_outcome: Option<String>,
    pub notice: Option<String>,
    pub lifetime: String,
    session_picker: Option<sessions::Picker>,
    seen_thread_reports: HashSet<String>,
    session_detail: Option<String>,
    session_detail_scroll: u16,
    pub metrics: Metrics,
    ask_sent_at: Option<Instant>,
}

impl Model {
    pub fn new(session_id: String, mode: String, projection: Projection) -> Self {
        let mut editor = Editor::default();
        editor.set_history(user_prompts(&projection.view));
        Self {
            session_id,
            mode,
            projection,
            connection: ConnectionState::Connected,
            editor,
            attachments: attachments::Draft::default(),
            inbox: inbox::Inbox::default(),
            safe_paste: false,
            safe_paste_cr: false,
            enhanced_keyboard: false,
            show_help: false,
            appearance: Appearance::default(),
            appearance_picker: None,
            provider_picker: None,
            thinking_visible: true,
            preview_reasoning: false,
            presentation_overlay: None,
            overlay_scroll: 0,
            transcript: RefCell::new(transcript::Transcript::default()),
            expanded_tools: HashSet::new(),
            viewer: None,
            pending_replies: VecDeque::new(),
            pending_ask: None,
            last_outcome: None,
            notice: None,
            lifetime: "embedded".into(),
            cwd: None,
            session_picker: None,
            seen_thread_reports: HashSet::new(),
            session_detail: None,
            session_detail_scroll: 0,
            metrics: Metrics::default(),
            ask_sent_at: None,
        }
    }

    /// Install authoritative connection state while retaining this session's Rust-owned UI state.
    pub fn reconnect_from(&mut self, fresh: Model) {
        self.projection = fresh.projection;
        self.editor.set_history(user_prompts(&self.projection.view));
        self.last_outcome = fresh.last_outcome;
        self.connection = ConnectionState::Connected;
        self.mode = fresh.mode;
        self.cwd = fresh.cwd;
        self.lifetime = fresh.lifetime;
        self.attachments.reconnect(fresh.attachments.supported);
        self.inbox.supported = fresh.inbox.supported;
        self.inbox.blocked |= fresh.inbox.blocked;
        self.inbox.selected = None;
        if self.inbox.pending.is_none() {
            self.inbox.pending = fresh.inbox.pending;
        }
        self.pending_replies.clear();
        self.pending_ask = None;
        self.ask_sent_at = None;
        self.provider_picker = None;
        self.session_picker = None;
        self.viewer = None;
        self.transcript.borrow_mut().source_key = None;
        self.notice = Some("Reattached; local draft and view restored.".into());
    }

    pub fn session_reply(&mut self, frame: &Value) -> bool {
        sessions::reply(self, frame)
    }

    fn selected_tool(&self) -> Option<String> {
        let selected = self.transcript.borrow().selected.clone()?;
        selected
            .strip_prefix(&format!("{}:tool:", self.session_id))
            .map(str::to_owned)
    }

    fn toggle_tool(&mut self) {
        if self.viewer.is_some() {
            return;
        }
        if let Some(id) = self.selected_tool() {
            if !self.expanded_tools.remove(&id) {
                self.expanded_tools.insert(id);
            }
            self.transcript.borrow_mut().source_key = None;
        }
    }

    fn open_tool(&mut self) {
        if self.viewer.is_some() {
            return;
        }
        if let Some(id) = self.selected_tool() {
            let mut state = transcript::Transcript::default();
            state.focused = true;
            state.follow = false;
            let saved = self.transcript.replace(state);
            self.viewer = Some((id, saved));
        }
    }

    fn close_tool(&mut self) {
        if let Some((_, saved)) = self.viewer.take() {
            self.transcript.replace(saved);
        }
    }

    pub fn prepare_submit(&mut self) -> Option<Value> {
        if self.inbox.blocked || (!self.inbox.supported && self.inbox.pending.is_some()) {
            self.notice = Some("Cannot resolve pending input identity; draft retained.".into());
            return None;
        }
        if self.inbox.supported {
            return inbox::submit(self, false);
        }
        if self.pending_ask.is_some() {
            self.notice = Some(
                "Acceptance pending or uncertain; draft retained. Do not retry blindly.".into(),
            );
            return None;
        }
        if self.connection != ConnectionState::Connected || self.mode != "control" {
            self.notice = Some(
                "Cannot send while detached, resynchronizing, or observing; draft retained.".into(),
            );
            return None;
        }
        if self.turn_state() != "idle" {
            self.notice =
                Some("Session busy; draft retained. Wait for idle before sending.".into());
            return None;
        }
        if self.editor.text().trim().is_empty() && self.attachments.selections.is_empty() {
            return None;
        }
        let mut request = ask_command(self.editor.text());
        if let Err(error) = self.attachments.augment(&mut request) {
            self.notice = Some(error.into());
            return None;
        }
        self.attachments.submitted_revision = Some(self.attachments.revision);
        self.pending_ask = Some((self.editor.revision(), Instant::now()));
        self.pending_replies.push_back(PendingReply::Ask);
        self.mark_ask_sent();
        Some(request)
    }

    pub fn track_interrupt(&mut self) -> bool {
        if self.connection == ConnectionState::Detached
            || self.mode != "control"
            || self.pending_replies.contains(&PendingReply::Interrupt)
        {
            return false;
        }
        self.pending_replies.push_back(PendingReply::Interrupt);
        true
    }

    pub fn prepare_steer(&mut self) -> Option<Value> {
        if self.inbox.supported {
            inbox::submit(self, true)
        } else {
            self.notice = Some("Steering requires input_queue_v1 support.".into());
            None
        }
    }

    pub fn pending_input_status(&self) -> Option<Value> {
        inbox::status_request(self)
    }
    pub fn input_receipt(&mut self, frame: &Value) -> bool {
        inbox::receipt(self, frame)
    }

    pub fn track_resnapshot(&mut self) {
        self.pending_replies.push_back(PendingReply::Snapshot);
    }

    // Protocol v2 responds serially on one connection; patches are not replies.
    // This is connection-local correlation, not durable submission identity.
    pub fn command_reply(&mut self, error: Option<&str>) {
        if self.pending_replies.pop_front() == Some(PendingReply::Ask)
            && let Some((revision, _)) = self.pending_ask.take()
        {
            if error.is_none() {
                if self.editor.revision() == revision
                    && self.attachments.submitted_revision == Some(self.attachments.revision)
                {
                    self.editor.clear();
                    self.attachments.clear_accepted();
                }
                self.notice = None;
            } else {
                self.ask_sent_at = None;
            }
        }
        if let Some(error) = error {
            self.notice = Some(format!("Server rejected command: {error}; draft retained."));
        }
    }

    pub fn next_attachment_request(&mut self) -> Option<Value> {
        self.attachments.outbox.pop_front()
    }

    pub fn attachment_reply(&mut self, frame: &Value) -> bool {
        attachments::reply(self, frame)
    }

    pub fn snapshot_reply(&mut self) {
        if self.pending_replies.front() == Some(&PendingReply::Snapshot) {
            self.pending_replies.pop_front();
        }
    }

    pub fn check_acceptance_timeout(&mut self) -> bool {
        if self
            .pending_ask
            .is_some_and(|(_, sent)| sent.elapsed() >= Duration::from_secs(5))
        {
            let notice = "Acceptance uncertain; draft retained. Inspect session before retrying.";
            if self.notice.as_deref() != Some(notice) {
                self.notice = Some(notice.into());
                return true;
            }
        }
        false
    }

    pub fn mark_disconnected(&mut self, error: &str) {
        self.connection = ConnectionState::Detached;
        self.notice = Some(if self.pending_ask.is_some() {
            format!(
                "Acceptance uncertain: {error}. Draft retained; inspect session before retrying."
            )
        } else {
            format!("Disconnected: {error}. Draft retained in this window; Esc exits.")
        });
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
                if ops.as_array().is_some_and(|ops| {
                    ops.iter()
                        .any(|op| op["op"] == "append_message" && op["message"]["role"] == "user")
                }) {
                    self.editor.set_history(user_prompts(&self.projection.view));
                }
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
        self.editor.set_history(user_prompts(&self.projection.view));
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

fn user_prompts(view: &Value) -> Vec<String> {
    view["messages"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|message| message["role"] == "user")
        .filter_map(|message| message["text"].as_str().map(str::to_owned))
        .collect()
}

#[derive(Debug, PartialEq, Eq)]
pub enum InputAction {
    None,
    Submit,
    Steer,
    Interrupt,
    Detach,
    ProviderSettings(Value),
    Attachment(Value),
    Session(Value),
    Reconnect(String),
}

fn provider_input(model: &mut Model, event: &crossterm::event::Event) -> Option<InputAction> {
    use crossterm::event::{Event, KeyCode, KeyEventKind};
    let Event::Key(key) = event else {
        return model.provider_picker.map(|_| InputAction::None);
    };
    if key.kind == KeyEventKind::Release || model.safe_paste {
        return None;
    }
    if model.provider_picker.is_none() && key.code != KeyCode::F(7) {
        return None;
    }
    let catalog = model.projection.view["provider_view"]["catalog"].as_array();
    if model.connection != ConnectionState::Connected
        || model.mode != "control"
        || catalog.is_none_or(Vec::is_empty)
    {
        model.notice = Some("Provider controls unavailable for this connection/provider.".into());
        model.provider_picker = None;
        return Some(InputAction::None);
    }
    let catalog = catalog.unwrap();
    let Some((mut m, mut e)) = model.provider_picker else {
        let current = &model.projection.view["provider_view"]["next_request"];
        let m = catalog
            .iter()
            .position(|item| item["model"] == current["model"])
            .unwrap_or(0);
        let e = catalog[m]["efforts"]
            .as_array()
            .and_then(|efforts| {
                efforts
                    .iter()
                    .position(|effort| effort == &current["effort"])
            })
            .unwrap_or(0);
        model.provider_picker = Some((m, e));
        return Some(InputAction::None);
    };
    m = m.min(catalog.len() - 1);
    let count = catalog[m]["efforts"].as_array().map_or(0, Vec::len);
    if count == 0 {
        model.provider_picker = None;
        return Some(InputAction::None);
    }
    e = e.min(count - 1);
    match key.code {
        KeyCode::Esc | KeyCode::F(7) => {
            model.provider_picker = None;
            return Some(InputAction::None);
        }
        KeyCode::Up => m = (m + catalog.len() - 1) % catalog.len(),
        KeyCode::Down => m = (m + 1) % catalog.len(),
        KeyCode::Left => e = (e + count - 1) % count,
        KeyCode::Right => e = (e + 1) % count,
        KeyCode::Enter => {
            let request = json!({"version": 2, "command": "set_provider_settings", "extension": "provider_visibility_v1", "model": catalog[m]["model"], "effort": catalog[m]["efforts"][e]});
            model.provider_picker = None;
            model.pending_replies.push_back(PendingReply::Settings);
            model.notice = Some("Settings submitted; awaiting authority for next request.".into());
            return Some(InputAction::ProviderSettings(request));
        }
        _ => {}
    }
    let selected_count = catalog[m]["efforts"].as_array().map_or(0, Vec::len);
    model.provider_picker = if selected_count == 0 {
        None
    } else {
        Some((m, e.min(selected_count - 1)))
    };
    Some(InputAction::None)
}

pub fn handle_input(
    model: &mut Model,
    event: crossterm::event::Event,
    width: usize,
) -> InputAction {
    use crossterm::event::{Event, KeyCode, KeyEventKind, KeyModifiers};
    if !model.safe_paste
        && let Some(action) = inbox::input(model, &event)
    {
        return action;
    }
    if !model.safe_paste
        && let Event::Key(key) = &event
        && key.kind == KeyEventKind::Press
    {
        match actions::lookup(*key, false) {
            Some(actions::Action::Queue) => return inbox::open(model),
            Some(actions::Action::Steer) => return InputAction::Steer,
            _ => {}
        }
    }
    if model.session_detail.is_some() {
        if let Event::Key(key) = &event
            && key.kind != KeyEventKind::Release
        {
            match key.code {
                KeyCode::Esc => model.session_detail = None,
                KeyCode::Up => {
                    model.session_detail_scroll = model.session_detail_scroll.saturating_sub(1)
                }
                KeyCode::Down => {
                    model.session_detail_scroll = model.session_detail_scroll.saturating_add(1)
                }
                KeyCode::PageUp => {
                    model.session_detail_scroll = model.session_detail_scroll.saturating_sub(10)
                }
                KeyCode::PageDown => {
                    model.session_detail_scroll = model.session_detail_scroll.saturating_add(10)
                }
                _ => {}
            }
        }
        return InputAction::None;
    }
    if let Event::Key(key) = &event
        && !model.safe_paste
        && key.kind == KeyEventKind::Press
        && actions::lookup(*key, false) == Some(actions::Action::Sessions)
    {
        return sessions::open(model);
    }
    if let Some(action) = sessions::input(model, &event) {
        return action;
    }
    if model.safe_paste && model.viewer.is_some() {
        model.close_tool();
    }
    if !model.safe_paste
        && model.provider_picker.is_some()
        && let Event::Key(key) = &event
        && key.kind == KeyEventKind::Press
    {
        match actions::lookup(*key, false) {
            Some(actions::Action::Interrupt) => return InputAction::Interrupt,
            Some(actions::Action::Escape) if key.code != KeyCode::Esc => {
                return InputAction::Detach;
            }
            _ => {}
        }
    }
    if let Some(action) = attachments::input(model, &event) {
        return action;
    }
    if let Some(action) = provider_input(model, &event) {
        return action;
    }
    if presentation::input(model, &event) {
        return InputAction::None;
    }
    let insert = |model: &mut Model, text: &str| {
        if !model.editor.insert(text) {
            model.notice =
                Some("Draft limit: 64 KiB. Insert rejected; existing text retained.".into());
        }
    };
    if let Event::Mouse(mouse) = &event
        && !model.safe_paste
        && !model.show_help
        && mouse.modifiers.is_empty()
    {
        use crossterm::event::{MouseButton, MouseEventKind};
        let inside = model
            .transcript
            .borrow()
            .rect
            .contains((mouse.column, mouse.row).into());
        if inside && matches!(mouse.kind, MouseEventKind::Down(MouseButton::Right)) {
            if model.viewer.is_some() {
                model.transcript.borrow_mut().drag_anchor = None;
                model.close_tool();
            } else {
                let point = model
                    .transcript
                    .borrow()
                    .mouse_point(mouse.column, mouse.row, false);
                if let Some(point) =
                    point.filter(|p| p.id.starts_with(&format!("{}:tool:", model.session_id)))
                {
                    model.transcript.borrow_mut().drag_anchor = None;
                    model.transcript.borrow_mut().selected = Some(point.id);
                    model.open_tool();
                }
            }
            return InputAction::None;
        }
        if inside
            && mouse.kind == MouseEventKind::Down(MouseButton::Left)
            && mouse.column < model.transcript.borrow().rect.x + 3
        {
            let point = model
                .transcript
                .borrow()
                .mouse_point(mouse.column, mouse.row, false);
            if point.as_ref().is_some_and(|p| {
                p.byte < 3 && p.id.starts_with(&format!("{}:tool:", model.session_id))
            }) {
                let mut state = model.transcript.borrow_mut();
                state.focused = true;
                state.scroll(0);
                state.selected = point.map(|p| p.id);
                state.drag_anchor = None;
                drop(state);
                model.toggle_tool();
                return InputAction::None;
            }
        }
    }
    if let Event::Mouse(mouse) = &event {
        use crossterm::event::MouseEventKind;
        if matches!(mouse.kind, MouseEventKind::Down(_) | MouseEventKind::Up(_)) {
            model.transcript.borrow_mut().drag_anchor = None;
        }
    }
    match event {
        Event::Mouse(mouse) if !model.safe_paste && !model.show_help => {
            use crossterm::event::{MouseButton, MouseEventKind};
            let mut state = model.transcript.borrow_mut();
            if mouse.modifiers.contains(KeyModifiers::SHIFT) {
                return InputAction::None;
            }
            match mouse.kind {
                MouseEventKind::ScrollUp
                    if state.rect.contains((mouse.column, mouse.row).into()) =>
                {
                    state.focused = true;
                    state.scroll(-3);
                }
                MouseEventKind::ScrollDown
                    if state.rect.contains((mouse.column, mouse.row).into()) =>
                {
                    state.focused = true;
                    state.scroll(3);
                }
                MouseEventKind::Down(MouseButton::Left)
                    if state.rect.contains((mouse.column, mouse.row).into()) =>
                {
                    state.focused = true;
                    state.scroll(0);
                    state.begin_drag(mouse.column, mouse.row);
                }
                MouseEventKind::Drag(MouseButton::Left) if state.drag_anchor.is_some() => {
                    if mouse.row < state.rect.y {
                        state.scroll(-1);
                    }
                    if mouse.row >= state.rect.bottom() {
                        state.scroll(1);
                    }
                    state.drag_to(mouse.column, mouse.row);
                }
                _ => {}
            }
        }
        Event::Paste(text) => {
            model.safe_paste_cr = false;
            if !model.safe_paste && !model.show_help && model.transcript.borrow().searching {
                if !model.transcript.borrow_mut().append_query(&text) {
                    model.notice = Some("Search limit: 4 KiB; query retained.".into());
                }
            } else {
                insert(model, &text);
            }
        }
        Event::Key(key) if key.kind != KeyEventKind::Release => {
            use actions::Action;
            let focused = model.transcript.borrow().focused;
            let action = actions::lookup(key, focused);
            if action == Some(Action::SafePaste) && key.kind == KeyEventKind::Press {
                if !model.safe_paste {
                    model.close_tool();
                }
                model.safe_paste = !model.safe_paste;
                model.safe_paste_cr = false;
                return InputAction::None;
            }
            // Unframed pasted controls must never invoke application commands.
            if model.safe_paste {
                let lf = key.code == KeyCode::Char('j') && key.modifiers == KeyModifiers::CONTROL;
                // Safe mode opts into paste semantics: decoded CR + LF is one newline.
                let crlf = model.safe_paste_cr && lf;
                model.safe_paste_cr = key.code == KeyCode::Enter;
                if crlf {
                    return InputAction::None;
                }
                match key.code {
                    KeyCode::Enter => insert(model, "\n"),
                    KeyCode::Char('j') if key.modifiers == KeyModifiers::CONTROL => {
                        insert(model, "\n")
                    }
                    KeyCode::Tab => insert(model, "\t"),
                    KeyCode::Char(c)
                        if !key.modifiers.intersects(
                            KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER,
                        ) =>
                    {
                        insert(model, &c.to_string())
                    }
                    _ => {}
                }
                return InputAction::None;
            }
            if action == Some(Action::Help) {
                model.show_help = !model.show_help;
                return InputAction::None;
            }
            if model.show_help {
                if key.code == KeyCode::Esc {
                    model.show_help = false;
                }
                return InputAction::None;
            }
            if action == Some(Action::Escape) && key.code != KeyCode::Esc {
                return InputAction::Detach;
            }
            if action == Some(Action::Interrupt) && key.kind == KeyEventKind::Press {
                return InputAction::Interrupt;
            }
            if model.transcript.borrow().searching {
                let mut state = model.transcript.borrow_mut();
                match key.code {
                    KeyCode::Esc => state.searching = false,
                    KeyCode::Enter => state.next_match(key.modifiers.contains(KeyModifiers::SHIFT)),
                    KeyCode::Backspace => {
                        state.query.pop();
                        state.search_changed();
                    }
                    KeyCode::Char(c)
                        if !key.modifiers.intersects(
                            KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER,
                        ) =>
                    {
                        let accepted = state.append_query(&c.to_string());
                        if !accepted {
                            model.notice = Some("Search limit: 4 KiB; query retained.".into());
                        }
                    }
                    _ => {}
                }
                return InputAction::None;
            }
            match action {
                Some(Action::ToggleTool) if focused => model.toggle_tool(),
                Some(Action::ToolViewer) if focused => model.open_tool(),
                Some(Action::Focus) => {
                    if model.viewer.is_some() {
                        model.close_tool();
                    } else {
                        model.transcript.borrow_mut().focused = !focused;
                    }
                }
                Some(Action::Escape) => {
                    if model.viewer.is_some() && key.code == KeyCode::Esc {
                        model.close_tool();
                    } else if focused && key.code == KeyCode::Esc {
                        model.transcript.borrow_mut().focused = false;
                    } else {
                        return InputAction::Detach;
                    }
                }
                Some(Action::Copy | Action::CopyEntry) => {
                    let text = if action == Some(Action::Copy) {
                        model.transcript.borrow().copy_selection()
                    } else {
                        model.transcript.borrow().copy_entry()
                    };
                    model.notice = Some(match text {
                        Some(text) if !text.is_empty() => match clipboard::copy(&text) {
                            Ok(()) => format!("Copied {} bytes to clipboard", text.len()),
                            Err(error) => error,
                        },
                        _ => "Nothing selected to copy".into(),
                    });
                }
                Some(action) if focused => {
                    let mut state = model.transcript.borrow_mut();
                    match action {
                        Action::Up => state.scroll(-1),
                        Action::Down => state.scroll(1),
                        Action::PageUp => state.page(-1),
                        Action::PageDown => state.page(1),
                        Action::Home => state.home(),
                        Action::Tail => state.tail(),
                        Action::PreviousTurn => state.user_turn(-1),
                        Action::NextTurn => state.user_turn(1),
                        Action::Search => {
                            state.searching = true;
                            state.query.clear();
                            state.search_changed();
                        }
                        Action::NextMatch | Action::Submit => state.next_match(false),
                        Action::PreviousMatch => state.next_match(true),
                        _ => {}
                    }
                }
                Some(Action::Newline) => insert(model, "\n"),
                Some(Action::Submit) if key.kind == KeyEventKind::Press => {
                    if let Some(action) = sessions::palette_command(model) {
                        return action;
                    }
                    return InputAction::Submit;
                }
                _ if !focused => {
                    model.editor.handle_key(key, width);
                }
                _ => {}
            }
        }
        _ => {}
    }
    InputAction::None
}

pub struct ClientConnection {
    writer: TcpStream,
    receiver: Receiver<Result<Value, String>>,
}

impl Drop for ClientConnection {
    fn drop(&mut self) {
        // The reader owns a cloned descriptor: dropping only the writer would
        // leave the old attachment (and its controller lease) alive forever.
        let _ = self.writer.shutdown(std::net::Shutdown::Both);
    }
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
    let mut model = Model::new(session, mode.to_string(), projection);
    model.cwd = frame["cwd"].as_str().map(str::to_owned);
    model.lifetime = frame["lifetime"].as_str().unwrap_or("unknown").to_string();
    model.attachments.supported = frame["extensions"].as_array().is_some_and(|extensions| {
        extensions
            .iter()
            .any(|extension| extension == attachments::EXTENSION)
    });
    model.inbox.supported = frame["extensions"]
        .as_array()
        .is_some_and(|extensions| extensions.iter().any(|e| e == inbox::EXTENSION));
    if model.inbox.supported && model.projection.view.get("inbox").is_none() {
        return Err("queue extension missing inbox snapshot".into());
    }
    inbox::restore(&mut model);
    Ok(model)
}

pub fn attach_request(target: &str, mode: &str, cursor: &Cursor) -> Value {
    if target == "new" {
        json!({
            "version": 2,
            "command": "create",
            "extensions": ["provider_visibility_v1", attachments::EXTENSION, inbox::EXTENSION, "thread_communication_v1"],
            "mode": mode,
            "cwd": std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")).to_string_lossy()
        })
    } else {
        json!({
            "version": 2,
            "command": "attach",
            "extensions": ["provider_visibility_v1", attachments::EXTENSION, inbox::EXTENSION, "thread_communication_v1"],
            "session_id": target,
            "mode": mode,
            "cursor": cursor.cursor,
            "incarnation": cursor.incarnation,
            "cwd": std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")).to_string_lossy()
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
    draw_content(frame, model);
    presentation::finish(frame, model);
    attachments::draw(frame, model);
    sessions::draw(frame, model);
    inbox::draw(frame, model);
    if let Some(text) = &model.session_detail {
        let area = frame.area();
        let rect = ratatui::layout::Rect::new(
            area.x + area.width / 10,
            area.y + area.height / 8,
            area.width * 4 / 5,
            area.height * 3 / 4,
        );
        frame.render_widget(ratatui::widgets::Clear, rect);
        frame.render_widget(
            Paragraph::new(text.as_str())
                .wrap(ratatui::widgets::Wrap { trim: false })
                .scroll((model.session_detail_scroll, 0))
                .block(
                    Block::default()
                        .borders(Borders::ALL)
                        .title(" Inspection · ↑/↓ scroll · Esc closes "),
                ),
            rect,
        );
    }
}

fn draw_content(frame: &mut ratatui::Frame<'_>, model: &Model) {
    let area = frame.area();
    if model.show_help {
        frame.render_widget(
            Paragraph::new(composer_help(model))
                .wrap(Wrap { trim: false })
                .block(
                    Block::default()
                        .borders(Borders::ALL)
                        .title(" Composer help · F1/Esc close "),
                ),
            area,
        );
        return;
    }
    if let Some((id, _)) = &model.viewer {
        let view = &model.projection.view;
        let call = view["tool_calls"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|call| call["id"] == *id);
        let name = call
            .and_then(|call| call["name"].as_str())
            .unwrap_or("unavailable");
        let viewer_area = ratatui::layout::Rect {
            height: area.height.saturating_sub(1),
            ..area
        };
        let mut state = model.transcript.borrow_mut();
        state.rect = viewer_area.inner(ratatui::layout::Margin::new(1, 1));
        let source_key = (
            model.session_id.clone(),
            model.projection.incarnation.clone(),
            model.projection.head,
            model.projection.snapshot_generation,
        );
        let entries = if state.source_key.as_ref() != Some(&source_key) {
            state.source_key = Some(source_key);
            Some(vec![
                call.map(|call| tools::entry(&model.session_id, call, true))
                    .unwrap_or_else(|| {
                        transcript::Entry::plain(id, "Tool unavailable in current snapshot.", false)
                    }),
            ])
        } else {
            None
        };
        state.update(
            entries,
            state_width(viewer_area.width),
            viewer_area.height.saturating_sub(2) as usize,
        );
        frame.render_widget(
            Paragraph::new(state.visible_lines()).block(
                Block::default()
                    .borders(Borders::ALL)
                    .title(format!(" Tool viewer · {name} · Esc/right-click close "))
                    .title_bottom(state.title()),
            ),
            viewer_area,
        );
        let status_area =
            ratatui::layout::Rect::new(area.x, area.bottom().saturating_sub(1), area.width, 1);
        let connection = match model.connection {
            ConnectionState::Connected => "connected",
            ConnectionState::Resynchronizing => "resynchronizing",
            ConnectionState::Detached => "detached",
        };
        let pending = if model.pending_ask.is_some() {
            " · Awaiting acceptance · draft retained"
        } else {
            ""
        };
        frame.render_widget(
            Paragraph::new(format!(
                "{connection}{pending} · {} · {} · {}",
                model.mode,
                model.turn_state(),
                model
                    .notice
                    .as_deref()
                    .unwrap_or("/ search · y copy entry · c copy selection · PgUp/PgDn scroll")
            )),
            status_area,
        );
        return;
    }
    let editor_layout = model
        .editor
        .layout(area.width.saturating_sub(2).max(1) as usize);
    let editor_height = editor_layout
        .rows
        .len()
        .clamp(1, (area.height as usize / 3).max(1)) as u16;
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(4),
            Constraint::Length(model.attachments.selections.len() as u16),
            Constraint::Length(editor_height + 2),
            Constraint::Length(1),
        ])
        .split(area);

    let transcript_area = presentation::panes(frame, model, chunks[0]);
    let mut state = model.transcript.borrow_mut();
    state.rect = transcript_area.inner(ratatui::layout::Margin::new(1, 1));
    let source_key = (
        model.session_id.clone(),
        model.projection.incarnation.clone(),
        model.projection.head,
        model.projection.snapshot_generation,
    );
    let entries = if state.source_key.as_ref() != Some(&source_key) {
        state.source_key = Some(source_key);
        Some(transcript_entries(model))
    } else {
        None
    };
    state.update(
        entries,
        state_width(transcript_area.width),
        transcript_area.height.saturating_sub(2) as usize,
    );
    let transcript = Paragraph::new(state.visible_lines()).block(
        Block::default()
            .borders(Borders::ALL)
            .title(format!(
                " {} / {} · F4 thinking {} · {} ",
                model.appearance.layout.name(),
                model.appearance.theme.name(),
                if model.thinking_visible {
                    "open"
                } else {
                    "hidden"
                },
                state.title()
            ))
            .title_bottom(if state.focused {
                actions::hints(true)
            } else {
                " Tab transcript · F5 thinking · F7 model/effort ".into()
            }),
    );
    frame.render_widget(transcript, transcript_area);
    drop(state);

    frame.render_widget(Paragraph::new(model.attachments.lines()), chunks[1]);

    let visible = chunks[2].height.saturating_sub(2) as usize;
    let first_row = editor_layout
        .cursor_row
        .saturating_sub(visible.saturating_sub(1));
    let input_lines: Vec<Line<'_>> = editor_layout
        .rows
        .iter()
        .skip(first_row)
        .take(visible)
        .map(|row| {
            Line::from(
                row.cells
                    .iter()
                    .map(|cell| {
                        let style = if cell.selected {
                            Style::default().bg(Color::Blue).fg(Color::White)
                        } else {
                            Style::default()
                        };
                        Span::styled(cell.text.as_ref(), style)
                    })
                    .collect::<Vec<_>>(),
            )
        })
        .collect();
    let prompt_title = if model.inbox.supported {
        format!(" Enter send/queue · {} ", inbox::summary(model))
    } else {
        actions::prompt_title()
    };
    let title = if model.safe_paste {
        " SAFE PASTE · Enter newline · F2 finish (does not send) "
    } else {
        &prompt_title
    };
    let bindings = if model.enhanced_keyboard {
        " Alt/Shift-Enter or Ctrl-J newline · Alt-↑/↓ history "
    } else {
        " Ctrl-J newline · Alt-Enter if mapped · Alt-↑/↓ history "
    };
    let input = Paragraph::new(input_lines).block(
        Block::default()
            .borders(Borders::ALL)
            .title(title)
            .title_bottom(bindings),
    );
    frame.render_widget(input, chunks[2]);
    if visible > 0 && chunks[2].width > 2 && !model.transcript.borrow().focused {
        frame.set_cursor_position((
            chunks[2].x + 1 + (editor_layout.cursor_column as u16).min(chunks[2].width - 3),
            chunks[2].y + 1 + (editor_layout.cursor_row - first_row) as u16,
        ));
    }

    let connection = match model.connection {
        ConnectionState::Connected => "connected",
        ConnectionState::Resynchronizing => "resynchronizing",
        ConnectionState::Detached => "detached",
    };
    let outcome = model.last_outcome.as_deref().unwrap_or("-");
    let status = if let Some(notice) = &model.notice {
        format!(" {notice}")
    } else if model.pending_ask.is_some() {
        " Awaiting acceptance · draft retained · no automatic retry ".to_string()
    } else {
        format!(
            " {} · {} · head {} · {} · outcome {} · {} ",
            model.mode,
            connection,
            model.projection.head,
            model.turn_state(),
            outcome,
            model.session_id
        )
    };
    let lifetime = match model.lifetime.as_str() {
        "embedded" => "embedded · exits with TUI",
        "long_lived" => "long-lived server",
        _ => "server lifetime unknown",
    };
    let status = format!(" {lifetime} ·{status}");
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            status,
            Style::default().bg(Color::DarkGray).fg(Color::White),
        ))),
        chunks[3],
    );
}

fn composer_help(model: &Model) -> Vec<Line<'static>> {
    let mut lines = vec![
        Line::from("Enter sends when idle; rejected/uncertain sends retain the draft."),
        Line::from("Prompt: arrows move; Shift selects; Ctrl-A selects all."),
        Line::from("Ctrl/Alt arrows/delete: words. Home/End: line; Ctrl: whole draft."),
        Line::from("Alt-Up/Down prompt history restores the original draft at newest."),
        Line::from("F2 BEFORE unframed paste: commands disabled, Enter inserts newline."),
        Line::from("F2 finishes safe paste without sending. Draft limit 64 KiB."),
        Line::from("Tabs/line breaks retained; other control bytes removed."),
        Line::from(if model.enhanced_keyboard {
            "Enhanced keys: modified Enter available."
        } else {
            "Legacy keys: Ctrl-J fallback; Alt-Enter depends on terminal mapping."
        }),
    ];
    lines.extend(actions::help());
    lines.push(Line::from(
        "Mouse wheel/drag: scroll/select; native selection: terminal modifier.",
    ));
    lines
}

fn state_width(width: u16) -> usize {
    width.saturating_sub(2).max(1) as usize
}

fn transcript_entries(model: &Model) -> Vec<transcript::Entry> {
    use transcript::Entry;
    let mut entries = Vec::new();
    let view = &model.projection.view;
    let canonical_calls = tools::calls(view);
    let summary_turns = presentation::summary_turns(model);
    let mut rendered_tools = HashSet::new();
    if let Some(messages) = view["messages"].as_array() {
        for (index, message) in messages.iter().enumerate() {
            let id = format!("{}:message:{index}", model.session_id);
            match message["role"].as_str() {
                Some("user") => {
                    let text = message["text"].as_str().unwrap_or_default();
                    let agent = message["agent_source"].is_object();
                    // Keep literal tabs in the source mapping; expand only visual cells.
                    let lines = text
                        .split('\n')
                        .enumerate()
                        .map(|(i, line)| {
                            Line::from(vec![
                                Span::styled(
                                    if i == 0 {
                                        if agent { "agent " } else { "you " }
                                    } else {
                                        "    "
                                    },
                                    Style::default()
                                        .fg(Color::Cyan)
                                        .add_modifier(Modifier::BOLD),
                                ),
                                Span::raw(line.to_owned()),
                            ])
                        })
                        .collect();
                    entries.push(Entry::rendered(id.clone(), lines, true, false));
                    if let Some(attachments) = message["attachments"].as_array() {
                        for (attachment_index, metadata) in attachments.iter().take(4).enumerate() {
                            entries.push(Entry::plain(
                                &format!("{id}:attachment:{attachment_index}"),
                                &attachments::history_label(metadata),
                                false,
                            ));
                        }
                    }
                    if let Some(thinking) =
                        presentation::inline_thinking(model, &id, summary_turns.contains(&index))
                    {
                        entries.push(thinking);
                    }
                }
                Some("assistant") => {
                    if message["interrupted"] == true {
                        entries.push(Entry::plain(
                            &format!("{id}:interrupted"),
                            "Interrupted · partial public response",
                            false,
                        ));
                    }
                    if let Some(parts) = message["public_content"]
                        .as_array()
                        .filter(|parts| !parts.is_empty())
                    {
                        let mut output: Vec<(u64, u64, bool, &Value)> = parts
                            .iter()
                            .map(|part| {
                                (
                                    part["output_index"].as_u64().unwrap_or(0),
                                    part["part_index"].as_u64().unwrap_or(0),
                                    false,
                                    part,
                                )
                            })
                            .collect();
                        output.extend(message["tool_calls"].as_array().into_iter().flatten().map(
                            |call| {
                                (
                                    call["output_index"].as_u64().unwrap_or(u64::MAX),
                                    0,
                                    true,
                                    call,
                                )
                            },
                        ));
                        output.sort_by_key(|(index, part, _, _)| (*index, *part));
                        for (_, _, is_tool, item) in output {
                            if is_tool {
                                let call_id = item["id"].as_str().unwrap_or("?");
                                if let Some(call) = canonical_calls.get(call_id) {
                                    entries.push(tools::entry(
                                        &model.session_id,
                                        call,
                                        model.expanded_tools.contains(call_id),
                                    ));
                                    rendered_tools.insert(call_id.to_owned());
                                }
                            } else {
                                entries.extend(presentation::public_entries(
                                    model,
                                    &id,
                                    std::slice::from_ref(item),
                                    false,
                                ));
                            }
                        }
                        continue;
                    } else if let Some(text) = message["text"].as_str()
                        && !text.is_empty()
                    {
                        entries.push(Entry::rendered(
                            id,
                            assistant_markdown_lines(text),
                            false,
                            false,
                        ));
                    }
                    if let Some(calls) = message["tool_calls"].as_array() {
                        for call in calls {
                            let id = call["id"].as_str().unwrap_or("?");
                            if let Some(call) = canonical_calls.get(id) {
                                entries.push(tools::entry(
                                    &model.session_id,
                                    call,
                                    model.expanded_tools.contains(id),
                                ));
                                rendered_tools.insert(id.to_owned());
                            }
                        }
                    }
                }
                Some("tool") => {
                    let id = message["call_id"].as_str().unwrap_or("?");
                    if rendered_tools.insert(id.to_owned())
                        && let Some(call) = canonical_calls.get(id)
                    {
                        entries.push(tools::entry(
                            &model.session_id,
                            call,
                            model.expanded_tools.contains(id),
                        ));
                    }
                }
                _ => {}
            }
        }
    }
    if let Some(parts) = view["provider_view"]["streaming"]["public_content"].as_array() {
        let id = format!(
            "{}:message:{}",
            model.session_id,
            view["messages"].as_array().map_or(0, Vec::len)
        );
        entries.extend(presentation::public_entries(model, &id, parts, true));
    }
    if let Some(deltas) = view["content_deltas"].as_object() {
        for (id, text) in deltas {
            let typed = &view["provider_view"]["streaming"];
            if typed["id"].as_str() == Some(id.as_str())
                && typed["public_content"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|part| part["kind"] == "final_answer")
            {
                continue;
            }
            if let Some(text) = text.as_str() {
                let mut entry = Entry::rendered(
                    format!("{}:stream:{id}", model.session_id),
                    assistant_markdown_lines(text),
                    false,
                    true,
                );
                entry.final_id = Some(format!(
                    "{}:message:{}",
                    model.session_id,
                    view["messages"].as_array().map_or(0, Vec::len)
                ));
                entries.push(entry);
            }
        }
    }
    if entries.is_empty() {
        entries.push(Entry::plain(
            &format!("{}:empty", model.session_id),
            "No messages yet.",
            false,
        ));
    }
    entries
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

fn assistant_markdown_lines(text: &str) -> Vec<Line<'static>> {
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
    if let Some(provider) = object.get("provider_view") {
        validate_provider_view(provider)?;
    }
    if let Some(inbox) = object.get("inbox") {
        inbox::validate(inbox, session["id"].as_str().unwrap())?;
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

fn validate_public_parts(value: &Value) -> Result<(), String> {
    let parts = value.as_array().ok_or("invalid public content")?;
    for part in parts {
        if !matches!(
            part["kind"].as_str(),
            Some("reasoning_summary" | "commentary" | "final_answer")
        ) || !part["item_id"].is_string()
            || !part["text"].is_string()
            || !part["output_index"].is_u64()
            || !part["part_index"].is_u64()
            || part.as_object().is_none_or(|object| object.len() != 5)
        {
            return Err("invalid public content part".into());
        }
    }
    Ok(())
}
fn validate_provider_view(value: &Value) -> Result<(), String> {
    if value["extension"] != "provider_visibility_v1" || !value["catalog"].is_array() {
        return Err("unsupported provider view extension".into());
    }
    if !value["streaming"].is_null() {
        validate_public_parts(&value["streaming"]["public_content"])?;
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
    if let Some(parts) = message.get("public_content") {
        validate_public_parts(parts)?;
    }
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
        Some("set_inbox") => {
            inbox::validate(&op["inbox"], view["session"]["id"].as_str().unwrap_or(""))?;
            view["inbox"] = op["inbox"].clone();
            Ok(())
        }
        Some("append_message") => append_message(view, op),
        Some("set_tool_status") => set_tool_status(view, op),
        Some("set_turn_state") => set_turn_state(view, op),
        Some("set_usage") => set_usage(view, op),
        Some("set_provider_view") => {
            validate_provider_view(&op["provider_view"])?;
            view["provider_view"] = op["provider_view"].clone();
            Ok(())
        }
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
    fn delayed_acceptance_is_visible_and_late_reply_clears_only_the_submitted_draft() {
        let mut model = fixture_model("idle");
        model.editor.insert("waiting draft");
        model.prepare_submit().unwrap();
        model.pending_ask.as_mut().unwrap().1 = Instant::now() - Duration::from_secs(6);
        assert!(model.check_acceptance_timeout());
        assert!(!model.check_acceptance_timeout());
        assert!(
            render_frame(&model, 80, 24)
                .unwrap()
                .lines()
                .last()
                .unwrap()
                .contains("Acceptance uncertain")
        );
        assert_eq!(model.editor.text(), "waiting draft");
        assert!(model.prepare_submit().is_none());
        model.snapshot_reply(); // a snapshot is not acceptance of the ask
        assert_eq!(model.editor.text(), "waiting draft");
        model.command_reply(None);
        assert_eq!(model.editor.text(), "");
    }

    #[test]
    fn acceptance_notice_is_visible_even_when_transcript_is_full() {
        let mut model = fixture_model("idle");
        model.projection.view["messages"][0]["text"] = json!("long text ".repeat(1_000));
        model.editor.insert("next prompt");
        model.prepare_submit().unwrap();
        let frame = render_frame(&model, 80, 24).unwrap();
        assert!(
            frame
                .lines()
                .last()
                .unwrap()
                .contains("Awaiting acceptance")
        );
        model.mark_disconnected("socket lost");
        let frame = render_frame(&model, 80, 24).unwrap();
        assert!(
            frame
                .lines()
                .last()
                .unwrap()
                .contains("Acceptance uncertain")
        );
    }

    #[test]
    fn composer_frames_cover_empty_wrapped_selected_and_tall_drafts() {
        use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/goldens");
        for name in ["empty", "wrapped", "selected", "tall"] {
            let mut model = fixture_model("idle");
            match name {
                "wrapped" => {
                    model
                        .editor
                        .insert(&"Unicode e\u{301} 👩‍💻 中 with spaces ".repeat(4));
                }
                "selected" => {
                    model.editor.insert("replace this selection");
                    model.editor.handle_key(
                        KeyEvent::new(KeyCode::Left, KeyModifiers::SHIFT | KeyModifiers::CONTROL),
                        78,
                    );
                    let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
                    terminal.draw(|frame| draw_model(frame, &model)).unwrap();
                    assert!(
                        terminal
                            .backend()
                            .buffer()
                            .content
                            .iter()
                            .any(|cell| cell.bg == model.appearance.theme.tokens().selection)
                    );
                }
                "tall" => {
                    model.editor.insert(&"multiline draft row\n".repeat(20));
                }
                _ => {}
            }
            let actual = render_frame(&model, 80, 24).unwrap();
            let path = root.join(format!("composer-{name}.txt"));
            if std::env::var_os("ELARA_UPDATE_GOLDENS").is_some() {
                fs::write(&path, &actual).unwrap();
            }
            assert_eq!(actual, fs::read_to_string(path).unwrap(), "composer {name}");
        }
    }

    #[test]
    fn paste_and_safe_fallback_never_submit_or_interrupt() {
        use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};
        let mut model = fixture_model("idle");
        let key = |code, modifiers| Event::Key(KeyEvent::new(code, modifiers));
        assert_eq!(
            handle_input(&mut model, Event::Paste("a\r\nb\t👩‍💻\u{1b}[31m".into()), 78),
            InputAction::None
        );
        assert_eq!(model.editor.text(), "a\nb\t👩‍💻[31m");
        handle_input(&mut model, key(KeyCode::F(2), KeyModifiers::NONE), 78);
        assert_eq!(
            handle_input(&mut model, key(KeyCode::Enter, KeyModifiers::NONE), 78),
            InputAction::None
        );
        assert_eq!(
            handle_input(
                &mut model,
                key(KeyCode::Char('x'), KeyModifiers::CONTROL),
                78
            ),
            InputAction::None
        );
        assert_eq!(
            handle_input(&mut model, key(KeyCode::Esc, KeyModifiers::NONE), 78),
            InputAction::None
        );
        handle_input(
            &mut model,
            key(KeyCode::Char('j'), KeyModifiers::CONTROL),
            78,
        );
        assert!(model.editor.text().ends_with("\n\n"));
        handle_input(&mut model, key(KeyCode::F(2), KeyModifiers::NONE), 78);
        for modifiers in [KeyModifiers::ALT, KeyModifiers::SHIFT] {
            assert_eq!(
                handle_input(&mut model, key(KeyCode::Enter, modifiers), 78),
                InputAction::None
            );
        }
        assert_eq!(
            handle_input(&mut model, key(KeyCode::Enter, KeyModifiers::NONE), 78),
            InputAction::Submit
        );
    }

    #[test]
    fn snapshots_streaming_interruptions_and_resize_preserve_selection_and_history_draft() {
        use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
        let mut model = fixture_model("idle");
        model.editor.insert("local\ndraft");
        model
            .editor
            .handle_key(KeyEvent::new(KeyCode::Left, KeyModifiers::SHIFT), 78);
        let cursor = model.editor.cursor();
        let selection = model.editor.selection();
        model.editor.history_previous();
        let frame = json!({"session_id": model.session_id, "incarnation": "inc-demo", "head": 6,
            "snapshot": model.projection.view});
        model.install_snapshot_frame(&frame).unwrap();
        let patch = json!({"incarnation": "inc-demo", "seq": 7, "ops": [{"op":"set_turn_state", "turn":{"state":"idle", "outcome":{"kind":"interrupted"}}}]});
        assert_eq!(model.apply_patch_frame(&patch).unwrap(), Ingest::Applied);
        model.editor.history_next();
        assert_eq!(model.editor.text(), "local\ndraft");
        assert_eq!(model.editor.cursor(), cursor);
        assert_eq!(model.editor.selection(), selection);
        for (width, height) in [(80, 24), (120, 40), (180, 45)] {
            render_frame(&model, width, height).unwrap();
            assert_eq!(model.editor.cursor(), cursor);
            assert_eq!(model.editor.selection(), selection);
        }
    }

    #[test]
    fn tall_editor_keeps_cursor_in_bounds_and_transcript_at_80_columns() {
        let mut model = fixture_model("idle");
        model
            .editor
            .insert(&("a long wrapped line ".repeat(10) + "\n").repeat(12));
        let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
        terminal.draw(|frame| draw_model(frame, &model)).unwrap();
        let cursor = terminal.get_cursor_position().unwrap();
        assert!(cursor.x > 0 && cursor.x < 79 && cursor.y > 0 && cursor.y < 23);
        let rendered = render_frame(&model, 80, 24).unwrap();
        assert!(rendered.contains("you inspect the build"));
        assert!(rendered.contains("F2 safe paste"));
    }

    #[test]
    fn agent_provenance_is_not_rendered_as_the_owner_in_any_layout() {
        for layout in appearance::ViewLayout::ALL {
            let mut model = fixture_model("idle");
            model.appearance.layout = *layout;
            model.projection.view["messages"] = json!([
                {"role":"user","text":"child evidence","agent_source":{"sender":"child","recipient":"parent","message_id":"report"}},
                {"role":"user","text":"owner correction"}
            ]);
            let rendered = render_frame(&model, 80, 24).unwrap();
            assert!(rendered.contains("agent child evidence"), "{rendered}");
            assert!(!rendered.contains("you child evidence"));
            assert!(rendered.contains("you owner correction"));
        }
    }

    #[test]
    fn submitted_editor_waits_for_its_own_acceptance() {
        let mut model = fixture_model("idle");
        model.editor.insert("first\nsecond 👩‍💻");
        model.track_interrupt();
        let request = model.prepare_submit().unwrap();
        assert_eq!(request["prompt"], "first\nsecond 👩‍💻");
        model.command_reply(None); // interrupt reply, not ask acceptance
        assert_eq!(model.editor.text(), "first\nsecond 👩‍💻");
        model.command_reply(None);
        assert_eq!(model.editor.text(), "");
    }

    #[test]
    fn rejection_and_newer_draft_survive_replies() {
        let mut model = fixture_model("idle");
        model.editor.insert("draft");
        model.prepare_submit().unwrap();
        assert!(model.prepare_submit().is_none());
        model.command_reply(Some("busy"));
        assert_eq!(model.editor.text(), "draft");
        model.prepare_submit().unwrap();
        model.editor.insert(" changed while waiting");
        model.command_reply(None);
        assert_eq!(model.editor.text(), "draft changed while waiting");
        model.prepare_submit().unwrap();
        model.mark_disconnected("lost socket");
        assert!(model.prepare_submit().is_none());
        assert!(model.notice.as_deref().unwrap().contains("uncertain"));
        assert_eq!(model.editor.text(), "draft changed while waiting");
    }

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
    fn user_transcript_preserves_multiline_literal_text_and_tab_stops() {
        let mut model = fixture_model("idle");
        let prompt = "first\n\n  **literal**\ne\u{301}\t👩‍💻\tend\n";
        model.projection.view["messages"] = json!([{"role": "user", "text": prompt}]);
        let frame = render_frame(&model, 80, 24).unwrap();
        let rows = frame.lines().collect::<Vec<_>>();
        let first = rows
            .iter()
            .position(|row| row.contains("you first"))
            .unwrap();
        assert!(rows[first + 1].trim_matches(['│', ' ']).is_empty());
        assert!(rows[first + 2].contains("│      **literal**"));
        assert!(rows[first + 3].contains("│    e\u{301}   👩‍💻  "));
        assert!(rows[first + 3].contains("end"));
        assert!(rows[first + 4].trim_matches(['│', ' ']).is_empty());
        assert_eq!(model.projection.view["messages"][0]["text"], prompt);
    }

    #[test]
    fn typed_answer_supersedes_only_its_matching_legacy_live_delta() {
        let mut model = fixture_model("streaming");
        model.projection.view["content_deltas"] =
            json!({"assistant-1":"UNIQUE_ANSWER", "other":"OTHER_STREAM"});
        model.projection.view["provider_view"] = json!({"streaming":{"id":"assistant-1","public_content":[{"kind":"final_answer","item_id":"m","output_index":0,"part_index":0,"text":"UNIQUE_ANSWER"}]}});
        let entries = transcript_entries(&model);
        assert_eq!(
            entries
                .iter()
                .filter(|entry| entry.text.contains("UNIQUE_ANSWER"))
                .count(),
            1
        );
        assert!(
            entries
                .iter()
                .any(|entry| entry.text.contains("OTHER_STREAM"))
        );
        model.projection.view["provider_view"]["streaming"]["public_content"][0]["kind"] =
            json!("reasoning_summary");
        model.projection.view["provider_view"]["streaming"]["public_content"][0]["text"] =
            json!("Reasoning only");
        assert!(
            transcript_entries(&model)
                .iter()
                .any(|entry| entry.text == "UNIQUE_ANSWER")
        );
    }

    #[test]
    fn assistant_markdown_renders_blocks_and_inline_styles() {
        let markdown = "# Heading\n\n**Bold** and *italic* with `code`.\n\n- [x] done\n\n> quote\n\n[docs](https://example.com)\n\n| A | B |\n| - | - |\n| 1 | 2 |";
        let lines = assistant_markdown_lines(markdown);
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
        let lines = assistant_markdown_lines("First paragraph\n\nSecond paragraph");

        assert_eq!(lines[0].spans[0].content, "ai  ");
        assert!(
            lines
                .iter()
                .skip(1)
                .all(|line| line.spans[0].content == "    ")
        );
        let entry = transcript::Entry::rendered("stream".into(), lines, false, true);
        let mut state = transcript::Transcript::default();
        state.layout(vec![entry], 80, 24);
        assert_eq!(
            state
                .visible_lines()
                .last()
                .unwrap()
                .spans
                .last()
                .unwrap()
                .content,
            "▌"
        );
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

#[cfg(test)]
mod transcript_input_tests {
    use super::*;
    use crossterm::event::{
        Event, KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
    };
    fn key(model: &mut Model, code: KeyCode) -> InputAction {
        handle_input(
            model,
            Event::Key(KeyEvent::new(code, KeyModifiers::NONE)),
            78,
        )
    }
    #[test]
    fn focus_search_and_safe_paste_preserve_local_draft() {
        let mut model = fixture_model("idle");
        model.editor.insert("unsent draft");
        render_frame(&model, 80, 24).unwrap();
        assert_eq!(key(&mut model, KeyCode::Tab), InputAction::None);
        key(&mut model, KeyCode::Home);
        key(&mut model, KeyCode::Char('/'));
        for c in "INSPECT".chars() {
            key(&mut model, KeyCode::Char(c));
        }
        assert_eq!(model.transcript.borrow().matches.len(), 1);
        assert_eq!(key(&mut model, KeyCode::Enter), InputAction::None);
        key(&mut model, KeyCode::Esc);
        assert!(model.transcript.borrow().focused);
        key(&mut model, KeyCode::F(2));
        key(&mut model, KeyCode::Tab);
        key(&mut model, KeyCode::Enter);
        key(&mut model, KeyCode::F(2));
        assert_eq!(model.editor.text(), "unsent draft\t\n");
        key(&mut model, KeyCode::Tab);
        assert!(!model.transcript.borrow().focused);
        assert_eq!(key(&mut model, KeyCode::Enter), InputAction::Submit);
    }
    #[test]
    fn mouse_drag_stops_follow_and_copy_mapping_excludes_speaker() {
        let mut model = fixture_model("idle");
        render_frame(&model, 80, 24).unwrap();
        for (kind, column) in [
            (MouseEventKind::Down(MouseButton::Left), 1),
            (MouseEventKind::Drag(MouseButton::Left), 11),
        ] {
            handle_input(
                &mut model,
                Event::Mouse(MouseEvent {
                    kind,
                    column,
                    row: 1,
                    modifiers: KeyModifiers::NONE,
                }),
                78,
            );
        }
        let state = model.transcript.borrow();
        assert!(!state.follow);
        assert!(state.focused);
        assert_eq!(state.copy_selection().as_deref(), Some("inspect"));
    }
    fn mouse(model: &mut Model, kind: MouseEventKind, column: u16, row: u16) {
        handle_input(
            model,
            Event::Mouse(MouseEvent {
                kind,
                column,
                row,
                modifiers: KeyModifiers::NONE,
            }),
            78,
        );
    }
    #[test]
    fn reverse_mouse_drag_includes_both_cells_and_unicode_graphemes() {
        for (text, start, end, expected) in [
            ("abc", 7, 5, "abc"),
            ("abc", 6, 5, "ab"),
            ("a界é", 8, 6, "界é"),
            ("a界é", 6, 8, "界é"),
        ] {
            let mut model = fixture_model("idle");
            model.projection.view["messages"][0]["text"] = json!(text);
            render_frame(&model, 80, 24).unwrap();
            mouse(
                &mut model,
                MouseEventKind::Down(MouseButton::Left),
                start,
                1,
            );
            mouse(&mut model, MouseEventKind::Drag(MouseButton::Left), end, 1);
            assert_eq!(
                model.transcript.borrow().copy_selection().as_deref(),
                Some(expected)
            );
        }
    }
    #[test]
    fn outside_wheel_preserves_prompt_focus_and_submission() {
        let mut model = fixture_model("idle");
        render_frame(&model, 80, 24).unwrap();
        for kind in [MouseEventKind::ScrollUp, MouseEventKind::ScrollDown] {
            mouse(&mut model, kind, 1, 23);
            assert!(!model.transcript.borrow().focused);
            assert!(model.transcript.borrow().follow);
        }
        key(&mut model, KeyCode::Char('a'));
        assert_eq!(model.editor.text(), "a");
        assert_eq!(key(&mut model, KeyCode::Enter), InputAction::Submit);
    }
    #[test]
    fn mouse_release_or_outside_down_ends_selection_drag() {
        for finish in [
            MouseEventKind::Up(MouseButton::Left),
            MouseEventKind::Down(MouseButton::Left),
        ] {
            let mut model = fixture_model("idle");
            model.projection.view["messages"][0]["text"] = json!("abc\n".repeat(60));
            render_frame(&model, 80, 24).unwrap();
            key(&mut model, KeyCode::Tab);
            key(&mut model, KeyCode::Home);
            mouse(&mut model, MouseEventKind::Down(MouseButton::Left), 5, 1);
            mouse(&mut model, MouseEventKind::Drag(MouseButton::Left), 6, 1);
            mouse(&mut model, finish, 1, 23);
            let before = model.transcript.borrow().copy_selection();
            let top = model.transcript.borrow().top;
            mouse(&mut model, MouseEventKind::Drag(MouseButton::Left), 1, 23);
            assert_eq!(model.transcript.borrow().copy_selection(), before);
            assert_eq!(model.transcript.borrow().top, top);
            mouse(&mut model, MouseEventKind::Down(MouseButton::Left), 5, 1);
            mouse(&mut model, MouseEventKind::Drag(MouseButton::Left), 1, 23);
            assert!(model.transcript.borrow().top > top);
        }
    }
    #[test]
    fn control_x_interrupts_search_unless_safe_paste() {
        let mut model = fixture_model("idle");
        render_frame(&model, 80, 24).unwrap();
        key(&mut model, KeyCode::Tab);
        key(&mut model, KeyCode::Char('/'));
        let control_x = Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::CONTROL));
        assert_eq!(
            handle_input(&mut model, control_x.clone(), 78),
            InputAction::Interrupt
        );
        key(&mut model, KeyCode::F(2));
        assert_eq!(handle_input(&mut model, control_x, 78), InputAction::None);
    }
    #[test]
    fn help_exposes_transcript_bindings_in_standard_window() {
        let mut model = fixture_model("idle");
        model.show_help = true;
        let frame = render_frame(&model, 80, 24).unwrap();
        assert!(frame.contains("/ search"));
        assert!(frame.contains("y copy entry"));
    }
    #[test]
    fn tool_entries_use_stable_call_ids_and_retain_outcome_content() {
        let mut model = fixture_model("idle");
        model.projection.view["messages"].as_array_mut().unwrap().push(json!({"role":"tool","call_id":"stable","name":"bash","outcome":{"ok":"a\tb\nresult"}}));
        model.projection.view["tool_calls"] = json!([{"id":"stable","name":"bash","args":{"ok":{"command":"echo result"}},"status":"succeeded","outcome":{"ok":"a\tb\nresult"}}]);
        let entries = transcript_entries(&model);
        let last = entries.last().unwrap();
        assert!(last.id.ends_with(":tool:stable"));
        model.expanded_tools.insert("stable".into());
        assert!(
            transcript_entries(&model)
                .last()
                .unwrap()
                .text
                .contains("a\tb\nresult")
        );
    }
    #[test]
    fn pasted_search_query_does_not_edit_draft() {
        let mut model = fixture_model("idle");
        model.editor.insert("draft");
        render_frame(&model, 80, 24).unwrap();
        key(&mut model, KeyCode::Tab);
        key(&mut model, KeyCode::Char('/'));
        handle_input(&mut model, Event::Paste("INSPECT\r\n\t\u{1b}".into()), 78);
        assert_eq!(model.editor.text(), "draft");
        assert_eq!(model.transcript.borrow().query, "INSPECT  ");
    }
    #[test]
    fn control_c_detaches_from_search_unless_safe_paste() {
        let mut model = fixture_model("idle");
        render_frame(&model, 80, 24).unwrap();
        key(&mut model, KeyCode::Tab);
        key(&mut model, KeyCode::Char('/'));
        let control_c = Event::Key(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL));
        assert_eq!(
            handle_input(&mut model, control_c.clone(), 78),
            InputAction::Detach
        );
        key(&mut model, KeyCode::F(2));
        assert_eq!(handle_input(&mut model, control_c, 78), InputAction::None);
    }
    #[test]
    fn composer_navigation_and_height_changes_reuse_transcript_cache() {
        let mut model = fixture_model("markdown");
        render_frame(&model, 80, 24).unwrap();
        let builds = model.transcript.borrow().layout_rebuilds;
        model.editor.insert("different\ndraft");
        render_frame(&model, 80, 30).unwrap();
        key(&mut model, KeyCode::Tab);
        key(&mut model, KeyCode::Home);
        render_frame(&model, 80, 30).unwrap();
        assert_eq!(model.transcript.borrow().layout_rebuilds, builds);
        render_frame(&model, 90, 30).unwrap();
        assert_eq!(model.transcript.borrow().layout_rebuilds, builds + 1);
        let mut snapshot = model.projection.view.clone();
        snapshot["messages"][0]["text"] = json!("replacement");
        model
            .projection
            .install_snapshot(
                snapshot,
                model.projection.incarnation.clone(),
                model.projection.head,
            )
            .unwrap();
        let frame = render_frame(&model, 90, 30).unwrap();
        assert_eq!(model.transcript.borrow().layout_rebuilds, builds + 2);
        assert!(frame.contains("replacement"));
    }
}

#[cfg(test)]
mod tool_inspection_tests {
    use super::*;
    use crossterm::event::{
        Event, KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
    };
    fn key(model: &mut Model, code: KeyCode) {
        handle_input(
            model,
            Event::Key(KeyEvent::new(code, KeyModifiers::NONE)),
            78,
        );
    }
    fn model() -> Model {
        let mut model = fixture_model("idle");
        let call = json!({"id":"inspect", "name":"read", "args":{"ok":{"path":"inspection.txt"}}});
        model.projection.view["messages"] = json!([
            {"role":"user","text":"inspect"},
            {"role":"assistant","text":null,"tool_calls":[call]},
        ]);
        let mut call = call;
        call["status"] = json!("running");
        call["outcome"] = Value::Null;
        model.projection.view["tool_calls"] = json!([call]);
        render_frame(&model, 80, 24).unwrap();
        key(&mut model, KeyCode::Tab);
        key(&mut model, KeyCode::Home);
        key(&mut model, KeyCode::Down);
        model
    }
    fn finish(model: &mut Model) {
        let output = "α\tretained\n".repeat(100) + "HIDDEN_MARKER";
        let frame = json!({"incarnation":model.projection.incarnation, "seq":model.projection.head+1,
            "ops":[{"op":"set_tool_status","id":"inspect","status":"succeeded","outcome":{"ok":output}}]});
        assert_eq!(model.apply_patch_frame(&frame).unwrap(), Ingest::Applied);
    }
    #[test]
    fn viewer_reports_connection_and_pending_acceptance() {
        let mut model = model();
        key(&mut model, KeyCode::Char('f'));
        for (state, label) in [
            (ConnectionState::Resynchronizing, "resynchronizing"),
            (ConnectionState::Detached, "detached"),
        ] {
            model.connection = state;
            model.notice = Some("notice".into());
            assert!(render_frame(&model, 120, 24).unwrap().contains(label));
        }
        model.pending_ask = Some((0, Instant::now()));
        assert!(
            render_frame(&model, 120, 24)
                .unwrap()
                .contains("Awaiting acceptance")
        );
    }
    #[test]
    fn safe_paste_closes_viewer_before_editing_draft() {
        let mut model = model();
        model.editor.insert("draft ");
        key(&mut model, KeyCode::Char('f'));
        key(&mut model, KeyCode::F(2));
        assert!(model.viewer.is_none());
        assert!(render_frame(&model, 80, 24).unwrap().contains("SAFE PASTE"));
        handle_input(&mut model, Event::Paste("pasted".into()), 78);
        key(&mut model, KeyCode::F(2));
        assert_eq!(model.editor.text(), "draft pasted");
        model.transcript.borrow_mut().selected = Some(format!("{}:tool:inspect", model.session_id));
        model.open_tool();
        model.safe_paste = true;
        handle_input(&mut model, Event::Paste(" visible".into()), 78);
        assert!(model.viewer.is_none());
        assert!(
            render_frame(&model, 80, 24)
                .unwrap()
                .contains("draft pasted visible")
        );
    }
    #[test]
    fn non_tool_right_click_preserves_saved_selection_and_focus() {
        let mut model = model();
        let selected = model.transcript.borrow().selected.clone();
        key(&mut model, KeyCode::Home);
        render_frame(&model, 80, 24).unwrap();
        model.transcript.borrow_mut().selected = selected.clone();
        model.transcript.borrow_mut().focused = false;
        handle_input(
            &mut model,
            Event::Mouse(MouseEvent {
                kind: MouseEventKind::Down(MouseButton::Right),
                column: 6,
                row: 1,
                modifiers: KeyModifiers::NONE,
            }),
            78,
        );
        assert_eq!(model.transcript.borrow().selected, selected);
        assert!(!model.transcript.borrow().focused);
        assert!(model.viewer.is_none());
    }
    #[test]
    fn tool_lifecycle_preserves_section_relative_selection_and_drag() {
        for (fullscreen, selected_text) in [
            (false, "inspection.txt"),
            (true, "inspection.txt"),
            (false, "α\tretained"),
            (true, "α\tretained"),
        ] {
            let mut model = model();
            if selected_text != "inspection.txt" {
                finish(&mut model);
            }
            key(
                &mut model,
                KeyCode::Char(if fullscreen { 'f' } else { ' ' }),
            );
            render_frame(&model, 80, 24).unwrap();
            let text = model.transcript.borrow().copy_entry().unwrap();
            let start = if selected_text == "inspection.txt" {
                text.rfind(selected_text)
            } else {
                text.find(selected_text)
            }
            .unwrap();
            let id = model.transcript.borrow().selected.clone().unwrap();
            let a = transcript::Point {
                id: id.clone(),
                byte: start,
            };
            let b = transcript::Point {
                id,
                byte: start + selected_text.len(),
            };
            {
                let mut state = model.transcript.borrow_mut();
                state.selection = Some((a.clone(), b.clone()));
                state.drag_anchor = state.selection.clone();
                state.anchor = Some(a);
                state.follow = false;
            }
            let frame = json!({"incarnation":model.projection.incarnation,"seq":model.projection.head+1,"ops":[{"op":"set_tool_status","id":"inspect","status":"succeeded","outcome":{"ok": "α\tretained\n".repeat(100) + "HIDDEN_MARKER\n[truncated 400 bytes]"}}]});
            model.apply_patch_frame(&frame).unwrap();
            render_frame(&model, 80, 24).unwrap();
            let state = model.transcript.borrow();
            assert_eq!(state.copy_selection().as_deref(), Some(selected_text));
            assert_eq!(state.drag_anchor, state.selection);
        }
    }
    #[test]
    fn transcript_uses_canonical_lifecycle_status_and_retained_result() {
        let mut model = model();
        assert!(
            render_frame(&model, 80, 24)
                .unwrap()
                .contains("read · running")
        );
        for (status, outcome) in [
            ("succeeded", json!({"ok":"completed result"})),
            ("failed", json!({"error":"cancelled"})),
            (
                "indeterminate",
                json!({"indeterminate":"completion unknown"}),
            ),
        ] {
            let frame = json!({"incarnation":model.projection.incarnation, "seq":model.projection.head+1,
                "ops":[{"op":"set_tool_status","id":"inspect","status":status,"outcome":outcome}]});
            assert_eq!(model.apply_patch_frame(&frame).unwrap(), Ingest::Applied);
            let rendered = render_frame(&model, 80, 24).unwrap();
            assert!(rendered.contains(&format!("read · {status}")));
            assert!(rendered.contains(crate::outcome(&outcome).1));
        }
    }
    #[test]
    fn fold_and_viewer_survive_completion_resnapshot_and_restore_transcript_position() {
        let mut model = model();
        model.editor.insert("unsent draft");
        key(&mut model, KeyCode::Char(' '));
        render_frame(&model, 80, 24).unwrap();
        let anchor = model.transcript.borrow().anchor.clone();
        key(&mut model, KeyCode::Char('f'));
        finish(&mut model);
        assert!(
            render_frame(&model, 80, 24)
                .unwrap()
                .contains("Tool viewer · read")
        );
        assert!(
            model
                .transcript
                .borrow()
                .copy_entry()
                .unwrap()
                .contains("HIDDEN_MARKER")
        );
        key(&mut model, KeyCode::Char('/'));
        handle_input(&mut model, Event::Paste("HIDDEN_MARKER".into()), 78);
        assert_eq!(model.transcript.borrow().matches.len(), 1);
        let snapshot = model.projection.view.clone();
        model
            .projection
            .install_snapshot(
                snapshot,
                model.projection.incarnation.clone(),
                model.projection.head,
            )
            .unwrap();
        assert!(
            render_frame(&model, 40, 12)
                .unwrap()
                .contains("HIDDEN_MARKER")
        );
        key(&mut model, KeyCode::Esc);
        key(&mut model, KeyCode::Esc);
        render_frame(&model, 80, 24).unwrap();
        assert!(model.viewer.is_none());
        assert_eq!(model.transcript.borrow().anchor, anchor);
        assert!(model.expanded_tools.contains("inspect"));
        assert_eq!(model.editor.text(), "unsent draft");
    }
    #[test]
    fn mouse_gutter_toggles_and_right_click_enters_and_leaves_viewer() {
        let mut model = model();
        key(&mut model, KeyCode::Home);
        render_frame(&model, 80, 24).unwrap();
        let mouse = |model: &mut Model, button, column, row| {
            handle_input(
                model,
                Event::Mouse(MouseEvent {
                    kind: MouseEventKind::Down(button),
                    column,
                    row,
                    modifiers: KeyModifiers::NONE,
                }),
                78,
            );
        };
        mouse(&mut model, MouseButton::Left, 1, 2);
        assert!(model.expanded_tools.contains("inspect"));
        render_frame(&model, 80, 24).unwrap();
        let anchor = model.transcript.borrow().anchor.clone();
        mouse(&mut model, MouseButton::Right, 6, 2);
        assert!(model.viewer.is_some());
        render_frame(&model, 80, 24).unwrap();
        mouse(&mut model, MouseButton::Right, 6, 2);
        assert!(model.viewer.is_none());
        assert_eq!(model.transcript.borrow().anchor, anchor);
        mouse(&mut model, MouseButton::Left, 1, 2);
        assert!(!model.expanded_tools.contains("inspect"));
    }
    #[test]
    fn expanded_result_selection_copy_keeps_unicode_tabs_newlines_across_wraps() {
        let mut model = model();
        finish(&mut model);
        key(&mut model, KeyCode::Char('f'));
        render_frame(&model, 20, 12).unwrap();
        let text = model.transcript.borrow().copy_entry().unwrap();
        let start = text.find("α\tretained\n").unwrap();
        let end = start + "α\tretained\n".len();
        let id = model.transcript.borrow().selected.clone().unwrap();
        model.transcript.borrow_mut().selection = Some((
            transcript::Point {
                id: id.clone(),
                byte: start,
            },
            transcript::Point { id, byte: end },
        ));
        assert_eq!(
            model.transcript.borrow().copy_selection().as_deref(),
            Some("α\tretained\n")
        );
        let anchor = model.transcript.borrow().anchor.clone();
        render_frame(&model, 80, 24).unwrap();
        assert_eq!(model.transcript.borrow().anchor, anchor);
        assert_eq!(
            model.transcript.borrow().copy_selection().as_deref(),
            Some("α\tretained\n")
        );
    }
}
