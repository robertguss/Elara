"""Observe actual terminal notification bytes for real scripted turns."""
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
import termios
import time

binary, server_port, session = sys.argv[1:]
notice = b"\x07\x1b]777;notify;Elara;"
captures = bytearray()


def client(turns):
    gate = pathlib.Path(os.environ["ELARA_TUI_STATE_DIR"]) / "editor-gate.py"
    gate.parent.mkdir(parents=True, exist_ok=True)
    ready, release = gate.with_suffix(".ready"), gate.with_suffix(".release")
    gate.write_text('''import pathlib, time
gate = pathlib.Path(__file__)
gate.with_suffix(".ready").touch()
while not gate.with_suffix(".release").exists():
    time.sleep(0.01)
''')
    pid, master = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.environ["VISUAL"] = f'{shlex.quote(sys.executable)} {shlex.quote(str(gate))}'
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
                if b"\x1b[c" in chunk:
                    os.write(master, b"\x1b[?1;2c")
                if b"\x1b[6n" in chunk:
                    os.write(master, b"\x1b[1;1R")

    def send(data):
        os.write(master, data)
        drain()

    def wait_for(needle, start=0):
        until = time.monotonic() + 8
        while time.monotonic() < until:
            drain()
            if needle in output[start:]:
                return
        raise AssertionError(f"missing {needle!r}: {bytes(output[-2500:])!r}")

    def await_server_idle(prompt):
        with socket.create_connection(("127.0.0.1", int(server_port)), timeout=5) as peer:
            reader = peer.makefile("rb")
            peer.sendall((json.dumps({"version": 2, "command": "attach",
                                     "token": os.environ["ELARA_SERVER_TOKEN"],
                                     "session_id": session, "mode": "observe", "cursor": 0}) + "\n").encode())
            assert json.loads(reader.readline())["type"] == "attached"
            until = time.monotonic() + 8
            while time.monotonic() < until:
                peer.sendall(b'{"version":2,"command":"resnapshot"}\n')
                while True:
                    frame = json.loads(reader.readline())
                    if frame["type"] == "snapshot":
                        view = frame["snapshot"]
                        break
                users = [m["text"] for m in view["messages"] if m["role"] == "user"]
                if users and users[-1] == prompt.decode() and view["turn"]["state"] == "idle":
                    reader.close()
                    return
                time.sleep(0.02)
            raise AssertionError("server never completed while client paused")

    try:
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 120, 0, 0))
        os.kill(pid, signal.SIGWINCH)
        wait_for(b"Ctrl-J")
        assert b"\x1b[?1004h" in output, "focus reporting requested"
        assert notice not in output, "attachment never re-notifies historical turns"
        for prompt, focus, command, result, notify in turns:
            coqueued = prompt in (b"error-turn", b"enabled-again")
            if focus and not coqueued:
                send(focus)
            if command:
                send(command + b"\r")
                saved = json.loads(pathlib.Path(os.environ["ELARA_TUI_APPEARANCE_FILE"]).read_text())
                assert saved["notifications"] == (command == b"/notifications on")
            before = len(output)
            send(prompt + b"\r")
            if prompt == b"enabled-again":
                send(b"\x07")
                until = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < until:
                    drain()
                assert ready.exists(), "main thread blocked in foreground editor"
                os.write(master, focus + b"\n")
                await_server_idle(prompt)
                # The socket reader remains live while main awaits the editor.
                release.touch()
            elif coqueued:
                os.kill(pid, signal.SIGSTOP)
                try:
                    os.write(master, focus)
                    await_server_idle(prompt)
                finally:
                    os.kill(pid, signal.SIGCONT)
            wait_for(result, before)
            drain(0.3)
            emitted = bytes(output[before:])
            assert emitted.count(notice) == int(notify), (prompt, emitted[-1500:])
            if notify:
                message = b"Turn ended with an error" if prompt == b"error-turn" else b"Turn complete"
                assert notice + message + b"\x1b\\" in emitted
                assert b"PRIVATE_PROVIDER_DETAIL" not in emitted[emitted.index(notice):emitted.index(notice) + len(notice) + len(message) + 2]
        send(b"/appearance\r")
        wait_for(b"Notifications:")
        # Save the opposite setting using the visible picker, then inspect disk.
        current = json.loads(pathlib.Path(os.environ["ELARA_TUI_APPEARANCE_FILE"]).read_text())["notifications"]
        capture = os.environ.get("ELARA_TUI_NOTIFICATIONS_CAPTURE")
        if capture:
            pathlib.Path(capture + f".appearance-{str(current).lower()}.ansi").write_bytes(output)
        send(b"n")
        if capture:
            pathlib.Path(capture + f".appearance-{str(not current).lower()}.ansi").write_bytes(output)
        send(b"s")
        assert json.loads(pathlib.Path(os.environ["ELARA_TUI_APPEARANCE_FILE"]).read_text())["notifications"] != current
        send(b"/notifications off\r")
        assert not json.loads(pathlib.Path(os.environ["ELARA_TUI_APPEARANCE_FILE"]).read_text())["notifications"]
        send(b"/detach\r")
        _, status = os.waitpid(pid, 0)
        pid = None
        assert os.waitstatus_to_exitcode(status) == 0
        assert b"\x1b[?1004l" in output, "focus reporting disabled on exit"
        captures.extend(output)
    finally:
        if pid is not None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(master)
        for path in (gate, ready, release):
            path.unlink(missing_ok=True)


client([
    (b"unknown-focus", None, None, b"reply-1", True),
    (b"focused-turn", b"\x1b[I", None, b"reply-2", False),
    (b"error-turn", b"\x1b[O", None, b"Turn ended with an error", True),
    (b"disabled-turn", None, b"/notifications off", b"reply-4", False),
])
client([
    (b"persisted-off", None, None, b"reply-5", False),
    (b"enabled-again", b"\x1b[I", b"/notifications on", b"reply-6", False),
    (b"lost-again", b"\x1b[O", None, b"reply-7", True),
])
capture = os.environ.get("ELARA_TUI_NOTIFICATIONS_CAPTURE")
if capture:
    pathlib.Path(capture).write_bytes(captures)
print("Notifications PTY passed: bell + OSC777 once per done/error, unknown/lost focus, focused suppression, off/restart/on, private details excluded, appearance toggle, focus cleanup")
