"""Real child lifecycle UI over PTY and the production server protocol (offline fixture)."""
import fcntl
import json
import os
import pty
import select
import signal
import socket
import struct
import sys
import termios
import time

binary, port, parent, stage = sys.argv[1:]
observer = socket.create_connection(("127.0.0.1", int(port)), timeout=5)
reader = observer.makefile("rb")


def request(command):
    observer.sendall((json.dumps(dict(version=2, **command)) + "\n").encode())
    while True:
        frame = json.loads(reader.readline())
        if frame["type"] != "patch":
            return frame


attached = request(dict(command="attach", session_id=parent, cwd=os.getcwd(), mode="observe"))
assert attached["type"] == "attached", attached
pid, master = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(binary, [binary, "--port", port, "--", parent])
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


def command(text):
    send(b"\x1b[200~" + text.encode() + b"\x1b[201~\r")


def wait(predicate, description):
    until = time.monotonic() + 10
    while time.monotonic() < until:
        drain(0.1)
        if predicate():
            return
    raise AssertionError(description + "\n" + repr(bytes(output[-5000:])))


def children():
    return request(dict(command="child_list"))["sessions"]


def child_messages():
    child = next(c for c in children() if c["coding"])
    with socket.create_connection(("127.0.0.1", int(port)), timeout=5) as sock:
        sock.sendall((json.dumps(dict(version=2, command="attach", session_id=child["id"], mode="observe")) + "\n").encode())
        with sock.makefile("rb") as stream:
            return json.loads(stream.readline())["snapshot"]["messages"]


def resize(width, height):
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))
    os.kill(pid, signal.SIGWINCH)
    drain()


try:
    resize(120, 40)
    wait(lambda: b"Ctrl-J" in output, "initial TUI frame")
    if stage == "start":
        command("/delegate coding PTY coding λ")
        wait(lambda: len(children()) == 1 and "completed" in children()[0]["state"], "coding child completes")
        wait(lambda: b"base_revision" in output, "durable creation details")
        send(b"\x1b")
        command("/delegate research PTY research failure")
        wait(lambda: len(children()) == 2 and any("failed" in c["state"] for c in children()), "sibling failure shown")
        send(b"\x1b")
    command("/children")
    wait(lambda: b"Limit 4" in output and b"Children" in output, "child limit and list rendered")
    resize(80, 24)
    resize(120, 40)
    send(b"PTY coding")
    send(b"\t")
    wait(lambda: b"parent_id" in output, "Tab inspects durable child metadata")
    send(b"\x1b")
    command("/children")
    send(b"PTY coding\r")
    wait(lambda: "PTY coding λ".encode() in output, "child transcript opens")
    if stage == "resume":
        command("explicit PTY child follow-up")
        wait(lambda: b"resumed" in output and any(m.get("text") == "PTY resumed answer" for m in child_messages()), "saved child resumes without replay")
    else:
        wait(lambda: b"coding answer" in output and any(m.get("text") == "PTY coding answer" for m in child_messages()), "actual child tool transcript")
    send(b"\x1b")
    wait(lambda: b"\x1b[?2004l" in output, "terminal state restored")
    _, status = os.waitpid(pid, 0)
    pid = None
    assert os.waitstatus_to_exitcode(status) == 0
    print("THREAD PTY " + stage + " passed")
finally:
    observer.close()
    reader.close()
    if pid is not None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(master)
