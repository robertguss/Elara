use std::collections::HashMap;
use std::io::{self, Write};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use crossterm::event::{
    self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture,
    KeyboardEnhancementFlags, PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
    supports_keyboard_enhancement,
};
use elara_tui::{
    Appearance, ClientConnection, ConnectionState, Cursor, CursorStore, DEFAULT_PORT, Ingest,
    InputAction, Model, Theme, ViewLayout, attach_request, attached_model, command, draw_model,
    handle_input, render_frame,
};
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use serde_json::{Value, json};

struct Args {
    appearance: bool,
    layout: Option<ViewLayout>,
    theme: Option<Theme>,
    preview_reasoning: bool,
    target: String,
    port: u16,
    observe: bool,
    headless: bool,
    event_dump: bool,
    ask: Option<String>,
    interrupt_after: Option<Duration>,
    timeout: Duration,
    width: u16,
    height: u16,
}

impl Args {
    fn parse() -> Result<Self, String> {
        Self::parse_from(std::env::args().skip(1))
    }

    fn parse_from(mut arguments: impl Iterator<Item = String>) -> Result<Self, String> {
        let mut appearance = false;
        let mut layout = None;
        let mut theme = None;
        let mut preview_reasoning = false;
        let mut target = None;
        let mut positional_only = false;
        let mut port = environment_port();
        let mut observe = false;
        let mut headless = false;
        let mut event_dump = false;
        let mut ask = None;
        let mut interrupt_after = None;
        let mut timeout = Duration::from_secs(30);
        let mut width = 100;
        let mut height = 24;

        while let Some(argument) = arguments.next() {
            if positional_only {
                if target.replace(argument.clone()).is_some() {
                    return Err(format!("unexpected argument {argument}\n{}", usage()));
                }
                continue;
            }
            match argument.as_str() {
                "--" => positional_only = true,
                "--appearance" => appearance = true,
                "--layout" => {
                    layout = Some(ViewLayout::parse(&next_value(&mut arguments, "--layout")?)?)
                }
                "--theme" => theme = Some(Theme::parse(&next_value(&mut arguments, "--theme")?)?),
                "--preview-reasoning" => preview_reasoning = true,
                "--port" => port = parse_next(&mut arguments, "--port")?,
                "--observe" | "-o" => observe = true,
                "--headless" => headless = true,
                "--event-dump" | "--dump-events" => event_dump = true,
                "--ask" => ask = Some(next_value(&mut arguments, "--ask")?),
                "--interrupt-after-ms" => {
                    let milliseconds: u64 = parse_next(&mut arguments, "--interrupt-after-ms")?;
                    interrupt_after = Some(Duration::from_millis(milliseconds));
                }
                "--timeout-ms" => {
                    let milliseconds: u64 = parse_next(&mut arguments, "--timeout-ms")?;
                    timeout = Duration::from_millis(milliseconds);
                }
                "--width" => width = parse_next(&mut arguments, "--width")?,
                "--height" => height = parse_next(&mut arguments, "--height")?,
                "--help" | "-h" => return Err(usage().to_string()),
                flag if flag.starts_with('-') => {
                    return Err(format!("unknown option {flag}\n{}", usage()));
                }
                value if target.is_none() => target = Some(value.to_string()),
                value => return Err(format!("unexpected argument {value}\n{}", usage())),
            }
        }

        let target = target.ok_or_else(|| usage().to_string())?;
        if width < 40 || height < 8 {
            return Err("headless frame must be at least 40x8".to_string());
        }
        if target == "list" && (observe || ask.is_some() || interrupt_after.is_some()) {
            return Err("list does not accept attachment or turn options".to_string());
        }
        if observe && (ask.is_some() || interrupt_after.is_some()) {
            return Err("an observing client cannot ask or interrupt".to_string());
        }

        if appearance && headless {
            return Err("--appearance requires an interactive terminal; use --layout/--theme with --headless".into());
        }
        Ok(Self {
            appearance,
            layout,
            theme,
            preview_reasoning,
            target,
            port,
            observe,
            headless,
            event_dump,
            ask,
            interrupt_after,
            timeout,
            width,
            height,
        })
    }
}

