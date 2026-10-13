"""Round-trip the shipped composer through a real foreground editor and socket."""
import fcntl
import json
import os
import pathlib
import pty
import select
import shlex
import signal
import socket
import struct
import sys
import tempfile
import termios
import time

binary, server_port, session = sys.argv[1:]
observer = socket.create_connection(("127.0.0.1", int(server_port)), timeout=5)
reader = observer.makefile("rb")
observer.sendall((json.dumps({"version": 2, "command": "attach",
                            "token": os.environ["ELARA_SERVER_TOKEN"],
                            "session_id": session, "mode": "observe", "cursor": 0}) + "\n").encode())
assert json.loads(reader.readline())["type"] == "attached"


def prompts():
    observer.sendall(b'{"version":2,"command":"resnapshot"}\n')
    while True:
        frame = json.loads(reader.readline())
        if frame["type"] == "snapshot":
            return [m["text"] for m in frame["snapshot"]["messages"] if m["role"] == "user"]


with tempfile.TemporaryDirectory(prefix="elara-editor-test-") as root:
    root = pathlib.Path(root)
    script = root / "editor with spaces.py"
    audit = root / "audit.json"
    script.write_text('''import json, os, pathlib, signal, sys, termios
audit, path = map(pathlib.Path, sys.argv[1:])
records = json.loads(audit.read_text()) if audit.exists() else []
flags = termios.tcgetattr(0)[3]
assert flags & termios.ICANON and flags & termios.ECHO, "editor received raw terminal"
assert path.stat().st_mode & 0o777 == 0o600, "draft must be private"
records.append({"text": path.read_text(), "path": str(path)})
audit.write_text(json.dumps(records))
number = len(records)
if number == 2:
    path.write_text("must not replace the draft")
    sys.exit(7)
elif number == 3:
    path.write_text("x" * 65537)
elif number == 4:
    path.write_bytes(b"\\xff")
elif number == 5:
    os.killpg(os.getpgrp(), signal.SIGINT)
else:
    # Real editors commonly save by replacing the original inode.
    replacement = path.with_suffix(".new")
    replacement.write_text(path.read_text() + "\\nfrom editor 界 👩‍💻")
    os.replace(replacement, path)
''')
    pid, master = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.environ["VISUAL"] = (
            f'{shlex.quote(sys.executable)} {shlex.quote(str(script))} {shlex.quote(str(audit))}'
        )
        os.environ["EDITOR"] = "false"
        os.execv(binary, [binary, "--port", server_port, "--", session])

    output = bytearray()

    def drain(seconds=0.15):
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

    def wait_for(predicate, description):
        until = time.monotonic() + 8
        while time.monotonic() < until:
            drain()
            if predicate():
                return
        raise AssertionError(description + repr(bytes(output[-4000:])))

    try:
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 120, 0, 0))
        os.kill(pid, signal.SIGWINCH)
        wait_for(lambda: b"Ctrl-J" in output, "initial frame")
        draft = "first line\nsecond é"
        expected = draft + "\nfrom editor 界 👩‍💻"
        send(b"\x1b[200~" + draft.encode() + b"\x1b[201~")
        for number, notice in enumerate([
            b"Editor saved", b"Editor exited", b"exceeds 64 KiB", b"Cannot read editor draft",
            b"Editor exited"
        ], 1):
            before = len(output)
            send(b"\x07")
            wait_for(lambda: notice in output[before:], "editor return notice")
            records = json.loads(audit.read_text())
            assert len(records) == number
            assert records[-1]["text"] == (draft if number == 1 else expected)
            assert not pathlib.Path(records[-1]["path"]).exists(), "temporary draft cleaned"
            assert prompts() == [], "editor must not send"
            assert b"\x1b[?2004l" in output[before:], "paste disabled for editor"
            assert b"\x1b[?2004h" in output[before:], "paste restored"
        send(b"\r")
        wait_for(lambda: prompts() == [expected], "exact saved draft submitted")
        send(b"/editor\r")
        wait_for(lambda: len(json.loads(audit.read_text())) == 6, "slash editor opens")
        assert json.loads(audit.read_text())[-1]["text"] == ""
        send(b"\r")
        wait_for(lambda: prompts() == [expected, "\nfrom editor 界 👩‍💻"], "slash draft submitted")
        send(b"/detach\r")
        _, status = os.waitpid(pid, 0)
        pid = None
        assert os.waitstatus_to_exitcode(status) == 0
        capture = os.environ.get("ELARA_TUI_EDITOR_CAPTURE")
        if capture:
            pathlib.Path(capture).write_bytes(output)
        print("Editor PTY passed: exact multiline/Unicode round-trip, VISUAL precedence, arguments/spaces, cooked terminal, atomic save, private file cleanup, exit/size/UTF-8 failure retention, slash command, no automatic send")
    finally:
        if pid is not None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(master)
        reader.close()
        observer.close()
