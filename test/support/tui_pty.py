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

binary, server_port, session, *detach = sys.argv[1:]
assert detach in ([], ["ctrl-c"])
observer = socket.create_connection(("127.0.0.1", int(server_port)), timeout=5)
reader = observer.makefile("rb")
observer.sendall((json.dumps({"version": 2, "command": "attach", "token": os.environ["ELARA_SERVER_TOKEN"], "session_id": session,
                              "mode": "observe", "cursor": 0,
                              "extensions": ["input_queue_v1"]}) + "\n").encode())
attached = json.loads(reader.readline())
assert attached["type"] == "attached"


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
started = time.monotonic()


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
            if directory := os.environ.get("ELARA_TUI_PTY_CAPTURE"):
                os.makedirs(directory, exist_ok=True)
                with open(os.path.join(directory, "frames.jsonl"), "a") as frames:
                    frames.write(json.dumps({"t": time.monotonic() - started, "bytes": chunk.hex()}) + "\n")
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


def capture(name):
    directory = os.environ.get("ELARA_TUI_PTY_CAPTURE")
    if directory:
        os.makedirs(directory, exist_ok=True)
        if name in ("help", "quit-confirmation", "quit-cancelled"):
            drain(1.2)  # Hold review states long enough to inspect the recording.
        with open(os.path.join(directory, name + ".ansi"), "wb") as file:
            file.write(output)
        with open(os.path.join(directory, name + ".json"), "w") as file:
            json.dump(snapshot(), file)


try:
    resize(80, 24)
    wait_for(lambda: b"Ctrl-J" in output, "initial interactive frame")
    assert b"\x1b[?2004h" in output, "bracketed paste enabled"
    capture("idle")
    send(b"\x1b")
    assert os.waitpid(pid, os.WNOHANG)[0] == 0, "idle Esc never exits"
    send(b"discard this draft\x03")
    assert os.waitpid(pid, os.WNOHANG)[0] == 0, "first Ctrl-C never exits"
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
    # Closing turns leaves the draft and running turn intact.
    send(b"\x12\x1b")
    assert snapshot()["turn"]["state"] != "idle", "panel Esc does not interrupt"
    send(b"\r\x1b")
    wait_for(lambda: snapshot()["turn"]["state"] == "idle", "interrupt reaches idle")
    assert prompts() == [expected], "paused queue has not been consumed"
    inbox = snapshot()["inbox"]
    assert inbox["paused"]
    assert inbox["entries"][-1]["text"] == "draft while streaminX"
    assert inbox["entries"][-1]["state"] == "queued"
    capture("interrupted")
    send(b"\x1b[1;3A\x1b[1;3B")  # history older/newest restores draft
    send(b"/resume-inputs\r")
    wait_for(lambda: prompts() == [expected, "draft while streaminX"], "selected draft survives resize/history/interrupt")
    send(b"\x1b")
    wait_for(lambda: snapshot()["turn"]["state"] == "idle", "second interrupt")
    send(b"\x16")  # Ctrl-V enters explicit safe paste
    send(b"safe\nsecond\rthird\r\nfourth\x1b\x03")
    assert len(prompts()) == 2, "safe paste controls never submit, interrupt or detach"
    send(b"\x16\r")
    wait_for(lambda: prompts()[-1] == "safe\nsecond\nthird\nfourth", "safe paste exact text")
    send(b"\x1b")
    send(b"/help\r")  # ? opens help
    assert b"Composer" in output
    resize(81, 24)
    resize(80, 24)
    capture("help")
    send(b"\x1b")  # close help
    send(b"\x03\x03")  # Request quit through either launcher or native client.
    if attached["lifetime"] == "embedded":
        wait_for(lambda: b"Quit Elara?" in output, "embedded quit asks for confirmation")
        assert os.waitpid(pid, os.WNOHANG)[0] == 0
        capture("quit-confirmation")
        send(b"\x1b")
        assert os.waitpid(pid, os.WNOHANG)[0] == 0, "Esc cancels quit"
        assert snapshot()["turn"]["state"] == "idle"
        capture("quit-cancelled")
        send(b"\x03\x03\r")
    wait_for(lambda: b"\x1b[?2004l" in output, "bracketed paste disabled on exit")
    _, status = os.waitpid(pid, 0)
    pid = None
    assert os.waitstatus_to_exitcode(status) == 0
    print("PTY passed: Esc interrupt/panel/idle, Ctrl-C clear/twice quit, embedded confirmation, exact Unicode multiline text, selection, history, streaming, durable queue/stop/resume, safe paste, 80x24/120x40/180x45, cleanup")
finally:
    if pid is not None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(master)
    reader.close()
    observer.close()
