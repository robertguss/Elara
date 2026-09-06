//! Presentation of retained canonical tool facts. No workspace reads.
use crate::appearance::slot;
use crate::transcript::Entry;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use serde_json::Value;
use std::collections::HashMap;

// Protocol snapshots and status patches already reconcile outcomes into these views.
pub(crate) fn calls(view: &Value) -> HashMap<&str, &Value> {
    view["tool_calls"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|call| Some((call["id"].as_str()?, call)))
        .collect()
}
fn sanitize(text: &str) -> String {
    text.chars()
        .filter(|c| !c.is_control() || matches!(c, '\n' | '\t'))
        .collect()
}
fn preview(text: &str) -> String {
    let mut chars = text.chars().filter_map(|c| match c {
        '\n' | '\t' => Some(' '),
        c if c.is_control() => None,
        c => Some(c),
    });
    let head: String = chars.by_ref().take(100).collect();
    if chars.next().is_some() {
        head + "…"
    } else {
        head
    }
}
// Bound both traversal and allocation before serialization, including nested containers.
fn compact_value(value: &Value, budget: &mut usize) -> Value {
    *budget = budget.saturating_sub(1);
    match value {
        Value::String(text) => Value::String(compact_string(text, budget)),
        Value::Array(values) => {
            let mut items = Vec::new();
            for value in values {
                if *budget == 0 {
                    break;
                }
                items.push(compact_value(value, budget));
            }
            Value::Array(items)
        }
        Value::Object(values) => {
            let mut items = serde_json::Map::new();
            for (key, value) in values {
                if *budget == 0 {
                    break;
                }
                let key = compact_string(key, budget);
                items.insert(key, compact_value(value, budget));
            }
            Value::Object(items)
        }
        value => value.clone(),
    }
}
fn compact_string(text: &str, budget: &mut usize) -> String {
    let text: String = text.chars().take(*budget).collect();
    *budget -= text.chars().count();
    text
}
fn generic_preview(value: &Value) -> String {
    let mut budget = 101;
    let bounded = compact_value(value, &mut budget);
    let mut text = preview(&bounded.to_string());
    if budget == 0 && !text.ends_with('…') {
        text.push('…');
    }
    text
}
/// Lines of a result block shown inline; the `f` viewer has no cap.
const INLINE_RESULT_LINES: usize = 40;
/// Human summary of the call's arguments for the compact header row.
fn summary(name: &str, args: &Value, call: &Value) -> String {
    match name {
        "bash" => preview(args["command"].as_str().unwrap_or("arguments unavailable")),
        "read" | "write" | "edit" => preview(args["path"].as_str().unwrap_or("?")),
        _ => generic_preview(&call["args"]),
    }
}
fn status_glyph(status: &str) -> Span<'static> {
    match status {
        "succeeded" => Span::styled("✓ ", Style::default().fg(slot::SUCCESS)),
        "failed" | "indeterminate" => Span::styled("✗ ", Style::default().fg(slot::FAILURE)),
        "running" => Span::styled("● ", Style::default().fg(slot::ACCENT)),
        _ => Span::styled("○ ", Style::default().fg(slot::MUTED)),
    }
}
fn muted(text: impl Into<String>) -> Span<'static> {
    Span::styled(text.into(), Style::default().fg(slot::MUTED))
}
/// Right-aligned header tail: lifecycle status, or a size hint once succeeded.
fn header_tail(name: &str, status: &str, args: &Value, result: &str) -> Vec<Span<'static>> {
    match (name, status) {
        ("edit", "succeeded") => {
            let count = |text: Option<&str>| text.map_or(0, |t| t.split('\n').count());
            vec![
                Span::styled(
                    format!("+{}", count(args["new_text"].as_str())),
                    Style::default().fg(slot::ADDED),
                ),
                Span::raw(" "),
                Span::styled(
                    format!("−{}", count(args["old_text"].as_str())),
                    Style::default().fg(slot::REMOVED),
                ),
            ]
        }
        ("write", "succeeded") => vec![muted(format!(
            "{} bytes",
            args["content"].as_str().map_or(0, str::len)
        ))],
        (_, "succeeded") if result.is_empty() => Vec::new(),
        (_, "succeeded") => vec![muted(format!("{} lines", result.lines().count()))],
        (_, "failed" | "indeterminate") => vec![Span::styled(
            status.to_owned(),
            Style::default().fg(slot::FAILURE),
        )],
        (_, "running") => vec![Span::styled(
            status.to_owned(),
            Style::default().fg(slot::ACCENT),
        )],
        _ => vec![muted(status.to_owned())],
    }
}
/// Compact transcript entry: one header row, plus the essentials when expanded.
/// Every retained fact stays available through `inspection` (the `f` viewer).
pub(crate) fn entry(session: &str, call: &Value, expanded: bool) -> Entry {
    let name = call["name"].as_str().unwrap_or("?");
    let id = call["id"].as_str().unwrap_or("?");
    let status = call["status"].as_str().unwrap_or("pending");
    let args = &call["args"]["ok"];
    let (_, result) = crate::outcome(&call["outcome"]);
    let mut lines = vec![Line::from(vec![
        Span::raw(""),
        Span::styled(
            name.to_owned(),
            Style::default().add_modifier(Modifier::BOLD),
        ),
        Span::raw("  "),
        muted(sanitize(&summary(name, args, call))),
    ])];
    // Body lines are (fill, text); line 0 is the header.
    let mut body: Vec<(Option<Color>, Vec<Span<'static>>)> = Vec::new();
    if expanded {
        let is_edit_diff = name == "edit"
            && status == "succeeded"
            && call["outcome"]["ok"].is_string()
            && args["old_text"].is_string()
            && args["new_text"].is_string();
        if is_edit_diff {
            body.push((
                None,
                vec![muted(sanitize(args["path"].as_str().unwrap_or("?")))],
            ));
            let rows = [
                (
                    "- ",
                    args["old_text"].as_str().unwrap_or(""),
                    slot::REMOVED,
                    slot::REMOVED_SURFACE,
                ),
                (
                    "+ ",
                    args["new_text"].as_str().unwrap_or(""),
                    slot::ADDED,
                    slot::ADDED_SURFACE,
                ),
            ];
            for (prefix, content, fg, bg) in rows {
                for line in sanitize(content).split('\n') {
                    body.push((
                        Some(bg),
                        vec![Span::styled(
                            format!("{prefix}{line}"),
                            Style::default().fg(fg),
                        )],
                    ));
                }
            }
        } else if call["outcome"].is_null() {
            body.push((None, vec![muted("Not reported yet.")]));
        } else {
            let text = sanitize(result);
            let mut shown = text.split('\n').peekable();
            let total = text.split('\n').count();
            let failed = matches!(status, "failed" | "indeterminate");
            for _ in 0..INLINE_RESULT_LINES.min(total) {
                let Some(line) = shown.next() else { break };
                let style = if failed {
                    Style::default().fg(slot::FAILURE)
                } else {
                    Style::default()
                };
                body.push((
                    Some(slot::SURFACE),
                    vec![Span::styled(line.to_owned(), style)],
                ));
            }
            if shown.peek().is_some() {
                body.push((
                    None,
                    vec![muted(format!(
                        "… {} more lines · f viewer",
                        total - INLINE_RESULT_LINES
                    ))],
                ));
            }
        }
    }
    let mut fills = Vec::new();
    for (fill, spans) in body {
        let mut line = vec![Span::raw("")];
        line.extend(spans);
        lines.push(Line::from(line));
        fills.push(fill);
    }
    let mut entry = Entry::rendered(format!("{session}:tool:{id}"), lines, false, false);
    entry.decorate_line(
        0,
        None,
        vec![
            muted(if expanded { "⌄ " } else { "› " }),
            status_glyph(status),
        ],
    );
    entry.tail(0, header_tail(name, status, args, result));
    for (index, fill) in fills.into_iter().enumerate() {
        entry.decorate_line(
            index + 1,
            fill.map(|bg| Style::default().bg(bg)),
            vec![Span::raw("    ")],
        );
    }
    entry
}
/// Full inspection text for the `f` viewer: call ID, retained arguments JSON,
/// retained result, truncation-marker notes and the replacement snippet.
pub(crate) fn inspection(session: &str, call: &Value) -> Entry {
    let name = call["name"].as_str().unwrap_or("?");
    let id = call["id"].as_str().unwrap_or("?");
    let status = call["status"].as_str().unwrap_or("pending");
    let args = &call["args"]["ok"];
    let mut text = format!(
        "{name} · {status}\n{}",
        sanitize(&summary(name, args, call))
    );
    let (_, result) = crate::outcome(&call["outcome"]);
    if name == "bash"
        && call["outcome"]["error"]
            .as_str()
            .is_some_and(|s| s.starts_with("output truncated: bytes_total="))
    {
        text.push_str(&format!(
            "\nSource cap reported marker: {}",
            result.lines().next().unwrap_or_default()
        ));
    }
    if let Some(marker) = result.lines().last()
        && marker.starts_with("[truncated ")
        && marker.ends_with(" bytes]")
        && marker
            .trim_start_matches("[truncated ")
            .trim_end_matches(" bytes]")
            .parse::<usize>()
            .is_ok()
    {
        text.push_str(&format!(
            "\nResult text ends with a truncation marker (source unverified): {marker}"
        ));
    }
    let mut sections = Vec::new();
    text.push_str(&format!("\nCall ID: {id}\nArguments (retained JSON):\n"));
    text = sanitize(&text);
    let start = text.len();
    text.push_str(&serde_json::to_string_pretty(&call["args"]).expect("JSON value"));
    sections.push(("arguments", start..text.len()));
    text.push_str("\nResult (retained text):\n");
    let start = text.len();
    if call["outcome"].is_null() {
        text.push_str("Not reported yet.");
    } else {
        text.push_str(&sanitize(result));
    }
    sections.push(("result", start..text.len()));
    if name == "edit"
        && status == "succeeded"
        && call["outcome"]["ok"].is_string()
        && let (Some(old), Some(new)) = (args["old_text"].as_str(), args["new_text"].as_str())
    {
        text.push_str("\nReported successful replacement snippet (not a full-file diff):");
        for (prefix, content) in [("- ", old), ("+ ", new)] {
            for line in sanitize(content).split('\n') {
                text.push('\n');
                text.push_str(prefix);
                text.push_str(line);
            }
        }
    }
    text.push_str("\nAll retained arguments/results shown; source/Core caps cannot be undone.");
    let mut entry = Entry::plain(&format!("{session}:tool:{id}"), &sanitize(&text), false);
    entry.sections = sections;
    let color = match status {
        "succeeded" => slot::SUCCESS,
        "failed" | "indeterminate" => slot::FAILURE,
        "running" => slot::ACCENT,
        _ => slot::MUTED,
    };
    entry.lines[0].style = Style::default().fg(color);
    entry
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn generic_preview_bounds_traversal_of_large_strings_and_containers() {
        for value in [
            json!({"huge": "界".repeat(4_000_000)}),
            json!(vec![0; 1_000_000]),
            json!({"\u{1b}".repeat(10000): "ignored"}),
        ] {
            let mut budget = 101;
            let bounded = compact_value(&value, &mut budget);
            assert_eq!(budget, 0);
            assert!(bounded.to_string().len() < 700);
            let summary = generic_preview(&value);
            assert!(summary.chars().count() <= 101);
            assert!(summary.ends_with('…'));
        }
    }
    #[test]
    fn builtin_and_plugin_views_retain_arguments_results_and_canonical_states() {
        for (name, args) in [
            ("bash", json!({"command":"printf hello"})),
            ("read", json!({"path":"file"})),
            ("write", json!({"path":"file","content":"new\nbytes"})),
            (
                "edit",
                json!({"path":"file","old_text":"old","new_text":"new"}),
            ),
            ("plugin", json!({"extra":[1,{"nested":"value"}]})),
        ] {
            for status in ["pending", "running", "succeeded", "failed", "indeterminate"] {
                let outcome = match status {
                    "succeeded" => json!({"ok":"success\nretained end"}),
                    "failed" => json!({"error":"timed out"}),
                    "indeterminate" => json!({"indeterminate":"completion unknown"}),
                    _ => Value::Null,
                };
                let call = json!({"id":"c", "name":name,"args":{"ok":args},"status":status,"outcome":outcome});
                let full = inspection("s", &call).text;
                assert!(full.contains(&format!("{name} · {status}")));
                assert!(full.contains(&serde_json::to_string_pretty(&call["args"]).unwrap()));
                assert_eq!(
                    full.contains("Reported successful replacement"),
                    name == "edit" && status == "succeeded"
                );
                if !outcome.is_null() {
                    assert!(full.contains(crate::outcome(&outcome).1));
                }
                // The compact header names the tool; the expanded entry adds the
                // retained result (or the edit rows) without the inspection notes.
                let folded = entry("s", &call, false);
                assert_eq!(folded.lines.len(), 1);
                assert!(folded.text.contains(name));
                let expanded = entry("s", &call, true).text;
                assert!(!expanded.contains("Call ID"));
                if name == "edit" && status == "succeeded" {
                    assert!(expanded.contains("- old") && expanded.contains("+ new"));
                } else if !outcome.is_null() {
                    assert!(expanded.contains(crate::outcome(&outcome).1));
                }
            }
        }
    }
    #[test]
    fn long_output_and_malformed_arguments_have_lossless_inspection() {
        let output =
            "👩‍💻\toutput\n".repeat(300) + "output truncated: bytes_total=9000 bytes_sent=8000";
        let call = json!({"id":"c","name":"plugin","args":{"malformed":"raw {"},"status":"failed","outcome":{"error":output}});
        assert!(inspection("s", &call).text.contains(&output));
        assert!(!entry("s", &call, false).text.contains("bytes_total"));
        assert!(inspection("s", &call).text.contains("raw {"));
        // Inline expansion caps the result and points at the viewer.
        let expanded = entry("s", &call, true).text;
        assert!(expanded.contains("output"));
        assert!(expanded.contains("more lines · f viewer"));
    }
    #[test]
    fn compact_labels_reported_source_and_core_caps_separately_from_folding() {
        for (outcome, expected) in [
            (
                json!({"error":"output truncated: bytes_total=20000 bytes_sent=10000\nretained"}),
                "Source cap reported",
            ),
            (
                json!({"ok":format!("{}\n[truncated 400 bytes]", "output\n".repeat(100))}),
                "Result text ends with a truncation marker (source unverified)",
            ),
        ] {
            let call = json!({"id":"c","name":"bash","args":{"ok":{}},"status":"failed","outcome":outcome});
            let text = inspection("s", &call).text;
            assert!(text.contains(expected));
            assert!(!entry("s", &call, false).text.contains(expected));
        }
    }
    #[test]
    fn preview_preserves_sanitization_and_caps_unicode_without_copying_the_tail() {
        assert_eq!(preview("a\r\n\tb\u{1b}"), "a  b");
        assert_eq!(preview(&"界".repeat(100)), "界".repeat(100));
        assert_eq!(
            preview(&("界".repeat(101) + &"large tail".repeat(10000))),
            "界".repeat(100) + "…"
        );
    }
    #[test]
    fn outcomes_are_joined_by_call_id_and_do_not_infer_success_from_text() {
        let view = json!({"tool_calls":[{"id":"a","name":"bash","status":"indeterminate","args":{"ok":{}},"outcome":{"indeterminate":"success printed"}}],"messages":[{"role":"tool","call_id":"a","name":"bash","outcome":{"ok":"wrong"}}]});
        let values = calls(&view);
        assert_eq!(values.len(), 1);
        assert_eq!(values["a"]["status"], "indeterminate");
        assert!(
            entry("s", values["a"], true)
                .text
                .contains("success printed")
        );
    }
}
