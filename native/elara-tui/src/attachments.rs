//! Connection-scoped input drafts. Only explicit selections become references.
use super::{ConnectionState, InputAction, Model};
use base64::Engine;
use crossterm::event::{Event, KeyCode, KeyEventKind, KeyModifiers, MouseButton, MouseEventKind};
use ratatui::{
    layout::Rect,
    text::Line,
    widgets::{Block, Borders, Clear, Paragraph},
};
use serde_json::{Value, json};
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::{cell::Cell, collections::VecDeque, fs::OpenOptions, io::Read, path::Path};
use unicode_segmentation::UnicodeSegmentation;

pub(super) const EXTENSION: &str = "input_attachments_v1";
const IMAGE_LIMIT: u64 = 2 * 1024 * 1024;
#[derive(Clone, Debug)]
pub(super) enum Selection {
    File { path: String, bytes: u64 },
    Image { metadata: Value, _data: Vec<u8> },
}
impl Selection {
    fn label(&self) -> String {
        match self {
            Self::File { path, bytes } => format!("@{} · text · {bytes} bytes", display(path)),
            Self::Image { metadata, .. } => format!(
                "{} · {} · {} bytes",
                display(metadata["name"].as_str().unwrap_or("image")),
                display(metadata["mime_type"].as_str().unwrap_or("image/png")),
                metadata["bytes"]
            ),
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mode {
    Files,
    Image,
    Selected,
}
#[derive(Clone, Debug)]
struct Picker {
    mode: Mode,
    query: String,
    selected: usize,
    inline: bool,
}
#[derive(Clone, Debug)]
struct PendingImage {
    request_id: String,
    data: Vec<u8>,
    cancelled: bool,
    query: String,
}
#[derive(Clone, Debug, Default)]
pub(super) struct Draft {
    pub supported: bool,
    pub selections: Vec<Selection>,
    pub revision: u64,
    pub submitted_revision: Option<u64>,
    picker: Option<Picker>,
    files: Vec<Value>,
    discovery: Option<String>,
    discovery_dirty: bool,
    ingestion: Option<PendingImage>,
    deferred_discards: Vec<Value>,
    serial: u64,
    pub outbox: VecDeque<Value>,
    reconnect_images: VecDeque<(String, Vec<u8>)>,
    status: String,
    rect: Cell<Rect>,
}
impl Draft {
    pub fn pending_payload(&self) -> Value {
        let image = |name: &str, data: &[u8]| json!({"name":name,"base64":base64::engine::general_purpose::STANDARD.encode(data)});
        let mut entries: Vec<Value> = self
            .selections
            .iter()
            .map(|s| match s {
                Selection::File { path, bytes } => json!({"path":path,"bytes":bytes}),
                Selection::Image { metadata, _data } => {
                    image(metadata["name"].as_str().unwrap_or("image.png"), _data)
                }
            })
            .collect();
        entries.extend(
            self.reconnect_images
                .iter()
                .map(|(name, data)| image(name, data)),
        );
        if let Some(pending) = &self.ingestion {
            entries.push(image(&pending.query, &pending.data));
        }
        entries.sort_by_key(Value::to_string);
        json!(entries)
    }

    pub fn restore_pending(&mut self, payload: &Value) {
        let Some(entries) = payload.as_array() else {
            return;
        };
        for entry in entries {
            if let (Some(path), Some(bytes)) = (entry["path"].as_str(), entry["bytes"].as_u64()) {
                self.selections.push(Selection::File {
                    path: path.into(),
                    bytes,
                });
            } else if let (Some(name), Some(encoded)) =
                (entry["name"].as_str(), entry["base64"].as_str())
                && let Ok(data) = base64::engine::general_purpose::STANDARD.decode(encoded)
            {
                self.reconnect_images.push_back((name.into(), data));
            }
        }
        self.next_reconnect_image();
    }

    pub fn reconnect(&mut self, supported: bool) {
        self.supported = supported;
        self.discovery = None;
        if let Some(pending) = self.ingestion.take()
            && !pending.cancelled
        {
            self.reconnect_images
                .push_back((pending.query, pending.data));
        }
        self.outbox.clear();
        self.deferred_discards.clear();
        self.submitted_revision = None;
        // Image IDs are connection-scoped. Re-ingest retained immutable payloads.
        let mut images = Vec::new();
        self.selections = std::mem::take(&mut self.selections)
            .into_iter()
            .filter_map(|selection| match selection {
                Selection::Image { metadata, _data } => {
                    images.push((metadata, _data));
                    None
                }
                other => Some(other),
            })
            .collect();
        for (metadata, data) in images {
            self.reconnect_images.push_back((
                metadata["name"].as_str().unwrap_or("image.png").into(),
                data,
            ));
        }
        self.next_reconnect_image();
        self.revision += 1;
    }
    fn next_reconnect_image(&mut self) {
        if self.ingestion.is_some() {
            return;
        }
        if let Some((name, data)) = self.reconnect_images.pop_front() {
            let mut request = self.request("ingest_image");
            request["name"] = json!(name);
            request["base64"] = json!(base64::engine::general_purpose::STANDARD.encode(&data));
            self.ingestion = Some(PendingImage {
                request_id: request["request_id"].as_str().unwrap().into(),
                data,
                cancelled: false,
                query: name,
            });
            self.outbox.push_back(request);
        }
    }
    fn request(&mut self, command: &str) -> Value {
        self.serial += 1;
        json!({"version":2,"command":command,"extension":EXTENSION,"request_id":format!("input-{}",self.serial)})
    }
    fn discover(&mut self) -> InputAction {
        self.files.clear();
        self.status = "Searching…".into();
        if self.discovery.is_some() {
            self.discovery_dirty = true;
            return InputAction::None;
        }
        self.discovery_dirty = false;
        let mut request = self.request("discover_files");
        request["query"] = json!(self.picker.as_ref().unwrap().query);
        self.discovery = request["request_id"].as_str().map(str::to_owned);
        InputAction::Attachment(request)
    }
    pub fn lines(&self) -> Vec<Line<'static>> {
        self.selections
            .iter()
            .map(|s| Line::from(format!(" {} · F10 remove", s.label())))
            .collect()
    }
    pub fn augment(&mut self, request: &mut Value) -> Result<(), &'static str> {
        if self.ingestion.is_some() {
            return Err("Image validation pending; draft retained.");
        }
        if self.selections.is_empty() {
            return Ok(());
        }
        request["extension"] = json!(EXTENSION);
        request["references"] = json!(
            self.selections
                .iter()
                .filter_map(|s| match s {
                    Selection::File { path, .. } => Some(path),
                    _ => None,
                })
                .collect::<Vec<_>>()
        );
        request["attachment_ids"] = json!(
            self.selections
                .iter()
                .filter_map(|s| match s {
                    Selection::Image { metadata, .. } => metadata["id"].as_str(),
                    _ => None,
                })
                .collect::<Vec<_>>()
        );
        Ok(())
    }
    fn discard(&mut self, selection: &Selection) {
        if let Selection::Image { metadata, .. } = selection {
            if self.ingestion.is_some() {
                self.deferred_discards.push(metadata.clone());
                return;
            }
            if self.selections.iter().any(|s| matches!(s, Selection::Image{metadata: existing,..} if existing["id"] == metadata["id"])) { return; }
            let mut request = self.request("discard_attachment");
            request["attachment_id"] = metadata["id"].clone();
            self.outbox.push_back(request);
        }
    }
    pub fn clear_accepted(&mut self) {
        self.reconnect_images.clear();
        if let Some(pending) = &mut self.ingestion {
            pending.cancelled = true;
        }
        for selection in std::mem::take(&mut self.selections) {
            self.discard(&selection);
        }
        self.revision += 1;
    }
    fn select(&mut self) {
        let Some(picker) = &self.picker else {
            return;
        };
        if self.selections.len() + usize::from(self.ingestion.is_some()) >= 4 {
            self.status = "Four selections maximum; F10 removes attachments.".into();
            return;
        }
        if let Some(file) = self.files.get(picker.selected) {
            let Some(path) = file["path"].as_str() else {
                return;
            };
            if !self
                .selections
                .iter()
                .any(|s| matches!(s, Selection::File {path: p,..} if p == path))
            {
                self.selections.push(Selection::File {
                    path: path.into(),
                    bytes: file["bytes"].as_u64().unwrap_or(0),
                });
                self.revision += 1;
            }
            self.picker = None;
        }
    }
}

pub(super) fn input(model: &mut Model, event: &Event) -> Option<InputAction> {
    if model.provider_picker.is_some() {
        return None;
    }
    if model.safe_paste {
        model.attachments.picker = None;
        return None;
    }
    if let Event::Key(key) = event {
        if key.kind == KeyEventKind::Release {
            return model.attachments.picker.as_ref().map(|_| InputAction::None);
        }
        if key.modifiers.contains(KeyModifiers::CONTROL) {
            match key.code {
                KeyCode::Char('c') if model.attachments.picker.is_some() => {
                    return Some(InputAction::Detach);
                }
                KeyCode::Char('x') if model.attachments.picker.is_some() => {
                    return Some(InputAction::Interrupt);
                }
                _ => {}
            }
        }
        if key.code == KeyCode::F(2) {
            model.attachments.picker = None;
            return None;
        }
        let inline = key.code == KeyCode::Char('@')
            && !key
                .modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
            && !model.transcript.borrow().focused
            && model.attachments.picker.is_none()
            && model.editor.text()[..model.editor.cursor()]
                .chars()
                .next_back()
                .is_none_or(char::is_whitespace);
        let mode = match key.code {
            KeyCode::F(8) => Some(Mode::Files),
            KeyCode::F(9) => Some(Mode::Image),
            KeyCode::F(10) => Some(Mode::Selected),
            _ if inline => Some(Mode::Files),
            _ => None,
        };
        if let Some(mode) = mode {
            if !model.attachments.supported
                || model.connection != ConnectionState::Connected
                || model.mode != "control"
            {
                if inline {
                    return None;
                }
                model.notice = Some(
                    "Attachments require a connected control session with input_attachments_v1."
                        .into(),
                );
                return Some(InputAction::None);
            }
            if inline {
                model.editor.insert("@");
            }
            model.attachments.picker = Some(Picker {
                mode,
                query: String::new(),
                selected: 0,
                inline,
            });
            model.attachments.status = String::new();
            return Some(if mode == Mode::Files {
                model.attachments.discover()
            } else {
                InputAction::None
            });
        }
    }
    let draft = &mut model.attachments;
    let picker = draft.picker.as_mut()?;
    let count = if picker.mode == Mode::Selected {
        draft.selections.len()
    } else {
        draft.files.len()
    };
    let mut removed = None;
    let mut select = false;
    let mut changed = false;
    match event {
        Event::Key(key) => match key.code {
            KeyCode::Esc => {
                if picker.mode == Mode::Image
                    && let Some(pending) = &mut draft.ingestion
                {
                    pending.cancelled = true;
                }
                draft.picker = None;
                return Some(InputAction::None);
            }
            KeyCode::Up => picker.selected = picker.selected.saturating_sub(1),
            KeyCode::Down => picker.selected = (picker.selected + 1).min(count.saturating_sub(1)),
            KeyCode::Enter if picker.mode == Mode::Files => select = true,
            KeyCode::Enter if picker.mode == Mode::Image => {
                if draft.selections.len() >= 4 {
                    draft.status = "Four selections maximum; F10 removes attachments.".into();
                } else if draft.ingestion.is_some() {
                    draft.status = "Image validation pending…".into();
                } else {
                    match read_image(&picker.query) {
                        Ok((name, data)) => {
                            let query = picker.query.clone();
                            let mut request = draft.request("ingest_image");
                            request["name"] = json!(name);
                            request["base64"] =
                                json!(base64::engine::general_purpose::STANDARD.encode(&data));
                            draft.ingestion = Some(PendingImage {
                                request_id: request["request_id"].as_str().unwrap().into(),
                                data,
                                cancelled: false,
                                query,
                            });
                            draft.revision += 1;
                            draft.status = "Validating image…".into();
                            return Some(InputAction::Attachment(request));
                        }
                        Err(error) => draft.status = error,
                    }
                }
            }
            KeyCode::Backspace | KeyCode::Delete if picker.mode == Mode::Selected => {
                if picker.selected < draft.selections.len() {
                    removed = Some(draft.selections.remove(picker.selected));
                    draft.revision += 1;
                    picker.selected = picker
                        .selected
                        .min(draft.selections.len().saturating_sub(1));
                }
            }
            KeyCode::Backspace if picker.mode != Mode::Selected => {
                changed = if let Some((index, _)) = picker.query.grapheme_indices(true).next_back()
                {
                    picker.query.truncate(index);
                    true
                } else {
                    false
                };
                if changed && picker.inline {
                    model.editor.handle_key(*key, 80);
                }
            }
            KeyCode::Char(c)
                if picker.mode != Mode::Selected
                    && !key
                        .modifiers
                        .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
            {
                let limit = if picker.mode == Mode::Files {
                    1024
                } else {
                    4096
                };
                if picker.query.len() + c.len_utf8() <= limit {
                    picker.query.push(c);
                    changed = true;
                    if picker.inline {
                        model.editor.insert(&c.to_string());
                    }
                }
            }
            _ => {}
        },
        Event::Paste(text) if picker.mode != Mode::Selected => {
            let limit = if picker.mode == Mode::Files {
                1024
            } else {
                4096
            };
            if picker.query.len() + text.len() <= limit && !text.contains(['\r', '\n']) {
                picker.query.push_str(text);
                changed = true;
                if picker.inline {
                    model.editor.insert(text);
                }
            } else {
                draft.status = "Path/query paste rejected: too long or contains a newline.".into();
            }
        }
        Event::Mouse(mouse) if draft.rect.get().contains((mouse.column, mouse.row).into()) => {
            match mouse.kind {
                MouseEventKind::ScrollDown => {
                    picker.selected = (picker.selected + 1).min(count.saturating_sub(1))
                }
                MouseEventKind::ScrollUp => picker.selected = picker.selected.saturating_sub(1),
                MouseEventKind::Down(MouseButton::Left)
                    if mouse.row >= draft.rect.get().y + 3
                        && mouse.row < draft.rect.get().bottom().saturating_sub(2) =>
                {
                    let visible = draft.rect.get().height.saturating_sub(5).max(1) as usize;
                    let first = picker.selected.saturating_sub(visible - 1);
                    let index = first + (mouse.row - draft.rect.get().y - 3) as usize;
                    if index < count {
                        picker.selected = index;
                        select = picker.mode == Mode::Files;
                    }
                }
                _ => {}
            }
        }
        _ => {}
    }
    if let Some(selection) = removed {
        draft.discard(&selection);
    }
    if select {
        draft.select();
    }
    if changed && draft.picker.as_ref().is_some_and(|p| p.mode == Mode::Files) {
        draft.picker.as_mut().unwrap().selected = 0;
        return Some(draft.discover());
    }
    Some(
        draft
            .outbox
            .pop_front()
            .map_or(InputAction::None, InputAction::Attachment),
    )
}

fn read_image(path: &str) -> Result<(String, Vec<u8>), String> {
    let path = Path::new(path);
    // Reject non-regular paths before open (in particular FIFOs), then recheck the descriptor.
    let metadata = std::fs::metadata(path).map_err(|e| format!("Cannot read image: {e}"))?;
    if !metadata.is_file() {
        return Err("Image path must be a regular file.".into());
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NONBLOCK);
    let file = options
        .open(path)
        .map_err(|e| format!("Cannot open image: {e}"))?;
    if !file.metadata().map_err(|e| e.to_string())?.is_file() {
        return Err("Image path must be a regular file.".into());
    }
    let mut bytes = Vec::new();
    file.take(IMAGE_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("Cannot read image: {e}"))?;
    if bytes.len() as u64 > IMAGE_LIMIT {
        return Err("Image exceeds 2 MiB; draft retained.".into());
    }
    if !bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Err("Unsupported image format: PNG required.".into());
    }
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or("Image filename must be Unicode.")?;
    Ok((name.into(), bytes))
}