fn next_value(arguments: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, String> {
    arguments
        .next()
        .ok_or_else(|| format!("{flag} requires a value"))
}

fn parse_next<T>(arguments: &mut impl Iterator<Item = String>, flag: &str) -> Result<T, String>
where
    T: std::str::FromStr,
{
    let value = next_value(arguments, flag)?;
    value
        .parse()
        .map_err(|_| format!("{flag} has an invalid value: {value}"))
}

fn environment_port() -> u16 {
    std::env::var("ELARA_SERVER_PORT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(DEFAULT_PORT)
}

fn usage() -> &'static str {
    "usage: elara-tui [OPTIONS] [--] SESSION|new|list\noptions: [--port PORT] [--observe] [--ask PROMPT] \
     [--headless] [--event-dump] [--appearance] [--layout ember|observatory|workbench] [--theme ember|observatory|workbench|forest] [--preview-reasoning]"
}

fn main() -> ExitCode {
    match Args::parse().and_then(run) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("elara-tui: {error}");
            ExitCode::from(1)
        }
    }
}

fn run(args: Args) -> Result<(), String> {
    if args.target == "list" {
        return list_sessions(args.port, args.event_dump);
    }

    let mut appearance = Appearance::load().unwrap_or_else(|error| {
        eprintln!("warning: {error}; using appearance defaults");
        Appearance::default()
    });
    if let Some(layout) = args.layout {
        appearance.layout = layout;
    }
    if let Some(theme) = args.theme {
        appearance.theme = theme;
    }
    if args.appearance {
        appearance = pick_appearance(appearance)?;
    }
    let mode = if args.observe { "observe" } else { "control" };
    let cursors = CursorStore::from_environment();
    let saved = if args.target == "new" {
        Cursor::default()
    } else {
        cursors.load(&args.target)
    };
    let request = attach_request(&args.target, mode, &saved);
    let started = Instant::now();
    let (mut connection, attached) = ClientConnection::connect(args.port, request)?;
    dump_frame(args.event_dump, started, &attached);
    let mut model = attached_model(&attached, mode)?;
    model.set_appearance(appearance);
    model.preview_reasoning = args.preview_reasoning;
    save_cursor(&cursors, &model);
    if let Some(request) = model.pending_input_status() {
        connection.send(&request)?;
    }
    if let Some(prompt) = &args.ask {
        if !model.editor.insert(prompt) {
            return Err("prompt exceeds the 64 KiB editor limit".into());
        }
        if let Some(request) = model.prepare_submit() {
            connection.send(&request)?;
        } else if args.headless {
            return Err(model
                .notice
                .clone()
                .unwrap_or_else(|| "prompt must contain text".into()));
        }
    }

    if args.headless {
        run_headless(
            &args,
            &mut connection,
            &mut model,
            &cursors,
            started,
            saved.cursor,
        )
    } else {
        run_interactive(&args, &mut connection, &mut model, &cursors, started)
    }
}

