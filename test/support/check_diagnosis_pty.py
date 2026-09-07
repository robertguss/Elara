"""Inspect a real diagnosis through the shipped Rust terminal client."""
import fcntl
import json
import os
import pty
import re
import select
import signal
import socket
import struct
import sys
import tempfile
import termios
import time
from pathlib import Path

binary, port, session, expected_path = sys.argv[1:]
expected = Path(expected_path).read_text()
observer = socket.create_connection(("127.0.0.1", int(port)), timeout=5)
reader = observer.makefile("rb")
observer.sendall((json.dumps({"version": 2, "command": "attach", "session_id": session,
                              "mode": "observe"}) + "\n").encode())
assert json.loads(reader.readline())["type"] == "attached"


def prompts():
    observer.sendall(b'{"version":2,"command":"resnapshot"}\n')
    while True:
        frame = json.loads(reader.readline())
        if frame["type"] == "snapshot":
            return [m["text"] for m in frame["snapshot"]["messages"] if m["role"] == "user"]

with tempfile.TemporaryDirectory(prefix="elara-diagnosis-pty-") as tmp:
    clipboard = Path(tmp) / "clipboard.txt"
    # Exercise the shipped clipboard command without altering the user's clipboard.
    for name in ["pbcopy", "wl-copy", "xclip", "xsel"]:
        command = Path(tmp) / name
        command.write_text("#!/usr/bin/env python3\nimport os,sys\n"
                           "with open(os.environ['TEST_CLIPBOARD_PATH'], 'wb') as f:\n"
                           "    f.write(sys.stdin.buffer.read())\n")
        command.chmod(0o755)

    pid, master = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.environ["PATH"] = tmp + os.pathsep + os.environ["PATH"]
        os.environ["TEST_CLIPBOARD_PATH"] = str(clipboard)
        os.execv(binary, [binary, "--port", port, "--", session])

    output = bytearray()

    def drain(seconds=0.15):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            if select.select([master], [], [], max(0, until - time.monotonic()))[0]:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    return
                output.extend(data)
                if b"\x1b[c" in data:
                    os.write(master, b"\x1b[?1;2c")
                if b"\x1b[6n" in data:
                    os.write(master, b"\x1b[1;1R")

    def send(data):
        os.write(master, data)
        drain()

    def wait_for(predicate, label):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            drain(0.1)
            if predicate():
                return
        raise AssertionError(f"Missing {label}: {bytes(output[-5000:])!r}")

    def plain():
        return re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", bytes(output))

    try:
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        os.kill(pid, signal.SIGWINCH)
        wait_for(lambda: b"Ctrl-J" in output, "initial frame")
        send(b"draft remains")
        send(b"\t/\x1b[200~diagnose_check\x1b[201~")
        wait_for(lambda: b"/diagnose_check" in plain(), "find diagnosis")
        send(b"\x1b")
        send(b"f")
        wait_for(lambda: b"Tool viewer" in output, "tool viewer")
        output.clear()
        send(b"/\x1b[200~direct/v1\x1b[201~")
        wait_for(lambda: b"1/1 matches" in plain(), "search retained strategy")
        output.clear()
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 42, 140, 0, 0))
        os.kill(pid, signal.SIGWINCH)
        # The strategy must be visible in the body as well as the search footer.
        wait_for(lambda: plain().count(b"direct/v1") >= 2, "redraw result body")
        send(b"\x1b")
        send(b"y")
        wait_for(lambda: clipboard.exists() and expected in clipboard.read_text(),
                 "copy complete diagnosis with canonical citations")
        send(b"\x1b")
        send(b"\t\r")
        wait_for(lambda: prompts()[-1] == "draft remains", "retained composer draft submitted")
        send(b"\x03")
        wait_for(lambda: b"\x1b[?1006l" in output, "mouse reporting disabled")
        _, status = os.waitpid(pid, 0)
        pid = None
        assert os.waitstatus_to_exitcode(status) == 0
        print("Diagnosis PTY passed: inspect strategy, redraw, copy citations, retain draft, detach")
    finally:
        if pid is not None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(master)
        reader.close()
        observer.close()
