# Rust TUI

The Rust TUI attaches to a local server, shows a session, and can ask from a headless off-screen frame. `mix elara.tui new` starts an embedded server when this run's port is free.

## Sub-features

- `tui-new-headless` creates a session and prints a frame plus a `summary session=` line.
- `tui-list` prints `SESSION`, `STATE`, `HEAD`, and `CWD` for live sessions.
- `tui-attach` reconnects by session ID without changing cwd.
- `tui-observe` attaches read-only; ask/interrupt are rejected.
- `tui-port` honors `--port` and `ELARA_SERVER_PORT`.

## How to get to it (user POV)

- Run `mix elara.tui new`.
- Run `mix elara.tui new --headless`.
- Run `mix elara.tui list`.
- Run `mix elara.tui SESSION_ID`.
- Run `mix elara.tui SESSION_ID --observe`.
- Run `mix elara.server` first when the session must outlive the TUI.

## Driving it with verify-elara

Preconditions:

- `bin/doctor` reports the instance is safe to drive.
- `ELARA_SERVER_PORT` is this run's port and is free.
- Isolated HOME has no tokens. `new` without `--ask` may use a placeholder API key only to pass config resolution.

- **Embedded new.** Run `.cursor/skills/verify-elara/bin/drive tui-headless --feature tui`. Exit code `0`. stdout is a headless frame. stderr contains `summary session=` and `incarnation=`. The frame or summary identifies a session. Do not pass `--ask` on this drive.
- **Port ownership.** After the command exits, the embedded server is gone. `bin/doctor` must still report the port free. A leftover listener that we did not record is a failed cleanup, not a pass.
- **Ask.** Only with a real provider or a server started with a scripted provider. Run `.cursor/skills/verify-elara/bin/drive tui-headless --feature tui --ask "Reply with exactly: tui works"`. Exit code `0`. Frame contains the reply. This is a different entry point from `tui-new-headless`.
- **Proof.** Keep stdout frame, stderr summary, and the standard drive files under `artifacts/tui/<run-id>/`. The summary must include `session=` from this run, not a session on port 4048.

## Gotchas

- Default port is `4048`. Attaching there can steal or confuse the user's daily-driver server. Always pass this run's `--port`.
- Leaving an embedded `new` TUI ends that server and its live sessions. Reattach needs `mix elara.server` started by this run.
- Frames smaller than 40×8 are rejected. The helper uses 100×24.
- `--headless --ask` waits until the turn settles. A placeholder API key will hang or fail if you pass `--ask`.
- `list` does not accept `--ask` or `--observe`.
- Provider env must be on the server process. Setting `ELARA_PROVIDER` only on the TUI does not reconfigure an existing server.
