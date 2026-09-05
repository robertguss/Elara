"""Real Codex adapter -> Core -> protocol -> Rust PTY with local synthetic SSE."""
import fcntl
import http.server
import json
import os
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

binary = sys.argv[1]
requests = []
finish_live = threading.Event()


def sse(event):
    return ("event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n").encode()


def response_frames(number, model):
    frames, output = [], []

    def emit(kind, **fields):
        frames.append(sse(dict(type=kind, **fields)))

    if number < 3:
        summary = "HISTORY_SUMMARY_ONLY" if number == 1 else "LIVE_SUMMARY_START LIVE_SUMMARY_END"
        reason = dict(type="reasoning", id=f"rs_{number}", summary=[])
        emit("response.output_item.added", output_index=0, item=reason.copy())
        emit("response.reasoning_summary_part.added", output_index=0, summary_index=0,
             part=dict(type="summary_text", text=""))
        emit("response.reasoning_summary_text.delta", output_index=0, summary_index=0,
             delta=summary if number == 1 else "LIVE_SUMMARY_START")
        if number == 2:
            emit("response.reasoning_summary_text.delta", output_index=0, summary_index=0,
                 delta=" LIVE_SUMMARY_END")
        emit("response.reasoning_summary_text.done", output_index=0, summary_index=0, text=summary)
        reason["summary"] = [dict(type="summary_text", text=summary)]
        reason["encrypted_content"] = "PRIVATE_REASONING_CANARY"
        emit("response.reasoning_summary_part.done", output_index=0, summary_index=0,
             part=reason["summary"][0])
        emit("response.output_item.done", output_index=0, item=reason)
        output.append(reason)

    texts = [("final_answer", "NO_SUMMARY_FINAL_ONLY")] if number == 3 else [
        ("commentary", "HISTORY_COMMENTARY_ONLY" if number == 1 else "LIVE_COMMENTARY_ONLY"),
        ("final_answer", "HISTORY_FINAL_ONLY" if number == 1 else "LIVE_FINAL_ONLY"),
    ]
    for phase, text in texts:
        index = len(output)
        item = dict(type="message", id=f"msg_{number}_{index}", role="assistant",
                    phase=phase, status="in_progress", content=[])
        emit("response.output_item.added", output_index=index, item=item.copy())
        emit("response.output_text.delta", output_index=index, content_index=0, delta=text)
        item.update(status="completed", content=[dict(type="output_text", text=text, annotations=[])])
        emit("response.output_item.done", output_index=index, item=item)
        output.append(item)
    usage = dict(input_tokens=80 + number * 20, output_tokens=10 + number * 10,
                 total_tokens=90 + number * 30,
                 input_tokens_details=dict(cached_tokens=number * 4),
                 output_tokens_details=dict(reasoning_tokens=3 + number * 2))
    emit("response.completed", response=dict(id=f"resp_{number}", status="completed",
                                              model=model, output=output, usage=usage))
    return frames


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        assert self.path == "/backend-api/codex/responses"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(body)
        number = len(requests)
        assert number <= 3, "unexpected provider request"
        frames = response_frames(number, body["model"])
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(sum(map(len, frames))))
        self.send_header("Connection", "close")
        self.end_headers()
        for index, frame in enumerate(frames):
            if number == 2 and index == 3:
                assert finish_live.wait(45), "test did not release the live summary"
            for chunk in [frame[:7], frame[7:]]:
                self.wfile.write(chunk)
                self.wfile.flush()
                time.sleep(.005)


http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
threading.Thread(target=http.serve_forever, daemon=True).start()
print(json.dumps(dict(http_port=http.server_port)), flush=True)
context = json.loads(sys.stdin.readline())
observer = socket.create_connection(("127.0.0.1", context["port"]), timeout=5)
reader = observer.makefile("rb")
observer.sendall((json.dumps(dict(version=2, command="attach", session_id=context["session"],
                                mode="observe", extensions=["provider_visibility_v1"])) + "\n").encode())
assert json.loads(reader.readline())["type"] == "attached"


def snapshot():
    observer.sendall(b'{"version":2,"command":"resnapshot"}\n')
    while True:
        frame = json.loads(reader.readline())
        if frame["type"] == "snapshot":
            return frame["snapshot"]


pid, master = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(binary, [binary, "--port", str(context["port"]),
                     "--layout", "observatory", "--theme", "forest", "--", context["session"]])
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


