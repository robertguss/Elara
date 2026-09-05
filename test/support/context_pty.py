"""Actual TUI automatically attaches a successor; unsent Unicode draft survives."""
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time
from pathlib import Path

binary, port, source, root = sys.argv[1:]
pid, master = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(binary, [binary, "--port", port, "--", source])
output = bytearray()


def drain(seconds=0.2):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if select.select([master], [], [], max(0, until-time.monotonic()))[0]:
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            output.extend(data)
            if b"\x1b[c" in data:
                os.write(master, b"\x1b[?1;2c")
            if b"\x1b[6n" in data:
                os.write(master, b"\x1b[1;1R")


def wait(text):
    until = time.monotonic() + 15
    while time.monotonic() < until:
        drain()
        if text.encode() in output:
            return
    raise AssertionError(text + repr(bytes(output[-6000:])))


def send(data):
    os.write(master, data)
    drain()


try:
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    os.kill(pid, signal.SIGWINCH)
    wait("Ctrl-J")
    send(b"continue useful work\r")
    wait("working")
    send(b"\x1b[200~" + "Unsent draft α survives".encode() + b"\x1b[201~")
    Path(root, "draft-ready").touch()
    # Only the successor's attached stream contains this answer. A transient
    # notice may be superseded by its completion before the next terminal draw.
    wait("HANDOFF_CONTINUED")
    # The ExUnit driver asserts the exact next provider input. Cursor-addressed
    # terminal diffs need not contain the entire draft as one contiguous string.
    send(b"\r")
    wait("DRAFT_DELIVERED")
    send(b"\x03")
    _, status = os.waitpid(pid, 0)
    pid = None
    assert os.waitstatus_to_exitcode(status) == 0
    print("CTX PTY explicit successor attach and retained draft passed")
finally:
    if pid is not None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(master)
