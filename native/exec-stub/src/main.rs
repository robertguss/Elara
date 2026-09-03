use serde_json::{Value, json};
use std::collections::HashMap;
use std::env;
use std::io::{self, Write};
use std::os::fd::{FromRawFd, RawFd};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

const PROTOCOL_VERSION: u64 = 1;
const POLL_INTERVAL_MS: i32 = 10;

struct Request {
    id: String,
    op: String,
    argv: Vec<String>,
    cwd: Option<String>,
    env: HashMap<String, String>,
    max_bytes: u64,
    timeout_ms: u64,
}

struct ManagedJob {
    guardian_pid: libc::pid_t,
    control_fd: RawFd,
    event_fd: RawFd,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Trigger {
    None,
    Cancelled,
    TimedOut,
    Truncated,
}

fn main() {
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }

    if let Err(error) = manager_loop() {
        let _ = writeln!(io::stderr(), "exec-stub: {error}");
        std::process::exit(1);
    }
}

fn manager_loop() -> io::Result<()> {
    set_nonblocking(libc::STDIN_FILENO)?;

    let mut stdout = io::stdout().lock();
    emit(
        &mut stdout,
        &json!({
            "ev": "ready",
            "protocol": PROTOCOL_VERSION,
            "stub_version": env!("CARGO_PKG_VERSION")
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

            let Some(job) = jobs.get(id) else {
                continue;
            };

            if !forward_events(job.event_fd, &mut stdout)? {
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

    Ok(Request {
        id,
        op,
        argv,
        cwd,
        env,
        max_bytes,
        timeout_ms,
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
    })
}

fn guardian_loop(request: &Request, control_fd: RawFd, event_fd: RawFd) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    unsafe {
        libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0);
    }
    set_nonblocking(control_fd)?;

    if !manager_alive(control_fd)? {
        return Ok(());
    }

    let output = pipe()?;
    set_nonblocking(output[0])?;
    let stdout_fd = duplicate_fd(output[1])?;
    let stderr_fd = duplicate_fd(output[1])?;

    let mut command = Command::new(&request.argv[0]);
    command
        .args(&request.argv[1..])
        .current_dir(request.cwd.as_deref().expect("validated cwd"))
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
            output_closed = !drain_output(
                output[0],
                event_fd,
                &request.id,
                request.max_bytes,
                pgid,
                &mut trigger,
                &mut bytes_total,
                &mut bytes_sent,
            )?;
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
        let status = status.expect("loop waits for child status");
        write_json_fd(
            event_fd,
            &json!({
                "id": request.id,
                "ev": "exit",
                "code": status.code(),
                "signal": status.signal(),
                "cancelled": trigger == Trigger::Cancelled,
                "timed_out": trigger == Trigger::TimedOut,
                "truncated": trigger == Trigger::Truncated,
                "bytes_total": bytes_total,
                "bytes_sent": bytes_sent,
                "elapsed_ms": started.elapsed().as_millis() as u64
            }),
        )?;
    }

    Ok(())
}

enum Control {
    Alive,
    Cancel,
    ManagerGone,
}

fn manager_alive(fd: RawFd) -> io::Result<bool> {
    match read_control(fd)? {
        Control::Alive => Ok(true),
        Control::Cancel | Control::ManagerGone => Ok(false),
    }
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
) -> io::Result<bool> {
    let mut buffer = [0_u8; 8192];

    loop {
        let count = unsafe { libc::read(output_fd, buffer.as_mut_ptr().cast(), buffer.len()) };
        if count == 0 {
            return Ok(false);
        }
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

        let count = count as usize;
        *bytes_total += count as u64;
        let room = max_bytes.saturating_sub(*bytes_sent) as usize;
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

        if *bytes_total > max_bytes && *trigger == Trigger::None {
            *trigger = Trigger::Truncated;
            kill_group(pgid);
        }
    }
}

fn forward_events(fd: RawFd, stdout: &mut impl Write) -> io::Result<bool> {
    let mut buffer = [0_u8; 8192];

    loop {
        let count = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
        if count == 0 {
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
        stdout.write_all(&buffer[..count as usize])?;
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
