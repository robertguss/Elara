//! Local composer state. All positions are UTF-8 grapheme boundaries.
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use std::borrow::Cow;
use std::ops::Range;
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

pub const MAX_INPUT_BYTES: usize = 64 * 1024;
const MAX_HISTORY: usize = 200;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Draft {
    text: String,
    cursor: usize,
    anchor: Option<usize>,
    desired_column: Option<usize>,
}

#[derive(Clone, Debug, Default)]
pub struct Editor {
    draft: Draft,
    revision: u64,
    history: Vec<String>,
    history_index: Option<usize>,
    saved_draft: Option<Draft>,
}

#[derive(Debug)]
pub(crate) struct EditorCell<'a> {
    pub text: Cow<'a, str>,
    pub selected: bool,
}

#[derive(Debug, Default)]
pub(crate) struct EditorRow<'a> {
    pub cells: Vec<EditorCell<'a>>,
}

#[derive(Debug)]
pub(crate) struct EditorLayout<'a> {
    pub rows: Vec<EditorRow<'a>>,
    pub cursor_row: usize,
    pub cursor_column: usize,
    positions: Vec<(usize, usize, usize)>,
}

fn sanitize(text: &str) -> String {
    text.replace("\r\n", "\n")
        .replace('\r', "\n")
        .chars()
        .filter(|c| !c.is_control() || *c == '\n' || *c == '\t')
        .collect()
}

