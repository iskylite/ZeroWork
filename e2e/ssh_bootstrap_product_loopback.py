#!/usr/bin/env python3
"""Exercise real product Controller/AppHost/ConnectJob/SSH Bootstrap wiring.

Uses the existing restricted loopback peer and fixture credentials only. The
single product metadata command runs verbatim in a clean noninteractive sh;
user profiles and credentials are not read. No native app window is opened.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import ssh_bootstrap_loopback as loopback

BasePeer = loopback.Peer


class ProductPeer(BasePeer):
    def check_channel_exec_request(self, channel, command):
        if command.startswith(b"LC_ALL=C; export LC_ALL; printf 'ZWBOOTSTRAP_PROBE_V1"):
            self.fixture.actions.append([channel.chanid, "product-platform-probe"])
            self.fixture.spawn(channel, ["/bin/sh", "-c", command.decode()], False)
            return True
        return super().check_channel_exec_request(channel, command)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["allow", "deny"], required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    loopback.Peer = ProductPeer
    fixture = loopback.Fixture("shared")
    try:
        with tempfile.TemporaryDirectory(prefix="zw-bootstrap-product-data-", dir="/tmp") as data:
            env = os.environ.copy()
            env.update(ZW_TEST_BOOTSTRAP_PRODUCT_PORT=str(fixture.port), ZW_TEST_BOOTSTRAP_PRODUCT_MODE=args.mode, ZEROWORK_DATA_DIR=data)
            result = subprocess.run([str(args.runner.resolve())], env=env, capture_output=True, text=True, timeout=45)
            (args.output / "stdout.log").write_text(result.stdout)
            (args.output / "stderr.log").write_text(result.stderr)
            leftovers = [path for path in fixture.roots if Path(path).exists()]
            probes = [a for a in fixture.actions if a[1] == "product-platform-probe"]
            shells = [a for a in fixture.actions if a[1] == "bootstrap-shell"]
            report = {
                "status": "passed" if result.returncode == 0 and not fixture.errors and not leftovers else "failed",
                "returncode": result.returncode, "mode": args.mode,
                "ssh_transports": len(fixture.transports), "actions": fixture.actions,
                "sftp": fixture.files, "errors": fixture.errors,
                "temporary_resource_leftovers": leftovers,
                "limits": ["Darwin arm64/zsh5.9 controlled loopback only.", "Real headless product Controller/AppHost/ConnectJob/Worker path; no native App/Provider UI rendering evidence."],
            }
            (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            assert result.returncode == 0 and not fixture.errors and not leftovers, report
            assert len(fixture.transports) == 1 and len(probes) == 1, report
            if args.mode == "deny":
                assert not fixture.files and not shells, report
            else:
                assert len(shells) == 1 and fixture.files, report
            print(json.dumps(report, indent=2))
    finally:
        fixture.close()


if __name__ == "__main__":
    main()