fn pick_appearance(original: Appearance) -> Result<Appearance, String> {
    use crossterm::event::{Event, KeyCode, KeyEventKind};
    use ratatui::widgets::{Block, Borders, Paragraph, Wrap};
    let _guard = TerminalGuard::enter()?;
    let mut terminal =
        Terminal::new(CrosstermBackend::new(io::stdout())).map_err(|e| e.to_string())?;
    let mut choice = original;
    let mut notice = String::new();
    loop {
        terminal
            .draw(|frame| {
                let t = choice.theme.tokens();
                let mut lines = choice.lines();
                lines.push(ratatui::text::Line::from(notice.clone()));
                frame.render_widget(
                    Paragraph::new(lines)
                        .style(ratatui::style::Style::default().fg(t.text).bg(t.background))
                        .wrap(Wrap { trim: false })
                        .block(
                            Block::default()
                                .borders(Borders::ALL)
                                .title(" Before session · Appearance "),
                        ),
                    frame.area(),
                );
            })
            .map_err(|e| e.to_string())?;
        if let Event::Key(key) = event::read().map_err(|e| e.to_string())? {
            if key.kind == KeyEventKind::Release {
                continue;
            }
            match key.code {
                KeyCode::Left => choice.layout = choice.layout.previous(),
                KeyCode::Right | KeyCode::Char('l') => choice.layout = choice.layout.next(),
                KeyCode::Up => choice.theme = choice.theme.previous(),
                KeyCode::Down | KeyCode::Char('t') => choice.theme = choice.theme.next(),
                KeyCode::Enter => return Ok(choice),
                KeyCode::Esc => return Ok(original),
                KeyCode::Char('c')
                    if key
                        .modifiers
                        .contains(crossterm::event::KeyModifiers::CONTROL) =>
                {
                    return Err("appearance canceled before attachment".into());
                }
                KeyCode::Char('s') => match choice.save() {
                    Ok(()) => return Ok(choice),
                    Err(error) => notice = error,
                },
                _ => {}
            }
        }
    }
}

fn list_sessions(port: u16, event_dump: bool) -> Result<(), String> {
    let started = Instant::now();
    let (_connection, frame) = ClientConnection::connect(
        port,
        json!({
            "version": 2, "command": "list",
            "cwd": std::env::current_dir().map_err(|error| error.to_string())?.to_string_lossy()
        }),
    )?;
    dump_frame(event_dump, started, &frame);
    if frame["type"].as_str() == Some("error") {
        return Err(format!(
            "session list failed: {}",
            frame["error"].as_str().unwrap_or("unknown server error")
        ));
    }
    if frame["type"].as_str() != Some("sessions") || !frame["sessions"].is_array() {
        return Err("server returned an invalid session list".to_string());
    }

    println!("SESSION\tSTATE\tHEAD\tCWD");
    for session in frame["sessions"].as_array().expect("checked sessions") {
        let id = session["id"]
            .as_str()
            .ok_or_else(|| "session list has an invalid id".to_string())?;
        let state = session["state"]
            .as_str()
            .filter(|state| {
                matches!(
                    *state,
                    "saved" | "idle" | "calling_provider" | "running_tool"
                )
            })
            .ok_or_else(|| "session list has an invalid state".to_string())?;
        let head = session["head"]
            .as_u64()
            .ok_or_else(|| "session list has an invalid head".to_string())?;
        let cwd = session["cwd"]
            .as_str()
            .ok_or_else(|| "session list has an invalid cwd".to_string())?;
        println!("{id}\t{state}\t{head}\t{cwd}");
    }
    Ok(())
}

fn run_headless(
    args: &Args,
    connection: &mut ClientConnection,
    model: &mut Model,
    cursors: &CursorStore,
    started: Instant,
    saved_cursor: u64,
) -> Result<(), String> {
    let mut saw_active = model.turn_state() != "idle";
    let mut interrupt_sent = false;

    if args.ask.is_some() || args.interrupt_after.is_some() || saw_active {
        loop {
            if started.elapsed() > args.timeout {
                return Err(format!(
                    "headless run timed out after {} ms",
                    args.timeout.as_millis()
                ));
            }
            if !interrupt_sent
                && let Some(after) = args.interrupt_after
                && started.elapsed() >= after
            {
                if model.track_interrupt() {
                    connection.send(&command("interrupt"))?;
                }
                interrupt_sent = true;
            }

            match connection.recv_timeout(Duration::from_millis(25)) {
                Ok(frame) => {
                    dump_frame(args.event_dump, started, &frame);
                    let rejected = frame["type"] == "error"
                        || (frame["type"] == "input_receipt" && frame["error"].is_string());
                    handle_frame(connection, model, cursors, frame)?;
                    if rejected {
                        return Err(model
                            .notice
                            .clone()
                            .unwrap_or_else(|| "command rejected".into()));
                    }
                    saw_active |= model.turn_state() != "idle";
                    if saw_active && model.turn_state() == "idle" && model.last_outcome.is_some() {
                        break;
                    }
                }
                Err(error) if error.contains("timed out") => {}
                Err(error) => return Err(error),
            }
        }
    }

    print!("{}", render_frame(model, args.width, args.height)?);
    eprintln!(
        "summary session={} incarnation={} saved_cursor={} head={} ask_to_active_ms={} ask_to_first_delta_ms={}",
        model.session_id,
        model.projection.incarnation,
        saved_cursor,
        model.projection.head,
        format_metric(model.metrics.ask_to_active_ms),
        format_metric(model.metrics.ask_to_first_delta_ms)
    );
    Ok(())
}

