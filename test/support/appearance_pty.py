"""Exercise appearance in a real session without using personal preferences."""
import fcntl
import json
import os
import pty
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

binary, port, session = sys.argv[1:]
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


with tempfile.TemporaryDirectory(prefix="elara-appearance-pty-") as tmp:
    preferences = Path(tmp) / "appearance.json"
    env = dict(os.environ, TERM="xterm-256color", ELARA_TUI_APPEARANCE_FILE=str(preferences))
    pid, master = pty.fork()
    if pid == 0:
        os.execve(binary, [binary, session, "--port", port, "--appearance", "--preview-reasoning"], env)
    output = bytearray()

    def drain(seconds=.15):
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
        raise AssertionError(label + "\n" + repr(bytes(output[-3500:])))

    def fresh(start):
        return re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", bytes(output[start:]))

    def resize(cols, rows):
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.kill(pid, signal.SIGWINCH)
        drain()

    try:
        resize(120, 40)
        wait_for(lambda: b"APPEARANCE" in output, "pre-session appearance picker")
        send(b"\x1b[C" * 2 + b"\x1b[B" * 3 + b"s")
        wait_for(lambda: preferences.exists(), "explicitly saved preferences")
        assert json.loads(preferences.read_text()) == {"layout": "workbench", "theme": "forest"}
        wait_for(lambda: b"Ctrl-J" in output, "attached session")
        send("left é 👩‍💻 right".encode())
        send(b"\x1b[1;2D" * 5)  # Keep a selected word through every presentation change.
        send(b"\t\x1b[H/\x1b[200~HIST_MARKER\x1b[201~\r\x1b")
        send(b"\x1b[14~")  # F4: hide thinking, sticky across layout and theme changes.
        layouts = ["workbench", "ember", "observatory"]
        themes = ["forest", "ember", "observatory", "workbench"]
        for layout_index, layout in enumerate(layouts):
            for theme_index, theme in enumerate(themes):
                start = len(output)
                send(b"\x1bOR")  # F3
                if layout_index and theme_index == 0:
                    send(b"\x1b[C")
                if theme_index or layout_index:
                    send(b"\x1b[B")
                send(b"\r")
                resize(181 - (layout_index * 4 + theme_index) % 2, 45)
                wait_for(lambda: f"{layout} / {theme}".encode() in fresh(start),
                         f"fresh {layout}/{theme} frame")
                assert b"HIST_MARKER earlier prompt" in fresh(start), "historical body survives reflow"
                assert b"1/1 matches" in fresh(start), "search survives appearance changes"
                start = len(output)
                send(b"\x1b[15~")
                wait_for(lambda: b"Hidden by you" in fresh(start), "visibility survives appearance changes")
                send(b"\x1b")
                assert json.loads(preferences.read_text()) == {"layout": "workbench", "theme": "forest"}, "apply does not save"
        resize(80, 24)
        start = len(output)
        send(b"\x1b[15~")  # F5
        wait_for(lambda: b"Hidden by you" in fresh(start), "narrow thinking overlay respects hidden state")
        send(b"\x1b")
        send(b"\x1b[14~")
        start = len(output)
        send(b"\x1b[15~")
        wait_for(lambda: b"PREVIEW fixture" in fresh(start), "explicit fixture label")
        assert b"historical" in fresh(start), "thinking remains bound to inspected historical turn"
        send(b"\x1b")

        def inspect_turn(source):
            start = len(output)
            send(b"\x1b[15~")
            resize(81, 24)
            resize(80, 24)
            wait_for(lambda: source.encode() in fresh(start), source)
            assert b"PREVIEW fixture" in fresh(start), "turn source is an explicit preview"
            send(b"\x1b")

        start = len(output)
        send(b"\x1b[17~")  # F6 starts from the first historical search match.
        resize(81, 24)
        resize(80, 24)
        wait_for(lambda: b"Up/Down select" in fresh(start), "turn navigator opens")
        assert b"01 HIST_MARKER earlier prompt" in fresh(start)
        assert b"02 SECOND_TURN later prompt" in fresh(start)
        send(b"\x1b[B\x1b")
        inspect_turn("turn 2 · historical")
        send(b"\x1b[17~\x1b[A\x1b")
        inspect_turn("turn 1 · historical")
        send(b"\x1b[17~\x1b[F\x1b")
        inspect_turn("turn 2 · live follow · complete")
        send(b"\tkept\r")
        wait_for(lambda: prompts()[-1] == "left é 👩‍💻 kept", "switches preserve Unicode draft selection")
        send(b"\x03")
        wait_for(lambda: b"\x1b[?1006l" in output, "clean terminal exit")
        _, status = os.waitpid(pid, 0)
        pid = None
        assert os.waitstatus_to_exitcode(status) == 0
        resumed = subprocess.run([binary, session, "--port", port, "--headless"], env=env,
                                 capture_output=True, timeout=10, check=True)
        assert b"workbench / forest" in resumed.stdout, "next launch loads saved defaults"
        assert b"PREVIEW fixture" not in resumed.stdout, "preview is never persisted as live reasoning"
        saved = preferences.read_bytes()
        for overrides, expected in [
            (["--layout", "observatory"], b"observatory / forest"),
            (["--theme", "ember"], b"workbench / ember"),
            (["--layout", "ember", "--theme", "workbench"], b"ember / workbench"),
        ]:
            result = subprocess.run([binary, session, "--port", port, "--headless", *overrides],
                                    env=env, capture_output=True, timeout=10, check=True)
            assert expected in result.stdout, "CLI overrides take precedence over saved defaults"
            assert preferences.read_bytes() == saved, "CLI overrides do not rewrite defaults"
        with socket.socket() as unattached:
            unattached.bind(("127.0.0.1", 0))
            unattached.listen()
            unattached.settimeout(.2)
            result = subprocess.run([binary, session, "--port", str(unattached.getsockname()[1]),
                                     "--appearance", "--headless"],
                                    env=env, capture_output=True, timeout=10)
            assert result.returncode == 1
            assert b"--appearance requires an interactive terminal" in result.stderr
            try:
                connection, _ = unattached.accept()
            except socket.timeout:
                pass
            else:
                connection.close()
                raise AssertionError("invalid CLI combination attached before rejection")
        malformed = Path(tmp) / "malformed.json"
        malformed.write_text("{broken")
        result = subprocess.run([binary, session, "--port", port, "--headless"],
                                env=dict(env, ELARA_TUI_APPEARANCE_FILE=str(malformed)),
                                capture_output=True, timeout=10, check=True)
        assert b"Invalid appearance preferences" in result.stderr
        assert b"using appearance defaults" in result.stderr
        assert b"ember / ember" in result.stdout
        assert malformed.read_text() == "{broken", "loading does not repair or rewrite preferences"
        assert preferences.read_bytes() == saved
        os.close(master)
        pid, master = pty.fork()
        if pid == 0:
            os.execve(binary, [binary, session, "--port", port, "--appearance"], env)
        output = bytearray()
        resize(120, 40)
        wait_for(lambda: b"APPEARANCE" in output, "save failure picker opens")
        # A directory at the atomic temporary-file path forces failure even as root.
        blocked_write = preferences.with_suffix(f".{pid}.tmp")
        blocked_write.mkdir()
        send(b"\x1b[C\x1b[B")
        start = len(output)
        send(b"s")
        wait_for(lambda: b"directory" in fresh(start).lower(), "save failure remains visible")
        assert b"Ctrl-J" not in output, "failed save stays in the pre-session picker"
        assert preferences.read_bytes() == saved, "failed save preserves original defaults"
        start = len(output)
        send(b"\r")
        wait_for(lambda: b"ember / ember" in fresh(start), "Enter applies unsaved local choice")
        assert b"Ctrl-J" in fresh(start), "Enter proceeds to the session after save failure"
        assert preferences.read_bytes() == saved, "local choice does not overwrite defaults"
        send(b"\x03")
        wait_for(lambda: b"\x1b[?1006l" in output, "save-failure session exits cleanly")
        _, status = os.waitpid(pid, 0)
        pid = None
        assert os.waitstatus_to_exitcode(status) == 0
        print("Appearance PTY passed: 12 combinations, sticky visibility, historical source, Unicode selection, defaults")
    finally:
        if pid is not None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(master)
        reader.close()
        observer.close()
