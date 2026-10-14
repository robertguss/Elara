#!/usr/bin/env python3
"""Offline boundary fixture; real fnox/age are exercised by the public proof."""
import json
import os
import pathlib
import sys
import time

args = sys.argv[1:]
assert args[:2] == ["--config", "fnox.toml"]
assert args[args.index("--profile") + 1] == "default"
assert "--non-interactive" in args and "--no-daemon" in args
assert "FNOX_PROFILE" not in os.environ
assert not any(k.startswith(("ELARA_", "XAI_", "OPENAI_", "EXA_")) for k in os.environ)
if "config-files" in args:
    print(pathlib.Path(".fnox-inventory").read_text(), end="")
else:
    plan = json.loads(pathlib.Path(".fnox-plan").read_text())
    if plan.get("test_change"):
        with open(plan["test_change"], "a") as target:
            target.write("\n# changed during resolution\n")
    if plan.get("test_delay"):
        time.sleep(plan["test_delay"])
    print(json.dumps(plan))
