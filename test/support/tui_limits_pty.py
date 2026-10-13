"""Change a live session's limits through the shipped TUI and verify its next turn."""
import base64
import fcntl
import json
import os
import pathlib
import pty
import select
import signal
import socket
import struct
import sys
import termios
import time

binary, port, session = sys.argv[1:]
pid, master = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(binary, [binary, "--port", port, "--", session])
output = bytearray()
capture = os.environ.get("ELARA_TUI_LIMITS_CAPTURE")
recording = open(capture + ".frames.jsonl", "w") if capture else None
started = time.monotonic()


def wait_for(*parts):
    deadline = time.monotonic() + 8
    start = len(output)
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            output.extend(chunk)
            if recording:
                recording.write(json.dumps({"t": time.monotonic() - started, "bytes": base64.b64encode(chunk).decode()}) + "\n")
            if b"\x1b[c" in chunk:
                os.write(master, b"\x1b[?1;2c")
            if b"\x1b[6n" in chunk:
                os.write(master, b"\x1b[1;1R")
        if all(part in output[start:] for part in parts) and not select.select([master], [], [], 0.1)[0]:
            return
    raise AssertionError(f"Missing {parts!r}: {bytes(output[-5000:])!r}")


def send(data, *parts):
    os.write(master, data)
    wait_for(*parts)


def snapshot():
    with socket.create_connection(("127.0.0.1", int(port)), timeout=5) as peer:
        peer.sendall((json.dumps({"version": 2, "command": "attach", "mode": "observe",
                                 "session_id": session, "extensions": ["runtime_limits_v1"],
                                 "token": os.environ["ELARA_SERVER_TOKEN"]}) + "\n").encode())
        return json.loads(peer.makefile("rb").readline())["snapshot"]


try:
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    os.kill(pid, signal.SIGWINCH)
    wait_for(b"Ctrl-J")
    send(b"/limits\r", b"Calls:", b"100", b"config", b"10m")
    capture = os.environ.get("ELARA_TUI_LIMITS_CAPTURE")
    if capture:
        pathlib.Path(capture + ".default.ansi").write_bytes(output)
    os.write(master, b"\x1b")
    time.sleep(0.15)
    send(b"active-proof\r", b"ACTIVE_LIMITS_MARKER")
    send(b"/limits calls 1\r", b"applies", b"next", b"turn")
    assert snapshot()["runtime_limits"]["next_turn"]["max_iterations"] == 1
    send(b"/limits timeout 20m\r")
    # An identical notice need not redraw; wait for authoritative server state.
    deadline = time.monotonic() + 5
    while snapshot()["runtime_limits"]["next_turn"]["tool_timeout_ms"] != 1_200_000:
        assert time.monotonic() < deadline
        time.sleep(0.02)
    send(b"/limits\r", b"Calls:", b"session", b"20m", b"Running", b"unchanged")
    limits = snapshot()["runtime_limits"]
    assert limits["pending"]
    assert limits["active_turn"]["max_iterations"] == 100
    assert limits["active_turn"]["tool_timeout_ms"] == 600_000
    if capture:
        pathlib.Path(capture + ".pending.ansi").write_bytes(output)
    os.write(master, b"\x1b")
    wait_for(b"active", b"finished")
    send(b"/limits\r", b"Calls:", b"session", b"20m")
    if capture:
        pathlib.Path(capture + ".overrides.ansi").write_bytes(output)
    os.write(master, b"\x1b")
    time.sleep(0.15)
    send(b"/limits timeout 61m\r", b"ceiling", b"60", b"minutes")
    assert snapshot()["runtime_limits"]["next_turn"]["tool_timeout_ms"] == 1_200_000
    send(b"limit-proof\r", b"Turn ended with an error")
    view = snapshot()
    assert view["turn"]["state"] == "idle"
    assert len([m for m in view["messages"] if m["role"] == "assistant"]) == 3
    assert not any(m.get("text") == "should not be requested" for m in view["messages"])
    send(b"/detach\r", b"\x1b[?2004l")
    _, status = os.waitpid(pid, 0)
    pid = None
    assert os.waitstatus_to_exitcode(status) == 0
    if capture:
        pathlib.Path(capture).write_bytes(output)
    print("Limits PTY passed: config provenance, calls and timeout edits, ceiling refusal, next turn stopped at one call")
finally:
    if pid is not None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(master)
    if recording:
        recording.close()
