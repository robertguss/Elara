use elara_tui::{fixture_model, render_frame};
use serde_json::json;
use std::{fs, path::Path};

#[test]
fn footer_uses_authoritative_usage_and_context_without_inventing_counters_or_spend() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/goldens");
    for (name, totals, nanos, complete, confidence, warning) in [
        (
            "priced",
            json!({"input_tokens":23001,"cached_input_tokens":2300,"output_tokens":790}),
            json!(21_600_000),
            true,
            "estimated",
            false,
        ),
        (
            "partial",
            json!({"input_tokens":23001,"cached_input_tokens":2300,"output_tokens":790}),
            json!(21_600_000),
            false,
            "estimated",
            true,
        ),
        (
            "subscription",
            json!({"input_tokens":12012,"cached_input_tokens":77}),
            json!(null),
            false,
            "estimated",
            false,
        ),
        ("unknown", json!(null), json!(null), false, "low", false),
    ] {
        let mut model = fixture_model("idle");
        model.projection.view["provider_view"] = json!({
            "usage":{"last_request":{"input_tokens":999}, "session_totals":totals,
                "cost":{"estimated_usd_nanos":nanos,"complete":complete}},
            "context":{"estimate_tokens":888,"advertised_limit":999}
        });
        model.projection.view["usage"] = json!({"input_tokens":444});
        model.projection.view["inbox"] = json!({"context":{
            "estimate_tokens":12400,"limit":272000,"confidence":confidence,
            "warning":warning,"handoff_required":false
        }});
        for width in [110, 40] {
            let frame = render_frame(&model, width, 28).unwrap();
            assert!(frame.contains("Ctx ~12400/272000"), "{frame}");
            if name == "subscription" {
                assert!(frame.contains("Tokens in 12012"), "{frame}");
                assert!(frame.contains("cached(in) 77"), "{frame}");
                assert!(frame.contains("out ?"), "{frame}");
                assert!(!frame.contains('$'), "{frame}");
            } else if name == "unknown" {
                assert!(frame.contains("Tokens in ?"), "{frame}");
                assert!(frame.contains("cached(in) ?"), "{frame}");
                assert!(frame.contains("out ?"), "{frame}");
                assert!(frame.contains("low confidence"), "{frame}");
                assert!(!frame.contains('$'), "{frame}");
            } else {
                assert!(frame.contains("Tokens in 23001"), "{frame}");
                assert!(frame.contains("cached(in) 2300"), "{frame}");
                assert!(frame.contains("out 790"), "{frame}");
                assert!(frame.contains("~$0.0216"), "{frame}");
                assert_eq!(frame.contains("partial"), !complete, "{frame}");
                assert_eq!(frame.contains("near limit"), warning, "{frame}");
            }
            let path = root.join(format!("usage-{name}-{width}.txt"));
            if std::env::var_os("ELARA_UPDATE_GOLDENS").is_some() {
                fs::write(&path, &frame).unwrap();
            }
            assert_eq!(frame, fs::read_to_string(path).unwrap());
        }
    }
}

#[test]
fn cost_rounding_preserves_tiny_nonzero_estimates_and_carries_into_dollars() {
    for (nanos, expected) in [
        (1, "~<$0.0001"),
        (99_999, "~<$0.0001"),
        (100_000, "~$0.0001"),
        (999_960_000, "~$1.0000"),
    ] {
        let mut model = fixture_model("idle");
        model.projection.view["provider_view"]["usage"] = json!({
            "cost":{"estimated_usd_nanos":nanos,"complete":true}
        });
        let frame = render_frame(&model, 110, 28).unwrap();
        assert!(frame.contains(expected), "{frame}");
    }
}

#[test]
fn footer_survives_tool_inspection_and_appearance_without_hiding_read_only_mode() {
    use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};
    use elara_tui::handle_input;
    for width in [40, 110] {
        let mut model = fixture_model("tool-running");
        model.projection.view["provider_view"]["usage"] = json!({
            "session_totals":{"input_tokens":1234,"cached_input_tokens":12,"output_tokens":56},
            "cost":{"estimated_usd_nanos":1_234_567,"complete":false}
        });
        model.projection.view["inbox"] = json!({
            "execution":{"read_only":true},
            "context":{"estimate_tokens":840,"limit":128000,"confidence":"low","handoff_required":true}
        });
        let check = |frame: &str| {
            for text in [
                "READ-ONLY",
                "Tokens in 1234",
                "cached(in) 12",
                "out 56",
                "~$0.0012 (partial)",
                "Ctx ~840/128000",
                "low confidence",
                "handoff required",
            ] {
                assert!(frame.contains(text), "missing {text}: {frame}");
            }
        };
        check(&render_frame(&model, width, 32).unwrap());
        for code in [KeyCode::Tab, KeyCode::Home] {
            handle_input(
                &mut model,
                Event::Key(KeyEvent::new(code, KeyModifiers::NONE)),
                usize::from(width - 2),
            );
        }
        for _ in 0..12 {
            handle_input(
                &mut model,
                Event::Key(KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)),
                usize::from(width - 2),
            );
        }
        handle_input(
            &mut model,
            Event::Key(KeyEvent::new(KeyCode::Char('f'), KeyModifiers::NONE)),
            usize::from(width - 2),
        );
        let frame = render_frame(&model, width, 32).unwrap();
        assert!(frame.contains("Tool viewer"), "{frame}");
        check(&frame);
        handle_input(
            &mut model,
            Event::Key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE)),
            usize::from(width - 2),
        );
        model.appearance_picker = Some(model.appearance);
        let frame = render_frame(&model, width, 32).unwrap();
        assert!(frame.contains("Appearance"), "{frame}");
        check(&frame);
    }
}
