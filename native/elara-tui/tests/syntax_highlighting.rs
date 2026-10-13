use elara_tui::{Appearance, Theme, draw_model, fixture_model};
use ratatui::{Terminal, backend::TestBackend, buffer::Buffer, style::Color};
use serde_json::json;
use std::{fs, path::Path};

fn render(markdown: &str, theme: Theme, edit: bool) -> Buffer {
    let mut model = fixture_model("idle");
    model.appearance = Appearance {
        theme,
        ..Appearance::default()
    };
    model.projection.view["messages"] = json!([
        {"role":"user", "text":"Review this module"},
        {"role":"assistant", "text":markdown, "tool_calls":[]}
    ]);
    if edit {
        let call = json!({"id":"edit-1", "name":"edit", "args":{"ok":{
            "path":"lib/demo.ex", "old_text":"  def value, do: 1",
            "new_text":"  def value, do: 42"
        }}, "status":"succeeded", "outcome":{"ok":"edited lib/demo.ex"}});
        model.projection.view["messages"][1]["tool_calls"] = json!([call]);
        model.projection.view["tool_calls"] = json!([call]);
        model.expand_tool("edit-1");
    }
    let mut terminal = Terminal::new(TestBackend::new(110, 36)).unwrap();
    terminal.draw(|frame| draw_model(frame, &model)).unwrap();
    terminal.backend().buffer().clone()
}

fn color(buffer: &Buffer, needle: &str, token: &str) -> (Color, Color) {
    for y in 0..buffer.area.height {
        let row = (0..buffer.area.width)
            .map(|x| buffer[(x, y)].symbol())
            .collect::<String>();
        if let Some(start) = row.find(needle) {
            let x = start + needle.find(token).unwrap(); // ASCII prefixes in these fixtures.
            let cell = &buffer[(x as u16, y)];
            return (cell.fg, cell.bg);
        }
    }
    panic!("missing visible text: {needle}");
}

fn colored_frame(buffer: &Buffer) -> String {
    let mut result = String::new();
    for y in 0..buffer.area.height {
        let mut previous = None;
        for x in 0..buffer.area.width {
            let cell = &buffer[(x, y)];
            let style = (cell.fg, cell.bg, cell.modifier);
            if previous != Some(style) {
                result.push_str(&format!("[{style:?}]"));
                previous = Some(style);
            }
            result.push_str(cell.symbol());
        }
        result.push('\n');
    }
    result
}

#[test]
fn elixir_and_edit_diff_color_goldens_follow_all_four_themes() {
    let source = "Before `inline` code.\n\n```elixir\n# explanatory comment\ndefmodule Demo do\n  def label, do: \"café\"\nend\n```\n\nAfter **bold** prose.";
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/goldens");
    for theme in Theme::ALL {
        let buffer = render(source, *theme, true);
        let tokens = theme.tokens();
        assert_eq!(
            color(&buffer, "defmodule Demo", "defmodule"),
            (tokens.focus, tokens.surface)
        );
        assert_eq!(
            color(&buffer, "# explanatory", "#"),
            (tokens.secondary, tokens.surface)
        );
        assert_eq!(
            color(&buffer, "-   def value, do: 1", "def"),
            (tokens.focus, tokens.removed_surface)
        );
        assert_eq!(
            color(&buffer, "+   def value, do: 42", "42"),
            (tokens.success, tokens.added_surface)
        );
        let actual = colored_frame(&buffer);
        let path = root.join(format!("syntax-{}.txt", theme.name()));
        if std::env::var_os("ELARA_UPDATE_GOLDENS").is_some() {
            fs::write(&path, &actual).unwrap();
        }
        assert_eq!(
            actual,
            fs::read_to_string(&path).unwrap(),
            "{}",
            path.display()
        );
    }
}

#[test]
fn supported_fences_and_injections_are_colored_without_replacing_markdown_layout() {
    let tokens = Theme::Ember.tokens();
    for (language, source, needle, token, expected) in [
        (
            "elixir",
            "def answer, do: 42",
            "def answer",
            "def",
            tokens.focus,
        ),
        (
            "heex",
            "<p><%= if true, do: \"hi\" %></p>",
            "if true",
            "if",
            tokens.focus,
        ),
        (
            "rust",
            "fn answer() -> u32 { 42 }",
            "fn answer",
            "fn",
            tokens.focus,
        ),
        (
            "shell",
            "echo \"hello\"",
            "echo \"hello\"",
            "\"hello\"",
            tokens.added,
        ),
        (
            "json",
            "{\"answer\": 42}",
            "\"answer\": 42",
            "42",
            tokens.success,
        ),
        ("markdown", "## Title", "## Title", "Title", tokens.focus),
        (
            "markdown",
            "```elixir\ndef answer, do: 42\n```",
            "def answer",
            "def",
            tokens.focus,
        ),
        (
            "unknown",
            "def answer, do: 42",
            "def answer",
            "def",
            tokens.text,
        ),
    ] {
        let markdown = format!(
            "**Before** `inline`.\n\n| Code |\n| --- |\n| `table` |\n\n> ~~~~{language}\n> \n> {code}\n> \n> ~~~~\n\n**After** `last`.",
            code = source.replace('\n', "\n> ")
        );
        let buffer = render(&markdown, Theme::Ember, false);
        assert_eq!(
            color(&buffer, needle, token),
            (expected, tokens.surface),
            "{language}: {source}"
        );
        assert_eq!(color(&buffer, "After last.", "After").0, tokens.text);
    }
}
