use super::*;
use std::sync::{Arc, Condvar, Mutex};

pub(super) struct Input {
    pub projection: Projection,
    pub session_id: String,
    pub appearance: Appearance,
    pub thinking_visible: bool,
    pub preview_reasoning: bool,
    pub expanded_tools: HashSet<String>,
    pub keymap: actions::Keymap,
    viewer: Option<String>,
}

impl From<&Model> for Input {
    fn from(model: &Model) -> Self {
        Self {
            projection: model.projection.clone(),
            session_id: model.session_id.clone(),
            appearance: model.appearance,
            thinking_visible: model.thinking_visible,
            preview_reasoning: model.preview_reasoning,
            expanded_tools: model.expanded_tools.clone(),
            keymap: model.keymap.clone(),
            viewer: model.viewer.as_ref().map(|(id, _)| id.clone()),
        }
    }
}

impl Input {
    fn entries(&self) -> Vec<transcript::Entry> {
        if let Some(id) = &self.viewer {
            let call = self.projection.view["tool_calls"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|call| call["id"] == *id);
            vec![
                call.map(|call| tools::inspection(&self.session_id, call))
                    .unwrap_or_else(|| {
                        transcript::Entry::plain(id, "Tool unavailable in current snapshot.", false)
                    }),
            ]
        } else {
            transcript_entries(self)
        }
    }
}

type SourceKey = (String, String, u64, u64);

fn source_key(model: &Model) -> SourceKey {
    (
        model.session_id.clone(),
        model.projection.incarnation.clone(),
        model.projection.head,
        model.projection.snapshot_generation,
    )
}

#[derive(Clone, PartialEq, Eq)]
struct Key {
    source: SourceKey,
    width: usize,
    appearance: Appearance,
    thinking_visible: bool,
    preview_reasoning: bool,
    expanded_tools: HashSet<String>,
    thinking_keys: String,
    viewer: Option<String>,
    query: String,
}

impl Key {
    fn new(model: &Model, width: usize, query: &str) -> Self {
        Self {
            source: source_key(model),
            width,
            appearance: model.appearance,
            thinking_visible: model.thinking_visible,
            preview_reasoning: model.preview_reasoning,
            expanded_tools: model.expanded_tools.clone(),
            thinking_keys: model.keymap.keys(actions::Action::Thinking),
            viewer: model.viewer.as_ref().map(|(id, _)| id.clone()),
            query: query.into(),
        }
    }

    fn can_present(&self, desired: &Self) -> bool {
        let mut same_presentation = self.clone();
        same_presentation.source.2 = desired.source.2;
        same_presentation == *desired && self.source.2 <= desired.source.2
    }
}

struct Job {
    key: Key,
    input: Input,
}

struct Completed {
    key: Key,
    transcript: transcript::Transcript,
}

#[derive(Default)]
struct Slots {
    pending: Option<Job>,
    ready: Option<Completed>,
    retired: Vec<transcript::Transcript>,
    closed: bool,
}

/// One worker, one replaceable pending snapshot, and one completed layout.
/// Only presentation data crosses this boundary; editor and viewport state stay live.
pub struct LiveRenderer {
    shared: Arc<(Mutex<Slots>, Condvar)>,
    desired: Option<Key>,
}

impl Default for LiveRenderer {
    fn default() -> Self {
        Self::start(|| {})
    }
}

impl LiveRenderer {
    fn start(mut before_prepare: impl FnMut() + Send + 'static) -> Self {
        let shared = Arc::new((Mutex::new(Slots::default()), Condvar::new()));
        let worker = shared.clone();
        std::thread::spawn(move || {
            let (lock, wake) = &*worker;
            loop {
                let mut slots = lock.lock().unwrap();
                while slots.pending.is_none() && slots.retired.is_empty() && !slots.closed {
                    slots = wake.wait(slots).unwrap();
                }
                let retired = std::mem::take(&mut slots.retired);
                let job = slots.pending.take();
                let closed = slots.closed;
                drop(slots);
                drop(retired);
                if closed {
                    break;
                }
                let Some(Job { key, input }) = job else {
                    continue;
                };
                before_prepare();
                let mut transcript = transcript::Transcript::default();
                transcript.query.clone_from(&key.query);
                transcript.update(Some(input.entries()), key.width, 1);
                let completed = Completed { key, transcript };
                let previous = lock.lock().unwrap().ready.replace(completed);
                drop(previous);
            }
        });
        Self {
            shared,
            desired: None,
        }
    }

    pub fn is_ready(&self) -> bool {
        self.shared.0.lock().unwrap().ready.is_some()
    }

    fn update(
        &mut self,
        model: &Model,
        state: &mut transcript::Transcript,
        width: usize,
        height: usize,
    ) {
        let key = Key::new(model, width, &state.query);
        let (lock, wake) = &*self.shared;
        if self.desired.as_ref() != Some(&key) {
            let job = Job {
                key: key.clone(),
                input: Input::from(model),
            };
            let previous = lock.lock().unwrap().pending.replace(job);
            drop(previous);
            self.desired = Some(key.clone());
            wake.notify_one();
        }
        let mut slots = lock.lock().unwrap();
        if slots
            .ready
            .as_ref()
            .is_some_and(|ready| ready.key.can_present(&key))
        {
            let ready = slots.ready.take().unwrap();
            state.source_key = Some(ready.key.source);
            slots.retired.push(state.install(ready.transcript, height));
            wake.notify_one();
        } else {
            if let Some(obsolete) = slots.ready.take() {
                slots.retired.push(obsolete.transcript);
                wake.notify_one();
            }
            state.resize_height(height);
        }
    }
}

