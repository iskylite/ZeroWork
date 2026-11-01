#!/usr/bin/env python3
"""Pass one hidden, in-memory connection JSON line to the native runner.

No target, username, known_hosts path, fingerprint or password is accepted in
argv or the environment. The JSON is never written to a file or echoed.
The child performs all schema, trust, route and read-only checks itself.
"""
import argparse
import getpass
import json
from pathlib import Path
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate-stdin", action="store_true")
    parser.add_argument("--binary", type=Path, help="Use a separately built acceptance runner")
    options = parser.parse_args()
    if not sys.stdin.isatty():
        print("An interactive TTY is required for hidden stdin input.", file=sys.stderr)
        return 2
    try:
        text = getpass.getpass("Connection JSON (hidden; memory only): ")
    except (KeyboardInterrupt, EOFError):
        print("Input cancelled; no native process started.", file=sys.stderr)
        return 130
    try:
        value = json.loads(text)
        if not isinstance(value, dict) or value.get("acceptance_mode", "read_only") != "read_only" or any(key in value for key in ("operator_approval", "click_target", "interactive_seconds")):
            raise ValueError("read-only connection input required")
        value["acceptance_mode"] = "read_only"
        payload = bytearray((json.dumps(value, separators=(",", ":")) + "\n").encode())
    except (ValueError, TypeError, UnicodeError):
        print("Invalid connection JSON.", file=sys.stderr)
        return 2
    finally:
        text = ""
    executable = options.binary.resolve() if options.binary else Path(__file__).resolve().parents[1] / "zig-out/bin/bmc-live-readonly"
    args = [str(executable)]
    if options.validate_stdin:
        args.append("--validate-stdin")
    child = None
    try:
        child = subprocess.Popen(args, stdin=subprocess.PIPE, start_new_session=True)
        child.stdin.write(payload)
        child.stdin.close()
        payload[:] = b"\0" * len(payload)
        value = None
        return child.wait()
    except KeyboardInterrupt:
        # The ordinary window close or the runner's 60-second deadline owns
        # logout/cleanup. Do not kill its protocol worker midway through logout.
        if child is not None:
            return child.wait()
        return 130
    finally:
        payload[:] = b"\0" * len(payload)
        value = None


if __name__ == "__main__":
    raise SystemExit(main())
