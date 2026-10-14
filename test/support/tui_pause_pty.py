"""Keep control across a foreground editor and real shell job suspension."""
import fcntl
import json
import os
import pathlib
import pty
import re
import select
import shlex
import signal
import socket
import struct
import subprocess
import sys
import termios
import time

binary, port, session, mode, dest, pause = sys.argv[1:]
pause = float(pause)
dest = pathlib.Path(dest)
dest.mkdir(parents=True, exist_ok=True)
gate = dest / "editor.py"
gate.write_text(f'import pathlib,time\np=pathlib.Path(__file__)\np.with_suffix(".ready").touch()\ntime.sleep({pause})\n')
shell_pid, master = pty.fork()
if shell_pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.environ["VISUAL"] = f'{shlex.quote(sys.executable)} {shlex.quote(str(gate))}'
    os.environ["PS1"] = "PAUSE_SHELL_READY> "
    os.execv("/bin/bash", ["bash", "--noprofile", "--norc", "-i"])
pid = None
view_pid = None
output = bytearray()
started = time.monotonic()
cast_events = []


def send(data):
    cast_events.append([time.monotonic() - started, "i", data.decode()])
    os.write(master, data)


def process_tree(root):
    rows = [row.split(None, 2) for row in subprocess.check_output(
        ["ps", "-ax", "-o", "pid=,ppid=,comm="]).decode().splitlines()]
    targets = {root}
    while children := {int(child) for child, parent, _ in rows if int(parent) in targets} - targets:
        targets.update(children)
    return {int(child): command for child, _, command in rows if int(child) in targets}


def drain(seconds=0.1):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if select.select([master], [], [], max(0, until - time.monotonic()))[0]:
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            output.extend(data)
            cast_events.append([time.monotonic() - started, "o", data.decode(errors="replace")])
            if b"\x1b[c" in data:
                send(b"\x1b[?1;2c")
            if b"\x1b[6n" in data:
                send(b"\x1b[1;1R")


def wait_for(needle, offset=0, redraw=False):
    until = time.monotonic() + 45
    while time.monotonic() < until:
        if redraw:
            for width in (119, 120):
                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, width, 0, 0))
                os.kill(view_pid, signal.SIGWINCH)
                drain(.05)
        else:
            drain()
        visible = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", output[offset:])
        if needle.replace(b" ", b"") in visible.replace(b" ", b""):
            return
    raise AssertionError(f"missing {needle!r}: {bytes(output[-2000:])!r}")


