use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers as M};
use elara_tui::{InputAction, Model, fixture_model, handle_input, render_frame};
use serde_json::json;
use std::{fs, process::Command};

fn key(model: &mut Model, code: KeyCode, modifiers: M) -> InputAction {
    handle_input(model, Event::Key(KeyEvent::new(code, modifiers)), 108)
}

#[test]
fn configurable_actions_follow_file_and_keep_fixed_controls() {
    if let Ok(case) = std::env::var("ELARA_KEYMAP_CASE") {
        let mut model = fixture_model("idle");
        if case == "defaults" {
            assert!(model.notice.is_none());
            model.editor.insert("draft");
            key(&mut model, KeyCode::Char('j'), M::CONTROL);
            assert_eq!(model.editor.text(), "draft\n");
            assert_eq!(
                key(&mut model, KeyCode::Enter, M::NONE),
                InputAction::Submit
            );
            return;
        }
        if case != "valid" {
            let notice = model.notice.clone().unwrap();
            assert!(notice.contains("Keymap:"), "{notice}");
            let mut projection = model.projection.clone();
            projection.view["inbox"]["execution"]["read_only_notice"] =
                json!("Owner unavailable; read-only");
            let combined = Model::new("combined".into(), "control".into(), projection);
            assert!(
                combined
                    .notice
                    .as_deref()
                    .unwrap()
                    .contains("Owner unavailable; read-only")
            );
            assert!(combined.notice.as_deref().unwrap().contains("Keymap:"));
            model.editor.insert("draft");
            assert_eq!(
                key(&mut model, KeyCode::Enter, M::NONE),
                InputAction::Submit
            );
            if case == "entries" {
                assert!(notice.contains("fixed control"));
                assert!(notice.contains("collides"));
                assert!(notice.contains("unknown action"));
                assert!(notice.contains("invalid key"));
                assert_eq!(key(&mut model, KeyCode::F(12), M::NONE), InputAction::None);
                assert!(!model.thinking_visible);
            }
            return;
        }
        let frame = render_frame(&model, 110, 34).unwrap();
        assert!(frame.contains("F3 send"));
        assert!(frame.contains("F11 paste"));
        model.editor.insert("alpha 中");
        assert_eq!(
            key(&mut model, KeyCode::Char('a'), M::CONTROL),
            InputAction::None
        );
        key(&mut model, KeyCode::Char('x'), M::NONE);
        assert_eq!(model.editor.text(), "alpha 中x");
        key(&mut model, KeyCode::F(6), M::NONE);
        key(&mut model, KeyCode::Char('z'), M::NONE);
        assert_eq!(model.editor.text(), "z");
        assert_eq!(
            key(&mut model, KeyCode::Char('j'), M::CONTROL),
            InputAction::None
        );
        assert_eq!(model.editor.text(), "z");
        key(&mut model, KeyCode::F(2), M::NONE);
        assert_eq!(model.editor.text(), "z\n");
        assert_eq!(key(&mut model, KeyCode::Enter, M::NONE), InputAction::None);
        assert_eq!(key(&mut model, KeyCode::F(3), M::NONE), InputAction::Submit);
        assert_eq!(key(&mut model, KeyCode::F(5), M::NONE), InputAction::Steer);
        assert_eq!(
            key(&mut model, KeyCode::F(4), M::NONE),
            InputAction::Interrupt
        );
        assert_eq!(
            key(&mut model, KeyCode::F(7), M::NONE),
            InputAction::Session(json!({"version":2,"command":"read_only"}))
        );
        assert!(
            model.session_reply(&json!({"version":2,"type":"read_only_changed","enabled":true}))
        );
        assert!(
            model
                .notice
                .as_deref()
                .unwrap()
                .contains("F9 stops the running one")
        );
        assert_eq!(
            model.editor.text(),
            "z\n",
            "bound slash action retains draft"
        );
        model.projection.view["provider_view"] = json!({
            "catalog":[{"model":"gpt-5.5","efforts":["medium","high"]}],
            "next_request":{"model":"gpt-5.5","effort":"medium"}
        });
        assert_eq!(
            key(&mut model, KeyCode::Char('p'), M::CONTROL),
            InputAction::None
        );
        key(&mut model, KeyCode::Char('k'), M::CONTROL);
        assert!(render_frame(&model, 110, 34).unwrap().contains("model"));
        assert_eq!(
            key(&mut model, KeyCode::Enter, M::NONE),
            InputAction::ProviderSettings(
                json!({"version":2,"command":"set_provider_settings","extension":"provider_visibility_v1","model":"gpt-5.5","effort":"medium"})
            )
        );
        key(&mut model, KeyCode::Char('a'), M::ALT);
        assert!(model.appearance_picker.is_some());
        assert_eq!(
            key(&mut model, KeyCode::F(4), M::NONE),
            InputAction::Interrupt
        );
        key(&mut model, KeyCode::Enter, M::NONE);
        assert!(model.appearance_picker.is_none());
        assert!(matches!(
            key(&mut model, KeyCode::F(8), M::NONE),
            InputAction::Session(_)
        ));
        key(&mut model, KeyCode::Esc, M::NONE);
        assert_eq!(model.editor.text(), "z\n");
        model.editor.clear();
        key(&mut model, KeyCode::F(10), M::NONE);
        assert!(model.show_help);
        let help = render_frame(&model, 160, 50).unwrap();
        for text in [
            "F3 submit",
            "F6 select all",
            "F7 read only",
            "F8 undo",
            "Ctrl-K provider settings",
            "Fixed:",
            "Fixed editing:",
        ] {
            assert!(help.contains(text), "missing {text}: {help}");
        }
        key(&mut model, KeyCode::Esc, M::NONE);
        assert!(!model.show_help);
        model.safe_paste = true;
        assert_eq!(key(&mut model, KeyCode::F(3), M::NONE), InputAction::None);
        assert!(model.safe_paste);
        key(&mut model, KeyCode::F(11), M::NONE);
        assert!(!model.safe_paste);
        return;
    }
    for (case, text) in [
        (
            "valid",
            r#"{"provider_settings":"Ctrl+K","newline":"f2","submit":"f3","interrupt":"f4","steer":"f5","select_all":"f6","read_only":"f7","undo":"f8","escape":"f9","help":"f10","paste":"f11","appearance":"alt+a"}"#,
        ),
        ("broken", "not JSON"),
        (
            "entries",
            r#"{"submit":"ctrl+p","help":"ctrl+enter","turns":"up","new_action":"f8","paste":42,"queue":"f9","steer":"f9","thinking":"f12","appearance":"r"}"#,
        ),
        (
            "defaults",
            r#"{"submit":"enter","help":"?","focus":"tab","newline":"ctrl+j"}"#,
        ),
        ("unreadable", ""),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("keymap.json");
        if case == "unreadable" {
            fs::create_dir(path).unwrap();
        } else {
            fs::write(path, text).unwrap();
        }
        let result = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "configurable_actions_follow_file_and_keep_fixed_controls",
                "--nocapture",
            ])
            .env("ELARA_KEYMAP_CASE", case)
            .env("ELARA_TUI_STATE_DIR", dir.path())
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{case}: {}\n{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
    }
}
