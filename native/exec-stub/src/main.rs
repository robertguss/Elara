use serde_json::{Value, json};
use std::collections::HashMap;
use std::env;
use std::io::{self, Read, Write};
use std::os::fd::{FromRawFd, RawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

const PROTOCOL_VERSION: u64 = 1;
const POLL_INTERVAL_MS: i32 = 10;

mod redaction;
use redaction::Redactor;
mod workspace_stat;

struct Request {
    id: String,
    op: String,
    argv: Vec<String>,
    cwd: Option<String>,
    env: HashMap<String, String>,
    max_bytes: u64,
    timeout_ms: u64,
    head_tail: bool,
    capture: Option<Capture>,
    redactions: Vec<(Vec<u8>, Vec<u8>)>,
}

struct Capture {
    path: String,
    max_bytes: u64,
}

struct ManagedJob {
    guardian_pid: libc::pid_t,
    control_fd: RawFd,
    event_fd: RawFd,
    event_buffer: Vec<u8>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Trigger {
    None,
    Cancelled,
    TimedOut,
    Truncated,
    CaptureLimited,
}

fn main() {
    let args: Vec<_> = env::args_os().collect();
    if args.len() == 3 && args[1] == "--workspace-blobs" {
        if workspace_stat::blobs(std::path::Path::new(&args[2])).is_err() {
            std::process::exit(1);
        }
        return;
    }
    if args.len() == 4 && args[1] == "--workspace-stat" {
        match workspace_stat::run(
            std::path::Path::new(&args[2]),
            std::path::Path::new(&args[3]),
        ) {
            Ok(value) => println!("{value}"),
            Err(_) => std::process::exit(1),
        }
        return;
    }
    if args.len() == 3 && args[1] == "--read-attachment" {
        match read_attachment(std::path::Path::new(&args[2])) {
            Ok(bytes) => {
                if io::stdout().write_all(&bytes).is_err() {
                    std::process::exit(1);
                }
            }
            Err(_) => std::process::exit(1),
        }
        return;
    }

    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }

    if let Err(error) = manager_loop() {
        let _ = writeln!(io::stderr(), "exec-stub: {error}");
        std::process::exit(1);
    }
}

// Run as a managed child so even a stalled filesystem read is killable without
// occupying a BEAM dirty-I/O scheduler. Never follow a replaced leaf symlink or
// wait for a FIFO writer; validate the opened descriptor before reading.
fn read_attachment(path: &std::path::Path) -> io::Result<Vec<u8>> {
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "not a regular file",
        ));
    }
    let mut bytes = Vec::with_capacity(65_545);
    bytes.extend_from_slice(&metadata.len().to_be_bytes());
    file.take(65_537).read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn manager_loop() -> io::Result<()> {
    set_nonblocking(libc::STDIN_FILENO)?;

    let mut stdout = io::stdout().lock();
    emit(
        &mut stdout,
        &json!({
            "ev": "ready",
            "protocol": PROTOCOL_VERSION,
            "stub_version": env!("CARGO_PKG_VERSION"),
            "output_policies": ["truncate", "head_tail", "capture"]
        }),
    )?;

    let mut input = Vec::new();
    let mut jobs: HashMap<String, ManagedJob> = HashMap::new();

    loop {
        let ids: Vec<String> = jobs.keys().cloned().collect();
        let mut poll_fds = Vec::with_capacity(ids.len() + 1);
        poll_fds.push(libc::pollfd {
            fd: libc::STDIN_FILENO,
            events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
            revents: 0,
        });

        for id in &ids {
            let job = &jobs[id];
            poll_fds.push(libc::pollfd {
                fd: job.event_fd,
                events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
                revents: 0,
            });
        }

        let ready = unsafe { libc::poll(poll_fds.as_mut_ptr(), poll_fds.len() as _, -1) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }

        if poll_fds[0].revents != 0 && !read_requests(&mut input, &mut jobs, &mut stdout)? {
            shutdown_jobs(jobs);
            return Ok(());
        }

        let mut finished = Vec::new();
        for (index, id) in ids.iter().enumerate() {
            if poll_fds[index + 1].revents == 0 {
                continue;
            }

            let Some(job) = jobs.get_mut(id) else {
                continue;
            };

            if !forward_events(job.event_fd, &mut job.event_buffer, &mut stdout)? {
                finished.push(id.clone());
            }
        }

        for id in finished {
            if let Some(job) = jobs.remove(&id) {
                close_fd(job.control_fd);
                close_fd(job.event_fd);
                wait_for_pid(job.guardian_pid);
            }
        }
    }
}

