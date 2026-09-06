"""Exercise explicit plugin activation through the shipped Rust client."""
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import sys
import termios
import time

binary, port, session, project, source = sys.argv[1:]
plugin = Path(project) / ".elara/plugins/elixir_project.exs"
pid, master = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.environ["ELARA_TUI_STATE_DIR"] = str(Path(project) / "client")
    os.execv(binary, [binary, "--port", port, "--", session])

output = bytearray()


def wait_for(text):
    parts = text if isinstance(text, tuple) else (text,)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            output.extend(chunk)
            if b"\x1b[c" in chunk:
                os.write(master, b"\x1b[?1;2c")
            if b"\x1b[6n" in chunk:
                os.write(master, b"\x1b[1;1R")
        # Ratatui can position each word separately instead of writing spaces.
        if all(part in output for part in parts):
            output.clear()
            return
    raise AssertionError(f"Missing {text!r}: {bytes(output[-5000:])!r}")


try:
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    os.kill(pid, signal.SIGWINCH)
    wait_for(b"Ctrl-J")
    plugin.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, plugin)
    os.write(master, b"/plugins reload\r")
    wait_for((b"Plugins", b"reloaded:", b"elixir_project", b"v2"))
    plugin.write_text("defmodule Broken do")
    os.write(master, b"/plugins reload\r")
    # The old notice can leave unchanged characters between newly drawn spans.
    # Socket coverage asserts the complete error; here check its visible prefix.
    wait_for(b"{:plugin")
    os.write(master, b"\x1b")
    wait_for(b"\x1b[?2004l")
    _, status = os.waitpid(pid, 0)
    pid = None
    assert os.waitstatus_to_exitcode(status) == 0
    print("PTY passed: plugin discovery, reload feedback, failure feedback, clean detach")
finally:
    if pid is not None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(master)
