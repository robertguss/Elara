use crate::{InputAction, Model};
use serde_json::{Value, json};

pub(crate) const EXTENSION: &str = "runtime_limits_v1";
const KEYS: [&str; 3] = ["max_iterations", "tool_timeout_ms", "max_tool_timeout_ms"];

pub(crate) fn validate(value: &Value) -> Result<(), String> {
    if value.is_null() {
        return Ok(());
    }
    for key in ["next_turn", "active_turn"] {
        let limits = &value[key];
        if limits.is_null() && key == "active_turn" {
            continue;
        }
        if !KEYS
            .iter()
            .all(|key| limits[key].as_u64().is_some_and(|v| v > 0))
            || limits["tool_timeout_ms"].as_u64() > limits["max_tool_timeout_ms"].as_u64()
        {
            return Err("invalid runtime limits".into());
        }
    }
    if !value["pending"].is_boolean()
        || !KEYS
            .iter()
            .all(|key| matches!(value["sources"][key].as_str(), Some("config" | "session")))
    {
        return Err("invalid runtime limit provenance".into());
    }
    Ok(())
}

fn duration(ms: u64) -> String {
    if ms.is_multiple_of(3_600_000) {
        format!("{}h", ms / 3_600_000)
    } else if ms.is_multiple_of(60_000) {
        format!("{}m", ms / 60_000)
    } else if ms.is_multiple_of(1_000) {
        format!("{}s", ms / 1_000)
    } else {
        format!("{ms}ms")
    }
}

pub(crate) fn summary(view: &Value) -> Vec<String> {
    let limits = &view["runtime_limits"];
    if limits.is_null() {
        return vec!["Session limits unavailable on this server.".into()];
    }
    let next = &limits["next_turn"];
    let source = |key| match limits["sources"][key].as_str() {
        Some("session") => "set this session",
        _ => "config",
    };
    let mut lines = vec![
        format!(
            "Calls: {} ({})",
            next["max_iterations"],
            source("max_iterations")
        ),
        format!(
            "Command timeout: {} ({})",
            duration(next["tool_timeout_ms"].as_u64().unwrap_or(0)),
            source("tool_timeout_ms")
        ),
        format!(
            "Timeout ceiling: {} (config)",
            duration(next["max_tool_timeout_ms"].as_u64().unwrap_or(0))
        ),
    ];
    if limits["pending"] == true {
        lines.push("Pending change applies from the next turn.".into());
    }
    if let Some(active) = limits["active_turn"].as_object() {
        lines.push(format!(
            "Running turn: {} calls, {} command timeout (unchanged)",
            active["max_iterations"],
            duration(active["tool_timeout_ms"].as_u64().unwrap_or(0))
        ));
    }
    lines.push("Session overrides survive reattach; restart restores startup config.".into());
    lines
}

pub(crate) fn command(model: &mut Model, argument: &str) -> InputAction {
    if argument.is_empty() {
        if model.projection.view.get("runtime_limits").is_some() {
            return InputAction::Session(
                json!({"version":2,"extension":EXTENSION,"command":"runtime_limits"}),
            );
        }
        model.session_detail = Some(summary(&model.projection.view).join("\n"));
        model.session_detail_scroll = 0;
        model.editor.clear();
        return InputAction::None;
    }
    if model.mode != "control" {
        model.notice = Some("Observe mode is read-only.".into());
        return InputAction::None;
    }
    if model.projection.view["runtime_limits"].is_null() {
        model.notice = Some("Session limits unavailable on this server.".into());
        return InputAction::None;
    }
    let words: Vec<_> = argument.split_whitespace().collect();
    let change = match words.as_slice() {
        ["calls" | "max_iterations", value] => {
            value.parse::<u64>().ok().map(|v| ("max_iterations", v))
        }
        ["timeout", value] => {
            let (number, scale) = match value.chars().last() {
                Some('s') => (&value[..value.len() - 1], 1_000),
                Some('m') => (&value[..value.len() - 1], 60_000),
                Some('h') => (&value[..value.len() - 1], 3_600_000),
                _ => ("", 1),
            };
            number
                .parse::<u64>()
                .ok()
                .and_then(|v| v.checked_mul(scale))
                .map(|v| ("tool_timeout_ms", v))
        }
        ["tool_timeout_ms", value] => value.parse::<u64>().ok().map(|v| ("tool_timeout_ms", v)),
        _ => None,
    };
    let Some((key, value)) = change.filter(|(_, value)| *value > 0 && *value <= i64::MAX as u64)
    else {
        model.notice = Some("Use /limits calls 150 or /limits timeout 20m (s/m/h).".into());
        return InputAction::None;
    };
    InputAction::Session(
        json!({"version":2,"extension":EXTENSION,"command":"set_runtime_limits","changes":{key:value}}),
    )
}
