"""Exercise hidden operator input, not an Exa network call."""
import json, os, pty, select, signal, stat, termios, time
from pathlib import Path

key = b"fixture-hidden-exa-login"
pid, fd = pty.fork()
if pid == 0:
    # The parent ExUnit process holds Mix's compilation lock. Use its built app.
    os.execvp("mix", ["mix", "run", "--no-compile", "--no-deps-check", "-e",
                        'Mix.Tasks.Elara.Login.run(["exa"])'])
output = bytearray()
sent = False
exited = False
echo = termios.tcgetattr(fd)[3] & termios.ECHO
try:
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if select.select([fd], [], [], .1)[0]:
            try:
                output.extend(os.read(fd, 65536))
            except OSError:
                break
            if not sent and b"Exa API key (hidden):" in output:
                os.write(fd, key + b"\r")
                sent = True
        stopped, status = os.waitpid(pid, os.WNOHANG)
        if stopped:
            assert os.waitstatus_to_exitcode(status) == 0
            exited = True
            break
    else:
        raise AssertionError("login timed out: " + output.decode(errors="replace").replace(
            key.decode(), "[fixture key]"))
    if not exited:
        _, status = os.waitpid(pid, 0)
        assert os.waitstatus_to_exitcode(status) == 0
    assert sent and key not in output, "key was echoed"
    assert termios.tcgetattr(fd)[3] & termios.ECHO == echo, "echo was not restored"
    path = Path(os.environ["HOME"], ".elara", "exa-auth.json")
    assert json.loads(path.read_text())["api_key"] == key.decode()
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    print("hidden input and private storage passed")
finally:
    try:
        os.kill(pid, signal.SIGTERM)
        os.waitpid(pid, 0)
    except (ProcessLookupError, ChildProcessError):
        pass
