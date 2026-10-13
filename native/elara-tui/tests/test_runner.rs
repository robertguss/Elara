#[cfg(unix)]
#[test]
fn cargo_test_runner_isolates_state_and_cleans_up_even_on_failure() {
    use std::{fs, os::unix::fs::symlink, process::Command};

    let root = std::env::temp_dir().join(format!("elara-runner-probe-{}", std::process::id()));
    fs::create_dir_all(root.join("deps")).unwrap();
    let shell = root.join("deps/probe");
    symlink("/bin/sh", &shell).unwrap();
    let runner = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/run-isolated");

    for status in [0, 7] {
        let output = Command::new(runner)
            .arg(&shell)
            .args(["-c", "printf '%s\n%s\n' \"$ELARA_TUI_STATE_DIR\" \"$ELARA_TUI_APPEARANCE_FILE\"; mkdir -p \"$ELARA_TUI_STATE_DIR\"; touch \"$ELARA_TUI_APPEARANCE_FILE\"; exit \"$1\"", "probe"])
            .arg(status.to_string())
            .env("ELARA_TUI_STATE_DIR", root.join("poison"))
            .env("ELARA_TUI_APPEARANCE_FILE", root.join("poison.json"))
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(status));
        let paths = String::from_utf8(output.stdout).unwrap();
        let paths: Vec<_> = paths.lines().map(std::path::PathBuf::from).collect();
        assert_eq!(paths.len(), 2);
        assert_ne!(paths[0], root.join("poison"));
        assert_ne!(paths[1], root.join("poison.json"));
        assert!(!paths[0].parent().unwrap().exists(), "test state leaked");
        assert!(!paths[1].exists(), "appearance file leaked");
    }

    let output = Command::new(runner)
        .args(["/bin/sh", "-c", "printf '%s' \"$ELARA_TUI_STATE_DIR\""])
        .env("ELARA_TUI_STATE_DIR", root.join("real-state"))
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        root.join("real-state").to_str().unwrap()
    );
    assert!(!root.join("poison").exists());
    assert!(!root.join("poison.json").exists());
    fs::remove_dir_all(root).unwrap();
}