fn format_metric(metric: Option<f64>) -> String {
    metric
        .map(|value| format!("{value:.1}"))
        .unwrap_or_else(|| "-".to_string())
}

fn run_interactive(
    args: &Args,
    connection: &mut ClientConnection,
    model: &mut Model,
    cursors: &CursorStore,
    started: Instant,
) -> Result<(), String> {
    let guard = TerminalGuard::enter()?;
    model.enhanced_keyboard = guard.enhanced_keyboard;
    let backend = CrosstermBackend::new(io::stdout());
    let mut terminal =
        Terminal::new(backend).map_err(|error| format!("terminal failed: {error}"))?;
    terminal
        .clear()
        .map_err(|error| format!("terminal failed: {error}"))?;
    let mut dirty = true;
    let mut session_models: HashMap<String, Model> = HashMap::new();
    let mut attempted_handoff = None;

    loop {
        if let Some(target) = model.handoff_target()
            && attempted_handoff.as_ref() != Some(&target)
        {
            attempted_handoff = Some(target.clone());
            let source = model.clone();
            match reconnect(args.port, &target, model, cursors, &mut session_models) {
                Ok(new_connection) => {
                    *connection = new_connection;
                    model.inherit_handoff_draft(&source);
                }
                Err(error) => {
                    model.notice = Some(format!(
                        "Handoff link exists, but attach failed: {error}. Draft retained; use /sessions to retry."
                    ))
                }
            }
            dirty = true;
        }
        if dirty {
            terminal
                .draw(|frame| draw_model(frame, model))
                .map_err(|error| format!("terminal failed: {error}"))?;
            dirty = false;
        }

        while model.connection != ConnectionState::Detached {
            match connection.try_recv() {
                Ok(Some(frame)) => {
                    dump_frame(args.event_dump, started, &frame);
                    let created = (frame["type"] == "session_created"
                        || frame["type"] == "thread_open")
                        .then(|| frame["session_id"].as_str().map(str::to_owned))
                        .flatten();
                    let fork_prompt = frame["prompt"].as_str().map(str::to_owned);
                    if let Err(error) = handle_frame(connection, model, cursors, frame) {
                        model.mark_disconnected(&error);
                    } else if let Some(target) = created {
                        match reconnect(args.port, &target, model, cursors, &mut session_models) {
                            Ok(new_connection) => {
                                *connection = new_connection;
                                if let Some(prompt) = fork_prompt {
                                    model.editor.insert(&prompt);
                                }
                            }
                            Err(error) => {
                                model.notice =
                                    Some(format!("Session created, but attachment failed: {error}"))
                            }
                        }
                    }
                    dirty = true;
                }
                Ok(None) => break,
                Err(error) => {
                    model.mark_disconnected(&error);
                    dirty = true;
                }
            }
        }
        while model.connection == ConnectionState::Connected {
            let Some(request) = model.next_attachment_request() else {
                break;
            };
            if let Err(error) = connection.send(&request) {
                model.mark_disconnected(&error);
                dirty = true;
            }
        }
        dirty |= model.check_acceptance_timeout();

        if event::poll(Duration::from_millis(30))
            .map_err(|error| format!("terminal input failed: {error}"))?
        {
            let event = event::read().map_err(|error| format!("terminal input failed: {error}"))?;
            let width = terminal.size().map_err(|error| error.to_string())?.width;
            dirty = true;
            let request = match handle_input(model, event, width.saturating_sub(2).max(1) as usize)
            {
                InputAction::Detach => return Ok(()),
                InputAction::Submit => model.prepare_submit(),
                InputAction::Steer => model.prepare_steer(),
                InputAction::ProviderSettings(request)
                | InputAction::Attachment(request)
                | InputAction::Session(request) => Some(request),
                InputAction::Reconnect(target) => {
                    match reconnect(args.port, &target, model, cursors, &mut session_models) {
                        Ok(new_connection) => *connection = new_connection,
                        Err(error) => {
                            model.notice =
                                Some(format!("Switch failed: {error}; current draft retained."))
                        }
                    }
                    None
                }
                InputAction::Interrupt if model.track_interrupt() => Some(command("interrupt")),
                _ => None,
            };
            if let Some(request) = request
                && let Err(error) = connection.send(&request)
            {
                model.mark_disconnected(&error);
            }
        }
    }
}

