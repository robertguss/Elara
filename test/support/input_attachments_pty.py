"""Real native attachment interaction against Elara and a bounded local HTTP fixture."""
import base64
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import socket
import struct
import sys
import termios
import threading
import time
import zlib

binary, root = sys.argv[1], Path(sys.argv[2])
requests = []


def png():
    width, height = 160, 80
    pixels = b"".join(b"\0" + b"".join(bytes((0, 0, 255) if x < 80 else (255, 255, 0))
                                      for x in range(width)) for _ in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


original = png()
encoded = base64.b64encode(original).decode()
image_path = root / "outside blue yellow α.png"
spare_path = root / "remove this duplicate.png"
image_path.write_bytes(original)
spare_path.write_bytes(original)
(root / "expected.png").write_bytes(original)
(root / "oversize.png").write_bytes(original + b"x" * (2 * 1024 * 1024))


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(request)
        answer = {"type": "message", "id": "message", "role": "assistant", "phase": "final_answer",
                  "content": [{"type": "output_text", "text": "INPUT_ATTACHMENT_DONE"}]}
        events = [
            {"type": "response.output_item.added", "output_index": 0, "item": dict(answer, content=[])},
            {"type": "response.output_text.delta", "output_index": 0, "item_id": "message", "content_index": 0, "delta": "INPUT_ATTACHMENT_DONE"},
            {"type": "response.output_item.done", "output_index": 0, "item": answer},
            {"type": "response.completed", "response": {"id": "response", "model": "gpt-5.5", "output": [answer]}},
        ]
        body = b"".join(("data: " + json.dumps(event) + "\n\n").encode() for event in events)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=http.serve_forever, daemon=True).start()
print(json.dumps({"http_port": http.server_port}), flush=True)
context = json.loads(sys.stdin.readline())
observer = socket.create_connection(("127.0.0.1", context["port"]), timeout=5)
reader = observer.makefile("rb")
observer.sendall((json.dumps(dict(version=2, command="attach", session_id=context["session"], mode="observe",
                                extensions=["provider_visibility_v1", "input_attachments_v1"])) + "\n").encode())
attached = json.loads(reader.readline())
assert attached["type"] == "attached", attached


def snapshot():
    observer.sendall(b'{"version":2,"command":"resnapshot"}\n')
    while True:
        frame = json.loads(reader.readline())
        if frame["type"] == "snapshot":
            return frame["snapshot"]


pid, master = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(binary, [binary, "--port", str(context["port"]), "--theme", "forest", "--", context["session"]])
output = bytearray()
last_frame = b""


def drain(seconds=.2):
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
            if b"\x1b[c" in data:
                os.write(master, b"\x1b[?1;2c")
            if b"\x1b[6n" in data:
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
    raise AssertionError(label + "\n" + re.sub(r" {3,}", " ", last_frame.decode(errors="replace")))


def redraw(cols=180, rows=45):
    global last_frame
    start = len(output)
    for width in [cols + 1, cols]:
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, width, 0, 0))
        os.kill(pid, signal.SIGWINCH)
        drain()
    positioned = re.sub(rb"\x1b\[\d+;\d+H", b"\n", bytes(output[start:]))
    last_frame = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", positioned)
    return last_frame


def attach_image(path):
    send(b"\x1b[20~")
    send(str(path).encode())
    send(b"\r")
    def selected():
        frame = redraw()
        return not visible("Image from disk", frame) and visible(path.name, frame) and visible("image/png", frame)
    wait_for(selected, "PNG selected outside workspace")


def visible(text, frame):
    # Cursor positioning can supply the spaces between separately painted spans.
    return re.sub(rb"\s", b"", text.encode()) in re.sub(rb"\s", b"", frame)


try:
    redraw()
    wait_for(lambda: b"Ctrl-J" in output, "initial frame")
    send("Analyze é 👩‍💻 keep".encode())
    send(b"\x1b[1;2D" * 4)
    send(b"\x1b[19~")  # F8 files; choose with the mouse.
    send(b"notes")
    wait_for(lambda: visible("notes α file.txt", redraw()), "Unicode/spaced file discovery")
    send(b"\x1b[<0;48;5M\x1b[<0;48;5m")
    wait_for(lambda: visible("F10 remove", redraw()), "explicit mouse file selection")
    attach_image(image_path)
    image_path.write_bytes(b"original disk image changed after ingestion")
    attach_image(spare_path)
    send(b"\x1b[21~\x1b[B\x1b[B\x7f")  # F10, third selection, remove duplicate bytes under another name.
    send(b"\x1b")
    selected = redraw()
    assert not visible("remove this duplicate", selected)
    assert visible("outside blue yellow", selected)
    send(b"\x1b[20~")
    send(str(root / "oversize.png").encode())
    send(b"\r")
    assert visible("Image exceeds 2 MiB", redraw()), "oversize image error remains visible"
    send(b"\x1b")
    for layout in ["observatory", "workbench", "ember"]:
        send(b"\x1bOR\x1b[C\r")
        frame = redraw(100, 32)
        assert visible("outside blue yellow", frame), f"{layout} retains image"
        assert visible("notes α file.txt", frame), f"{layout} retains reference"
    (root / "workspace" / "notes α file.txt").write_text("AT_SUBMISSION")
    send(b"sent\r")
    wait_for(lambda: len(requests) == 1 and snapshot()["provider_view"]["active_request"] is None, "attachment request completes")
    contents = requests[0]["input"][0]["content"]
    assert len([part for part in contents if part["type"] == "input_image"]) == 1, "removed image is not delivered"
    assert next(part["image_url"] for part in contents if part["type"] == "input_image") == "data:image/png;base64," + encoded
    text = "\n".join(part["text"] for part in contents if part["type"] == "input_text")
    assert "AT_SUBMISSION" in text and "BEFORE_SELECTION" not in text
    assert "Analyze é 👩‍💻 sent" in text, "modal choices preserve selected composer text"
    assert encoded.encode() not in output, "image data is never rendered as base64"
    send(b"\x03")
    _, status = os.waitpid(pid, 0)
    pid = None
    assert os.waitstatus_to_exitcode(status) == 0
    print(json.dumps({"phase": "terminal_done"}), flush=True)
    assert sys.stdin.readline().strip() == "finish"
    assert len(requests) == 2
    prior = requests[1]["input"][0]["content"]
    assert next(part["image_url"] for part in prior if part["type"] == "input_image") == "data:image/png;base64," + encoded
    assert any("AT_SUBMISSION" in part.get("text", "") for part in prior)
    print("Input attachment PTY passed", flush=True)
finally:
    if pid is not None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(master)
    reader.close()
    observer.close()
    http.shutdown()
    http.server_close()