fn read_requests(
    input: &mut Vec<u8>,
    jobs: &mut HashMap<String, ManagedJob>,
    stdout: &mut impl Write,
) -> io::Result<bool> {
    let mut buffer = [0_u8; 8192];

    loop {
        let count =
            unsafe { libc::read(libc::STDIN_FILENO, buffer.as_mut_ptr().cast(), buffer.len()) };
        if count == 0 {
            return Ok(false);
        }
        if count < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::WouldBlock {
                break;
            }
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        input.extend_from_slice(&buffer[..count as usize]);
    }

    while let Some(newline) = input.iter().position(|byte| *byte == b'\n') {
        let mut line: Vec<u8> = input.drain(..=newline).collect();
        line.pop();
        if line.is_empty() {
            continue;
        }

        let request = match parse_request(&line) {
            Ok(request) => request,
            Err(error) => {
                emit(
                    stdout,
                    &json!({"ev": "protocol_error", "error": error.to_string()}),
                )?;
                continue;
            }
        };

        handle_request(request, jobs, stdout)?;
    }

    Ok(true)
}

fn parse_request(line: &[u8]) -> Result<Request, String> {
    let value: Value = serde_json::from_slice(line).map_err(|error| error.to_string())?;
    let object = value
        .as_object()
        .ok_or_else(|| "request must be a JSON object".to_owned())?;

    let id = object
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| "request id must be a string".to_owned())?
        .to_owned();
    let op = object
        .get("op")
        .and_then(Value::as_str)
        .ok_or_else(|| "request op must be a string".to_owned())?
        .to_owned();

    let argv = match object.get("argv") {
        None => Vec::new(),
        Some(Value::Array(values)) => values
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| "argv entries must be strings".to_owned())
            })
            .collect::<Result<Vec<_>, _>>()?,
        Some(_) => return Err("argv must be an array".to_owned()),
    };

    let cwd = match object.get("cwd") {
        None | Some(Value::Null) => None,
        Some(Value::String(value)) => Some(value.clone()),
        Some(_) => return Err("cwd must be a string".to_owned()),
    };

    let env = match object.get("env") {
        None => HashMap::new(),
        Some(Value::Object(values)) => values
            .iter()
            .map(|(key, value)| {
                value
                    .as_str()
                    .map(|value| (key.clone(), value.to_owned()))
                    .ok_or_else(|| "environment values must be strings".to_owned())
            })
            .collect::<Result<HashMap<_, _>, _>>()?,
        Some(_) => return Err("env must be an object".to_owned()),
    };

    let max_bytes = object
        .get("max_bytes")
        .map(|value| {
            value
                .as_u64()
                .ok_or_else(|| "max_bytes must be an unsigned integer".to_owned())
        })
        .transpose()?
        .unwrap_or(0);
    let timeout_ms = object
        .get("timeout_ms")
        .map(|value| {
            value
                .as_u64()
                .ok_or_else(|| "timeout_ms must be an unsigned integer".to_owned())
        })
        .transpose()?
        .unwrap_or(0);

    let head_tail = match object.get("output_policy") {
        None => false,
        Some(Value::String(policy)) if policy == "truncate" => false,
        Some(Value::String(policy)) if policy == "head_tail" => true,
        _ => return Err("unknown output_policy".to_owned()),
    };

    let capture = match object.get("capture") {
        None => None,
        Some(value) => {
            let path = value
                .get("path")
                .and_then(Value::as_str)
                .filter(|path| !path.contains('\0') && std::path::Path::new(path).is_absolute())
                .ok_or_else(|| "capture path must be absolute".to_owned())?;
            let cap = value
                .get("max_bytes")
                .and_then(Value::as_u64)
                .filter(|cap| *cap > 0)
                .ok_or_else(|| "capture max_bytes must be positive".to_owned())?;
            if !head_tail {
                return Err("capture requires head_tail".to_owned());
            }
            Some(Capture {
                path: path.to_owned(),
                max_bytes: cap,
            })
        }
    };

    let mut redactions = Vec::new();
    if let Some(value) = object.get("redactions") {
        let rules = value
            .as_array()
            .filter(|rules| rules.len() <= 256)
            .ok_or("invalid redactions")?;
        for rule in rules {
            let pair = rule
                .as_array()
                .filter(|pair| pair.len() == 2)
                .ok_or("invalid redactions")?;
            let secret = pair[0]
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= 65_536)
                .ok_or("invalid redactions")?;
            let replacement = pair[1].as_str().ok_or("invalid redactions")?;
            redactions.push((secret.as_bytes().to_vec(), replacement.as_bytes().to_vec()));
        }
    }

    Ok(Request {
        id,
        op,
        argv,
        cwd,
        env,
        max_bytes,
        timeout_ms,
        head_tail,
        capture,
        redactions,
    })
}

