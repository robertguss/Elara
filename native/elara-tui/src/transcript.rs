use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use std::collections::{HashMap, HashSet};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

#[derive(Clone, Debug)]
pub(crate) struct Entry {
    pub id: String,
    pub text: String,
    pub lines: Vec<Line<'static>>,
    pub user: bool,
    pub stream: bool,
    pub prefix: usize,
    pub final_id: Option<String>,
    pub sections: Vec<(&'static str, std::ops::Range<usize>)>,
}
impl Entry {
    pub fn plain(id: &str, text: &str, user: bool) -> Self {
        Self {
            id: id.into(),
            text: text.into(),
            lines: text.split('\n').map(|s| Line::from(s.to_owned())).collect(),
            user,
            stream: false,
            prefix: 0,
            final_id: None,
            sections: Vec::new(),
        }
    }
    pub fn rendered(id: String, lines: Vec<Line<'static>>, user: bool, stream: bool) -> Self {
        // Every renderer supplies one four-column speaker span per logical line.
        let text = lines
            .iter()
            .map(|line| {
                line.spans
                    .iter()
                    .skip(1)
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n");
        Self {
            id,
            text,
            lines,
            user,
            stream,
            prefix: 1,
            final_id: None,
            sections: Vec::new(),
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Point {
    pub id: String,
    pub byte: usize,
}
#[derive(Clone, Debug)]
struct Cell {
    text: String,
    style: Style,
    start: usize,
    end: usize,
    chrome: bool,
}
#[derive(Clone, Debug)]
struct Row {
    id: String,
    start: usize,
    cells: Vec<Cell>,
}
#[derive(Clone, Debug)]
pub(crate) struct Transcript {
    pub focused: bool,
    pub follow: bool,
    pub anchor: Option<Point>,
    pub selected: Option<String>,
    pub selection: Option<(Point, Point)>,
    pub drag_anchor: Option<(Point, Point)>,
    pub searching: bool,
    pub query: String,
    pub matches: Vec<Point>,
    pub match_index: usize,
    entries: Vec<Entry>,
    rows: Vec<Row>,
    pub top: usize,
    height: usize,
    pub rect: ratatui::layout::Rect,
    pub source_key: Option<(String, String, u64, u64)>,
    width: usize,
    entry_ranks: HashMap<String, usize>,
    match_starts: HashSet<(usize, usize)>,
    #[cfg(test)]
    pub layout_rebuilds: usize,
}
impl Default for Transcript {
    fn default() -> Self {
        Self {
            focused: false,
            follow: true,
            anchor: None,
            selected: None,
            selection: None,
            drag_anchor: None,
            searching: false,
            query: String::new(),
            matches: Vec::new(),
            match_index: 0,
            entries: Vec::new(),
            rows: Vec::new(),
            top: 0,
            height: 1,
            rect: Default::default(),
            source_key: None,
            width: 0,
            entry_ranks: HashMap::new(),
            match_starts: HashSet::new(),
            #[cfg(test)]
            layout_rebuilds: 0,
        }
    }
}
impl Transcript {
    #[cfg(test)]
    pub fn layout(&mut self, entries: Vec<Entry>, width: usize, height: usize) {
        self.update(Some(entries), width, height);
    }
    pub fn update(&mut self, entries: Option<Vec<Entry>>, width: usize, height: usize) {
        let source_changed = entries.is_some();
        if let Some(entries) = entries {
            let remap = |point: &mut Point| {
                if !entries.iter().any(|e| e.id == point.id) {
                    let old = self
                        .entries
                        .iter()
                        .position(|e| e.id == point.id)
                        .unwrap_or(0);
                    let candidate = self
                        .entries
                        .get(old)
                        .and_then(|previous| previous.final_id.as_ref())
                        .and_then(|id| entries.iter().find(|e| &e.id == id));
                    let survivor = self
                        .entries
                        .iter()
                        .enumerate()
                        .filter_map(|(index, previous)| {
                            entries
                                .iter()
                                .find(|entry| entry.id == previous.id)
                                .map(|entry| (index.abs_diff(old), index, entry))
                        })
                        .min_by_key(|(distance, index, _)| (*distance, *index))
                        .map(|(_, _, entry)| entry);
                    if let Some(entry) = candidate.or(survivor).or_else(|| entries.first()) {
                        point.id.clone_from(&entry.id);
                    }
                }
                if let Some(entry) = entries.iter().find(|e| e.id == point.id) {
                    if let Some(previous) = self.entries.iter().find(|e| e.id == point.id)
                        && let Some((name, old)) = previous
                            .sections
                            .iter()
                            .find(|(_, range)| range.start <= point.byte && point.byte <= range.end)
                        && let Some((_, new)) =
                            entry.sections.iter().find(|(section, _)| section == name)
                    {
                        point.byte = new.start + (point.byte - old.start).min(new.len());
                    }
                    point.byte = point.byte.min(entry.text.len());
                    point.byte = entry
                        .text
                        .grapheme_indices(true)
                        .map(|(i, _)| i)
                        .chain(std::iter::once(entry.text.len()))
                        .take_while(|&i| i <= point.byte)
                        .last()
                        .unwrap_or(0);
                }
            };
            if let Some(anchor) = &mut self.anchor {
                remap(anchor);
            }
            if let Some(id) = &mut self.selected {
                let mut point = Point {
                    id: id.clone(),
                    byte: 0,
                };
                remap(&mut point);
                *id = point.id;
            }
            if let Some((a, b)) = &mut self.selection {
                remap(a);
                remap(b);
            }
            if let Some((a, b)) = &mut self.drag_anchor {
                remap(a);
                remap(b);
            }
            self.entries = entries;
            self.entry_ranks = self
                .entries
                .iter()
                .enumerate()
                .map(|(i, entry)| (entry.id.clone(), i))
                .collect();
            self.refresh_matches();
        }
        if source_changed || width != self.width {
            self.width = width;
            #[cfg(test)]
            {
                self.layout_rebuilds += 1;
            }
            self.rows.clear();
            for entry in &self.entries {
                let mut byte = 0;
                for (line_index, line) in entry.lines.iter().enumerate() {
                    let mut row = Row {
                        id: entry.id.clone(),
                        start: byte,
                        cells: Vec::new(),
                    };
                    let mut column = 0;
                    for (span_index, span) in line.spans.iter().enumerate() {
                        for grapheme in span.content.graphemes(true) {
                            let chrome = span_index < entry.prefix;
                            let size = if grapheme == "\t" {
                                4 - column % 4
                            } else {
                                grapheme.width()
                            };
                            if column + size > width.max(1) && !row.cells.is_empty() {
                                self.rows.push(row);
                                row = Row {
                                    id: entry.id.clone(),
                                    start: byte,
                                    cells: Vec::new(),
                                };
                                column = 0;
                            }
                            let end = if chrome { byte } else { byte + grapheme.len() };
                            let display = if grapheme == "\t" {
                                " ".repeat((4 - column % 4).min(width.max(1)))
                            } else if grapheme.width() > width.max(1) {
                                "�".into()
                            } else {
                                grapheme.into()
                            };
                            let size = display.width();
                            row.cells.push(Cell {
                                text: display,
                                style: line.style.patch(span.style),
                                start: byte,
                                end,
                                chrome,
                            });
                            byte = end;
                            column += size;
                        }
                    }
                    self.rows.push(row);
                    if line_index + 1 < entry.lines.len() {
                        byte += 1;
                    }
                }
                if entry.stream {
                    if self.rows.last().is_some_and(|row| {
                        row.cells
                            .iter()
                            .map(|cell| cell.text.width())
                            .sum::<usize>()
                            >= width.max(1)
                    }) {
                        self.rows.push(Row {
                            id: entry.id.clone(),
                            start: byte,
                            cells: Vec::new(),
                        });
                    }
                    let row = self.rows.last_mut().expect("entry has a line");
                    row.cells.push(Cell {
                        text: "▌".into(),
                        style: Style::default(),
                        start: byte,
                        end: byte,
                        chrome: true,
                    });
                }
            }
        }
        self.height = height.max(1);
        self.top = if self.follow {
            self.rows.len().saturating_sub(self.height)
        } else {
            self.anchor
                .as_ref()
                .and_then(|p| self.row_for(p))
                .unwrap_or(0)
        };
        self.top = self.top.min(self.rows.len().saturating_sub(1));
        if self.selected.is_none() {
            self.selected = self.rows.get(self.top).map(|r| r.id.clone());
        }
    }
    fn row_for(&self, point: &Point) -> Option<usize> {
        self.rows
            .iter()
            .enumerate()
            .filter(|(_, r)| r.id == point.id && r.start <= point.byte)
            .map(|(i, _)| i)
            .next_back()
            .or_else(|| {
                // A presentation-only entry can move into a pane without losing its anchor.
                let rank = self.entry_ranks.get(&point.id)?;
                self.rows
                    .iter()
                    .rposition(|row| self.entry_ranks.get(&row.id).is_some_and(|r| r < rank))
            })
    }
    fn pin(&mut self) {
        self.follow = false;
        self.anchor = self.rows.get(self.top).map(|r| Point {
            id: r.id.clone(),
            byte: r.start,
        });
        self.selected = self.anchor.as_ref().map(|p| p.id.clone());
    }
    pub fn scroll(&mut self, delta: isize) {
        self.top = self
            .top
            .saturating_add_signed(delta)
            .min(self.rows.len().saturating_sub(1));
        self.pin();
    }
    pub fn page(&mut self, direction: isize) {
        self.scroll(direction * self.height.saturating_sub(1).max(1) as isize);
    }
    pub fn home(&mut self) {
        self.top = 0;
        self.pin();
    }
    pub fn tail(&mut self) {
        self.follow = true;
        self.anchor = None;
        self.top = self.rows.len().saturating_sub(self.height);
        self.selected = self.entries.last().map(|e| e.id.clone());
    }
    pub fn selected_user_turn(&self) -> usize {
        let selected = self
            .selected
            .as_ref()
            .or(self.anchor.as_ref().map(|p| &p.id));
        let end = selected
            .and_then(|id| self.entry_ranks.get(id))
            .map_or(0, |i| i + 1);
        self.entries
            .iter()
            .take(end)
            .filter(|entry| entry.user)
            .count()
    }
    pub fn user_turn(&mut self, direction: isize) {
        let current = self
            .selected
            .as_ref()
            .and_then(|id| self.entries.iter().position(|e| &e.id == id))
            .unwrap_or(0);
        let target = if direction < 0 {
            (0..current).rev().find(|&i| self.entries[i].user)
        } else {
            ((current + 1)..self.entries.len()).find(|&i| self.entries[i].user)
        };
        if let Some(i) = target {
            self.jump(Point {
                id: self.entries[i].id.clone(),
                byte: 0,
            });
        }
    }
    fn jump(&mut self, point: Point) {
        if let Some(row) = self.row_for(&point) {
            self.top = row;
            self.pin();
            self.anchor = Some(point);
        }
    }
    pub fn refresh_matches(&mut self) {
        self.matches.clear();
        self.match_starts.clear();
        if self.query.is_empty() {
            self.match_index = 0;
            return;
        }
        let query = self.query.to_lowercase();
        for entry in &self.entries {
            // Lowercasing can change byte length: map folded bytes back to original chars.
            let mut folded = String::new();
            let mut offsets = Vec::new();
            for (byte, c) in entry.text.char_indices() {
                let lower = c.to_lowercase().to_string();
                offsets.extend(std::iter::repeat_n(byte, lower.len()));
                folded.push_str(&lower);
            }
            for (byte, _) in folded.match_indices(&query) {
                self.matches.push(Point {
                    id: entry.id.clone(),
                    byte: offsets[byte],
                });
            }
        }
        self.match_starts = self
            .matches
            .iter()
            .map(|point| (self.entry_ranks[&point.id], point.byte))
            .collect();
        self.match_index = self.match_index.min(self.matches.len().saturating_sub(1));
    }
    pub fn append_query(&mut self, text: &str) -> bool {
        let sanitized: String = text
            .replace("\r\n", "\n")
            .chars()
            .filter_map(|c| match c {
                '\n' | '\r' | '\t' => Some(' '),
                c if c.is_control() => None,
                c => Some(c),
            })
            .collect();
        if self.query.len() + sanitized.len() > 4096 {
            return false;
        }
        self.query.push_str(&sanitized);
        self.search_changed();
        true
    }
    pub fn search_changed(&mut self) {
        self.match_index = 0;
        self.refresh_matches();
        self.show_match();
    }
    fn show_match(&mut self) {
        if let Some(point) = self.matches.get(self.match_index).cloned() {
            self.jump(point);
        }
    }
    pub fn next_match(&mut self, backwards: bool) {
        if !self.matches.is_empty() {
            self.match_index = (self.match_index
                + if backwards { self.matches.len() - 1 } else { 1 })
                % self.matches.len();
            self.show_match();
        }
    }
    fn ordered_selection(&self) -> Option<(&Point, &Point)> {
        let (a, b) = self.selection.as_ref()?;
        let rank = |p: &Point| {
            (
                self.entries.iter().position(|e| e.id == p.id).unwrap_or(0),
                p.byte,
            )
        };
        Some(if rank(a) <= rank(b) { (a, b) } else { (b, a) })
    }
    pub fn copy_selection(&self) -> Option<String> {
        let (a, b) = self.ordered_selection()?;
        let start = self.entries.iter().position(|e| e.id == a.id)?;
        let end = self.entries.iter().position(|e| e.id == b.id)?;
        Some(
            self.entries[start..=end]
                .iter()
                .map(|e| {
                    &e.text[if e.id == a.id { a.byte } else { 0 }..if e.id == b.id {
                        b.byte
                    } else {
                        e.text.len()
                    }]
                })
                .collect::<Vec<_>>()
                .join("\n"),
        )
    }
    pub fn copy_entry(&self) -> Option<String> {
        self.entries
            .iter()
            .find(|e| Some(&e.id) == self.selected.as_ref())
            .map(|e| e.text.clone())
    }
    pub fn begin_drag(&mut self, column: u16, row: u16) {
        self.drag_anchor = self
            .mouse_point(column, row, false)
            .zip(self.mouse_point(column, row, true));
        if let Some((start, _)) = &self.drag_anchor {
            self.selected = Some(start.id.clone());
            self.selection = Some((start.clone(), start.clone()));
        }
    }
    pub fn drag_to(&mut self, column: u16, row: u16) {
        let Some((anchor_start, anchor_end)) = &self.drag_anchor else {
            return;
        };
        let Some(start) = self.mouse_point(column, row, false) else {
            return;
        };
        let Some(end) = self.mouse_point(column, row, true) else {
            return;
        };
        let rank = |p: &Point| (self.entry_ranks.get(&p.id).copied().unwrap_or(0), p.byte);
        self.selection = Some(if rank(&start) < rank(anchor_start) {
            (start, anchor_end.clone())
        } else {
            (anchor_start.clone(), end)
        });
    }
    pub fn mouse_point(&self, column: u16, row: u16, end: bool) -> Option<Point> {
        let y = row.saturating_sub(self.rect.y) as usize;
        let x = column.saturating_sub(self.rect.x) as usize;
        let row = self
            .rows
            .get((self.top + y).min(self.rows.len().saturating_sub(1)))?;
        let mut width = 0;
        for cell in &row.cells {
            width += cell.text.width();
            if x < width {
                return Some(Point {
                    id: row.id.clone(),
                    byte: if end { cell.end } else { cell.start },
                });
            }
        }
        Some(Point {
            id: row.id.clone(),
            byte: row.cells.last().map_or(row.start, |c| c.end),
        })
    }
    pub fn visible_lines(&self) -> Vec<Line<'static>> {
        let selection = self.ordered_selection();
        let rank = |id: &str, byte: usize| (self.entry_ranks.get(id).copied().unwrap_or(0), byte);
        self.rows
            .iter()
            .skip(self.top)
            .take(self.height)
            .map(|row| {
                Line::from(
                    row.cells
                        .iter()
                        .map(|cell| {
                            let selected = selection.is_some_and(|(a, b)| {
                                !cell.chrome
                                    && rank(&row.id, cell.end) > rank(&a.id, a.byte)
                                    && rank(&row.id, cell.start) < rank(&b.id, b.byte)
                            });
                            let matched = !cell.chrome
                                && self.match_starts.contains(&rank(&row.id, cell.start));
                            Span::styled(
                                cell.text.clone(),
                                if selected {
                                    cell.style.bg(Color::Blue).fg(Color::White)
                                } else if matched {
                                    cell.style.bg(Color::Yellow).fg(Color::Black)
                                } else if self.focused && self.selected.as_deref() == Some(&row.id)
                                {
                                    cell.style.bg(Color::DarkGray)
                                } else {
                                    cell.style
                                },
                            )
                        })
                        .collect::<Vec<_>>(),
                )
            })
            .collect()
    }
    pub fn title(&self) -> String {
        let mode = if self.follow { "FOLLOW" } else { "PAUSED" };
        let focus = if self.focused {
            "transcript focus"
        } else {
            "prompt focus"
        };
        let search = if self.searching || !self.query.is_empty() {
            format!(
                " · /{} · {}/{} matches",
                self.query,
                if self.matches.is_empty() {
                    0
                } else {
                    self.match_index + 1
                },
                self.matches.len()
            )
        } else {
            String::new()
        };
        format!(" transcript · {focus} · {mode}{search} ")
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wrapped_unicode_copy_and_anchor() {
        let entries = vec![
            Entry::plain("m0", "a👩‍💻bc\nnext", true),
            Entry::plain("m1", "last", false),
        ];
        let mut state = Transcript::default();
        state.layout(entries.clone(), 4, 2);
        state.scroll(-100);
        let anchor = state.anchor.clone();
        state.layout(entries, 8, 2);
        assert_eq!(state.anchor, anchor);
        state.selection = Some((
            Point {
                id: "m0".into(),
                byte: 1,
            },
            Point {
                id: "m1".into(),
                byte: 4,
            },
        ));
        assert_eq!(state.copy_selection().unwrap(), "👩‍💻bc\nnext\nlast");
        assert!(!state.follow);
        state.tail();
        assert!(state.follow);
    }
}

#[cfg(test)]
mod navigation_tests {
    use super::*;

    #[test]
    fn finalization_uses_expected_message_position_even_for_identical_text() {
        let prior = Entry::plain("session:message:0", "same", false);
        let mut stream = Entry::plain("session:stream:live", "same", false);
        stream.stream = true;
        stream.final_id = Some("session:message:1".into());
        let mut state = Transcript::default();
        state.layout(vec![prior.clone(), stream.clone()], 20, 1);
        state.scroll(0);
        state.selection = Some((
            Point {
                id: stream.id.clone(),
                byte: 0,
            },
            Point {
                id: stream.id,
                byte: 4,
            },
        ));
        state.layout(
            vec![
                prior,
                Entry::plain("session:message:1", "same finished", false),
            ],
            20,
            1,
        );
        assert_eq!(state.anchor.as_ref().unwrap().id, "session:message:1");
        assert_eq!(state.copy_selection().as_deref(), Some("same"));
        assert_eq!(state.copy_entry().as_deref(), Some("same finished"));
    }

    #[test]
    fn output_and_repeated_layout_do_not_move_paused_anchor_or_selection() {
        let first = Entry::plain("m0", &"a👩‍💻漢字".repeat(40), true);
        let mut state = Transcript::default();
        state.layout(vec![first.clone()], 12, 3);
        state.home();
        state.scroll(3);
        let anchor = state.anchor.clone();
        for width in [12, 30, 8, 12] {
            state.layout(
                vec![
                    first.clone(),
                    Entry::plain("stream", "additional output", false),
                ],
                width,
                3,
            );
            assert_eq!(state.anchor, anchor);
            assert!(!state.follow);
        }
        state.tail();
        state.layout(
            vec![
                first,
                Entry::plain("stream", &"additional output".repeat(30), false),
            ],
            12,
            3,
        );
        assert_eq!(state.top, state.rows.len() - 3);
    }

    #[test]
    fn removed_entry_falls_back_to_surviving_position_and_clamps_graphemes() {
        let mut state = Transcript::default();
        state.layout(vec![Entry::plain("old", "abcdef", true)], 10, 1);
        state.home();
        state.selection = Some((
            Point {
                id: "old".into(),
                byte: 1,
            },
            Point {
                id: "old".into(),
                byte: 5,
            },
        ));
        state.layout(vec![Entry::plain("new", "👩‍💻", true)], 10, 1);
        assert_eq!(state.selected.as_deref(), Some("new"));
        assert_eq!(state.copy_selection().as_deref(), Some(""));
    }

    #[test]
    fn search_maps_unicode_lowercase_offsets_and_cycles() {
        let mut state = Transcript::default();
        state.layout(
            vec![
                Entry::plain("m0", "İx NEEDLE\nneedle", true),
                Entry::plain("m1", "Needle", false),
            ],
            8,
            2,
        );
        state.query = "needle".into();
        state.search_changed();
        assert_eq!(state.matches.len(), 3);
        assert_eq!(state.matches[0].byte, "İx ".len());
        state.next_match(true);
        assert_eq!(state.match_index, 2);
        assert_eq!(state.selected.as_deref(), Some("m1"));
        state.next_match(false);
        assert_eq!(state.match_index, 0);
        assert!(state.title().contains("1/3 matches"));
    }

    #[test]
    fn mouse_selection_skips_speaker_and_soft_wraps_but_keeps_tabs_and_newlines() {
        let lines = vec![
            Line::from(vec![Span::raw("you "), Span::raw("a\t👩‍💻b")]),
            Line::from(vec![Span::raw("    "), Span::raw("last")]),
        ];
        let entry = Entry::rendered("m0".into(), lines, true, false);
        let mut state = Transcript::default();
        state.layout(vec![entry], 8, 10);
        state.home();
        assert_eq!(state.copy_entry().as_deref(), Some("a\t👩‍💻b\nlast"));
        state.rect = ratatui::layout::Rect::new(1, 1, 8, 10);
        let start = state.mouse_point(1, 1, false).unwrap();
        let end = Point {
            id: "m0".into(),
            byte: state.entries[0].text.len(),
        };
        state.selection = Some((end, start));
        assert_eq!(state.copy_selection().as_deref(), Some("a\t👩‍💻b\nlast"));
    }

    #[test]
    fn user_turns_and_pages_preserve_explicit_follow_choice() {
        let mut state = Transcript::default();
        state.layout(
            vec![
                Entry::plain("u0", "first", true),
                Entry::plain("a0", "answer", false),
                Entry::plain("u1", "next", true),
                Entry::plain("a1", "answer", false),
            ],
            20,
            2,
        );
        state.home();
        state.user_turn(1);
        assert_eq!(state.selected.as_deref(), Some("u1"));
        state.user_turn(-1);
        assert_eq!(state.selected.as_deref(), Some("u0"));
        state.page(1);
        assert_eq!(state.top, 1);
        assert!(!state.follow);
        state.scroll(100);
        assert!(!state.follow);
        state.tail();
        assert!(state.follow);
    }
    #[test]
    fn narrow_rows_never_overflow_and_keep_original_copy_bytes() {
        let mut entry = Entry::plain("m0", "👩‍💻\t漢", false);
        entry.stream = true;
        let mut state = Transcript::default();
        state.layout(vec![entry], 1, 20);
        assert!(
            state
                .rows
                .iter()
                .all(|row| row.cells.iter().map(|c| c.text.width()).sum::<usize>() <= 1)
        );
        assert_eq!(state.copy_entry().as_deref(), Some("👩‍💻\t漢"));
    }
    #[test]
    fn search_paste_limit_is_atomic_and_unicode_safe() {
        let mut state = Transcript::default();
        assert!(state.append_query("İ\r\n漢\t\u{1b}"));
        assert_eq!(state.query, "İ 漢 ");
        let original = state.query.clone();
        assert!(!state.append_query(&"👩‍💻".repeat(4096)));
        assert_eq!(state.query, original);
    }
}
