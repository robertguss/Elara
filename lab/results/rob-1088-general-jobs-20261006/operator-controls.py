import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
out = Path(__file__).resolve().parent
server = root / "lib/elara/server.ex"
fixture = root / "test/elara/jobs_profile_test.exs"
mode = sys.argv[1]
assert mode in {"authority", "confirmation", "cleanup"}
attempt = sys.argv[2] if len(sys.argv) == 3 else ""
prefix = f"operator-{mode}" + (f"-{attempt}" if attempt else "")
original = {path: path.read_bytes() for path in (server, fixture)}

def replace(path, old, new):
    text = path.read_text()
    assert text.count(old) == 1, (path, old)
    path.write_text(text.replace(old, new))

env = os.environ.copy()
try:
    if mode == "authority":
        replace(server, '              "job_status"\n            ],',
                '              "job_status",\n              "job_acknowledge_stopped"\n            ],')
    elif mode == "confirmation":
        replace(server, 'if request["confirm_stopped"] == true do', 'if true do')
    else:
        witness = out / f"{prefix}-witness.json"
        assert not witness.exists()
        env["ROB1088_OPERATOR_WITNESS"] = str(witness)
        replace(fixture, '    inspect_job = %{"version" => 2, "command" => "job_status", "job_id" => "profiled"}',
                '''    {:ok, foreign_pid} = Elara.session_pid(foreign)
    Agent.update(ctx.resources, &Map.put(&1, :operator, %{
      server: server, foreign: foreign_pid, sockets: [controller, observer, outsider]
    }))
    flunk("forced operator cleanup control")
    inspect_job = %{"version" => 2, "command" => "job_status", "job_id" => "profiled"}''')
        replace(fixture, '      File.rm_rf!(root)\n      Agent.stop(resources)',
                '''      File.rm_rf!(root)
      operator = Agent.get(resources, & &1[:operator])
      if operator do
        File.write!(System.fetch_env!("ROB1088_OPERATOR_WITNESS"), JSON.encode!(%{
          root_removed: not File.exists?(root),
          server_stopped: not Process.alive?(operator.server),
          foreign_stopped: not Process.alive?(operator.foreign),
          sockets_closed: Enum.all?(operator.sockets, fn socket ->
            not match?({:ok, _}, :inet.sockname(socket))
          end)
        }))
      end
      Agent.stop(resources)''')
    source_hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in original}
    line = next(i for i, text in enumerate(fixture.read_text().splitlines(), 1)
                if text.startswith('  test "v2 operator job inspection'))
    with (out / f"{prefix}-control.log").open("xb") as log:
        result = subprocess.run(["mix", "test", f"test/elara/jobs_profile_test.exs:{line}",
                                 "--seed", "1088"], cwd=root, env=env, stdout=log,
                                stderr=subprocess.STDOUT, timeout=60)
    code = result.returncode
finally:
    for path, content in original.items():
        path.write_bytes(content)
        assert path.read_bytes() == content

manifest = {"mode": mode, "selected_line": line, "exit_code": code, "source_hashes": source_hashes,
            "restored_hashes": {str(p.relative_to(root)): hashlib.sha256(b).hexdigest()
                                for p, b in original.items()}, "byte_exact_restored": True}
if mode == "cleanup":
    manifest["cleanup"] = json.loads(witness.read_text())
    assert all(manifest["cleanup"].values()), manifest
(out / f"{prefix}-control.json").write_text(json.dumps(manifest, indent=2) + "\n")
assert code == 2, manifest
print(json.dumps(manifest))