pub(super) fn reply(model: &mut Model, frame: &Value) -> bool {
    let command = frame["command"].as_str().unwrap_or("");
    if !matches!(
        command,
        "discover_files" | "ingest_image" | "discard_attachment"
    ) {
        return false;
    }
    let draft = &mut model.attachments;
    let id = frame["request_id"].as_str();
    if command == "discover_files" && id.is_some() && id == draft.discovery.as_deref() {
        draft.discovery = None;
        if !draft.picker.as_ref().is_some_and(|p| p.mode == Mode::Files) {
            draft.discovery_dirty = false;
            return true;
        }
        if draft.discovery_dirty {
            if let InputAction::Attachment(request) = draft.discover() {
                draft.outbox.push_back(request);
            }
            return true;
        }
        draft.files = frame["files"].as_array().cloned().unwrap_or_default();
        draft.status = if frame["type"] == "error" {
            format!(
                "Discovery failed: {}",
                frame["error"].as_str().unwrap_or("unknown")
            )
        } else if frame["truncated"] == true {
            "Results truncated; refine the query.".into()
        } else if draft.files.is_empty() {
            "No matching files.".into()
        } else {
            "Enter/click selects a file; selection is explicit.".into()
        };
    } else if command == "ingest_image"
        && id.is_some()
        && draft
            .ingestion
            .as_ref()
            .is_some_and(|pending| Some(pending.request_id.as_str()) == id)
    {
        let PendingImage {
            data,
            cancelled,
            query,
            ..
        } = draft.ingestion.take().unwrap();
        if cancelled {
            if frame["attachment"]["id"].is_string() {
                draft.discard(&Selection::Image {
                    metadata: frame["attachment"].clone(),
                    _data: data,
                });
            }
        } else if frame["type"] == "error" {
            draft.status = format!(
                "Image rejected: {}",
                frame["error"].as_str().unwrap_or("unknown")
            );
            model.notice = Some(draft.status.clone());
        } else if draft.selections.iter().any(|s| matches!(s, Selection::Image{metadata,..} if metadata["id"] == frame["attachment"]["id"])) {
            draft.status = "Image already attached.".into();
        } else if frame["attachment"]["id"].is_string() && draft.selections.len() < 4 {
            draft.selections.push(Selection::Image {
                metadata: frame["attachment"].clone(),
                _data: data,
            });
            draft.revision += 1;
            draft.status = "Image attached.".into();
            if draft.picker.as_ref().is_some_and(|p| p.mode == Mode::Image && p.query == query) {
                draft.picker = None;
            }
        } else {
            if frame["attachment"]["id"].is_string() {
                draft.discard(&Selection::Image {
                    metadata: frame["attachment"].clone(),
                    _data: data,
                });
            }
            draft.status =
                "Cannot attach image: invalid reply or four selections already present.".into();
            model.notice = Some(draft.status.clone());
        }
        draft.next_reconnect_image();
    }
    if draft.ingestion.is_none() {
        for metadata in std::mem::take(&mut draft.deferred_discards) {
            draft.discard(&Selection::Image {
                metadata,
                _data: Vec::new(),
            });
        }
    }
    true
}