fn handle_request(
    request: Request,
    jobs: &mut HashMap<String, ManagedJob>,
    stdout: &mut impl Write,
) -> io::Result<()> {
    match request.op.as_str() {
        "run" => {
            if request.id.is_empty()
                || request.argv.is_empty()
                || request.argv.iter().any(|arg| arg.contains('\0'))
                || request.cwd.as_ref().is_none_or(|cwd| cwd.contains('\0'))
                || request.max_bytes == 0
                || request.timeout_ms == 0
                || request.env.iter().any(|(key, value)| {
                    key.is_empty() || key.contains(['=', '\0']) || value.contains('\0')
                })
            {
                emit(
                    stdout,
                    &json!({
                        "id": request.id,
                        "ev": "rejected",
                        "stage": "validate",
                        "message": "invalid run request"
                    }),
                )?;
            } else if jobs.contains_key(&request.id) {
                emit(
                    stdout,
                    &json!({
                        "id": request.id,
                        "ev": "protocol_error",
                        "error": "duplicate job id"
                    }),
                )?;
            } else {
                let job = spawn_guardian(&request, jobs)?;
                jobs.insert(request.id, job);
            }
        }
        "cancel" => {
            if let Some(job) = jobs.get(&request.id) {
                write_all_fd(job.control_fd, b"C")?;
            }
        }
        "ping" => emit(
            stdout,
            &json!({"id": request.id, "ev": "pong", "protocol": PROTOCOL_VERSION}),
        )?,
        _ => emit(
            stdout,
            &json!({
                "id": request.id,
                "ev": "protocol_error",
                "error": "unknown operation"
            }),
        )?,
    }

    Ok(())
}

fn spawn_guardian(
    request: &Request,
    existing: &HashMap<String, ManagedJob>,
) -> io::Result<ManagedJob> {
    let control = pipe()?;
    let events = pipe()?;
    let pid = unsafe { libc::fork() };

    if pid < 0 {
        close_fd(control[0]);
        close_fd(control[1]);
        close_fd(events[0]);
        close_fd(events[1]);
        return Err(io::Error::last_os_error());
    }

    if pid == 0 {
        close_fd(control[1]);
        close_fd(events[0]);
        close_fd(libc::STDIN_FILENO);
        close_fd(libc::STDOUT_FILENO);

        for job in existing.values() {
            close_fd(job.control_fd);
            close_fd(job.event_fd);
        }

        let code = match guardian_loop(request, control[0], events[1]) {
            Ok(()) => 0,
            Err(error) => {
                let _ = write_json_fd(
                    events[1],
                    &json!({
                        "id": request.id,
                        "ev": "protocol_error",
                        "error": error.to_string()
                    }),
                );
                1
            }
        };

        close_fd(control[0]);
        close_fd(events[1]);
        unsafe { libc::_exit(code) }
    }

    close_fd(control[0]);
    close_fd(events[1]);
    set_nonblocking(events[0])?;

    Ok(ManagedJob {
        guardian_pid: pid,
        control_fd: control[1],
        event_fd: events[0],
        event_buffer: Vec::new(),
    })
}