impl Drop for LiveRenderer {
    fn drop(&mut self) {
        self.shared.0.lock().unwrap().closed = true;
        self.shared.1.notify_one();
    }
}

pub(super) fn update(
    model: &Model,
    state: &mut transcript::Transcript,
    width: usize,
    height: usize,
    renderer: Option<&mut LiveRenderer>,
) {
    if let Some(renderer) = renderer {
        renderer.update(model, state, width, height);
    } else {
        let key = source_key(model);
        let entries = if state.source_key.as_ref() != Some(&key) {
            state.source_key = Some(key);
            Some(Input::from(model).entries())
        } else {
            None
        };
        state.update(entries, width, height);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};
    use ratatui::{Terminal, backend::TestBackend};
    use serde_json::json;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    fn frame(model: &Model, renderer: &mut LiveRenderer, width: u16) -> String {
        let mut terminal = Terminal::new(TestBackend::new(width, 24)).unwrap();
        terminal
            .draw(|frame| draw_model_live(frame, model, renderer))
            .unwrap();
        terminal
            .backend()
            .buffer()
            .content
            .iter()
            .map(|cell| cell.symbol())
            .collect()
    }

    fn wait_ready(renderer: &LiveRenderer) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !renderer.is_ready() {
            assert!(Instant::now() < deadline, "reconstruction did not complete");
            std::thread::yield_now();
        }
    }

    #[test]
    fn rebuilding_keeps_input_and_navigation_live_and_rejects_obsolete_snapshots() {
        let mut model = fixture_model("idle");
        model.projection.view["messages"][1]["text"] = json!("ORIGINAL SCREEN");
        render_frame(&model, 80, 24).unwrap();
        let (permit, work) = mpsc::channel();
        let mut renderer = LiveRenderer::start(move || {
            work.recv().unwrap();
        });

        let mut stale = model.projection.view.clone();
        stale["messages"][0]["text"] = json!("OBSOLETE USER");
        stale["messages"][1]["text"] = json!("many rows\n".repeat(80));
        model
            .projection
            .install_snapshot(stale, "inc-demo".into(), 5)
            .unwrap();
        let first = frame(&model, &mut renderer, 80);
        assert!(first.contains("ORIGINAL SCREEN"), "{first}");
        // Finish only the obsolete job, then change the authoritative snapshot before presenting it.
        permit.send(()).unwrap();
        wait_ready(&renderer);
        let mut latest = model.projection.view.clone();
        latest["messages"][0]["text"] = json!("LATEST USER");
        model
            .projection
            .install_snapshot(latest, "inc-demo".into(), 5)
            .unwrap();
        model.appearance.layout = ViewLayout::Workbench;
        model.editor.insert("typed while rebuilding");
        for code in [KeyCode::Tab, KeyCode::Home] {
            handle_input(
                &mut model,
                Event::Key(KeyEvent::new(code, KeyModifiers::NONE)),
                59,
            );
        }
        let pending = frame(&model, &mut renderer, 61);
        assert!(!pending.contains("OBSOLETE USER"), "{pending}");
        assert!(pending.contains("typed while rebuilding"), "{pending}");
        permit.send(()).unwrap();
        wait_ready(&renderer);
        let final_frame = frame(&model, &mut renderer, 61);
        assert!(final_frame.contains("LATEST USER"), "{final_frame}");
        assert!(
            final_frame.contains("typed while rebuilding"),
            "{final_frame}"
        );
        assert_eq!(model.editor.text(), "typed while rebuilding");
    }

    #[test]
    fn search_entered_before_the_first_layout_waits_for_results_then_reveals_the_match() {
        let mut model = fixture_model("idle");
        model.projection.view["messages"][1]["text"] =
            json!("many rows ".repeat(1000) + "TARGET FOUND AT THE END");
        let (permit, work) = mpsc::channel();
        let mut renderer = LiveRenderer::start(move || {
            work.recv().unwrap();
        });
        for code in [KeyCode::Tab, KeyCode::Char('/')] {
            handle_input(
                &mut model,
                Event::Key(KeyEvent::new(code, KeyModifiers::NONE)),
                118,
            );
        }
        handle_input(&mut model, Event::Paste("TARGET".into()), 118);
        let pending = frame(&model, &mut renderer, 120);
        assert!(pending.contains("/TARGET"), "{pending}");
        assert!(!pending.contains("0/0 matches"), "{pending}");
        permit.send(()).unwrap();
        wait_ready(&renderer);
        let ready = frame(&model, &mut renderer, 120);
        assert!(ready.contains("1/1 matches"), "{ready}");
        assert!(
            ready.replace(' ', "").contains("TARGETFOUNDATTHEEND"),
            "{ready}"
        );
    }
}
