"""Drop a real gateway connection, then explicitly reopen the same session."""
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
import threading
import time

binary, backend_port = sys.argv[1:3]
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen()
listener.settimeout(0.2)
stop = threading.Event()
connected = threading.Event()
errors = []
authenticated = []
peers = []
sessions = []
terminal_bytes = bytearray()


def forward():
    first_session = None
    try:
        while not stop.is_set():
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            with client, socket.create_connection(("127.0.0.1", int(backend_port)), timeout=2) as backend:
                peers.extend([client, backend])
                client.settimeout(2)
                incoming = client.makefile("rb")
                line = incoming.readline()
                request = json.loads(line)
                assert request["token"] == os.environ["ELARA_SERVER_TOKEN"], "retry omitted authentication"
                authenticated.append(request["command"])
                backend.sendall(line)
                outgoing = backend.makefile("rb")
                response = outgoing.readline()
                frame = json.loads(response)
                client.sendall(response)
                incoming.close()
                outgoing.close()
                if frame["type"] != "attached":
                    continue
                if first_session is None:
                    first_session = frame["session_id"]
                    sessions.append(first_session)
                    continue  # Closing both sockets injects actual transport loss.
                assert request["command"] == "attach" and request["session_id"] == first_session
                assert frame["session_id"] == first_session
                connected.set()
                while not stop.is_set():
                    ready, _, _ = select.select([client, backend], [], [], 0.1)
                    for source in ready:
                        data = source.recv(65536)
                        if not data:
                            return
                        (backend if source is client else client).sendall(data)
    except (OSError, ValueError, AssertionError, KeyError) as error:
        if not stop.is_set():
            errors.append(str(error))


thread = threading.Thread(target=forward)
pid, master = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv(binary, [binary, "--port", str(listener.getsockname()[1]), "--", "new"])
thread.start()


def drain():
    if select.select([master], [], [], 0.1)[0]:
        data = os.read(master, 65536)
        terminal_bytes.extend(data)
        if b"\x1b[c" in data:
            os.write(master, b"\x1b[?1;2c")
        if b"\x1b[6n" in data:
            os.write(master, b"\x1b[1;1R")


try:
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    os.kill(pid, signal.SIGWINCH)
    deadline = time.monotonic() + 8
    while (not sessions or b"Disconnected:" not in terminal_bytes) and not errors and time.monotonic() < deadline:
        drain()
    assert sessions and b"Disconnected:" in terminal_bytes and not errors, "transport loss was not observed"
    os.write(master, ("/open " + sessions[0] + "\r").encode())
    deadline = time.monotonic() + 8
    while not connected.is_set() and not errors and time.monotonic() < deadline:
        drain()
    assert connected.is_set() and not errors, "native reconnect did not attach with authentication"
    assert authenticated[0] == "create" and "attach" in authenticated[1:]
    if len(sys.argv) > 3:
        raise AssertionError("forced failure after authenticated reconnect")
    os.write(master, b"\x1b")
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        found, status = os.waitpid(pid, os.WNOHANG)
        if found:
            pid = None
            assert os.waitstatus_to_exitcode(status) == 0
            break
        try:
            drain()
        except OSError:
            pass
    assert pid is None, "native detach did not exit"
    print("Reconnect auth passed: same session, create and retry both authenticated")
finally:
    if pid is not None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(master)
    stop.set()
    listener.close()
    thread.join(3)
    print("cleanup=" + json.dumps({"native_stopped": True, "proxy_thread_stopped": not thread.is_alive(), "listener_closed": listener.fileno() == -1, "peer_sockets_closed": bool(peers) and all(peer.fileno() == -1 for peer in peers)}), flush=True)
