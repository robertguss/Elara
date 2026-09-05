"""Typed tool inspection through a real session, PTY, and clipboard subprocess."""
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


with tempfile.TemporaryDirectory(prefix="elara-tool-inspection-pty-") as tmp:
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
        send(b"draft survives inspection")
        send(b"\t\x1b[H")
        # The first user occupies row 2; the read block begins on row 3.
        send(b"\x1b[<0;6;3M\x1b[<0;6;3m")
        send(b" ")  # expand the selected call
        send(b"f")  # fullscreen retained details
        wait_for(lambda: b"Tool viewer" in output, "fullscreen tool viewer opens")
        send(b"/\x1b[200~HIDDEN_MARKER\x1b[201~")
        wait_for(lambda: b"1/1 matches" in output, "viewer searches retained output")
        # Inspect only the new resize frame, and include result text beyond the
        # query in the footer. Clipboard state cannot prove the body was drawn.
        # Finish at a different size from the original transcript viewport so
        # closing the viewer also exercises restoration after a size change.
        for cols, rows in [(120, 40), (180, 45), (80, 24), (120, 40)]:
            drain()
            resize_start = len(output)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
            os.kill(pid, signal.SIGWINCH)
            wait_for(lambda: b"HIDDEN_MARKER row 55: retained Unicode" in
                     re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", bytes(output[resize_start:])),
                     f"viewer redraws the searched result body at {cols}x{rows}")
        send(b"\x1b")
        send(b"y")
        wait_for(lambda: copied() is not None and expected in copied(),
                 "viewer copies all retained output without injected wrap newlines")
        assert "inspection.txt" in copied(), "viewer retains canonical arguments"
        send(b"\x1b")  # restore transcript and its viewport
        clipboard.unlink()
        send(b"\x1b[<0;2;3M\x1b[<0;2;3m")  # gutter click collapses the same block
        send(b"y")
        wait_for(lambda: copied() is not None and "Display folded" in copied(),
                 "restored transcript retains its expanded state and click collapses it")
        assert "HIDDEN_MARKER" not in copied(), "compact copy remains visibly folded"
        viewer_start = len(output)
        send(b"\x1b[<2;6;3M\x1b[<2;6;3m")  # right-click opens fullscreen
        wait_for(lambda: b"Tool viewer" in output[viewer_start:], "mouse opens tool viewer")
        clipboard.unlink()
        send(b"y")
        wait_for(lambda: copied() is not None and expected in copied(), "mouse viewer retains full copy")
        send(b"\x1b[<2;6;3M\x1b[<2;6;3m")  # right-click closes fullscreen
        send(b"\t\r")
        wait_for(lambda: prompts()[-1] == "draft survives inspection",
                 "tool inspection preserves composer and returns prompt focus")
        send(b"\x03")
        wait_for(lambda: b"\x1b[?1006l" in output, "mouse reporting disabled on exit")
        _, status = os.waitpid(pid, 0)
        pid = None
        assert os.waitstatus_to_exitcode(status) == 0
        print("Tool inspection PTY passed: expand, fullscreen, search, retained copy, draft")
    finally:
        if pid is not None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(master)
        reader.close()
        observer.close()
