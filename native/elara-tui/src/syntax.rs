//! Shared, byte-preserving code colors. No workspace reads or theme-specific RGB.
use crate::appearance::slot;
use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag, TagEnd};
use ratatui::{
    style::{Color, Modifier, Style},
    text::{Line, Span},
};
use std::{
    cell::RefCell,
    collections::{HashMap, VecDeque},
    sync::OnceLock,
};
use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

// A renderer-only marker: replaced before any cells reach the terminal.
pub(crate) const CODE_BACKGROUND: Color = Color::Indexed(255);
const MAX_PARSE_BYTES: usize = 64 * 1024;
const CACHE_BYTES: usize = 4 * 1024 * 1024;
const SCOPES: &[&str] = &[
    "comment",
    "keyword",
    "string",
    "number",
    "boolean",
    "constant",
    "function",
    "type",
    "tag",
    "attribute",
    "operator",
    "punctuation",
    "markup.heading",
    "markup.link",
    "markup.italic",
    "markup.bold",
    "text.title",
    "text.uri",
    "text.reference",
    "text.emphasis",
    "text.strong",
];

fn resolve_language(hint: &str) -> Option<&'static str> {
    let token = hint.split_whitespace().next().unwrap_or("");
    let token = token
        .rsplit('.')
        .next()
        .unwrap_or(token)
        .to_ascii_lowercase();
    match token.as_str() {
        "ex" | "exs" | "elixir" => Some("elixir"),
        "heex" | "eex" => Some("heex"),
        "rs" | "rust" => Some("rust"),
        "sh" | "bash" | "shell" | "zsh" => Some("bash"),
        "json" => Some("json"),
        "md" | "markdown" => Some("markdown"),
        "markdown_inline" => Some("markdown_inline"),
        _ => None,
    }
}

fn configurations() -> &'static HashMap<&'static str, HighlightConfiguration> {
    static CONFIGURATIONS: OnceLock<HashMap<&'static str, HighlightConfiguration>> =
        OnceLock::new();
    CONFIGURATIONS.get_or_init(|| {
        let specs = [
            (
                "elixir",
                tree_sitter_elixir::LANGUAGE,
                tree_sitter_elixir::HIGHLIGHTS_QUERY,
                tree_sitter_elixir::INJECTIONS_QUERY,
            ),
            (
                "heex",
                tree_sitter_heex::LANGUAGE,
                tree_sitter_heex::HIGHLIGHTS_QUERY,
                tree_sitter_heex::INJECTIONS_QUERY,
            ),
            (
                "rust",
                tree_sitter_rust::LANGUAGE,
                tree_sitter_rust::HIGHLIGHTS_QUERY,
                tree_sitter_rust::INJECTIONS_QUERY,
            ),
            (
                "bash",
                tree_sitter_bash::LANGUAGE,
                tree_sitter_bash::HIGHLIGHT_QUERY,
                "",
            ),
            (
                "json",
                tree_sitter_json::LANGUAGE,
                tree_sitter_json::HIGHLIGHTS_QUERY,
                "",
            ),
            (
                "markdown",
                tree_sitter_md::LANGUAGE,
                tree_sitter_md::HIGHLIGHT_QUERY_BLOCK,
                tree_sitter_md::INJECTION_QUERY_BLOCK,
            ),
            (
                "markdown_inline",
                tree_sitter_md::INLINE_LANGUAGE,
                tree_sitter_md::HIGHLIGHT_QUERY_INLINE,
                tree_sitter_md::INJECTION_QUERY_INLINE,
            ),
        ];
        specs
            .into_iter()
            .map(|(name, grammar, highlights, injections)| {
                let mut config =
                    HighlightConfiguration::new(grammar.into(), name, highlights, injections, "")
                        .expect("bundled highlight queries must match their bundled grammars");
                config.configure(SCOPES);
                (name, config)
            })
            .collect()
    })
}

fn style(scope: Option<usize>) -> Style {
    let base = Style::default().fg(slot::TEXT);
    match scope.map(|index| SCOPES[index]) {
        Some("comment") => base.fg(slot::MUTED).add_modifier(Modifier::ITALIC),
        Some("string") => base.fg(slot::ADDED),
        Some("number" | "boolean" | "constant") => base.fg(slot::SUCCESS),
        Some("keyword" | "type" | "markup.heading" | "text.title") => {
            base.fg(slot::ACCENT).add_modifier(Modifier::BOLD)
        }
        Some("function" | "tag" | "attribute" | "markup.link" | "text.uri" | "text.reference") => {
            base.fg(slot::ACCENT)
        }
        Some("markup.italic" | "text.emphasis") => base.add_modifier(Modifier::ITALIC),
        Some("markup.bold" | "text.strong") => base.add_modifier(Modifier::BOLD),
        _ => base,
    }
}

struct Cached {
    language: &'static str,
    source: String,
    lines: Vec<Line<'static>>,
    bytes: usize,
}
#[derive(Default)]
struct Engine {
    highlighter: Highlighter,
    cache: VecDeque<Cached>,
    cache_bytes: usize,
}
thread_local! {
    static ENGINE: RefCell<Engine> = RefCell::new(Engine::default());
}

