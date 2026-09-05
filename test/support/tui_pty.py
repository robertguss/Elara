"""Drive the shipped interactive client through a PTY against a real Elara server.

No emulator or provider credentials: this checks byte decoding and the product
socket path, not Ghostty/WezTerm clipboard or native keyboard mappings.
"""
import fcntl
import json
import os
import pty
import select
import signal
import socket
import struct
import sys
import termios
import time

binary, server_port, session = sys.argv[1:]
observer = socket.create_connection(("127.0.0.1", int(server_port)), timeout=5)
reader = observer.makefile("rb")
observer.sendall((json.dumps({"version": 2, "command": "attach", "session_id": session,
                              "mode": "observe", "cursor": 0,
                              "extensions": ["input_queue_v1"]}) + "\n").encode())
assert json.loads(reader.readline())["type"] == "attached"


def snapshot():
    observer.sendall(b'{"version":2,"command":"resnapshot"}\n')
    while True:
        frame = json.loads(reader.readline())
        if frame["type"] == "snapshot":
            return frame["snapshot"]


def prompts():
    return [m["text"] for m in snapshot()["messages"] if m["role"] == "user"]


pid, master = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(binary, [binary, "--port", server_port, "--", session])

output = bytearray()


def drain(seconds=0.2):
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
            # Minimal legacy terminal query replies; no enhanced-key support claim.
            if b"\x1b[c" in chunk:
                os.write(master, b"\x1b[?1;2c")
            if b"\x1b[6n" in chunk:
                os.write(master, b"\x1b[1;1R")


def send(data):
    os.write(master, data)
    drain()


def wait_for(predicate, description):
    until = time.monotonic() + 8
    while time.monotonic() < until:
        drain(0.1)
        if predicate():
            return
    raise AssertionError(description + "\nterminal output: " + repr(bytes(output[-5000:])))


def resize(columns, rows):
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
    os.kill(pid, signal.SIGWINCH)
    drain()


try:
    resize(80, 24)
    wait_for(lambda: b"Ctrl-J" in output, "initial interactive frame")
    assert b"\x1b[?2004h" in output, "bracketed paste enabled"
    paste = "first\r\ncombining e\u0301 👩‍💻\t\x1b[31m".encode()
    send(b"\x1b[200~" + paste + b"\x1b[201~")
    assert prompts() == [], "paste must not submit"
    send(b"\x1b[D\x7fZ")  # end ...[31m -> ...[3Zm
    send(b"\x1b[F\nlast")  # End, Ctrl-J fallback, final line
    assert prompts() == [], "newline must not submit"
    expected = "first\ncombining e\u0301 👩‍💻\t[3Zm\nlast"
    send(b"\r")
    wait_for(lambda: prompts() == [expected], "exact edited multiline prompt accepted")
    send(b"draft while streaming")
    send(b"\x1b[1;2D")  # select last grapheme
    resize(120, 40)
    resize(180, 45)
    resize(80, 24)
    send(b"X")
    # Busy Enter durably queues the edited draft; stop preserves and pauses it.
    send(b"\r\x18")
    wait_for(lambda: snapshot()["turn"]["state"] == "idle", "interrupt reaches idle")
    assert prompts() == [expected], "paused queue has not been consumed"
    inbox = snapshot()["inbox"]
    assert inbox["paused"]
    assert inbox["entries"][-1]["text"] == "draft while streaminX"
    assert inbox["entries"][-1]["state"] == "queued"
    send(b"\x1b[1;3A\x1b[1;3B")  # history older/newest restores draft
    send(b"/resume-inputs\r")
    wait_for(lambda: prompts() == [expected, "draft while streaminX"], "selected draft survives resize/history/interrupt")
    send(b"\x18")
    wait_for(lambda: snapshot()["turn"]["state"] == "idle", "second interrupt")
    send(b"\x1bOQ")  # F2 enters explicit safe paste
    send(b"safe\nsecond\rthird\r\nfourth\x18\x03")
    assert len(prompts()) == 2, "safe paste controls never submit, interrupt or detach"
    send(b"\x1bOQ\r")
    wait_for(lambda: prompts()[-1] == "safe\nsecond\nthird\nfourth", "safe paste exact text")
    send(b"\x18")
    send(b"\x1bOP")  # F1 opens help
    assert b"Composer" in output
    send(b"\x1b")  # close help
    send(b"\x1b")  # detach
    wait_for(lambda: b"\x1b[?2004l" in output, "bracketed paste disabled on exit")
    _, status = os.waitpid(pid, 0)
    pid = None
    assert os.waitstatus_to_exitcode(status) == 0
    print("PTY passed: exact Unicode multiline text, selection, history, streaming, durable queue/stop/resume, safe paste, 80x24/120x40/180x45, cleanup")
finally:
    if pid is not None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(master)
    reader.close()
    observer.close()
