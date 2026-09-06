//! Render a rich fixture session as ANSI for design review:
//! `cargo run --example preview -- LAYOUT THEME [WIDTH HEIGHT] [--diagnostics] [--hidden]`
use elara_tui::{Appearance, Model, Theme, ViewLayout, fixture_model, render_ansi};
use serde_json::json;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let layout = ViewLayout::parse(args.first().map_or("ember", String::as_str)).unwrap();
    let theme = Theme::parse(args.get(1).map_or("ember", String::as_str)).unwrap();
    let width: u16 = args.get(2).and_then(|v| v.parse().ok()).unwrap_or(120);
    let height: u16 = args.get(3).and_then(|v| v.parse().ok()).unwrap_or(40);
    let diagnostics = args.iter().any(|a| a == "--diagnostics");
    let hidden = args.iter().any(|a| a == "--hidden");
    let mut model: Model = fixture_model("idle");
    model.cwd = Some(format!(
        "{}/Projects/Elara",
        std::env::var("HOME").unwrap_or_default()
    ));
    let view = &mut model.projection.view;
    view["messages"] = json!([
        {"role":"user","text":"Keep my draft intact when a stream updates or the session resnapshots. Add a regression test."},
        {"role":"assistant","text":null,"public_content":[
            {"kind":"reasoning_summary","item_id":"r","output_index":0,"part_index":0,
             "text":"Checking how incoming snapshots affect the composer.\nThe draft belongs to the editor. Updating server-owned conversation state should leave it untouched."},
            {"kind":"final_answer","item_id":"a","output_index":1,"part_index":0,
             "text":"I found the draft being replaced when the projection updates. I’ll keep editor state local and test both streaming updates and resnapshots."}
        ],"tool_calls":[
            {"id":"c1","name":"read","output_index":2,"args":{"ok":{"path":"native/elara-tui/src/model.rs"}}},
            {"id":"c2","name":"edit","output_index":3,"args":{"ok":{"path":"native/elara-tui/src/model.rs","old_text":"self.prompt.clear();","new_text":"// Projection updates preserve local editor state.\nself.projection = snapshot;\nself.editor.restore(draft);"}}},
            {"id":"c3","name":"bash","output_index":4,"args":{"ok":{"command":"cargo test draft_survives"}}}
        ]}
    ]);
    view["tool_calls"] = json!([
        {"id":"c1","name":"read","args":{"ok":{"path":"native/elara-tui/src/model.rs"}},"status":"succeeded","outcome":{"ok":"pub struct Model {\n    pub editor: Editor,\n}"}},
        {"id":"c2","name":"edit","args":{"ok":{"path":"native/elara-tui/src/model.rs","old_text":"self.prompt.clear();","new_text":"// Projection updates preserve local editor state.\nself.projection = snapshot;\nself.editor.restore(draft);"}},"status":"succeeded","outcome":{"ok":"replaced"}},
        {"id":"c3","name":"bash","args":{"ok":{"command":"cargo test draft_survives"}},"status":"running","outcome":null}
    ]);
    view["turn"] = json!({"state":"running_tool","iteration":1,"tool_call_id":"c3"});
    view["provider_view"] = json!({"extension":"provider_visibility_v1","catalog":[],
        "next_request":{"model":"grok-4","effort":"high"},"streaming":null});
    model.set_appearance(Appearance {
        layout,
        theme,
        diagnostics,
    });
    model.thinking_visible = !hidden;
    model.expand_tool("c2");
    model
        .editor
        .insert("Also check that resizing the terminal preserves the selection.");
    print!("{}", render_ansi(&model, width, height).unwrap());
}
