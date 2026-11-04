#!/usr/bin/env python3
"""Validate the macOS production worker against an explicit disposable Linux/Bash 4.2 peer.

The peer must listen on loopback, accept only the fixture credentials below,
and start a clean Bash 4.2 login shell. It is provisioned separately; this
script neither changes an existing host nor installs anything remotely.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile

import paramiko


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("only an explicitly published disposable peer port is allowed")
    args.output.mkdir(parents=True, exist_ok=True)
    client = paramiko.SSHClient()
    # An isolated peer's generated host key is trusted in memory only.
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect("127.0.0.1", port=args.port, username="shell-fixture", password="fixture-only", look_for_keys=False, allow_agent=False, timeout=10)
        _, stdout, stderr = client.exec_command("uname -srm; printf 'BASH_VERSION=%s\\n' \"$BASH_VERSION\"", timeout=10)
        preflight = stdout.read().decode()
        diagnostic = stderr.read().decode()
        if stdout.channel.recv_exit_status() != 0 or not preflight.startswith("Linux ") or not re.search(r"BASH_VERSION=4\.2\.", preflight):
            raise RuntimeError(f"peer is not Linux/Bash 4.2: {preflight!r} {diagnostic!r}")
    finally:
        client.close()

    cases = []
    for mode in ("nominal", "attach-timeout", "attach-evidence"):
        output = args.output / mode
        output.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="zw-linux42-worker-", dir="/tmp") as isolated:
            result = subprocess.run([str(args.runner.resolve()), str(args.port), isolated, mode], env=dict(os.environ, ZEROWORK_DATA_DIR=isolated), text=True, capture_output=True, timeout=65)
            (output / "stdout.log").write_text(result.stdout)
            (output / "stderr.log").write_text(result.stderr)
            shutil.copytree(isolated, output / "artifacts", dirs_exist_ok=True)
        cases.append({"mode": mode, "passed": result.returncode == 0 and f"SHELL_EXECUTION_PASS mode={mode}" in result.stderr, "returncode": result.returncode})

    report = {
        "passed": all(case["passed"] for case in cases),
        "host_worker_platform": platform.system(),
        "target": preflight.strip().splitlines(),
        "cases": cases,
        "scope": "Production Session/SshWorker/VT/recording over SSH to an isolated Linux kernel and a real Bash 4.2 process; nominal execution, payload-ACK timeout/cancel barrier/same-PTY retry, actual late remote output before first initializer write, input and Shell evidence fences",
        "limits": ["Peer provisioning and Linux distribution are recorded separately", "Does not certify arbitrary remote rc files or older Linux distributions", "Native UI and external model calls are not exercised"],
    }
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
