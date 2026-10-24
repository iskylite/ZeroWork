"""Real pipe/process exit regressions. Pass current yix-lsp executable as argv[1]."""
import json
import pathlib
import subprocess
import sys
import tempfile
import time

binary = sys.argv[1]
with tempfile.TemporaryDirectory() as directory:
    stub = pathlib.Path(directory) / "zls"
    for code, limit, label in [
        ("import os,time\nos.close(1)\ntime.sleep(60)\n", 5, "stdout closed before ZLS process exit"),
        ("import time\ntime.sleep(60)\n", 7, "ZLS ignores stdin EOF; watchdog kills child"),
    ]:
        stub.write_text("#!" + sys.executable + "\n" + code)
        stub.chmod(0o755)
        start = time.monotonic()
        result = subprocess.run([binary, "--zls", str(stub)], input=b"", capture_output=True, timeout=limit)
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert b"error.EndOfStream" not in result.stderr, result.stderr
        print("PASS %s (%.2fs)" % (label, time.monotonic() - start))
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}).encode()
    frame = b"Content-Length: %d\r\n\r\n" % len(body) + body
    result = subprocess.run([binary, "--zls", str(pathlib.Path(directory) / "missing")], input=frame, capture_output=True, timeout=5)
    assert result.returncode == 0 and b"capabilities" in result.stdout, result
    assert b"error.EndOfStream" not in result.stderr, result.stderr
    print("PASS no-ZLS fallback initialize and clean EOF")
