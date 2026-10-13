"""Local MCP fixture; no external services or credentials."""
import json
import os
import pathlib
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = pathlib.Path(sys.argv[1])
era = sys.argv[2]
initialized = False
with (root / "starts").open("a") as file:
    file.write("start\n")


def answer(request, headers=None):
    global initialized
    mode_file = root / "era.txt"
    mode = mode_file.read_text() if mode_file.exists() else era
    identity_file = root / "identity.json"
    identity = json.loads(identity_file.read_text()) if identity_file.exists() else {"name": "fixture", "version": "1.0"}
    method = request["method"]
    with (root / "requests").open("a") as file:
        file.write(method + "\n")
    if method == "notifications/initialized":
        initialized = True
        return None
    if mode == "legacy" and method == "server/discover":
        return {"error": {"code": -32601, "message": "legacy"}}
    if method == "initialize":
        return {"result": {"protocolVersion": "2025-11-25", "capabilities": {}, "serverInfo": identity}}
    if method == "server/discover":
        return {"result": {"supportedVersions": ["2026-07-28"], "capabilities": {"tools": {}}, "resultType": "complete", "_meta": {"io.modelcontextprotocol/serverInfo": identity}}}
    if mode == "legacy" and not initialized:
        return {"error": {"code": -32000, "message": "not initialized"}}
    if method == "tools/list":
        tools = json.loads((root / "catalog.json").read_text())
        if request["params"].get("cursor") == "second":
            return {"result": {"tools": tools[1:]}}
        return {"result": {"tools": tools[:1], "nextCursor": "second"}}
    if method == "tools/call":
        name = request["params"]["name"]
        with (root / "calls").open("a") as file:
            file.write(name + "\n")
        if name == "lost":
            return "lost"
        if name == "slow":
            time.sleep(2)
        if name == "flood":
            size = request["params"]["arguments"].get("bytes", 16_778_240)
            return {"result": {"content": [{"type": "text", "text": "x" * size}]}}
        if name == "input":
            return {"result": {"resultType": "input_required", "inputRequests": []}}
        return {"result": {"content": [{"type": "text", "text": "echo ✓"}], "isError": False,
            "structuredContent": {"params": request["params"], "headers": dict(headers or {}),
                "server_token_present": "SERVER_TOKEN" in os.environ,
                "unrelated_token_present": "ELARA_TEST_MCP_UNRELATED" in os.environ}}}
    return {"error": {"code": -32601, "message": "unknown"}}


def envelope(request, reply):
    return dict(reply, jsonrpc="2.0", id=request["id"])


if "--http" in sys.argv:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            expected = root / "expected-token"
            if expected.exists() and self.headers.get("Authorization") != "Bearer " + expected.read_text():
                self.send_response(401)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            reply = answer(request, {key.lower(): value for key, value in self.headers.items() if key.lower() != "authorization"})
            if reply == "lost":
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            if reply is None:
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = json.dumps(envelope(request, reply)).encode()
            sse = request["method"] == "tools/call"
            if sse:
                body = b': comment\r\ndata: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}\r\n\r\ndata: ' + body + b'\r\n\r\n'
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream" if sse else "application/json")
            if era == "legacy":
                self.send_header("Mcp-Session-Id", "fixture-session")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                for offset in range(0, len(body), 113):
                    self.wfile.write(body[offset:offset + 113])
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
else:
    for line in sys.stdin:
        request = json.loads(line)
        reply = answer(request)
        if reply == "lost":
            sys.exit(3)
        if reply is not None:
            try:
                print(json.dumps(envelope(request, reply)), flush=True)
            except BrokenPipeError:
                os._exit(0)
