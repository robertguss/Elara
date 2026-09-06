use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use std::collections::{HashMap, HashSet};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

/// A presentation-only row placed above or below an entry's source lines.
/// Synthetic rows carry no bytes: they never change `Entry::text`, copy
/// ranges, or search offsets.
#[derive(Clone, Debug)]
pub(crate) enum Synthetic {
    /// Full-width rule such as `─────` or a box edge `┌────┐`.
    Rule {
        left: &'static str,
        fill: char,
        right: &'static str,
        style: Style,
    },
    /// Decorated chrome text (eyebrow labels, footers), with the entry's
    /// gutter, fill, and edge; `tail` is right-aligned on the same row.
    Text {
        spans: Vec<Span<'static>>,
        tail: Vec<Span<'static>>,
    },
    /// An empty spacer row with no decoration.
    Blank,
}
/// Per-logical-line decoration overrides.
#[derive(Clone, Debug, Default)]
pub(crate) struct LineDecor {
    pub fill: Option<Style>,
    pub indent: Vec<Span<'static>>,
    pub tail: Vec<Span<'static>>,
}
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
    /// Chrome prepended to every visual row, including wrapped continuations.
    pub gutter: Vec<Span<'static>>,
    /// Chrome appended after full-width padding on every visual row.
    pub edge: Vec<Span<'static>>,
    /// Pad every row to the full width with this style (row background).
    pub fill: Option<Style>,
    pub line_decor: HashMap<usize, LineDecor>,
    pub above: Vec<Synthetic>,
    pub below: Vec<Synthetic>,
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
            gutter: Vec::new(),
            edge: Vec::new(),
            fill: None,
            line_decor: HashMap::new(),
            above: Vec::new(),
            below: Vec::new(),
        }
    }
    pub fn rendered(id: String, lines: Vec<Line<'static>>, user: bool, stream: bool) -> Self {
        // Every renderer supplies one chrome span per logical line (may be empty).
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
            gutter: Vec::new(),
            edge: Vec::new(),
            fill: None,
            line_decor: HashMap::new(),
            above: Vec::new(),
            below: Vec::new(),
        }
    }
    pub fn tail(&mut self, line: usize, tail: Vec<Span<'static>>) {
        self.line_decor.entry(line).or_default().tail = tail;
    }
    pub fn decorate_line(&mut self, line: usize, fill: Option<Style>, indent: Vec<Span<'static>>) {
        let decor = self.line_decor.entry(line).or_default();
        decor.fill = fill;
        decor.indent = indent;
    }
    /// Apply one style to every span of every source line (e.g. muted thinking).
    pub fn restyle(&mut self, style: Style) {
        for line in &mut self.lines {
            line.style = line.style.patch(style);
        }
    }
}
fn spans_width(spans: &[Span<'_>]) -> usize {
    spans.iter().map(|s| s.content.width()).sum()
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
    /// A literal source space: a soft-wrap opportunity.
    space: bool,
}
#[derive(Clone, Debug)]
struct Row {
    id: String,
    start: usize,
    cells: Vec<Cell>,
    /// Position among consecutive rows of this entry sharing `start`, so a
    /// viewport pinned on a synthetic row does not drift onto its neighbour.
    ordinal: usize,
    /// Row background applied by `fill`; focus highlighting may replace it.
    fill_bg: Option<Color>,
}
/// Builds the visual rows of one entry: source lines are wrapped first, then
/// each row is assembled as `gutter | indent | body | tail | padding | edge`.
struct RowBuilder<'a> {
    entry: &'a Entry,
    width: usize,
    gutter_width: usize,
    edge_width: usize,
    rows: Vec<Row>,
}
impl<'a> RowBuilder<'a> {
    fn new(entry: &'a Entry, width: usize) -> Self {
        let width = width.max(1);
        // Decoration degrades before the body loses its last column.
        let mut gutter_width = spans_width(&entry.gutter);
        let mut edge_width = spans_width(&entry.edge);
        if gutter_width + edge_width >= width {
            edge_width = 0;
            gutter_width = gutter_width.min(width.saturating_sub(1));
        }
        Self {
            entry,
            width,
            gutter_width,
            edge_width,
            rows: Vec::new(),
        }
    }
    fn chrome(text: impl Into<String>, style: Style, byte: usize) -> Cell {
        Cell {
            text: text.into(),
            style,
            start: byte,
            end: byte,
            chrome: true,
            space: false,
        }
    }
    /// Soft-wrap at the last space in `row` so words stay whole. Returns the
    /// cells carried to the next row and that row's first source byte; an
    /// unbreakable row starts the next one empty at `byte`.
    fn break_word(row: &mut Vec<Cell>, byte: usize) -> (Vec<Cell>, usize) {
        let space = row
            .iter()
            .rposition(|cell| cell.space)
            .filter(|index| index + 1 < row.len());
        let Some(space) = space else {
            return (Vec::new(), byte);
        };
        let carried = row.split_off(space + 1);
        let start = carried[0].start;
        (carried, start)
    }
    fn fixed(&self, spans: &[Span<'static>], budget: usize, base: Style, byte: usize) -> Vec<Cell> {
        let mut cells = Vec::new();
        let mut used = 0;
        for span in spans {
            let mut text = String::new();
            for grapheme in span.content.graphemes(true) {
                if used + grapheme.width() > budget {
                    break;
                }
                used += grapheme.width();
                text.push_str(grapheme);
            }
            if !text.is_empty() {
                cells.push(Self::chrome(text, base.patch(span.style), byte));
            }
        }
        cells
    }
    /// Assemble one visual row from body cells whose source bytes are already set.
    fn finish(&mut self, body: Vec<Cell>, start: usize, decor: Option<&LineDecor>, last: bool) {
        let entry = self.entry;
        let fill = decor.and_then(|d| d.fill).or(entry.fill);
        let base = fill.unwrap_or_default();
        let end = body.last().map_or(start, |cell| cell.end);
        let mut cells = Vec::new();
        if self.gutter_width > 0 {
            cells.extend(self.fixed(&entry.gutter, self.gutter_width, base, start));
        }
        let indent_budget = self
            .width
            .saturating_sub(self.gutter_width + self.edge_width + 1);
        let indent = decor.map_or(&[][..], |d| d.indent.as_slice());
        cells.extend(self.fixed(indent, indent_budget, base, start));
        let mut used: usize = cells.iter().map(|c| c.text.width()).sum();
        used += body.iter().map(|c| c.text.width()).sum::<usize>();
        cells.extend(body);
        let remaining = self.width.saturating_sub(used + self.edge_width);
        let tail = decor
            .filter(|_| last)
            .map_or(&[][..], |d| d.tail.as_slice());
        let tail_width = spans_width(tail);
        let mut padding = remaining;
        if !tail.is_empty() && tail_width < remaining {
            padding = remaining - tail_width;
            let mut tail_cells = self.fixed(tail, tail_width, base, end);
            if padding > 0 {
                cells.push(Self::chrome(" ".repeat(padding), base, end));
            }
            cells.append(&mut tail_cells);
            padding = 0;
        }
        if padding > 0 && (fill.is_some() || self.edge_width > 0) {
            cells.push(Self::chrome(" ".repeat(padding), base, end));
        }
        if self.edge_width > 0 {
            cells.extend(self.fixed(&entry.edge, self.edge_width, base, end));
        }
        self.rows.push(Row {
            id: entry.id.clone(),
            start,
            cells,
            ordinal: 0,
            fill_bg: fill.and_then(|s| s.bg),
        });
    }
    fn synthetic(&mut self, row: &Synthetic, byte: usize) {
        match row {
            Synthetic::Blank => self.rows.push(Row {
                id: self.entry.id.clone(),
                start: byte,
                cells: Vec::new(),
                ordinal: 0,
                fill_bg: None,
            }),
            Synthetic::Rule {
                left,
                fill,
                right,
                style,
            } => {
                let mut text = String::new();
                let caps = left.width() + right.width();
                if caps <= self.width {
                    text.push_str(left);
                    text.extend(std::iter::repeat_n(*fill, self.width - caps));
                    text.push_str(right);
                } else {
                    text.extend(std::iter::repeat_n(*fill, self.width));
                }
                self.rows.push(Row {
                    id: self.entry.id.clone(),
                    start: byte,
                    cells: vec![Self::chrome(text, *style, byte)],
                    ordinal: 0,
                    fill_bg: style.bg,
                });
            }
            Synthetic::Text { spans, tail } => {
                let budget = self
                    .width
                    .saturating_sub(self.gutter_width + self.edge_width)
                    .max(1);
                let body = self.fixed(spans, budget, Style::default(), byte);
                let decor = LineDecor {
                    fill: None,
                    indent: Vec::new(),
                    tail: tail.clone(),
                };
                self.finish(body, byte, Some(&decor), true);
            }
        }
    }
    /// Wrap the entry's source lines and append the stream cursor to the body.
    fn body(&mut self) {
        let entry = self.entry;
        let mut byte = 0;
        for (line_index, line) in entry.lines.iter().enumerate() {
            let decor = entry.line_decor.get(&line_index);
            let fill = decor
                .and_then(|d| d.fill)
                .or(entry.fill)
                .unwrap_or_default();
            let indent_width = decor.map_or(0, |d| spans_width(&d.indent)).min(
                self.width
                    .saturating_sub(self.gutter_width + self.edge_width + 1),
            );
            let offset = self.gutter_width + indent_width;
            let capacity = self.width.saturating_sub(offset + self.edge_width).max(1);
            let mut flow: Vec<Vec<Cell>> = vec![Vec::new()];
            let mut starts = vec![byte];
            let mut column = 0;
            for (span_index, span) in line.spans.iter().enumerate() {
                for grapheme in span.content.graphemes(true) {
                    let chrome = span_index < entry.prefix;
                    let size = if grapheme == "\t" {
                        4 - (offset + column) % 4
                    } else {
                        grapheme.width()
                    };
                    if column + size > capacity && !flow.last().unwrap().is_empty() {
                        let (carried, start) = if grapheme == " " {
                            (Vec::new(), byte)
                        } else {
                            Self::break_word(flow.last_mut().unwrap(), byte)
                        };
                        column = carried.iter().map(|cell| cell.text.width()).sum();
                        flow.push(carried);
                        starts.push(start);
                    }
                    let end = if chrome { byte } else { byte + grapheme.len() };
                    let display = if grapheme == "\t" {
                        " ".repeat((4 - (offset + column) % 4).min(capacity))
                    } else if grapheme.width() > capacity {
                        "�".into()
                    } else {
                        grapheme.into()
                    };
                    let size = display.width();
                    flow.last_mut().unwrap().push(Cell {
                        text: display,
                        style: fill.patch(line.style).patch(span.style),
                        start: byte,
                        end,
                        chrome,
                        space: !chrome && grapheme == " ",
                    });
                    byte = end;
                    column += size;
                }
            }
            if entry.stream && line_index + 1 == entry.lines.len() {
                let full = flow
                    .last()
                    .unwrap()
                    .iter()
                    .map(|cell| cell.text.width())
                    .sum::<usize>()
                    >= capacity;
                if full {
                    flow.push(Vec::new());
                    starts.push(byte);
                }
                flow.last_mut()
                    .unwrap()
                    .push(Self::chrome("▌", Style::default(), byte));
            }
            let count = flow.len();
            for (index, (cells, start)) in flow.into_iter().zip(starts).enumerate() {
                self.finish(cells, start, decor, index + 1 == count);
            }
            if line_index + 1 < entry.lines.len() {
                byte += 1;
            }
        }
    }
    fn build(mut self) -> Vec<Row> {
        if self.entry.lines.is_empty() {
            // Hidden entries keep identity and copy ranges but draw nothing.
            return Vec::new();
        }
        for row in &self.entry.above {
            self.synthetic(row, 0);
        }
        self.body();
        let end = self.entry.text.len();
        for row in &self.entry.below {
            self.synthetic(row, end);
        }
        let mut previous: Option<usize> = None;
        let mut ordinal = 0;
        for row in &mut self.rows {
            ordinal = if previous == Some(row.start) {
                ordinal + 1
            } else {
                0
            };
            row.ordinal = ordinal;
            previous = Some(row.start);
        }
        self.rows
    }
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
    anchor_ordinal: usize,
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
            anchor_ordinal: 0,
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
                self.rows.extend(RowBuilder::new(entry, width).build());
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
        let group = self
            .rows
            .iter()
            .enumerate()
            .filter(|(_, r)| r.id == point.id && r.start <= point.byte)
            .map(|(i, _)| i)
            .next_back()
            .map(|last| {
                // Rewind to the first row of the (id, start) group, then step
                // forward by the pinned ordinal (clamped to the group).
                let start = self.rows[last].start;
                let first = (0..=last)
                    .rev()
                    .take_while(|&i| self.rows[i].id == point.id && self.rows[i].start == start)
                    .last()
                    .unwrap_or(last);
                (first + self.anchor_ordinal).min(last)
            });
        group.or_else(|| {
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
        self.anchor_ordinal = self.rows.get(self.top).map_or(0, |r| r.ordinal);
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
            self.anchor_ordinal = 0;
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
    /// The entry and source byte at which the visual row under the mouse starts.
    pub fn mouse_row_start(&self, column: u16, row: u16) -> Option<Point> {
        if !self.rect.contains((column, row).into()) {
            return None;
        }
        let y = row.saturating_sub(self.rect.y) as usize;
        let row = self.rows.get(self.top + y)?;
        Some(Point {
            id: row.id.clone(),
            byte: row.start,
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
                                } else if self.focused
                                    && self.selected.as_deref() == Some(&row.id)
                                    && (cell.style.bg.is_none() || cell.style.bg == row.fill_bg)
                                {
                                    // Highlight the row surface without flattening
                                    // diff or panel backgrounds inside it.
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
    fn soft_wrap_breaks_between_words_and_keeps_copy_bytes() {
        let entry = Entry::plain("m0", "Keep my draft intact when a stream updates.", false);
        let mut state = Transcript::default();
        state.layout(vec![entry], 16, 20);
        let rows: Vec<String> = state
            .rows
            .iter()
            .map(|row| row.cells.iter().map(|c| c.text.as_str()).collect())
            .collect();
        assert_eq!(
            rows,
            ["Keep my draft ", "intact when a ", "stream updates."]
        );
        assert_eq!(
            state.rows.iter().map(|row| row.start).collect::<Vec<_>>(),
            [0, 14, 28]
        );
        // Unbreakable runs still wrap per grapheme rather than overflowing.
        state.layout(vec![Entry::plain("m1", "abcdefghij", false)], 4, 20);
        assert!(
            state
                .rows
                .iter()
                .all(|row| row.cells.iter().map(|c| c.text.width()).sum::<usize>() <= 4)
        );
        assert_eq!(state.rows.len(), 3);
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
