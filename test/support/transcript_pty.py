"""Transcript product-path checks with an isolated clipboard command sink."""
import fcntl
import json
import os
import pty
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


with tempfile.TemporaryDirectory(prefix="elara-transcript-pty-") as tmp:
    clipboard = Path(tmp) / "clipboard.txt"
    # Exercise real child-process clipboard delivery without replacing the user's clipboard.
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
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                output.extend(chunk)
                if b"\x1b[c" in chunk:
                    os.write(master, b"\x1b[?1;2c")
                if b"\x1b[6n" in chunk:
                    os.write(master, b"\x1b[1;1R")

    def send(data):
        os.write(master, data)
        drain()

    def wait_for(predicate, label):
        until = time.monotonic() + 8
        while time.monotonic() < until:
            drain(.1)
            if predicate():
                return
        raise AssertionError(label + "\n" + repr(bytes(output[-3000:])))

    def copied():
        return clipboard.read_text() if clipboard.exists() else None

    try:
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        os.kill(pid, signal.SIGWINCH)
        wait_for(lambda: b"Ctrl-J" in output, "initial frame")
        send(b"preserved local draft")
        send(b"\t\x1b[Hy")  # transcript focus, top, whole entry copy
        wait_for(lambda: copied() == expected, "top entry copies exact unwrapped Unicode text")
        assert b"\x1b[?1006h" in output, "SGR mouse reporting enabled"
        assert prompts() == [expected, "last user"], "navigation never submits"
        clipboard.unlink()
        send(b"/\x1b[200~final\x1b[201~\r")  # pasted query selects a different entry
        send(b"\x1b")  # standalone Escape closes search, not an Alt-y chord
        send(b"y")  # copy matched entry
        wait_for(lambda: copied() == "final reply", "search moves from the first entry to the matching entry")
        send(b"\x1b[F")  # return to live tail
        send(b"\t\r")  # prompt focus; submit the preserved draft
        wait_for(lambda: prompts()[-1] == "preserved local draft", "focus/search preserve composer")
        send(b"\x03")
        wait_for(lambda: b"\x1b[?1006l" in output, "mouse reporting disabled on exit")
        _, status = os.waitpid(pid, 0)
        pid = None
        assert os.waitstatus_to_exitcode(status) == 0
        print("Transcript PTY passed: navigation, search, exact clipboard, focus/draft, mouse cleanup")
    finally:
        if pid is not None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(master)
        reader.close()
        observer.close()