def redraw(cols=180, rows=45):
    start = len(output)
    for width in [cols + 1, cols]:
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, width, 0, 0))
        os.kill(pid, signal.SIGWINCH)
        drain()
    return start


try:
    redraw()
    wait_for(lambda: b"HISTORY_FINAL_ONLY" in output, "initial historical provider content")
    send(b"live provider check\r")
    wait_for(lambda: "LIVE_SUMMARY_START" in json.dumps(snapshot()["provider_view"]), "live summary reaches Core")
    send("next é 👩‍💻 keep".encode())
    send(b"\x1b[1;2D" * 4)
    send(b"\t\x1b[H\x1b[15~")  # Historical turn while the second request remains live.
    start = redraw()
    assert b"HISTORY_SUMMARY_ONLY" in fresh(start), "history uses its actual public summary"
    assert b"LIVE_SUMMARY_START" not in fresh(start), "active summary does not replace historical content"
    send(b"\x1b")
    send(b"\x1b[18~")  # F7 model/effort picker.
    send(b"\x1b[B\x1b[C\x1b[C\r")
    next_settings = dict(model="gpt-5.4-mini", effort="high")
    wait_for(lambda: snapshot()["provider_view"]["next_request"] == next_settings, "settings accepted for next request")
    assert snapshot()["provider_view"]["active_request"] == dict(model="gpt-5.5", effort="low")
    assert requests[1]["model"] == "gpt-5.5" and requests[1]["reasoning"]["effort"] == "low"
    send(b"\x1b[14~")  # Sticky hide through each layout and completion.
    for layout in ["workbench", "ember", "observatory"]:
        send(b"\x1bOR\x1b[C\r")
        send(b"\x1b[15~")
        start = redraw()
        assert b"Hidden by you" in fresh(start), f"{layout} retains explicit hide"
        assert b"HISTORY_SUMMARY_ONLY" not in fresh(start)
        send(b"\x1b")
    finish_live.set()
    wait_for(lambda: snapshot()["provider_view"]["active_request"] is None, "live response completes")
    send(b"\x1b[15~")
    start = redraw(80, 24)
    assert b"Hidden by you" in fresh(start), "completion preserves hidden state"
    send(b"\x1b[14~")  # Show within F5, while still inspecting history.
    start = redraw(80, 24)
    assert b"HISTORY_SUMMARY_ONLY" in fresh(start)
    assert b"LIVE_SUMMARY_END" not in fresh(start)
    send(b"\x1b")
    send(b"\x1b[F\x1b[15~")
    start = redraw(80, 24)
    assert b"LIVE_SUMMARY_END" in fresh(start), "follow live binds the completed current summary"
    send(b"\x1b")
    send(b"\tsent\r")
    wait_for(lambda: len(requests) == 3 and snapshot()["provider_view"]["active_request"] is None,
             "next request completes with accepted settings")
    assert requests[2]["model"] == "gpt-5.4-mini"
    assert requests[2]["reasoning"]["effort"] == "high"
    assert requests[2]["input"][-1]["content"][0]["text"] == "next é 👩‍💻 sent"
    view = snapshot()
    assert view["provider_view"]["usage"]["session_totals"]["input_tokens"] == 360
    assert view["provider_view"]["usage"]["session_totals"]["output_tokens"] == 90
    assert view["provider_view"]["context"]["occupancy"] is None
    assert view["provider_view"]["context"]["advertised_limit"] == 272000
    assert view["provider_view"]["context"]["estimate_tokens"] > 0
    send(b"\x1b[15~")
    start = redraw(80, 24)
    assert b"unavailable" in fresh(start).lower(), "no-summary response is explicitly unavailable"
    for canary in ["PRIVATE_REASONING_CANARY", "provider-product-access-canary", "provider-product-refresh-canary"]:
        assert canary not in json.dumps(view), "private provider state is excluded from display DTO"
        assert canary.encode() not in output, "private provider state is excluded from terminal output"
    send(b"\x1b")
    send(b"\x03")
    wait_for(lambda: b"\x1b[?1006l" in output, "terminal reporting restored")
    _, status = os.waitpid(pid, 0)
    pid = None
    assert os.waitstatus_to_exitcode(status) == 0
    print("Provider visibility PTY passed", flush=True)
finally:
    finish_live.set()
    if pid is not None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(master)
    reader.close()
    observer.close()
    http.shutdown()
    http.server_close()
