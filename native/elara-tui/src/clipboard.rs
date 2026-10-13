use std::io::{Read, Seek, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub(crate) enum Content {
    Text(String),
    Image(Vec<u8>),
}

pub(crate) fn paste() -> Result<Content, String> {
    #[cfg(target_os = "macos")]
    let images: &[(&str, &[&str])] = &[("osascript", &["-e", "get the clipboard as «class PNGf»"])];
    #[cfg(not(target_os = "macos"))]
    let images: &[(&str, &[&str])] = &[
        ("wl-paste", &["--no-newline", "--type", "image/png"]),
        (
            "xclip",
            &["-selection", "clipboard", "-o", "-t", "image/png"],
        ),
    ];
    for (program, args) in images {
        if let Ok(data) = read(program, args, 4 * 1024 * 1024 + 64) {
            #[cfg(target_os = "macos")]
            let data = decode_png_descriptor(&data)?;
            if data.starts_with(b"\x89PNG\r\n\x1a\n") {
                if data.len() > 2 * 1024 * 1024 {
                    return Err("Clipboard image exceeds 2 MiB; draft retained.".into());
                }
                return Ok(Content::Image(data));
            }
        }
    }
    #[cfg(target_os = "macos")]
    let texts: &[(&str, &[&str])] = &[("pbpaste", &[])];
    #[cfg(not(target_os = "macos"))]
    let texts: &[(&str, &[&str])] = &[
        ("wl-paste", &["--no-newline", "--type", "text"]),
        (
            "xclip",
            &["-selection", "clipboard", "-o", "-t", "UTF8_STRING"],
        ),
        ("xsel", &["--clipboard", "--output"]),
    ];
    for (program, args) in texts {
        if let Ok(data) = read(program, args, 64 * 1024) {
            return String::from_utf8(data)
                .map(Content::Text)
                .map_err(|_| "Clipboard text is not UTF-8; draft retained.".into());
        }
    }
    Err("Clipboard unavailable; protected terminal paste enabled. Ctrl-V finishes; /image attaches a PNG from disk.".into())
}

#[cfg(target_os = "macos")]
fn decode_png_descriptor(data: &[u8]) -> Result<Vec<u8>, String> {
    let text = std::str::from_utf8(data).map_err(|_| "Invalid clipboard PNG descriptor")?;
    let hex = text
        .trim()
        .strip_prefix("«data PNGf")
        .and_then(|s| s.strip_suffix('»'))
        .ok_or("Invalid clipboard PNG descriptor")?;
    if hex.len() % 2 != 0 {
        return Err("Invalid clipboard PNG descriptor".into());
    }
    hex.as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let byte = std::str::from_utf8(pair).map_err(|_| "Invalid clipboard PNG descriptor")?;
            u8::from_str_radix(byte, 16).map_err(|_| "Invalid clipboard PNG descriptor".into())
        })
        .collect()
}

fn read(program: &str, args: &[&str], limit: usize) -> Result<Vec<u8>, String> {
    let mut output = tempfile::tempfile().map_err(|e| e.to_string())?;
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(output.try_clone().map_err(|e| e.to_string())?)
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| e.to_string())?;
    let deadline = Instant::now() + Duration::from_millis(300);
    loop {
        if output.metadata().map_err(|e| e.to_string())?.len() > limit as u64
            || Instant::now() >= deadline
        {
            let _ = child.kill();
            let _ = child.wait();
            return Err("Clipboard read exceeded its size/time limit".into());
        }
        match child.try_wait().map_err(|e| e.to_string())? {
            Some(status) if status.success() => break,
            Some(_) => return Err("Clipboard type unavailable".into()),
            None => std::thread::sleep(Duration::from_millis(5)),
        }
    }
    output.rewind().map_err(|e| e.to_string())?;
    let mut bytes = Vec::new();
    output
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > limit {
        return Err("Clipboard read exceeded its size limit".into());
    }
    Ok(bytes)
}

pub(crate) fn copy(text: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    let commands: &[(&str, &[&str])] = &[("pbcopy", &[])];
    #[cfg(not(target_os = "macos"))]
    let commands: &[(&str, &[&str])] = &[
        ("wl-copy", &[]),
        ("xclip", &["-selection", "clipboard"]),
        ("xsel", &["--clipboard", "--input"]),
    ];
    let mut failures = Vec::new();
    for (program, args) in commands {
        let result = (|| {
            let mut child = Command::new(program)
                .args(*args)
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|e| e.to_string())?;
            let written = child
                .stdin
                .take()
                .expect("piped stdin")
                .write_all(text.as_bytes());
            let status = child.wait().map_err(|e| e.to_string())?;
            written.map_err(|e| e.to_string())?;
            if status.success() {
                Ok(())
            } else {
                Err(format!("exit {status}"))
            }
        })();
        match result {
            Ok(()) => return Ok(()),
            Err(error) => failures.push(format!("{program}: {error}")),
        }
    }
    Err(format!(
        "Clipboard failed ({}); use terminal-native selection/copy",
        failures.join("; ")
    ))
}