fn guardian_loop(request: &Request, control_fd: RawFd, event_fd: RawFd) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    unsafe {
        libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0);
    }
    set_nonblocking(control_fd)?;

    match read_control(control_fd)? {
        Control::Alive => {}
        Control::Cancel => {
            // The manager still owns a submitted job. Report proven non-start
            // so its caller can retire the job even when cancellation wins the
            // race with command spawn.
            write_json_fd(
                event_fd,
                &json!({
                    "id": request.id,
                    "ev": "rejected",
                    "stage": "cancel",
                    "message": "cancelled before spawn"
                }),
            )?;
            return Ok(());
        }
        Control::ManagerGone => return Ok(()),
    }

    let mut capture = match &request.capture {
        None => None,
        Some(spec) => match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&spec.path)
        {
            Ok(file) => Some(file),
            Err(error) => {
                write_json_fd(
                    event_fd,
                    &json!({
                        "id": request.id, "ev": "rejected", "stage": "capture", "message": error.to_string()
                    }),
                )?;
                return Ok(());
            }
        },
    };

    let mut redactor = Redactor::new(request.redactions.clone());
    let output = pipe()?;
    set_nonblocking(output[0])?;
    let stdout_fd = duplicate_fd(output[1])?;
    let stderr_fd = duplicate_fd(output[1])?;

    let mut command = Command::new(&request.argv[0]);
    command
        .args(&request.argv[1..])
        .current_dir(request.cwd.as_deref().expect("validated cwd"))
        .env_clear()
        .envs(&request.env)
        .stdin(Stdio::null())
        .stdout(unsafe { Stdio::from_raw_fd(stdout_fd) })
        .stderr(unsafe { Stdio::from_raw_fd(stderr_fd) })
        .process_group(0);

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            close_fd(output[0]);
            close_fd(output[1]);
            write_json_fd(
                event_fd,
                &json!({
                    "id": request.id,
                    "ev": "rejected",
                    "stage": "spawn",
                    "message": error.to_string()
                }),
            )?;
            return Ok(());
        }
    };
    drop(command);
    close_fd(output[1]);

    let pgid = child.id() as libc::pid_t;
    write_json_fd(
        event_fd,
        &json!({"id": request.id, "ev": "started", "pid": pgid}),
    )?;

    let started = Instant::now();
    let deadline = started + Duration::from_millis(request.timeout_ms);
    let mut trigger = Trigger::None;
    let mut bytes_total = 0_u64;
    let mut bytes_sent = 0_u64;
    let mut bytes_persisted = 0_u64;
    let mut tail = Vec::new();
    let mut output_closed = false;
    let mut status: Option<ExitStatus> = None;
    let mut manager_present = true;

    while status.is_none() || !output_closed {
        let mut fds = [
            libc::pollfd {
                fd: control_fd,
                events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
                revents: 0,
            },
            libc::pollfd {
                fd: output[0],
                events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
                revents: 0,
            },
        ];

        let timeout = deadline
            .checked_duration_since(Instant::now())
            .map(|remaining| remaining.as_millis().min(POLL_INTERVAL_MS as u128) as i32)
            .unwrap_or(0);
        let polled = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as _, timeout) };
        if polled < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            kill_group(pgid);
            return Err(io::Error::last_os_error());
        }

        if fds[0].revents != 0 {
            match read_control(control_fd)? {
                Control::Alive => {}
                Control::Cancel => {
                    if trigger == Trigger::None {
                        trigger = Trigger::Cancelled;
                        kill_group(pgid);
                    }
                }
                Control::ManagerGone => {
                    manager_present = false;
                    kill_group(pgid);
                }
            }
        }

        if fds[1].revents != 0 && !output_closed {
            let drained = drain_output(
                output[0],
                event_fd,
                &request.id,
                request.max_bytes,
                pgid,
                &mut trigger,
                &mut bytes_total,
                &mut bytes_sent,
                request.head_tail,
                &mut tail,
                &mut capture,
                request.capture.as_ref().map(|spec| spec.max_bytes),
                &mut bytes_persisted,
                &mut redactor,
            );
            match drained {
                Ok(open) => output_closed = !open,
                Err(error) => {
                    kill_group(pgid);
                    let _ = child.wait();
                    close_fd(output[0]);
                    reap_descendants();
                    return Err(error);
                }
            }
        }

        if trigger == Trigger::None && Instant::now() >= deadline {
            trigger = Trigger::TimedOut;
            kill_group(pgid);
        }

        if status.is_none() {
            match child.try_wait() {
                Ok(Some(exit)) => {
                    status = Some(exit);
                    kill_group(pgid);
                }
                Ok(None) => {}
                Err(error) => {
                    kill_group(pgid);
                    close_fd(output[0]);
                    return Err(error);
                }
            }
        }

        if !manager_present && status.is_some() && output_closed {
            break;
        }
    }

    close_fd(output[0]);
    reap_descendants();

    if manager_present {
        if let Some(file) = &capture {
            file.sync_all()?;
        }
        let status = status.expect("loop waits for child status");
        let mut terminal = json!({
            "id": request.id,
            "ev": "exit",
            "code": status.code(),
            "signal": status.signal(),
            "cancelled": trigger == Trigger::Cancelled,
            "timed_out": trigger == Trigger::TimedOut,
            "truncated": trigger == Trigger::Truncated,
            "bytes_total": bytes_total,
            "bytes_sent": bytes_sent + tail.len() as u64,
            "elapsed_ms": started.elapsed().as_millis() as u64
        });
        if request.head_tail {
            terminal["output_capped"] = json!(bytes_total > bytes_sent + tail.len() as u64);
            terminal["tail"] = json!(tail);
        }
        if request.capture.is_some() {
            terminal["bytes_persisted"] = json!(bytes_persisted);
            terminal["capture_limited"] = json!(trigger == Trigger::CaptureLimited);
        }
        write_json_fd(event_fd, &terminal)?;
    }

    Ok(())
}

