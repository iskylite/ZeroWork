#!/usr/bin/env python3
"""Disposable real SSH/PTY peer for AppHost explicit disconnect acceptance."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
from ssh_bootstrap_loopback import Fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["independent", "shared"], required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    fixture = Fixture("independent")
    try:
        with tempfile.TemporaryDirectory(prefix="zw-disconnect-", dir="/tmp") as directory:
            environment = dict(os.environ, ZEROWORK_DATA_DIR=directory)
            result = subprocess.run([args.runner, str(fixture.port), args.mode], env=environment, capture_output=True, text=True, timeout=35)
            (args.output / "stdout.log").write_text(result.stdout)
            (args.output / "stderr.log").write_text(result.stderr)
            inputs = b"".join(bytes(value) for value in fixture.inputs.values())
            report = {"status": "passed" if result.returncode == 0 and not fixture.errors else "failed", "returncode": result.returncode, "mode": args.mode, "transports": len(fixture.transports), "actions": fixture.actions, "errors": fixture.errors, "terminal_input": inputs.decode(errors="replace"), "checks": ["production AppHost and WorkerThread accepted pending then actual cleanup receipt", "same request operation has one disconnect entry", "tab/runtime/VT/output survive disconnect", "old exec binding and ordinary buffered input are rejected", "automatic reconnect stays disabled despite enabled fixture configuration", "explicit reconnect uses a new generation without reviving old binding"], "limits": ["Controlled loopback and real disposable zsh PTY only; no native App window/provider/user host or credentials."]}
            if args.mode == "shared":
                report["checks"].append("sibling shell remains writable after current channel release")
            if b"NEVER_AFTER_DISCONNECT" in inputs or b"NEVER_BUFFERED_AFTER_DISCONNECT" in inputs:
                report["status"] = "failed"
            (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            assert report["status"] == "passed", report
    finally:
        fixture.close()


if __name__ == "__main__":
    main()