fn handle_frame(
    connection: &mut ClientConnection,
    model: &mut Model,
    cursors: &CursorStore,
    frame: Value,
) -> Result<(), String> {
    if model.attachment_reply(&frame) || model.session_reply(&frame) || model.input_receipt(&frame)
    {
        return Ok(());
    }
    if frame["type"] == "thread_open" && frame["version"] == 2 {
        return Ok(());
    }
    if frame["type"] == "session_created" && frame["version"] == 2 {
        model.notice = Some(format!(
            "Session {} created; use /sessions to open it.",
            frame["session_id"].as_str().unwrap_or("?")
        ));
        return Ok(());
    }
    if frame["type"] == "session_result" && frame["version"] == 2 {
        if frame["command"] == "session_delete" {
            connection.send(&json!({"version":2,"command":"session_list"}))?;
        }
        model.notice = Some(format!(
            "{} completed.",
            frame["command"].as_str().unwrap_or("session action")
        ));
        return Ok(());
    }
    match frame["type"].as_str() {
        Some("patch") if frame["version"].as_u64() == Some(2) => {
            match model.apply_patch_frame(&frame)? {
                Ingest::Applied => save_cursor(cursors, model),
                Ingest::Ignored => {}
                Ingest::Resnapshot => {
                    model.track_resnapshot();
                    connection.send(&command("resnapshot"))?;
                }
            }
        }
        Some("snapshot") if frame["version"].as_u64() == Some(2) => {
            model.install_snapshot_frame(&frame)?;
            model.snapshot_reply();
            save_cursor(cursors, model);
        }
        Some("ok") => model.command_reply(None),
        Some("error") => model.command_reply(Some(frame["error"].as_str().unwrap_or("unknown"))),
        Some("status") => model.notice = Some(format!("Status: {}", frame["status"])),
        _ => return Err("server returned an invalid protocol v2 frame".to_string()),
    }
    Ok(())
}

fn reconnect(
    port: u16,
    target: &str,
    model: &mut Model,
    cursors: &CursorStore,
    cache: &mut HashMap<String, Model>,
) -> Result<ClientConnection, String> {
    let mut request = attach_request(target, &model.mode, &cursors.load(target));
    if let Some(cwd) = &model.cwd {
        request["cwd"] = json!(cwd);
    }
    let (mut connection, attached) = ClientConnection::connect(port, request)?;
    let fresh = attached_model(&attached, &model.mode)?;
    if fresh.session_id != target {
        return Err("attachment identity does not match selected session".into());
    }
    if let Some(request) = fresh.pending_input_status() {
        connection.send(&request)?;
    }
    if target == model.session_id {
        model.reconnect_from(fresh);
        save_cursor(cursors, model);
        return Ok(connection);
    }
    let old_id = model.session_id.clone();
    let mut next = cache.remove(target).unwrap_or_else(|| {
        let mut fresh = fresh.clone();
        fresh.appearance = model.appearance;
        fresh.enhanced_keyboard = model.enhanced_keyboard;
        fresh
    });
    next.reconnect_from(fresh);
    let old = std::mem::replace(model, next);
    cache.insert(old_id, old);
    save_cursor(cursors, model);
    Ok(connection)
}