fn display(text: &str) -> String {
    text.chars()
        .map(|c| if c.is_control() { '�' } else { c })
        .collect()
}

pub(super) fn history_label(metadata: &Value) -> String {
    let name = display(metadata["name"].as_str().unwrap_or("attachment"));
    if metadata["kind"] == "text" {
        format!(
            "@{name} · text · {}/{} bytes{}",
            metadata["included_bytes"],
            metadata["bytes"],
            if metadata["clipped"] == true {
                " · clipped"
            } else {
                ""
            }
        )
    } else {
        format!(
            "{name} · {} · {} bytes",
            display(metadata["mime_type"].as_str().unwrap_or("image")),
            metadata["bytes"]
        )
    }
}

pub(super) fn draw(frame: &mut ratatui::Frame<'_>, model: &Model) {
    let draft = &model.attachments;
    let Some(picker) = &draft.picker else {
        return;
    };
    let area = frame.area();
    let rect = Rect::new(
        area.x + area.width.saturating_sub(88) / 2,
        area.y + 1,
        area.width.min(88),
        area.height.saturating_sub(3).min(18),
    );
    draft.rect.set(rect);
    let title = match picker.mode {
        Mode::Files => " @ files · Enter/click select · 64 KiB/text · Esc cancel ",
        Mode::Image => " Image from disk · PNG ≤2 MiB · Enter attach · Esc cancel ",
        Mode::Selected => " Attachments · ↑/↓ select · Delete remove · Esc close ",
    };
    let query_width = rect.width.saturating_sub(10) as usize;
    let query_display = display(&picker.query);
    let mut query = query_display.as_str();
    while unicode_width::UnicodeWidthStr::width(query) > query_width {
        let next = query
            .grapheme_indices(true)
            .nth(1)
            .map_or(query.len(), |(i, _)| i);
        query = &query[next..];
    }
    let mut lines = vec![
        Line::from(format!(
            "{}{}",
            if picker.mode == Mode::Image {
                "Path: "
            } else {
                "Query: "
            },
            query
        )),
        Line::from(display(&draft.status)),
    ];
    let labels: Vec<String> = if picker.mode == Mode::Selected {
        draft.selections.iter().map(Selection::label).collect()
    } else if picker.mode == Mode::Files {
        draft
            .files
            .iter()
            .map(|f| {
                format!(
                    "{} · {} bytes",
                    display(f["path"].as_str().unwrap_or("")),
                    f["bytes"]
                )
            })
            .collect()
    } else {
        vec![
            "Enter a local path (outside workspace allowed). Paste paths with spaces directly."
                .into(),
        ]
    };
    let visible = rect.height.saturating_sub(5).max(1) as usize;
    let first = picker.selected.saturating_sub(visible - 1);
    lines.extend(
        labels
            .iter()
            .enumerate()
            .skip(first)
            .take(visible)
            .map(|(i, label)| {
                Line::from(format!(
                    "{} {label}",
                    if i == picker.selected { "›" } else { " " }
                ))
            }),
    );
    if picker.mode == Mode::Selected && labels.is_empty() {
        lines.push(Line::from("No attachments selected."));
    }
    if rect.width > 10 && rect.height > 2 && picker.mode != Mode::Selected {
        frame.set_cursor_position((
            rect.x
                + (if picker.mode == Mode::Image { 7 } else { 8 })
                + unicode_width::UnicodeWidthStr::width(query) as u16,
            rect.y + 1,
        ));
    }
    frame.render_widget(Clear, rect);
    frame.render_widget(
        Paragraph::new(lines).block(
            Block::default()
                .borders(Borders::ALL)
                .title(title)
                .title_bottom(" F8 files · F9 image · F10 attachments "),
        ),
        rect,
    );
}
