#!/usr/bin/env python3
"""Yix CLI output contracts: build progress must not look like an error."""
import pathlib
import subprocess
import sys
import tempfile

exe = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="zenit-yix-output-") as folder:
    root = pathlib.Path(folder)
    source = root / "styles.yss"
    source.write_text('const ui = @import("ui");\nstyle root { padding: 8; }\n')
    stamp = root / "generated.ok"
    result = subprocess.run([str(exe), "gen", "--stamp", str(stamp), str(root)], capture_output=True)
    assert result.returncode == 0, result.stderr.decode()
    assert result.stderr == b"" and result.stdout == b"", (result.stdout, result.stderr)
    assert stamp.read_text() == "1\n"
    assert (root / "_styles.yss.zig").is_file()

    result = subprocess.run([str(exe), "gen", str(root)], capture_output=True)
    assert result.returncode == 0, result.stderr.decode()
    assert result.stderr == b"", result.stderr
    assert result.stdout == b"yix gen: 1 file(s)\n", result.stdout

    source.write_text('const ui = @import("ui");\nstyle root { unsupported-property: 8; }\n')
    stamp.unlink()
    result = subprocess.run([str(exe), "gen", "--stamp", str(stamp), str(root)], capture_output=True)
    assert result.returncode != 0
    assert result.stderr, "Real errors must retain stderr diagnostics"
    assert not stamp.exists(), "Failed generation must not publish a success stamp"
print("Yix CLI output contracts: 3/3 PASS")
