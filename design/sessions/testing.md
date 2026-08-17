# Session plan checks

Back: [overview.md](overview.md)

Every slice runs `mix test` and `mix format --check-formatted`.

Use `Harness.Provider.Scripted` for process tests. Use `control-cli` (tmux or a PTY) for the slice's runtime check. Wait for a screen pattern, not a sleep, when the CLI is the surface.

Auth write in `lib/harness/auth.ex` is the model for durable files. Temp path, rename, mode 600.

Do not hit a live provider in tests. A live `mix harness.chat --continue` after login is allowed for the slice 1 runtime check if a scripted Mix path is missing. Prefer a scripted `Harness.Chat.run/3` plus a real file under a temp `HOME` if you can set that without changing production defaults.