impl Editor {
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn text(&self) -> &str {
        &self.draft.text
    }
    pub fn cursor(&self) -> usize {
        self.draft.cursor
    }
    pub fn selection(&self) -> Option<Range<usize>> {
        self.draft
            .anchor
            .filter(|a| *a != self.cursor())
            .map(|a| a.min(self.cursor())..a.max(self.cursor()))
    }
    pub fn clear(&mut self) {
        self.revision = self.revision.wrapping_add(1);
        self.draft = Draft::default();
        self.history_index = None;
        self.saved_draft = None;
    }
    /// Replace selection atomically; never silently truncate a pasted prompt.
    pub fn insert(&mut self, text: &str) -> bool {
        let text = sanitize(text);
        let range = self.selection().unwrap_or(self.cursor()..self.cursor());
        if self.text().len() - range.len() + text.len() > MAX_INPUT_BYTES {
            return false;
        }
        if self.text()[range.clone()] != text {
            self.revision = self.revision.wrapping_add(1);
        }
        self.draft.text.replace_range(range.clone(), &text);
        let end = range.start + text.len();
        // A newly inserted combining mark or ZWJ can merge adjacent graphemes.
        self.draft.cursor = self
            .text()
            .grapheme_indices(true)
            .map(|(i, _)| i)
            .chain(std::iter::once(self.text().len()))
            .find(|i| *i >= end)
            .unwrap();
        self.draft.anchor = None;
        self.draft.desired_column = None;
        true
    }
    pub fn set_history(&mut self, history: Vec<String>) {
        let history: Vec<String> = history
            .into_iter()
            .map(|s| sanitize(&s))
            .filter(|s| s.len() <= MAX_INPUT_BYTES)
            .rev()
            .take(MAX_HISTORY)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        if self.history != history {
            // Keep a recalled prompt and its original draft through authority refresh.
            let recalled = self
                .history_index
                .and_then(|i| self.history.get(i))
                .cloned();
            self.history = history;
            if self.history_index.is_some() {
                self.history_index = Some(
                    recalled
                        .and_then(|prompt| self.history.iter().rposition(|s| s == &prompt))
                        .unwrap_or(self.history.len()),
                );
            }
        }
    }
    pub fn history_previous(&mut self) {
        if self.history.is_empty() {
            return;
        }
        let index = match self.history_index {
            None => {
                self.saved_draft = Some(self.draft.clone());
                self.history.len() - 1
            }
            Some(0) => return,
            Some(i) => i - 1,
        };
        self.recall(index);
    }
    pub fn history_next(&mut self) {
        match self.history_index {
            Some(i) if i + 1 < self.history.len() => self.recall(i + 1),
            Some(_) => {
                self.revision = self.revision.wrapping_add(1);
                self.draft = self.saved_draft.take().unwrap_or_default();
                self.history_index = None;
            }
            None => {}
        }
    }
    fn recall(&mut self, index: usize) {
        self.revision = self.revision.wrapping_add(1);
        self.draft = Draft {
            text: self.history[index].clone(),
            cursor: self.history[index].len(),
            ..Draft::default()
        };
        self.history_index = Some(index);
    }
    fn previous(&self) -> usize {
        self.text()[..self.cursor()]
            .grapheme_indices(true)
            .next_back()
            .map_or(0, |(i, _)| i)
    }
    fn next(&self) -> usize {
        self.text()[self.cursor()..]
            .graphemes(true)
            .next()
            .map_or(self.cursor(), |g| self.cursor() + g.len())
    }
    fn word(&self, backwards: bool) -> usize {
        let mut target = self.cursor();

        let mut crossed_word = false;
        if backwards {
            for (i, g) in self.text()[..self.cursor()].grapheme_indices(true).rev() {
                let whitespace = g.chars().all(char::is_whitespace);
                if crossed_word && whitespace {
                    break;
                }
                crossed_word |= !whitespace;
                target = i;
            }
        } else {
            for (i, g) in self.text()[self.cursor()..]
                .grapheme_indices(true)
                .map(|(i, g)| (i + self.cursor(), g))
            {
                let whitespace = g.chars().all(char::is_whitespace);
                if crossed_word && whitespace {
                    break;
                }
                crossed_word |= !whitespace;
                target = i + g.len();
            }
        }
        target
    }
    fn move_to(&mut self, target: usize, selecting: bool) {
        let cursor = self.cursor();
        if selecting {
            self.draft.anchor.get_or_insert(cursor);
        } else {
            self.draft.anchor = None;
        }
        self.draft.cursor = target;
        self.draft.desired_column = None;
    }
    fn delete_to(&mut self, target: usize) {
        if self.selection().is_none() {
            self.draft.anchor = Some(target);
        }
        self.insert("");
    }
    fn vertical(&mut self, down: bool, selecting: bool, width: usize) {
        let layout = self.layout(width);
        let desired = self.draft.desired_column.unwrap_or(layout.cursor_column);
        let row = if down {
            (layout.cursor_row + 1).min(layout.rows.len() - 1)
        } else {
            layout.cursor_row.saturating_sub(1)
        };
        let target = layout
            .positions
            .iter()
            .filter(|(_, r, _)| *r == row)
            .min_by_key(|(_, _, c)| c.abs_diff(desired))
            .map(|(i, _, _)| *i)
            .unwrap_or(self.cursor());
        self.move_to(target, selecting);
        self.draft.desired_column = Some(desired);
    }
    pub fn handle_key(&mut self, key: KeyEvent, width: usize) -> bool {
        let selecting = key.modifiers.contains(KeyModifiers::SHIFT);
        let word = key
            .modifiers
            .intersects(KeyModifiers::ALT | KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Up if key.modifiers.contains(KeyModifiers::ALT) => self.history_previous(),
            KeyCode::Down if key.modifiers.contains(KeyModifiers::ALT) => self.history_next(),
            KeyCode::Up => self.vertical(false, selecting, width),
            KeyCode::Down => self.vertical(true, selecting, width),
            KeyCode::Left | KeyCode::Right => {
                let left = key.code == KeyCode::Left;
                let target = if !selecting && !word && self.selection().is_some() {
                    let r = self.selection().unwrap();
                    if left { r.start } else { r.end }
                } else if word {
                    self.word(left)
                } else if left {
                    self.previous()
                } else {
                    self.next()
                };
                self.move_to(target, selecting);
            }
            KeyCode::Home => {
                let target = if word {
                    0
                } else {
                    self.text()[..self.cursor()]
                        .rfind('\n')
                        .map_or(0, |i| i + 1)
                };
                self.move_to(target, selecting);
            }
            KeyCode::End => {
                let target = if word {
                    self.text().len()
                } else {
                    self.text()[self.cursor()..]
                        .find('\n')
                        .map_or(self.text().len(), |i| self.cursor() + i)
                };
                self.move_to(target, selecting);
            }
            KeyCode::Backspace => self.delete_to(if word {
                self.word(true)
            } else {
                self.previous()
            }),
            KeyCode::Delete => self.delete_to(if word { self.word(false) } else { self.next() }),
            KeyCode::Char('a') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.draft.anchor = Some(0);
                self.draft.cursor = self.text().len();
            }
            KeyCode::Char(c) if !word => {
                self.insert(&c.to_string());
            }
            KeyCode::Tab if !word => {
                self.insert("\t");
            }
            _ => return false,
        }
        true
    }
    /// Cell geometry used by rendering and vertical cursor movement alike.
    pub(crate) fn layout(&self, width: usize) -> EditorLayout<'_> {
        let width = width.max(1);
        let mut layout = EditorLayout {
            rows: vec![EditorRow::default()],
            cursor_row: 0,
            cursor_column: 0,
            positions: vec![],
        };
        let mut column = 0;
        let mut just_wrapped = false;
        for (i, g) in self.text().grapheme_indices(true) {
            let mut size = if g == "\t" {
                (4 - column % 4).min(width)
            } else {
                UnicodeWidthStr::width(g).min(width)
            };
            if g != "\n" && column + size > width {
                layout.rows.push(EditorRow::default());
                column = 0;
                if g == "\t" {
                    size = 4.min(width);
                }
            }
            layout.positions.push((i, layout.rows.len() - 1, column));
            let selected = self.selection().is_some_and(|r| r.contains(&i));
            if g == "\n" {
                // A selected hard line break remains visible as a highlighted cell.
                if selected && !just_wrapped {
                    layout.rows.last_mut().unwrap().cells.push(EditorCell {
                        text: " ".into(),
                        selected,
                    });
                }
                if !just_wrapped {
                    layout.rows.push(EditorRow::default());
                }
                column = 0;
                just_wrapped = false;
            } else {
                let text = if g == "\t" {
                    Cow::Owned(" ".repeat(size))
                } else if UnicodeWidthStr::width(g) > width {
                    "�".into()
                } else {
                    g.into()
                };
                layout
                    .rows
                    .last_mut()
                    .unwrap()
                    .cells
                    .push(EditorCell { text, selected });
                column += size;
                just_wrapped = column == width;
                if just_wrapped {
                    layout.rows.push(EditorRow::default());
                    column = 0;
                }
            }
        }
        layout
            .positions
            .push((self.text().len(), layout.rows.len() - 1, column));
        let (_, r, c) = layout
            .positions
            .iter()
            .find(|(i, _, _)| *i == self.cursor())
            .unwrap();
        layout.cursor_row = *r;
        layout.cursor_column = *c;
        layout
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn key(e: &mut Editor, code: KeyCode, modifiers: KeyModifiers) {
        assert!(e.handle_key(KeyEvent::new(code, modifiers), 5));
    }
    #[test]
    fn repeated_history_replacement_keeps_sentinel_in_bounds_and_restores_draft() {
        let mut e = Editor::default();
        e.insert("draft");
        e.set_history(vec!["a".into(), "b".into(), "c".into()]);
        e.history_previous();
        e.set_history(vec!["p".into(), "q".into(), "r".into()]);
        e.set_history(vec!["m".into(), "n".into()]);
        e.history_previous();
        assert_eq!(e.text(), "n");
        e.history_next();
        assert_eq!(e.text(), "draft");
    }

    #[test]
    fn no_op_delete_does_not_change_the_submitted_revision() {
        let mut e = Editor::default();
        e.insert("submitted");
        let revision = e.revision();
        key(&mut e, KeyCode::Delete, KeyModifiers::NONE);
        assert_eq!(e.revision(), revision);
    }

    #[test]
    fn edits_graphemes_and_selection_without_splitting_emoji() {
        let mut e = Editor::default();
        e.insert("ae\u{301}👨‍👩‍👧‍👦z");
        key(&mut e, KeyCode::Left, KeyModifiers::NONE);
        key(&mut e, KeyCode::Left, KeyModifiers::SHIFT);
        e.insert("中");
        assert_eq!(e.text(), "ae\u{301}中z");
        key(&mut e, KeyCode::Backspace, KeyModifiers::NONE);
        key(&mut e, KeyCode::Backspace, KeyModifiers::NONE);
        assert_eq!(e.text(), "az");
    }
    #[test]
    fn history_restores_exact_selected_draft() {
        let mut e = Editor::default();
        e.insert("draft");
        key(&mut e, KeyCode::Left, KeyModifiers::SHIFT);
        let draft = e.draft.clone();
        e.set_history(vec!["one".into(), "two".into()]);
        e.history_previous();
        e.insert(" edited");
        e.history_previous();
        assert_eq!(e.text(), "one");
        e.history_next();
        assert_eq!(e.text(), "two");
        e.history_next();
        assert_eq!(e.draft, draft);
    }
    #[test]
    fn paste_is_atomic_sanitized_and_bounded() {
        let mut e = Editor::default();
        e.insert("a\r\nb\t\u{1b}[31m\0\u{7f}");
        assert_eq!(e.text(), "a\nb\t[31m");
        let old = e.draft.clone();
        assert!(!e.insert(&"x".repeat(MAX_INPUT_BYTES)));
        assert_eq!(e.draft, old);
    }
    #[test]
    fn wrapped_navigation_remembers_column_and_resize_preserves_state() {
        let mut e = Editor::default();
        e.insert("abcd\nx\n12345");
        key(&mut e, KeyCode::Left, KeyModifiers::NONE); // row 2 column 4
        key(&mut e, KeyCode::Up, KeyModifiers::NONE);
        assert_eq!(e.cursor(), 6);
        key(&mut e, KeyCode::Up, KeyModifiers::NONE);
        assert_eq!(e.cursor(), 4);
        let old = e.draft.clone();
        e.layout(2);
        assert_eq!(e.draft, old);
        let mut wide = Editor::default();
        wide.insert("中\t👩‍💻");
        let frame = wide.layout(5);
        assert_eq!((frame.cursor_row, frame.cursor_column), (1, 2));
    }

    #[test]
    fn full_width_hard_break_does_not_add_a_phantom_row() {
        let mut e = Editor::default();
        e.insert("abcde\nx");
        let frame = e.layout(5);
        assert_eq!(frame.rows.len(), 2);
        assert_eq!((frame.cursor_row, frame.cursor_column), (1, 1));
    }
    #[test]
    fn history_refresh_preserves_original_draft() {
        let mut e = Editor::default();
        e.insert("draft");
        e.set_history(vec!["one".into()]);
        e.history_previous();
        e.insert(" edited");
        e.set_history(vec!["one".into(), "two".into()]);
        assert_eq!(e.text(), "one edited");
        e.history_next();
        e.history_next();
        assert_eq!(e.text(), "draft");
    }
    #[test]
    fn words_and_logical_line_edges() {
        let mut e = Editor::default();
        e.insert("one two\nthree");
        key(&mut e, KeyCode::Backspace, KeyModifiers::ALT);
        assert_eq!(e.text(), "one two\n");
        key(&mut e, KeyCode::Left, KeyModifiers::CONTROL);
        assert_eq!(e.cursor(), 4);
        key(&mut e, KeyCode::Home, KeyModifiers::NONE);
        assert_eq!(e.cursor(), 0);
        key(&mut e, KeyCode::End, KeyModifiers::SHIFT);
        assert_eq!(e.selection(), Some(0..7));
    }
}