try:
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 120, 0, 0))
    wait_for(b"PAUSE_SHELL_READY>")
    send(("set -b\n" + shlex.join([binary, "--diagnostics", "--port", port, "--", session]) + "\n").encode())
    wait_for(b"Ctrl-J")
    pid = os.tcgetpgrp(master)
    assert pid != shell_pid, "TUI must run in a foreground job"
    clients = [child for child, command in process_tree(pid).items()
               if pathlib.Path(command).name == "elara-tui"]
    assert len(clients) == 1, f"expected one native client, got {clients}"
    view_pid = clients[0]
    send(b"long-turn\r")
    drain(0.3)
    send(b"kept draft")
    draft_start = len(output)
    draft = b"kept draft"
    if mode == "editor":
        send(b"\x07")
        until = time.monotonic() + 8
        while not gate.with_suffix(".ready").exists() and time.monotonic() < until:
            drain()
        assert gate.with_suffix(".ready").exists(), "editor did not start"
        drain(pause + 0.5)
    else:
        (dest / "processes-before.txt").write_bytes(subprocess.check_output(
            ["ps", "-ax", "-o", "pid=,ppid=,pgid=,sess=,stat=,comm="]))
        if mode == "suspend-command":
            draft = b"/suspend"
            send(b"\x01\x7f" + draft + b"\r")
        else:
            send(b"\x1a")
        wait_for(b"Stopped")
        state = subprocess.check_output(["ps", "-o", "stat=", "-p", str(pid)]).strip()
        assert b"T" in state, "suspend did not stop the foreground job"
        assert os.tcgetpgrp(master) == shell_pid, "suspend did not return the shell to foreground"
        assert termios.tcgetattr(master)[3] & termios.ISIG, "shell lost terminal signals"
        shell_start = len(output)
        send(b"printf 'SHELL_IS_USABLE\\n'\n")
        wait_for(b"SHELL_IS_USABLE\r\n", shell_start)
        background_start = len(output)
        send(b"bg\n")
        wait_for(b"Stopped", background_start)
        assert os.tcgetpgrp(master) == shell_pid, "bg stole the foreground terminal"
        assert termios.tcgetattr(master)[3] & termios.ISIG, "bg disabled shell terminal signals"
        assert b"\x1b[?1049h" not in output[background_start:], "bg redrew the TUI"
        time.sleep(pause)
        with socket.create_connection(("127.0.0.1", int(port)), timeout=30) as peer:
            peer.sendall((json.dumps({"version": 2, "command": "attach", "token": os.environ["ELARA_SERVER_TOKEN"],
                                     "session_id": session, "mode": "observe", "cursor": 0}) + "\n").encode())
            with peer.makefile("rb") as reader:
                frame = json.loads(reader.readline())
            assert frame["type"] == "attached", frame["type"]
            assert frame["snapshot"]["turn"]["state"] == "idle", "external server did not finish while suspended"
            assert any(m["role"] == "assistant" and m["text"].endswith("LONG TURN DONE")
                       for m in frame["snapshot"]["messages"]), "external turn incomplete before fg"
        draft_start = len(output)
        send(b"fg\n")
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 119, 0, 0))
    os.kill(pid, signal.SIGWINCH)
    wait_for(b"LONG TURN DONE")
    if mode == "suspend-command":
        # Submitting a slash command consumes that command, not a saved draft.
        draft = b"new draft after resume"
        send(draft)
    wait_for(draft, draft_start, redraw=mode != "editor")
    if mode != "editor":
        # The notice can be a cursor-addressed diff with unchanged letters
        # omitted. Request one full frame before matching its exact bytes.
        wait_for(b"Reattached; local draft and view restored.", redraw=True)
    assert os.tcgetpgrp(master) == pid, "resumed TUI is not the foreground job"
    assert not termios.tcgetattr(master)[3] & termios.ICANON, "resumed TUI input is not raw"
    print(f"Resumed {mode}: foreground and raw input verified", flush=True)
    drain(0.3)
    (dest / "resumed.ansi").write_bytes(output)
    send(b"\x01")
    drain(0.2)
    send(b"\x7f")
    drain(0.2)
    send(b"/read-only on\r")
    with socket.create_connection(("127.0.0.1", int(port)), timeout=30) as peer:
        peer.sendall((json.dumps({"version": 2, "command": "attach", "token": os.environ["ELARA_SERVER_TOKEN"],
                                 "session_id": session, "mode": "observe", "cursor": 0,
                                 "extensions": ["input_queue_v1"]}) + "\n").encode())
        with peer.makefile("rb") as reader:
            frame = json.loads(reader.readline())
            assert frame["type"] == "attached"
            view = frame["snapshot"]
            deadline = time.monotonic() + 10
            while not view["inbox"]["execution"]["read_only"] and time.monotonic() < deadline:
                drain()
                peer.sendall(b'{"version":2,"command":"resnapshot"}\n')
                frame = json.loads(reader.readline())
                while frame["type"] in ("event", "patch"):
                    frame = json.loads(reader.readline())
                assert frame["type"] == "snapshot", frame["type"]
                view = frame["snapshot"]
        assert view["inbox"]["execution"]["read_only"], "resumed TUI lacks control"
        assert [m["text"] for m in view["messages"] if m["role"] == "user"] == ["long-turn"]
        assert len([m for m in view["messages"] if m["role"] == "assistant" and m["text"].endswith("LONG TURN DONE")]) == 1
    drain(0.3)
    wait_for(b"Read-only from the next tool call", redraw=True)
    print(f"Pause PTY passed: {mode}, {pause}s, control retained, exact transcript")
finally:
    (dest / "terminal.ansi").write_bytes(output)
    header = {"version": 2, "width": 120, "height": 32, "title": f"Elara {mode} pause"}
    (dest / "terminal.cast").write_text("\n".join(json.dumps(row) for row in [header] + cast_events) + "\n")
    # Include launcher descendants even when the broken Port detached the TUI
    # into another session. A failed assertion must not leave a native holder.
    for target in process_tree(shell_pid):
        try:
            os.kill(target, signal.SIGCONT)
            os.kill(target, signal.SIGKILL)
        except ProcessLookupError:
            pass
    os.waitpid(shell_pid, 0)
    os.close(master)
