#!/usr/bin/env python3
"""Real product open_session and AI execution over a no-upload SSH fixture.

Build with `zig build ssh-shell-product-acceptance
-Dtest-filter='lifecycle default shell integration opens SSH work terminal'`.
This launches no native window and never accesses an external host.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

import paramiko
import ssh_shell_execution_loopback as loopback


class ProductPeer(loopback.Peer):
    def check_auth_password(self, user, password):
        return paramiko.AUTH_SUCCESSFUL if user == "bootstrap-fixture" and password == "fixture-only" else paramiko.AUTH_FAILED

    def check_channel_shell_request(self, channel):
        self.fixture.actions.append([channel.chanid, "shell"])
        self.fixture.spawn(DelayedPromptChannel(channel, self.fixture) if self.fixture.delay_prompts else channel)
        return True


class DelayedPromptChannel:
    """Deliver the real shell's D receipt before its following A/B prompt."""
    def __init__(self, channel, fixture):
        self.channel, self.fixture, self.after_end = channel, fixture, False

    def __getattr__(self, name):
        return getattr(self.channel, name)

    def sendall(self, data):
        end = data.find(b"\x1b]133;D;")
        if end >= 0:
            self.after_end = True
        prompt = data.find(b"\x1b]133;A", max(0, end))
        if self.after_end and prompt >= 0:
            self.channel.sendall(data[:prompt])
            self.fixture.delayed_prompt_count += 1
            time.sleep(0.3)
            self.channel.sendall(data[prompt:])
            self.after_end = False
        else:
            self.channel.sendall(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--delay-prompts", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    loopback.Peer = ProductPeer
    with tempfile.TemporaryDirectory(prefix="zw-bootstrap-product-shell-", dir="/tmp") as directory:
        home = Path(directory) / "shell-home"
        home.mkdir()
        fixture = loopback.Fixture("/bin/zsh", "nominal", str(home))
        fixture.delay_prompts = args.delay_prompts
        fixture.delayed_prompt_count = 0
        try:
            env = os.environ.copy()
            env.update(ZW_TEST_BOOTSTRAP_PRODUCT_PORT=str(fixture.port), ZEROWORK_DATA_DIR=directory)
            result = subprocess.run([str(args.runner.resolve())], env=env, capture_output=True, text=True, timeout=50)
        finally:
            fixture.close()
        (args.output / "stdout.log").write_text(result.stdout)
        (args.output / "stderr.log").write_text(result.stderr)
        (args.output / "pty-input.bin").write_bytes(fixture.inputs)
        (args.output / "pty-output.bin").write_bytes(fixture.outputs)
        shells = [row for row in fixture.actions if row[1] == "shell"]
        checks = {"product_test_passed": result.returncode == 0 and "lifecycle default shell integration opens SSH work terminal" in result.stderr and "SKIP" not in result.stderr, "real_ai_run_wait_and_input": "SHELL_PRODUCT_AI_PASS run=3 wait=true input=text+enter same_session=true source=shell_reported exits=0,7,0" in result.stderr, "one_shared_transport": len(fixture.transports) == 1, "source_and_owned_shell": len(shells) == 2, "no_helper_upload_or_exec": not fixture.errors, "no_shell_configuration_written": not list(home.iterdir())}
        checks["zero_byte_mouse_and_modifier_preserve_prompt"] = "SHELL_PRODUCT_NOOP_INPUT_PASS mouse_bytes=0 modifier_bytes=0 epoch_unchanged=true ready=true" in result.stderr
        checks["draft_and_ctrl_u_remain_protected_until_real_prompt"] = "SHELL_PRODUCT_DRAFT_GATE_PASS draft_blocked=true ctrl_u_still_blocked=true ctrl_c_shell_prompt_restored=true same_session=true" in result.stderr
        checks["blocked_draft_was_never_executed"] = b"NEVER_ADMITTED" not in fixture.inputs and b"printf NEVER_EXECUTE_DRAFT\x15\x03" in fixture.inputs
        checks["task_model_input_and_recording_settled"] = "SHELL_PRODUCT_SETTLED model_done=true input_released=true recordings_settled=true" in result.stderr
        checks["takeover_observer_natural_finish_and_settlement"] = "SHELL_PRODUCT_TAKEOVER_PASS same_execution=true natural_end=true complete_output=true task_settled=true" in result.stderr
        checks["ai_lease_rejects_write_key_ctrl_c_and_paste_without_pending"] = "SHELL_PRODUCT_READONLY_PASS write=true key=true ctrl_c=true paste=true pending=0 sequence_unchanged=true epoch_unchanged=true" in result.stderr
        checks["takeover_accepts_fresh_human_paste_without_replaying_old_payload"] = "SHELL_PRODUCT_HUMAN_INPUT_PASS old_payload=0 new_paste=true enter=true same_execution=true" in result.stderr
        checks["rejected_readonly_payload_never_reached_pty"] = b"NEVER_READONLY_WRITE" not in fixture.inputs and b"NEVER_READONLY_PASTE" not in fixture.inputs
        if args.delay_prompts:
            checks["real_shell_prompt_delayed_after_completion"] = fixture.delayed_prompt_count >= 3
        report = {"passed": all(checks.values()), "checks": checks, "returncode": result.returncode, "actions": fixture.actions, "errors": fixture.errors, "scope": "Actual Controller/AppHost/ConnectJob/Worker lifecycle plus ai_execution_backend Context, Driver, Bridge and approval broker: open_session then three run/wait commands, AI input, read-only ordinary write/key/Ctrl-C/paste rejection, and fresh human paste+Enter after takeover in the same SSH shell", "limits": ["Headless real host tool runtime: no external model/provider invocation or native UI", "Controlled Darwin zsh5.9 login; no Linux/bash4.2 server or arbitrary rc accessed", "The existing test environment variable prefix is retained for compatibility; no Bootstrap is requested"]}
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
        raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
