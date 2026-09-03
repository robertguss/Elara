# Persistent chat

Persistent chat is the line client. It prints a banner, an idle `> ` prompt, accepts prompts and slash commands, and keeps the session until `/quit`.

## Sub-features

- `chat-banner` shows `elara  ·  /help  /interrupt  /reload  /resume  /quit`.
- `chat-help` lists commands from `/help`, `/h`, or `/?`.
- `chat-turn` submits a prompt and returns to `> ` after the answer.
- `chat-quit` exits 0 on `/quit`, `/exit`, `/q`, or Ctrl-D while idle.
- `chat-busy` refuses a second prompt during a turn with `busy. wait for the turn or /interrupt.`
- `chat-slash-literal` sends text that starts with `/` when the line is prefixed `//`.

## How to get to it (user POV)

- Run `mix elara.chat`.
- Run `mix elara.chat "what starts this application?"`.
- Run `mix elara.chat --name "runtime investigation"`.
- Type `/help` at the `> ` prompt.

## Driving it with verify-elara

Preconditions:

- `bin/doctor` reports the instance is safe to drive.
- Isolated HOME has no auth files.

- **Help while idle.** Run `.cursor/skills/verify-elara/bin/drive scripted-chat --feature chat --lines '/help,/quit'`. Exit code `0`. `transcript.txt` contains the banner `elara  ·  /help`, the help line `/help       this list`, `/quit       exit`, and returns to `> ` after help.
- **Scripted turn.** Run `.cursor/skills/verify-elara/bin/drive scripted-chat --feature chat --lines 'hello,/quit' --reply 'hello from elara'`. Exit code `0`. Transcript contains `  you` / `  hello` and `hello from elara`, then returns to `> ` before quit.
- **Mix chat.** `bin/drive mix-chat` refuses without a TTY. A credentialed Mix chat is a separate entry point; drive it only in a real terminal with exported credentials, from `$WORKTREE`. Do not mark Mix chat verified from scripted-chat.
- **Proof.** Keep `transcript.txt` plus the standard drive files under `artifacts/chat/<run-id>/`. The transcript must show both the action (`/help` or `hello`) and the resulting help text or reply, not only the final `> `.

## Gotchas

- `mix elara.chat` resolves credentials before it prints the banner. Isolated HOME fails Mix chat at the login gate. Scripted-chat is the credential-free drive of the same `Elara.Chat.run/3` surface.
- Commands that change session state are refused during a turn. Interrupt first.
- Prefix `//` to send a prompt that begins with `/`.
- During a turn, the first quit interrupts; a second quit exits. Idle quit exits immediately.
- Do not send Mix chat lines through `bin/drive mix-chat` without a TTY. Use scripted-chat.
