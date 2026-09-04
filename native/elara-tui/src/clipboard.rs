use std::io::Write;
use std::process::{Command, Stdio};

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
