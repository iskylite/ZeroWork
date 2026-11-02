#!/usr/bin/env python3
"""Explicit, fixed-plan native KVM acceptance; credentials stay in stdin memory.

This runs the production generic tool gateway against the local native BMC
session. Images stay local: this wrapper does not configure a model/provider.
The native runner validates the operator approval, limits actions and owns its
bounded disconnect/logout deadline. Default read-only usage remains in
bmc_live_readonly.py.
"""
import argparse
import getpass
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def prepare_payload(value: object, phase: str, deadline_seconds: int = 180) -> bytearray:
    if not isinstance(value, dict):
        raise ValueError("connection JSON must be an object")
    # Control approval comes from the explicit phase flag, never a hidden
    # boolean left in an old connection JSON document.
    if any(key in value for key in ("acceptance_mode", "operator_approval", "interactive_seconds")):
        raise ValueError("connection JSON must not contain a control approval")
    if phase == "safe-interaction":
        if "click_target" in value:
            raise ValueError("the safe plan does not accept a click target")
        value["acceptance_mode"] = "safe_interaction"
        value["operator_approval"] = "safe_shift_and_pointer"
    elif phase == "native-interactive":
        if "click_target" in value or not 30 <= deadline_seconds <= 900:
            raise ValueError("invalid native interactive parameters")
        value["acceptance_mode"] = "native_interactive"
        value["operator_approval"] = "native_view_and_observed_actions"
        value["interactive_seconds"] = deadline_seconds
    elif phase == "ai-pointer-click":
        point = value.get("click_target")
        if not isinstance(point, dict) or set(point) != {"x", "y"}:
            raise ValueError("a single click target is required")
        if any(type(point[axis]) is not int or not 0 <= point[axis] < 8192 for axis in ("x", "y")):
            raise ValueError("invalid click target")
        value["acceptance_mode"] = "ai_pointer_click"
        value["operator_approval"] = "observed_screen_single_click"
    else:
        raise ValueError("unsupported phase")
    return bytearray((json.dumps(value, separators=(",", ":")) + "\n").encode())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", required=True, choices=("safe-interaction", "ai-pointer-click", "native-interactive"))
    parser.add_argument("--validate-stdin", action="store_true")
    parser.add_argument("--deadline-seconds", type=int, default=180, help="Native interactive deadline: 30–900 seconds, plus 10 seconds cleanup")
    parser.add_argument("--binary", type=Path, help="Use a separately built acceptance runner")
    options = parser.parse_args()
    if not sys.stdin.isatty():
        print("An interactive TTY is required for hidden stdin input.", file=sys.stderr)
        return 2
    if options.phase == "safe-interaction":
        print("Approved fixed plan: local observations; synthetic runner ContentContext Shift tap and pointer move; observe; AI Shift tap and pointer move. No click. This phase does not verify native View event handling.", file=sys.stderr)
    elif options.phase == "native-interactive":
        print("Native View phase: the operator clicks the real video, taps Shift, moves the mouse, and releases with Ctrl+Alt+Escape. No automatic input.", file=sys.stderr)
        print("After inspecting the current local observation, private /app/bmc-live/command permits one observed pointer action or Shift. Fixed text_probe (codex-kvm-check, no Enter) and separate clear_line (Ctrl+U) additionally require observed_idle_prompt=true. No OS credential or arbitrary text command is accepted.", file=sys.stderr)
        print(f"Interaction deadline: {options.deadline_seconds}s; cleanup reserve: 10s. finish performs normal disconnect/logout.", file=sys.stderr)
    else:
        print("Explicit click phase: use only after reviewing the actual remote screen. One left-button click at click_target; no keyboard input.", file=sys.stderr)
    try:
        text = getpass.getpass("Connection JSON (hidden; memory only): ")
    except (KeyboardInterrupt, EOFError):
        print("Input cancelled; no native process started.", file=sys.stderr)
        return 130
    value = None
    payload = bytearray()
    try:
        value = json.loads(text)
        payload = prepare_payload(value, options.phase, options.deadline_seconds)
    except (ValueError, TypeError, UnicodeError):
        print("Invalid connection JSON or unsafe phase parameters.", file=sys.stderr)
        return 2
    finally:
        text = ""
        value = None
    executable = options.binary.resolve() if options.binary else Path(__file__).resolve().parents[1] / "zig-out/bin/bmc-live-readonly"
    args = [str(executable)]
    if options.validate_stdin:
        args.append("--validate-stdin")
    child = None
    receipt_path = None
    try:
        # The receipt contains only native runner's redacted scalar JSON lines.
        # Never persist the connection JSON, image bytes or arbitrary stderr.
        fd, receipt_path = tempfile.mkstemp(prefix="zerowork-bmc-control-receipt-", suffix=".jsonl", dir="/tmp")
        os.chmod(receipt_path, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as receipt:
            child_env = os.environ.copy()
            if options.phase == "native-interactive" and not options.validate_stdin:
                rpc_path = tempfile.mkdtemp(prefix="zerowork-bmc-live-native-rpc-", dir="/tmp")
                os.chmod(rpc_path, 0o700)
                child_env["ZENIT_E2E_FILE_RPC_DIR"] = rpc_path
                # Zenit test-mode otherwise forces cx.window_active=true for
                # screenshot fixtures. Native acceptance must retain real OS
                # activation and blur instead of that synthetic appearance.
                child_env["ZENIT_E2E_REAL_ACTIVATION"] = "1"
                # Native input/focus must be observed from the real foreground
                # window. This phase never sets window_active or fake focus.
                for key in ("ZENIT_E2E_BACKGROUND", "ZENIT_E2E_ISOLATE_POINTER", "ZENIT_E2E_ISOLATE_KEYBOARD"):
                    child_env.pop(key, None)
                print(f"Private test RPC (no connection JSON or credentials): {rpc_path}", file=sys.stderr)
            child = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True, env=child_env)
            child.stdin.write(payload)
            child.stdin.close()
            payload[:] = b"\0" * len(payload)
            while True:
                try:
                    line = child.stdout.readline()
                except KeyboardInterrupt:
                    # The runner owns the bounded logout. Do not terminate its
                    # worker while a remote key release or DELETE is in flight.
                    continue
                if not line:
                    break
                rendered = line.decode("utf-8", errors="replace")
                sys.stderr.write(rendered)
                if rendered.startswith("BMC_LIVE "):
                    try:
                        safe_event = json.loads(rendered[len("BMC_LIVE "):])
                    except ValueError:
                        continue
                    receipt.write(json.dumps(safe_event, separators=(",", ":")) + "\n")
                    receipt.flush()
            result = child.wait()
        print(f"Redacted receipt: {receipt_path}", file=sys.stderr)
        return result
    except OSError:
        print("Native acceptance process could not start or receipt IO failed.", file=sys.stderr)
        if child is not None:
            return child.wait()
        return 2
    finally:
        payload[:] = b"\0" * len(payload)
        value = None


if __name__ == "__main__":
    raise SystemExit(main())
