#!/usr/bin/env python3
"""Actual SSH worker + Bash/Zsh PTY startup timing; only disposable loopback IO."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from ssh_shell_execution_loopback import Fixture


def run(runner, shell, mode, output):
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="zw-startup-", dir="/tmp") as directory:
        home = Path(directory) / "home"
        home.mkdir()
        delay = "6" if mode == "startup-timeout" else ".15"
        if Path(shell).name == "bash":
            # Delay after hook installation, between the final init ACK and B.
            rc = f"PROMPT_COMMAND='if [[ -n ${{__zw_osc_version-}} ]]; then sleep {delay}; fi'\nPS1='fixture> '\n"
            (home / ".bashrc").write_text(rc)
        else:
            rc = f"precmd() {{ if [[ -n ${{__zw_osc_version-}} ]]; then sleep {delay}; fi; }}\nPROMPT='fixture> '\n"
            (home / ".zshrc").write_text(rc)
        fixture = Fixture(shell, mode, str(home))
        try:
            result = subprocess.run([runner, str(fixture.port), directory, mode], capture_output=True, text=True, timeout=30, env={**os.environ, "ZEROWORK_DATA_DIR": directory})
        finally:
            fixture.close()
        (output / "runner.log").write_text(result.stderr)
        (output / "pty-input.bin").write_bytes(fixture.inputs)
        (output / "pty-output.bin").write_bytes(fixture.outputs)
        checks = {"runner": result.returncode == 0 and "SHELL_EXECUTION_PASS" in result.stderr, "one_shell": len(fixture.transports) == 1, "no_peer_errors": not fixture.errors}
        if mode == "startup-prompts":
            for command in [b"cd /tmp", b"export ZW_STARTUP_SEQ=ok", b"printf 'INITIAL_%s"]:
                checks[command.decode() + " sent once"] = fixture.inputs.count(command) == 1
                checks[command.decode() + " echoed once"] = fixture.outputs.count(command) == 1
            checks["executed_in_order"] = b"STARTUP_/tmp/ok" in fixture.outputs and b"INITIAL_once" in fixture.outputs
        else:
            checks["remaining_commands_unsent"] = b"FORBIDDEN_" not in fixture.inputs
            checks["human_input_resumed"] = b"ANSWER_answer" in fixture.outputs if mode == "startup-interactive" else b"MANUAL_ready" in fixture.outputs
        checks["isolated_rc_unchanged"] = {p.name: p.read_bytes() for p in home.iterdir()} == fixture.initial_home_files
        report = {"shell": shell, "mode": mode, "passed": all(checks.values()), "checks": checks, "returncode": result.returncode, "errors": fixture.errors}
        (output / "report.json").write_text(json.dumps(report, indent=2))
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    reports = [run(str(Path(args.runner).resolve()), shell, mode, args.output / (Path(shell).name + "-" + mode)) for shell in ["/bin/bash", "/bin/zsh"] for mode in ["startup-prompts", "startup-timeout", "startup-interactive"]]
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "report.json").write_text(json.dumps(reports, indent=2))
    print(json.dumps(reports, indent=2))
    raise SystemExit(0 if all(r["passed"] for r in reports) else 1)


if __name__ == "__main__":
    main()