enum Control {
    Alive,
    Cancel,
    ManagerGone,
}

fn read_control(fd: RawFd) -> io::Result<Control> {
    let mut byte = 0_u8;
    let count = unsafe { libc::read(fd, (&mut byte as *mut u8).cast(), 1) };
    if count == 0 {
        return Ok(Control::ManagerGone);
    }
    if count > 0 {
        return Ok(Control::Cancel);
    }

    let error = io::Error::last_os_error();
    if error.kind() == io::ErrorKind::WouldBlock {
        Ok(Control::Alive)
    } else if error.kind() == io::ErrorKind::Interrupted {
        read_control(fd)
    } else {
        Err(error)
    }
}

#[allow(clippy::too_many_arguments)]
fn drain_output(
    output_fd: RawFd,
    event_fd: RawFd,
    id: &str,
    max_bytes: u64,
    pgid: libc::pid_t,
    trigger: &mut Trigger,
    bytes_total: &mut u64,
    bytes_sent: &mut u64,
    head_tail: bool,
    tail: &mut Vec<u8>,
    capture: &mut Option<std::fs::File>,
    capture_limit: Option<u64>,
    bytes_persisted: &mut u64,
    redactor: &mut Redactor,
) -> io::Result<bool> {
    let mut buffer = [0_u8; 8192];
    let head_limit = if !head_tail {
        max_bytes
    } else if capture.is_some() {
        max_bytes * 3 / 8
    } else {
        max_bytes / 2
    };
    let tail_limit = (max_bytes - head_limit) as usize;

    // Return to the control/deadline poll even with a continuously full pipe.
    for _ in 0..64 {
        let count = unsafe { libc::read(output_fd, buffer.as_mut_ptr().cast(), buffer.len()) };
        if count < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::WouldBlock {
                return Ok(true);
            }
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }

        let eof = count == 0;
        let redacted = redactor.feed(&buffer[..count as usize], eof);
        let buffer = redacted.as_slice();
        let count = buffer.len();
        *bytes_total += count as u64;
        if let Some(file) = capture {
            let limit = capture_limit.expect("capture has a limit");
            let kept = count.min(limit.saturating_sub(*bytes_persisted) as usize);
            file.write_all(&buffer[..kept])?;
            *bytes_persisted += kept as u64;
            if *bytes_persisted == limit && *trigger == Trigger::None {
                *trigger = Trigger::CaptureLimited;
                kill_group(pgid);
            }
        }
        let room = head_limit.saturating_sub(*bytes_sent) as usize;
        let sent = count.min(room);

        if sent > 0 {
            write_json_fd(
                event_fd,
                &json!({
                    "id": id,
                    "ev": "chunk",
                    "stream": "combined",
                    "bytes": &buffer[..sent]
                }),
            )?;
            *bytes_sent += sent as u64;
        }

        if head_tail && tail_limit > 0 {
            let rest = &buffer[sent..count];
            if rest.len() >= tail_limit {
                tail.clear();
                tail.extend_from_slice(&rest[rest.len() - tail_limit..]);
            } else {
                let excess = (tail.len() + rest.len()).saturating_sub(tail_limit);
                tail.drain(..excess);
                tail.extend_from_slice(rest);
            }
        }

        if !head_tail && *bytes_total > max_bytes && *trigger == Trigger::None {
            *trigger = Trigger::Truncated;
            kill_group(pgid);
        }
        if eof {
            return Ok(false);
        }
    }
    Ok(true)
}