fn plain(source: &str) -> Vec<Line<'static>> {
    source
        .split('\n')
        .map(|line| Line::from(Span::styled(line.to_owned(), style(None))))
        .collect()
}

/// Highlight one source snippet, retaining every byte, including unparsed tails.
pub(crate) fn lines(hint: &str, source: &str) -> Vec<Line<'static>> {
    let Some(language) = resolve_language(hint) else {
        return plain(source);
    };
    ENGINE.with_borrow_mut(|engine| {
        if let Some(index) = engine
            .cache
            .iter()
            .position(|item| item.language == language && item.source == source)
        {
            let cached = engine.cache.remove(index).unwrap();
            let lines = cached.lines.clone();
            engine.cache.push_back(cached);
            return lines;
        }
        let mut end = source.len().min(MAX_PARSE_BYTES);
        while !source.is_char_boundary(end) {
            end -= 1;
        }
        let mut parsed = source[..end].to_owned();
        // Markdown's block grammar completes its final line only at a newline.
        if language == "markdown" && !parsed.ends_with('\n') {
            parsed.push('\n');
        }
        let configs = configurations();
        let highlighted = (|| {
            let events = engine
                .highlighter
                .highlight(&configs[language], parsed.as_bytes(), None, |name| {
                    resolve_language(name).and_then(|name| configs.get(name))
                })
                .ok()?;
            let mut stack = Vec::new();
            let mut spans = Vec::new();
            for event in events {
                match event.ok()? {
                    HighlightEvent::HighlightStart(scope) => stack.push(scope.0),
                    HighlightEvent::HighlightEnd => {
                        stack.pop();
                    }
                    HighlightEvent::Source { start, end: stop } => {
                        spans.push((start.min(end), stop.min(end), style(stack.last().copied())))
                    }
                }
            }
            spans.push((end, source.len(), style(None)));
            let mut lines = vec![Line::default()];
            for (start, end, style) in spans {
                for (index, part) in source[start..end].split('\n').enumerate() {
                    if index > 0 {
                        lines.push(Line::default());
                    }
                    if !part.is_empty() {
                        lines
                            .last_mut()
                            .unwrap()
                            .spans
                            .push(Span::styled(part.to_owned(), style));
                    }
                }
            }
            Some(lines)
        })()
        .unwrap_or_else(|| plain(source));
        let bytes = source.len()
            + highlighted.capacity() * std::mem::size_of::<Line<'static>>()
            + highlighted
                .iter()
                .map(|line| {
                    line.spans.capacity() * std::mem::size_of::<Span<'static>>()
                        + line
                            .spans
                            .iter()
                            .map(|span| span.content.len())
                            .sum::<usize>()
                })
                .sum::<usize>();
        if bytes <= CACHE_BYTES {
            while engine.cache_bytes + bytes > CACHE_BYTES || engine.cache.len() >= 128 {
                engine.cache_bytes -= engine.cache.pop_front().unwrap().bytes;
            }
            engine.cache_bytes += bytes;
            engine.cache.push_back(Cached {
                language,
                source: source.to_owned(),
                lines: highlighted.clone(),
                bytes,
            });
        }
        highlighted
    })
}

/// Recolor renderer-marked code spans without reparsing its Markdown layout.
pub(crate) fn markdown(rendered: &mut [Line<'static>], source: &str) {
    let mut code = VecDeque::new();
    let mut block = None;
    let mut text = String::new();
    for event in Parser::new_ext(source, Options::all()) {
        match event {
            Event::Start(Tag::CodeBlock(kind)) => {
                block = Some(match kind {
                    CodeBlockKind::Fenced(hint) => hint.into_string(),
                    CodeBlockKind::Indented => String::new(),
                });
                text.clear();
            }
            Event::Text(content) if block.is_some() => text.push_str(&content),
            Event::End(TagEnd::CodeBlock) => {
                code.extend(lines(
                    block.take().as_deref().unwrap_or(""),
                    text.trim_end_matches('\n'),
                ));
            }
            Event::Code(content) => code.push_back(Line::from(content.into_string())),
            _ => {}
        }
    }
    for line in rendered {
        let block_line = line.style.bg == Some(CODE_BACKGROUND);
        if block_line {
            line.style.bg = Some(slot::SURFACE);
        }
        let mut spans = Vec::new();
        for mut span in std::mem::take(&mut line.spans) {
            if !block_line && span.style.bg != Some(CODE_BACKGROUND) {
                spans.push(span);
                continue;
            }
            if span.style.bg == Some(CODE_BACKGROUND) {
                span.style.bg = Some(slot::SURFACE);
            }
            while code
                .front()
                .is_some_and(|line| line.spans.iter().all(|span| span.content.is_empty()))
            {
                code.pop_front();
            }
            let matched = code.front().is_some_and(|line| {
                line.spans
                    .iter()
                    .map(|span| span.content.as_ref())
                    .collect::<String>()
                    == span.content
            });
            if matched {
                spans.extend(
                    code.pop_front().unwrap().spans.into_iter().map(|colored| {
                        Span::styled(colored.content, span.style.patch(colored.style))
                    }),
                );
            } else {
                spans.push(span);
            }
        }
        line.spans = spans;
    }
}
