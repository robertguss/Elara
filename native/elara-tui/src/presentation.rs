use super::*;
use crossterm::event::{Event, KeyCode, KeyEventKind};
use ratatui::layout::Rect;

// Public summary headings from docs/fixtures/subscription-preflight-2026-09-04.json.
// Presentation fixture only: never inserted into Projection or sent to Core.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Overlay {
    Thinking,
    Turns,
}

const PREVIEW_SUMMARY: &str =
    "Evaluating three-digit numbers with digit sum 19\nFinding smallest 3-digit multiple 469";

pub(super) fn input(model: &mut Model, event: &Event) -> bool {
    let modal = model.appearance_picker.is_some() || model.presentation_overlay.is_some();
    if let Event::Paste(_) = event {
        if modal || model.show_help {
            model.appearance_picker = None;
            model.presentation_overlay = None;
            model.show_help = false;
            model.close_tool();
        }
        return false;
    }
    let Event::Key(key) = event else {
        return modal;
    };
    if key.kind == KeyEventKind::Release {
        return modal;
    }
    if model.safe_paste {
        return false;
    }
    let action = actions::lookup(*key, model.transcript.borrow().focused);
    if action == Some(actions::Action::SafePaste) {
        model.appearance_picker = None;
        model.presentation_overlay = None;
        model.show_help = false;
        return false;
    }
    if modal && action == Some(actions::Action::Escape) && key.code != KeyCode::Esc {
        model.appearance_picker = None;
        model.presentation_overlay = None;
        return false;
    }
    if modal && action == Some(actions::Action::Interrupt) {
        return false;
    }
    if let Some(mut choice) = model.appearance_picker {
        match key.code {
            KeyCode::Left => choice.layout = choice.layout.previous(),
            KeyCode::Right | KeyCode::Char('l') => choice.layout = choice.layout.next(),
            KeyCode::Up => choice.theme = choice.theme.previous(),
            KeyCode::Down | KeyCode::Char('t') => choice.theme = choice.theme.next(),
            KeyCode::Esc | KeyCode::F(3) => {
                model.appearance_picker = None;
                return true;
            }
            KeyCode::Enter | KeyCode::Char('s') => {
                if key.code == KeyCode::Char('s') {
                    if let Err(error) = choice.save() {
                        model.notice = Some(error);
                        return true;
                    }
                    model.notice = Some("Appearance defaults saved".into());
                }
                model.set_appearance(choice);
                model.appearance_picker = None;
                return true;
            }
            _ => {}
        }
        model.appearance_picker = Some(choice);
        return true;
    }
    if let Some(overlay) = model.presentation_overlay {
        if overlay == Overlay::Thinking && action == Some(actions::Action::Thinking) {
            model.thinking_visible = !model.thinking_visible;
            model.transcript.borrow_mut().source_key = None;
            return true;
        }
        match key.code {
            KeyCode::Esc | KeyCode::F(5) | KeyCode::F(6) => model.presentation_overlay = None,
            KeyCode::Up if overlay == Overlay::Turns => model.transcript.borrow_mut().user_turn(-1),
            KeyCode::Down if overlay == Overlay::Turns => {
                model.transcript.borrow_mut().user_turn(1)
            }
            KeyCode::End if overlay == Overlay::Turns => model.transcript.borrow_mut().tail(),
            KeyCode::Up => model.overlay_scroll = model.overlay_scroll.saturating_sub(1),
            KeyCode::Down => model.overlay_scroll = model.overlay_scroll.saturating_add(1),
            KeyCode::PageUp => model.overlay_scroll = model.overlay_scroll.saturating_sub(8),
            KeyCode::PageDown => model.overlay_scroll = model.overlay_scroll.saturating_add(8),
            _ => {}
        }
        return true;
    }
    if model.show_help || model.viewer.is_some() {
        return false;
    }
    match action {
        Some(actions::Action::Appearance) => model.appearance_picker = Some(model.appearance),
        Some(actions::Action::Thinking) => {
            model.thinking_visible = !model.thinking_visible;
            model.transcript.borrow_mut().source_key = None;
        }
        Some(actions::Action::ThinkingView) => {
            model.presentation_overlay = Some(Overlay::Thinking);
            model.overlay_scroll = 0;
        }
        Some(actions::Action::Turns) => {
            model.presentation_overlay = Some(Overlay::Turns);
            model.overlay_scroll = 0;
        }
        _ => return false,
    }
    true
}
impl Model {
    pub fn set_appearance(&mut self, appearance: Appearance) {
        if self.appearance.layout != appearance.layout {
            self.transcript.borrow_mut().source_key = None;
        }
        self.appearance = appearance;
    }
    pub fn thinking_source(&self) -> String {
        let state = self.transcript.borrow();
        let count = if state.follow {
            self.projection.view["messages"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|m| m["role"] == "user")
                .count()
        } else {
            state.selected_user_turn()
        };
        format!(
            "turn {} · {}",
            count,
            if state.follow {
                if self.turn_state() == "idle" {
                    "live follow · complete"
                } else {
                    "live follow · active"
                }
            } else {
                "historical"
            }
        )
    }
}
fn thinking_lines(model: &Model) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(format!(
        "Thinking · {}",
        model.thinking_source()
    ))];
    if !model.thinking_visible {
        lines.push(Line::from("Hidden by you · F4 show"));
    } else if model.preview_reasoning {
        lines.push(Line::from(
            "PREVIEW fixture · subscription preflight sample",
        ));
        lines.extend(
            PREVIEW_SUMMARY
                .split('\n')
                .map(|s| Line::from(s.to_owned())),
        );
        lines.push(Line::from(
            "Illustrative binding; not this turn's live reasoning.",
        ));
    } else {
        lines.push(Line::from("Live reasoning unavailable until PROV-2."));
    }
    lines
}
pub(super) fn inline_thinking(model: &Model, id: &str) -> Option<transcript::Entry> {
    if !model.preview_reasoning {
        return None;
    }
    let text = format!("Thinking · PREVIEW fixture (not live)\n{PREVIEW_SUMMARY}");
    let mut entry = transcript::Entry::plain(&format!("{id}:thinking"), &text, false);
    for line in &mut entry.lines {
        line.style = Style::default().fg(Color::Gray);
    }
    // Retain source identity/copy ranges when its visual content moves to a pane.
    if model.appearance.layout != ViewLayout::Ember || !model.thinking_visible {
        entry.lines.clear();
    }
    Some(entry)
}
fn panel(frame: &mut ratatui::Frame<'_>, lines: Vec<Line<'static>>, area: Rect, title: &str) {
    frame.render_widget(
        Paragraph::new(lines)
            .wrap(Wrap { trim: false })
            .block(Block::default().borders(Borders::ALL).title(title)),
        area,
    );
}
fn turn_prompts(model: &Model) -> impl Iterator<Item = &str> {
    model.projection.view["messages"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|message| message["role"] == "user")
        .filter_map(|message| message["text"].as_str())
}
fn turn_lines(model: &Model, skip: usize, rows: usize) -> Vec<Line<'_>> {
    std::iter::once(Line::from(model.thinking_source()))
        .chain(turn_prompts(model).enumerate().map(|(i, prompt)| {
            Line::from(vec![
                Span::raw(format!("{:02} ", i + 1)),
                Span::raw(prompt.lines().next().unwrap_or("")),
            ])
        }))
        .chain(std::iter::once(Line::from("F6 turns · End live")))
        .skip(skip)
        .take(rows)
        .collect()
}
fn turns_panel(
    frame: &mut ratatui::Frame<'_>,
    model: &Model,
    area: Rect,
    scroll: usize,
    title: &str,
) {
    let rows = area.height.saturating_sub(2) as usize;
    let skip = if scroll == 0 {
        0
    } else {
        scroll.min(
            turn_prompts(model)
                .count()
                .saturating_add(2)
                .saturating_sub(rows),
        )
    };
    // Each summary occupies one visual row. Borrow prompt text and format only the
    // visible window; full text and copy ranges remain in the canonical transcript.
    frame.render_widget(
        Paragraph::new(turn_lines(model, skip, rows))
            .block(Block::default().borders(Borders::ALL).title(title)),
        area,
    );
}
pub(super) fn panes(frame: &mut ratatui::Frame<'_>, model: &Model, area: Rect) -> Rect {
    if area.width < 100 || area.height < 12 {
        // Optional panes collapse; full views remain available without shrinking the draft.
        return area;
    }
    match model.appearance.layout {
        ViewLayout::Observatory if model.thinking_visible => {
            let parts =
                Layout::horizontal([Constraint::Percentage(64), Constraint::Percentage(36)])
                    .split(area);
            panel(
                frame,
                thinking_lines(model),
                parts[1],
                " Thinking · F4 hide · F5 view ",
            );
            parts[0]
        }
        ViewLayout::Workbench => {
            let parts =
                Layout::horizontal([Constraint::Length(23), Constraint::Min(1)]).split(area);
            turns_panel(frame, model, parts[0], 0, " Turns · F6 ");
            if model.thinking_visible {
                let main =
                    Layout::vertical([Constraint::Min(4), Constraint::Length(7)]).split(parts[1]);
                panel(
                    frame,
                    thinking_lines(model),
                    main[1],
                    " Thinking strip · F5 view ",
                );
                main[0]
            } else {
                parts[1]
            }
        }
        _ => area,
    }
}
pub(super) fn finish(frame: &mut ratatui::Frame<'_>, model: &Model) {
    if model.appearance_picker.is_some() || model.presentation_overlay.is_some() {
        let area = frame.area();
        // Preserve the composer and status when the overlay has enough content rows.
        let editor_height = model
            .editor
            .layout(area.width.saturating_sub(2).max(1) as usize)
            .rows
            .len()
            .clamp(1, (area.height as usize / 3).max(1)) as u16
            + 2;
        let overlay_area = Rect {
            height: area.height.saturating_sub(editor_height + 1),
            ..area
        };
        if overlay_area.height < 10 {
            frame.render_widget(ratatui::widgets::Clear, area);
            panel(
                frame,
                vec![Line::from("Resize terminal to use this view · Esc close")],
                area,
                " Resize · Esc close ",
            );
        } else if let Some(choice) = model.appearance_picker {
            frame.render_widget(ratatui::widgets::Clear, overlay_area);
            panel(
                frame,
                choice.lines(),
                overlay_area,
                " Appearance · Enter apply · Esc cancel ",
            );
        } else if let Some(overlay) = model.presentation_overlay {
            frame.render_widget(ratatui::widgets::Clear, overlay_area);
            if overlay == Overlay::Turns {
                turns_panel(
                    frame,
                    model,
                    overlay_area,
                    model.overlay_scroll,
                    " Turns · Up/Down select · End live · Esc close ",
                );
            } else {
                let lines = thinking_lines(model);
                let max = lines
                    .len()
                    .saturating_sub(overlay_area.height.saturating_sub(2) as usize);
                let skip = model.overlay_scroll.min(max);
                panel(
                    frame,
                    lines.into_iter().skip(skip).collect(),
                    overlay_area,
                    " Thinking view · Up/Down scroll · Esc close ",
                );
            }
        }
    }
    let t = model.appearance.theme.tokens();
    let buffer = frame.buffer_mut();
    for cell in &mut buffer.content {
        let original_bg = cell.bg;
        cell.bg = match original_bg {
            Color::Blue => t.selection,
            Color::Yellow | Color::Cyan => t.focus,
            Color::Black | Color::DarkGray => t.surface,
            Color::Reset => t.background,
            c => c,
        };
        cell.fg = if matches!(original_bg, Color::Yellow | Color::Cyan) {
            t.background
        } else {
            match cell.fg {
                Color::Reset | Color::White => t.text,
                Color::Gray | Color::DarkGray => t.secondary,
                Color::Cyan
                | Color::Blue
                | Color::Yellow
                | Color::Magenta
                | Color::LightCyan
                | Color::LightBlue
                | Color::LightYellow
                | Color::LightMagenta => t.focus,
                Color::Green | Color::LightGreen => t.added,
                Color::Red | Color::LightRed => t.removed,
                Color::Black => t.text,
                _ => t.text,
            }
        };
        if cell.modifier.contains(Modifier::DIM) {
            cell.modifier.remove(Modifier::DIM);
            cell.fg = t.secondary;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::{KeyEvent, KeyModifiers};
    fn key(model: &mut Model, code: KeyCode) {
        assert_eq!(
            handle_input(
                model,
                Event::Key(KeyEvent::new(code, KeyModifiers::NONE)),
                78
            ),
            InputAction::None
        );
    }
    fn preview() -> Model {
        let mut model = fixture_model("streaming");
        model.projection.view["messages"] = json!([
            {"role":"user","text":"Historical question α"},
            {"role":"assistant","text":"Historical answer","tool_calls":[]},
            {"role":"user","text":"Live question 中"}
        ]);
        model.preview_reasoning = true;
        model.editor.insert("Preserve 👩‍💻 selected draft");
        model.editor.handle_key(
            KeyEvent::new(KeyCode::Left, KeyModifiers::CONTROL | KeyModifiers::SHIFT),
            78,
        );
        model
    }
    #[test]
    fn workbench_turn_summaries_are_bounded_to_visible_rows() {
        let mut model = preview();
        model.projection.view["messages"] = json!(
            (0..10_000)
                .map(|i| json!({"role":"user", "text":format!("prompt {i}")}))
                .collect::<Vec<_>>()
        );
        for _ in 0..3 {
            let lines = turn_lines(&model, 0, 10);
            assert!(
                lines.len() <= 10,
                "formatted {} rows for a ten-row pane",
                lines.len()
            );
        }
    }

    #[test]
    fn short_modals_always_show_escape_and_restore_draft() {
        for height in 4..=10 {
            for code in [KeyCode::F(3), KeyCode::F(5), KeyCode::F(6)] {
                let mut model = preview();
                let draft = model.editor.text().to_owned();
                key(&mut model, code);
                let frame = render_frame(&model, 80, height).unwrap();
                assert!(
                    frame.contains("Esc"),
                    "{code:?} at height {height}: {frame}"
                );
                assert!(
                    frame.contains("Resize")
                        || frame.contains("Layout:")
                        || frame.contains("Thinking")
                        || frame.contains("turn 2")
                );
                key(&mut model, KeyCode::Esc);
                assert!(model.appearance_picker.is_none());
                assert!(model.presentation_overlay.is_none());
                assert_eq!(model.editor.text(), draft);
            }
        }
    }

    #[test]
    fn turns_page_down_reaches_second_prompt_after_long_first_prompt() {
        let mut model = preview();
        let first = "x".repeat(2_000);
        model.projection.view["messages"] = json!([
            {"role":"user", "text":first},
            {"role":"user", "text":"DISTINCT SECOND PROMPT"}
        ]);
        key(&mut model, KeyCode::F(6));
        key(&mut model, KeyCode::PageDown);
        let frame = render_frame(&model, 80, 24).unwrap();
        assert!(frame.contains("DISTINCT SECOND PROMPT"));
        assert_eq!(model.projection.view["messages"][0]["text"], first);
        let mut state = model.transcript.borrow_mut();
        state.selection = Some((
            transcript::Point {
                id: "session-demo:message:0".into(),
                byte: 0,
            },
            transcript::Point {
                id: "session-demo:message:0".into(),
                byte: first.len(),
            },
        ));
        assert_eq!(state.copy_selection().as_deref(), Some(first.as_str()));
    }

    #[test]
    fn thinking_overlay_honors_its_f4_show_control() {
        let mut model = preview();
        key(&mut model, KeyCode::F(4));
        key(&mut model, KeyCode::F(5));
        assert!(
            render_frame(&model, 80, 24)
                .unwrap()
                .contains("Hidden by you")
        );
        key(&mut model, KeyCode::F(4));
        assert!(model.thinking_visible);
        assert_eq!(model.presentation_overlay, Some(Overlay::Thinking));
        assert!(model.transcript.borrow().source_key.is_none());
        assert!(
            !render_frame(&model, 80, 24)
                .unwrap()
                .contains("Hidden by you")
        );
    }

    #[test]
    fn turns_open_resets_thinking_overlay_scroll() {
        let mut model = preview();
        model.projection.view["messages"] = json!(
            (1..=40)
                .map(|i| json!({"role":"user", "text":format!("QUESTION {i:02}")}))
                .collect::<Vec<_>>()
        );
        key(&mut model, KeyCode::F(5));
        for _ in 0..3 {
            key(&mut model, KeyCode::PageDown);
        }
        key(&mut model, KeyCode::Esc);
        key(&mut model, KeyCode::F(6));
        assert_eq!(model.overlay_scroll, 0);
        assert!(
            render_frame(&model, 80, 24)
                .unwrap()
                .contains("QUESTION 01")
        );
    }

    #[test]
    fn layout_and_theme_switches_preserve_all_shared_state_and_historical_binding() {
        let mut model = preview();
        render_frame(&model, 120, 40).unwrap();
        model.transcript.borrow_mut().focused = true;
        model.transcript.borrow_mut().home();
        {
            let mut t = model.transcript.borrow_mut();
            t.selection = Some((
                transcript::Point {
                    id: "session-demo:message:0".into(),
                    byte: 0,
                },
                transcript::Point {
                    id: "session-demo:message:0".into(),
                    byte: 10,
                },
            ));
            t.query = "Historical".into();
            t.search_changed();
        }
        model.expanded_tools.insert("call-1".into());
        let editor = (
            model.editor.text().to_owned(),
            model.editor.cursor(),
            model.editor.selection(),
        );
        let selection = model.transcript.borrow().selection.clone();
        let anchor = model.transcript.borrow().anchor.clone();
        key(&mut model, KeyCode::F(4));
        for layout in ViewLayout::ALL {
            for theme in Theme::ALL {
                model.set_appearance(Appearance {
                    layout: *layout,
                    theme: *theme,
                });
                for (w, h) in [(80, 24), (120, 40), (180, 45), (80, 24)] {
                    render_frame(&model, w, h).unwrap();
                    assert_eq!(model.thinking_source(), "turn 1 · historical");
                    assert!(!model.thinking_visible);
                    assert_eq!(model.transcript.borrow().selection, selection);
                    assert_eq!(model.transcript.borrow().anchor, anchor);
                    assert_eq!(model.transcript.borrow().query, "Historical");
                    assert!(model.expanded_tools.contains("call-1"));
                    assert_eq!(
                        (
                            model.editor.text().to_owned(),
                            model.editor.cursor(),
                            model.editor.selection()
                        ),
                        editor
                    );
                }
                model.projection.head += 1;
                model.projection.view["content_deltas"]["stream-1"] =
                    json!("Another live answer chunk");
                render_frame(&model, 80, 24).unwrap();
                assert_eq!(model.thinking_source(), "turn 1 · historical");
                key(&mut model, KeyCode::F(5));
                assert!(
                    render_frame(&model, 80, 24)
                        .unwrap()
                        .contains("turn 1 · historical")
                );
                key(&mut model, KeyCode::Esc);
                assert!(model.transcript.borrow().focused);
            }
        }
        model.projection.view["turn"]["state"] = json!("idle");
        model.projection.head += 1;
        render_frame(&model, 80, 24).unwrap();
        assert!(!model.thinking_visible);
        model.transcript.borrow_mut().tail();
        assert_eq!(model.thinking_source(), "turn 2 · live follow · complete");
        key(&mut model, KeyCode::F(4));
        assert!(model.thinking_visible);
    }
    #[test]
    fn modal_safe_paste_closes_overlays_and_preserves_draft_focus() {
        for modal in [KeyCode::F(3), KeyCode::F(5), KeyCode::F(6), KeyCode::F(1)] {
            let mut model = preview();
            key(&mut model, modal);
            key(&mut model, KeyCode::F(2));
            assert!(model.safe_paste);
            assert!(
                model.appearance_picker.is_none()
                    && model.presentation_overlay.is_none()
                    && !model.show_help
            );
            let frame = render_frame(&model, 80, 24).unwrap();
            assert!(frame.contains("SAFE PASTE"));
            assert!(frame.contains("Preserve"));
            key(&mut model, KeyCode::F(3));
            assert!(model.appearance_picker.is_none());
            key(&mut model, KeyCode::F(2));
        }
    }
    #[test]
    fn appearance_cancel_preserves_choices_and_paste_is_never_hidden() {
        let mut model = preview();
        let original = model.appearance;
        key(&mut model, KeyCode::F(3));
        key(&mut model, KeyCode::Right);
        key(&mut model, KeyCode::Down);
        key(&mut model, KeyCode::Esc);
        assert_eq!(model.appearance, original);
        key(&mut model, KeyCode::F(3));
        key(&mut model, KeyCode::Left);
        key(&mut model, KeyCode::Up);
        key(&mut model, KeyCode::Enter);
        assert_eq!(
            model.appearance,
            Appearance {
                layout: ViewLayout::Workbench,
                theme: Theme::Forest
            }
        );
        key(&mut model, KeyCode::F(5));
        handle_input(&mut model, Event::Paste("visible paste".into()), 78);
        assert!(model.presentation_overlay.is_none());
        assert!(
            render_frame(&model, 80, 24)
                .unwrap()
                .contains("visible paste")
        );
    }
    #[test]
    fn inline_reasoning_selection_survives_moving_to_panes_and_hiding() {
        let mut model = preview();
        render_frame(&model, 120, 40).unwrap();
        let id = "session-demo:message:0:thinking".to_owned();
        let start = transcript::Point {
            id: id.clone(),
            byte: 0,
        };
        let end = transcript::Point {
            id: id.clone(),
            byte: 8,
        };
        {
            let mut state = model.transcript.borrow_mut();
            state.follow = false;
            state.anchor = Some(start.clone());
            state.selected = Some(id.clone());
            state.selection = Some((start.clone(), end.clone()));
        }
        for layout in ViewLayout::ALL {
            model.set_appearance(Appearance {
                layout: *layout,
                theme: Theme::Forest,
            });
            for visible in [false, true] {
                model.thinking_visible = visible;
                model.transcript.borrow_mut().source_key = None;
                render_frame(&model, 80, 24).unwrap();
                assert_eq!(model.thinking_source(), "turn 1 · historical");
                let state = model.transcript.borrow();
                assert_eq!(state.anchor, Some(start.clone()));
                assert_eq!(state.selected, Some(id.clone()));
                assert_eq!(state.selection, Some((start.clone(), end.clone())));
                assert_eq!(state.copy_selection().as_deref(), Some("Thinking"));
            }
        }
    }
    #[test]
    fn overlays_keep_pending_and_disconnect_visible_and_honor_controls() {
        for code in [KeyCode::F(3), KeyCode::F(5), KeyCode::F(6)] {
            let mut model = fixture_model("idle");
            model.editor.insert("unsent");
            model.prepare_submit().unwrap();
            key(&mut model, code);
            assert!(
                render_frame(&model, 80, 24)
                    .unwrap()
                    .contains("Awaiting acceptance")
            );
            model.mark_disconnected("lost connection");
            assert!(
                render_frame(&model, 80, 24)
                    .unwrap()
                    .contains("Acceptance uncertain")
            );
            let interrupt = handle_input(
                &mut model,
                Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::CONTROL)),
                78,
            );
            assert_eq!(interrupt, InputAction::Interrupt);
            let detach = handle_input(
                &mut model,
                Event::Key(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL)),
                78,
            );
            assert_eq!(detach, InputAction::Detach);
        }
    }

    #[test]
    fn all_twelve_combinations_render_required_states_and_frames() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/goldens/appearance");
        for layout in ViewLayout::ALL {
            for theme in Theme::ALL {
                let mut frames = String::new();
                for scenario in [
                    "idle",
                    "composing",
                    "streaming",
                    "reasoning-open",
                    "reasoning-hidden",
                    "tool-failed",
                ] {
                    let mut model = fixture_model(if scenario == "streaming" {
                        "streaming"
                    } else if scenario == "tool-failed" {
                        "tool-running"
                    } else {
                        "idle"
                    });
                    model.set_appearance(Appearance {
                        layout: *layout,
                        theme: *theme,
                    });
                    model.preview_reasoning = scenario.starts_with("reasoning");
                    model.thinking_visible = scenario != "reasoning-hidden";
                    if scenario == "composing" {
                        model
                            .editor
                            .insert("Unicode draft 👩‍💻 中\nKeep this visible");
                    }
                    if scenario == "tool-failed" {
                        model.projection.view["tool_calls"][0]["status"] = json!("failed");
                    }
                    for (w, h) in [(80, 24), (120, 40), (180, 45)] {
                        let actual = render_frame(&model, w, h).unwrap();
                        assert!(actual.contains(&format!("{} / {}", layout.name(), theme.name())));
                        assert!(actual.contains("Enter send"));
                        if scenario == "composing" {
                            assert!(actual.contains("Keep this visible"));
                        }
                        frames.push_str(&format!("=== {scenario} {w}x{h} ===\n{actual}\n"));
                    }
                }
                let path = root.join(format!("{}-{}.txt", layout.name(), theme.name()));
                if std::env::var_os("ELARA_UPDATE_GOLDENS").is_some() {
                    fs::create_dir_all(&root).unwrap();
                    fs::write(&path, &frames).unwrap();
                }
                assert_eq!(fs::read_to_string(path).unwrap(), frames);
            }
        }
    }
}