fn forward_events(fd: RawFd, pending: &mut Vec<u8>, stdout: &mut impl Write) -> io::Result<bool> {
    let mut buffer = [0_u8; 8192];

    loop {
        let count = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
        if count == 0 {
            if !pending.is_empty() {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "guardian closed with an incomplete event",
                ));
            }
            return Ok(false);
        }
        if count < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::WouldBlock {
                stdout.flush()?;
                return Ok(true);
            }
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        let bytes = &buffer[..count as usize];
        let previous = pending.len();
        pending.extend_from_slice(bytes);
        // A pipe read may stop inside a frame. Never interleave that suffix
        // with another guardian's frames on the shared protocol stream.
        if let Some(end) = bytes.iter().rposition(|byte| *byte == b'\n') {
            let complete = previous + end + 1;
            stdout.write_all(&pending[..complete])?;
            pending.drain(..complete);
        }
    }
}

fn shutdown_jobs(jobs: HashMap<String, ManagedJob>) {
    let mut pids = Vec::with_capacity(jobs.len());
    for job in jobs.into_values() {
        close_fd(job.control_fd);
        close_fd(job.event_fd);
        pids.push(job.guardian_pid);
    }
    for pid in pids {
        wait_for_pid(pid);
    }
}

fn reap_descendants() {
    loop {
        let mut status = 0;
        let waited = unsafe { libc::waitpid(-1, &mut status, 0) };
        if waited > 0 {
            continue;
        }
        if waited < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
            continue;
        }
        break;
    }
}

fn wait_for_pid(pid: libc::pid_t) {
    loop {
        let waited = unsafe { libc::waitpid(pid, std::ptr::null_mut(), 0) };
        if waited == pid {
            return;
        }
        if waited < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
            continue;
        }
        return;
    }
}

fn kill_group(pgid: libc::pid_t) {
    unsafe {
        libc::kill(-pgid, libc::SIGKILL);
    }
}

fn pipe() -> io::Result<[RawFd; 2]> {
    let mut fds = [-1; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }

    for fd in fds {
        if let Err(error) = set_close_on_exec(fd) {
            close_fd(fds[0]);
            close_fd(fds[1]);
            return Err(error);
        }
    }

    Ok(fds)
}

fn duplicate_fd(fd: RawFd) -> io::Result<RawFd> {
    let duplicate = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3) };
    if duplicate >= 0 {
        Ok(duplicate)
    } else {
        Err(io::Error::last_os_error())
    }
}

fn set_close_on_exec(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn emit(writer: &mut impl Write, value: &Value) -> io::Result<()> {
    serde_json::to_writer(&mut *writer, value)?;
    writer.write_all(b"\n")?;
    writer.flush()
}

fn write_json_fd(fd: RawFd, value: &Value) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(value)?;
    bytes.push(b'\n');
    write_all_fd(fd, &bytes)
}

fn write_all_fd(fd: RawFd, mut bytes: &[u8]) -> io::Result<()> {
    while !bytes.is_empty() {
        let written = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if written < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        bytes = &bytes[written as usize..];
    }
    Ok(())
}