fn save_cursor(cursors: &CursorStore, model: &Model) {
    if let Err(error) = cursors.save(
        &model.session_id,
        &model.projection.incarnation,
        model.projection.head,
    ) {
        eprintln!("warning: {error}");
    }
}

fn dump_frame(enabled: bool, started: Instant, frame: &Value) {
    if enabled {
        eprintln!(
            "event_ms={:.1} frame={frame}",
            started.elapsed().as_secs_f64() * 1_000.0
        );
    }
}

struct TerminalGuard {
    enhanced_keyboard: bool,
}

impl TerminalGuard {
    fn enter() -> Result<Self, String> {
        enable_raw_mode().map_err(|error| format!("cannot enable terminal raw mode: {error}"))?;
        let mut guard = Self {
            enhanced_keyboard: false,
        };
        execute!(
            io::stdout(),
            EnterAlternateScreen,
            EnableBracketedPaste,
            EnableMouseCapture
        )
        .map_err(|error| format!("cannot initialize terminal: {error}"))?;
        if supports_keyboard_enhancement().unwrap_or(false) {
            execute!(
                io::stdout(),
                PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
            )
            .map_err(|error| format!("cannot enable enhanced keyboard: {error}"))?;
            guard.enhanced_keyboard = true;
        }
        Ok(guard)
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        if self.enhanced_keyboard {
            let _ = execute!(io::stdout(), PopKeyboardEnhancementFlags);
        }
        let _ = execute!(
            io::stdout(),
            DisableBracketedPaste,
            DisableMouseCapture,
            LeaveAlternateScreen,
            crossterm::cursor::Show
        );
        let _ = disable_raw_mode();
        let _ = io::stdout().flush();
    }
}

#[cfg(test)]
mod argument_tests {
    use super::Args;

    fn parse(arguments: &[&str]) -> Result<Args, String> {
        Args::parse_from(arguments.iter().map(|value| (*value).to_owned()))
    }

    #[test]
    fn end_of_options_accepts_the_reported_hyphen_leading_session() {
        let args = parse(&[
            "--port",
            "4321",
            "--headless",
            "--",
            "-cs4HS4nJbLUqcYi8LhWHw",
        ])
        .unwrap();
        assert_eq!(args.target, "-cs4HS4nJbLUqcYi8LhWHw");
        assert_eq!(args.port, 4321);
        assert!(args.headless);
        assert_eq!(parse(&["--", "--help"]).unwrap().target, "--help");
    }

    #[test]
    fn delimiter_preserves_ordinary_forms_and_rejects_extra_positionals() {
        for arguments in [
            &["new", "--headless"][..],
            &["--headless", "new"],
            &["--headless", "--", "new"],
        ] {
            let args = parse(arguments).unwrap();
            assert_eq!(args.target, "new");
            assert!(args.headless);
        }
        assert_eq!(parse(&["list"]).unwrap().target, "list");
        assert_eq!(parse(&["session", "--"]).unwrap().target, "session");
        assert_eq!(
            parse(&["--ask", "--", "session"]).unwrap().ask.as_deref(),
            Some("--")
        );
        for arguments in [
            &["--"][..],
            &["--", "session", "--headless"],
            &["session", "--", "extra"],
        ] {
            assert!(parse(arguments).is_err());
        }
        assert!(
            parse(&["--typo", "session"])
                .err()
                .unwrap()
                .contains("unknown option --typo")
        );
        assert!(
            parse(&["-cs4HS4nJbLUqcYi8LhWHw"])
                .err()
                .unwrap()
                .contains("unknown option")
        );
    }
}
