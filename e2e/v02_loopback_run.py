"""Run the real native acceptance client against an owned loopback SSH peer."""
import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--binary", required=True)
parser.add_argument("--sha", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--shared-challenge", action="store_true")
parser.add_argument("--sftp-ai", action="store_true")
parser.add_argument("--ai-config")
parser.add_argument("--fresh-ai-chat", action="store_true")
parser.add_argument("--continuous-ai", action="store_true")
args = parser.parse_args()
assert not args.continuous_ai or (args.sftp_ai and not args.fresh_ai_chat)
assert not args.sftp_ai or args.ai_config, "--sftp-ai requires private --ai-config"
workspace = Path(__file__).resolve().parent.parent
out = Path(args.out).resolve()
out.mkdir(parents=True, exist_ok=True)
assert not (out / "report.json").exists(), "Preserve earlier attempts in separate directories"
state = Path(tempfile.mkdtemp(prefix="zw-v02-loopback-", dir="/tmp"))
root = Path("/tmp/zerowork-unified-" + secrets.token_hex(8))
root.mkdir(mode=0o700)
peer_log = (out / "peer.log").open("w")
server = subprocess.Popen(["python3", str(workspace / "e2e/v02_loopback_server.py"),
                           "--state-dir", str(state), "--root", str(root)],
                          stdout=peer_log, stderr=peer_log)
result = None
try:
    for _ in range(100):
        if (state / "ready.json").exists():
            break
        assert server.poll() is None, "Owned peer failed to start"
        time.sleep(0.05)
    assert (state / "ready.json").exists(), "Owned peer startup timed out"
    assert (state / "private.json").stat().st_mode & 0o077 == 0
    env = dict(os.environ, ZEROWORK_ACCEPTANCE_CONFIG=str(state / "private.json"),
               ZEROWORK_ACCEPTANCE_REMOTE_DIR=str(root))
    command = ["node", "e2e/v02_run.mjs", "vm", "--binary", str(Path(args.binary).resolve()),
               "--expected-sha", args.sha, "--out", str(out)]
    if args.shared_challenge:
        command.extend(["--shared-challenge", "1"])
    if args.sftp_ai:
        command.extend(["--sftp-ai", "1", "--ai-config", str(Path(args.ai_config).resolve())])
    if args.fresh_ai_chat:
        assert args.sftp_ai
        command.extend(["--fresh-ai-chat", "1"])
    if args.continuous_ai:
        command.extend(["--continuous-ai", "1"])
    result = subprocess.run(command, cwd=workspace, env=env)
finally:
    server.terminate()
    try:
        server.wait(timeout=8)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait()
    peer_log.close()
    for source, destination in (("ready.json", "peer-ready.json"), ("audit.jsonl", "peer-audit.jsonl")):
        if (state / source).exists():
            shutil.copyfile(state / source, out / destination)
    shutil.rmtree(root)
    shutil.rmtree(state)
    (out / "peer-cleanup.json").write_text(json.dumps({
        "environment": "controlled_loopback_paramiko_not_user_vm",
        "peer_exit_code": server.returncode,
        "runner_exit_code": None if result is None else result.returncode,
        "owned_root_removed": not root.exists(), "private_data_removed": not state.exists(),
    }, indent=2))
if result is not None:
    raise SystemExit(result.returncode)