fn close_fd(fd: RawFd) {
    if fd >= 0 {
        unsafe {
            libc::close(fd);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancellation_before_spawn_reports_rejection_but_manager_loss_stays_silent() {
        for cancelled in [true, false] {
            let control = pipe().unwrap();
            let events = pipe().unwrap();
            if cancelled {
                write_all_fd(control[1], b"C").unwrap();
            } else {
                close_fd(control[1]);
            }

            let request = Request {
                id: "pre-spawn".into(),
                op: "run".into(),
                argv: vec!["/bin/sh".into(), "-c".into(), "exit 99".into()],
                cwd: Some(env::temp_dir().to_string_lossy().into_owned()),
                env: HashMap::new(),
                max_bytes: 128,
                timeout_ms: 1000,
                head_tail: false,
                capture: None,
                redactions: Vec::new(),
            };
            guardian_loop(&request, control[0], events[1]).unwrap();
            close_fd(control[0]);
            if cancelled {
                close_fd(control[1]);
            }
            close_fd(events[1]);
            let mut output = String::new();
            unsafe { std::fs::File::from_raw_fd(events[0]) }
                .read_to_string(&mut output)
                .unwrap();

            if cancelled {
                let event: Value = serde_json::from_str(&output).unwrap();
                assert_eq!(event["id"], "pre-spawn");
                assert_eq!(event["ev"], "rejected");
                assert_eq!(event["stage"], "cancel");
            } else {
                assert!(output.is_empty());
            }
        }
    }

    #[test]
    fn attachment_reader_rejects_replaced_fifo_and_symlink_without_waiting() {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        let path = env::temp_dir().join(format!("elara-attachment-{}", std::process::id()));
        std::fs::write(&path, b"selected before replacement").unwrap();
        assert!(std::fs::metadata(&path).unwrap().is_file());
        std::fs::remove_file(&path).unwrap();
        let cpath = CString::new(path.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(cpath.as_ptr(), 0o600) }, 0);
        let started = Instant::now();
        assert!(read_attachment(&path).is_err());
        assert!(started.elapsed() < Duration::from_secs(1));
        std::fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink("/dev/zero", &path).unwrap();
        assert!(read_attachment(&path).is_err());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn attachment_reader_caps_bytes_and_uses_opened_file_size() {
        let path = env::temp_dir().join(format!("elara-attachment-bounded-{}", std::process::id()));
        std::fs::write(&path, vec![255; 100_000]).unwrap();
        let bytes = read_attachment(&path).unwrap();
        assert_eq!(&bytes[..8], &100_000_u64.to_be_bytes());
        assert_eq!(bytes.len(), 8 + 65_537);
        assert!(bytes[8..].iter().all(|byte| *byte == 255));
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn parses_run_with_environment() {
        let request = parse_request(
            r#"{"id":"j1","op":"run","argv":["printf","ok"],"cwd":"/tmp","env":{"A":"B"},"max_bytes":10,"timeout_ms":20}"#
                .as_bytes(),
        )
        .unwrap();

        assert_eq!(request.id, "j1");
        assert_eq!(request.argv, ["printf", "ok"]);
        assert_eq!(request.env["A"], "B");
        assert_eq!(request.max_bytes, 10);
        assert_eq!(request.timeout_ms, 20);
        assert!(!request.head_tail);
    }

    #[test]
    fn output_policy_is_explicit_and_unknown_values_are_rejected() {
        let request =
            parse_request(br#"{"id":"j1","op":"run","output_policy":"head_tail"}"#).unwrap();
        assert!(request.head_tail);
        for policy in [json!("other"), json!(null), json!(true), json!(1)] {
            let bytes =
                serde_json::to_vec(&json!({"id":"j1","op":"run","output_policy":policy})).unwrap();
            assert!(parse_request(&bytes).is_err());
        }
    }

    #[test]
    fn byte_chunks_are_lossless_json_arrays() {
        let bytes = [0, 127, 128, 255];
        let encoded = json!({"bytes": bytes});
        assert_eq!(encoded["bytes"], json!([0, 127, 128, 255]));
    }

    #[test]
    fn pipes_are_closed_on_exec() {
        let fds = pipe().unwrap();

        for fd in fds {
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
            assert!(flags >= 0);
            assert_ne!(flags & libc::FD_CLOEXEC, 0);
            close_fd(fd);
        }
    }
}
