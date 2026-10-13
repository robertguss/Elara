"""Observe actual terminal notification bytes for real scripted turns."""
import fcntl
import json
import os
import pathlib
import pty
import select
import signal
import struct
import sys
import termios
import time

binary, server_port, session = sys.argv[1:]
notice = b"\x07\x1b]777;notify;Elara;"
captures = bytearray()


def client(turns):
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

    try:
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 120, 0, 0))
        os.kill(pid, signal.SIGWINCH)
        wait_for(b"Ctrl-J")
        assert b"\x1b[?1004h" in output, "focus reporting requested"
        assert notice not in output, "attachment never re-notifies historical turns"
        for prompt, focus, command, result, notify in turns:
            if focus:
                send(focus)
            if command:
                send(command + b"\r")
                saved = json.loads(pathlib.Path(os.environ["ELARA_TUI_APPEARANCE_FILE"]).read_text())
                assert saved["notifications"] == (command == b"/notifications on")
            before = len(output)
            send(prompt + b"\r")
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


client([
    (b"unknown-focus", None, None, b"reply-1", True),
    (b"focused-turn", b"\x1b[I", None, b"reply-2", False),
    (b"error-turn", b"\x1b[O", None, b"Turn ended with an error", True),
    (b"disabled-turn", None, b"/notifications off", b"reply-4", False),
])
client([
    (b"persisted-off", None, None, b"reply-5", False),
    (b"enabled-again", None, b"/notifications on", b"reply-6", True),
])
capture = os.environ.get("ELARA_TUI_NOTIFICATIONS_CAPTURE")
if capture:
    pathlib.Path(capture).write_bytes(captures)
print("Notifications PTY passed: bell + OSC777 once per done/error, unknown/lost focus, focused suppression, off/restart/on, private details excluded, appearance toggle, focus cleanup")
