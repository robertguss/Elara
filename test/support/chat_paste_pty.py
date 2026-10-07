"""Exercise real chat startup and terminal IO with a scripted provider, no network."""
import os
import pty
import select
import signal
import sys
import tempfile
import termios
import time

code = r'''
alias Elara.Message
{:ok, first} = Message.assistant("FIRST_PASTE_COMPLETED", [])
{:ok, second} = Message.assistant("SECOND_PASTE_COMPLETED", [])
{:ok, agent} = Agent.start_link(fn -> [{:ok, first}, {:ok, second}] end)
cwd = hd(System.argv())
tty = List.last(System.argv())
{before, 0} = System.cmd("sh", ["-c", "stty -g <\"$1\"", "test-chat", tty])
try do
  Elara.Chat.main([], cwd: cwd, provider: {Elara.Provider.Scripted, agent})
catch
  :exit, {:shutdown, 0} -> :ok
end
unless System.cmd("sh", ["-c", "stty -g <\"$1\"", "test-chat", tty]) == {before, 0},
  do: raise("terminal flags not restored")
[session] = Enum.filter(Elara.live_sessions(), &(&1.cwd == cwd))
users = for %Message.User{text: text} <- Elara.transcript(session.id), do: text
unless users == ["first λ\n\n/quit\nlast line", "/quit"], do: raise(inspect(users))
unless Agent.get(agent, & &1) == [], do: raise("scripted replies not consumed")
IO.puts("CHAT_ASSERTIONS_PASSED")
'''

with tempfile.TemporaryDirectory(prefix="elara-chat-paste-") as cwd:
    pid, master = pty.fork()
    if pid == 0:
        if sys.argv[1] == "noechoctl":
            flags = termios.tcgetattr(0)
            flags[3] &= ~termios.ECHOCTL
            termios.tcsetattr(0, termios.TCSANOW, flags)
        os.environ["MIX_ENV"] = "test"
        os.environ["TERM"] = "xterm-256color"
        os.execvp("mix", ["mix", "run", "-e", code, "--", cwd, os.ttyname(0)])

    output = bytearray()

    def drain(seconds=0.1):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            if select.select([master], [], [], max(0, until - time.monotonic()))[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)

    def wait_for(text):
        until = time.monotonic() + 20
        while time.monotonic() < until:
            drain()
            if text in output:
                return
        raise AssertionError(f"missing {text!r}: {bytes(output[-3000:])!r}")

    try:
        wait_for(b"\x1b[?2004h")
        wait_for(b"/help  /interrupt")
        os.write(master, "\x1b[200~first λ\n\n/quit\nlast line\n\x1b[201~".encode())
        drain(0.25)
        assert b"FIRST_PASTE_COMPLETED" not in output, "paste submitted without Enter"
        os.write(master, b"\r")
        wait_for(b"FIRST_PASTE_COMPLETED")
        os.write(master, b"\x1b[200~/quit\x1b[201~")
        drain(0.25)
        assert b"SECOND_PASTE_COMPLETED" not in output
        os.write(master, b"\r")
        wait_for(b"SECOND_PASTE_COMPLETED")
        os.write(master, b"/quit\r")
        wait_for(b"CHAT_ASSERTIONS_PASSED")
        assert b"\x1b[?2004l" in output, "bracketed paste mode not restored"
        assert b"^[[200~" not in output, "paste markers visibly echoed"
        assert b"in a turn." not in output, "paste split into busy refusals"
        _, status = os.waitpid(pid, 0)
        pid = None
        assert os.waitstatus_to_exitcode(status) == 0
        print("Chat PTY passed: atomic multiline paste, literal slash text, separate quit, mode restoration")
    finally:
        if pid is not None:
            os.killpg(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(master)
