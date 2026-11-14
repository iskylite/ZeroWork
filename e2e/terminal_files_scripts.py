#!/usr/bin/env python3
"""Execute the production SSH file scripts in disposable directories, no SFTP.

Python is only the test harness; the shipped scripts use sh and native utilities.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
READ = (ROOT / "src/host/terminal_file_read.sh").read_text()
WRITE = (ROOT / "src/host/terminal_file_write.sh").read_text()

def invoke(script, *args, data=b""):
    return subprocess.run(["/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", "/bin/sh", "-c", script, "zw-file", *map(str, args)], input=data, capture_output=True, timeout=10)

def read(path, limit=65536, missing=False):
    result = invoke(READ, path, limit, int(missing))
    assert result.returncode == 0, result.stderr
    if result.stdout == b"ZWFILE1 absent\n":
        return b"", ""
    header, rest = result.stdout.split(b"\n", 1)
    stamp = header.removeprefix(b"ZWFILE1 ")
    size = int(stamp.split(b":")[2])
    assert rest[size:] == b"\nZWEND1 " + stamp + b"\n"
    return rest[:size], stamp.decode()

def main():
    with tempfile.TemporaryDirectory(prefix="zerowork-file-script-") as directory:
        root = Path(directory)
        missing_parent = root / "absent" / "verify_inner.sh"
        for failure in (
            invoke(READ, missing_parent, 65536, 1),
            invoke(WRITE, missing_parent, "create", 0, 1, "", data=b"x"),
        ):
            assert failure.returncode == 1 and not failure.stdout
            assert b"No such file or directory" in failure.stderr
            assert failure.stderr.endswith(b"\nZWFILEERROR1 InvalidParent\n")
        assert not missing_parent.parent.exists()

        path = root / "a 'quoted' $(touch INJECTED);.txt"
        content = b"\xef\xbb\xbfport=80\r\n" + b"x" * 65520
        assert len(content) <= 65536
        created = invoke(WRITE, path, "create", 0, len(content), "", data=content)
        assert created.returncode == 0 and created.stdout == b"ZWCOMMIT1\n", created.stderr
        assert path.read_bytes() == content
        assert not (root / "INJECTED").exists()
        assert (path.stat().st_mode & 0o777) == 0o600
        existing = invoke(WRITE, path, "create", 0, 3, "", data=b"bad")
        assert existing.returncode == 1 and existing.stderr.endswith(b"\nZWFILEERROR1 PathAlreadyExists\n")
        assert path.read_bytes() == content
        before, stamp = read(path)
        after = before.replace(b"port=80", b"port=90")
        changed = invoke(WRITE, path, "replace", len(before), len(after), stamp, data=before + after)
        assert changed.returncode == 0 and changed.stdout == b"ZWCOMMIT1\n", changed.stderr
        assert read(path)[0] == after
        stale = invoke(WRITE, path, "replace", len(before), 3, stamp, data=before + b"bad")
        assert stale.returncode != 0 and path.read_bytes() == after
        # Same size / same-second metadata can hide a change; cmp still rejects it.
        current, stamp = read(path)
        path.write_bytes(current.replace(b"90", b"91", 1))
        conflict = invoke(WRITE, path, "replace", len(current), 3, stamp, data=current + b"bad")
        assert conflict.returncode != 0 and b"91" in path.read_bytes()
        link = root / "symlink"
        link.symlink_to(path)
        assert invoke(READ, link, 65536, 0).returncode != 0
        assert invoke(WRITE, link, "create", 0, 3, "", data=b"bad").returncode != 0
        short = root / "short"
        incomplete = invoke(WRITE, short, "create", 0, 10, "", data=b"x")
        assert incomplete.returncode == 1 and incomplete.stderr.endswith(b"\nZWFILEERROR1 IncompleteInput\n")
        assert not short.exists()
        oversized = root / "too-big"
        oversized.write_bytes(b"x" * 65537)
        assert invoke(READ, oversized, 65536, 0).returncode != 0
        image = root / "image.png"
        pixels = bytes(range(256)) * 32
        image.write_bytes(pixels)
        assert read(image, 10000000)[0] == pixels
        protected = root / "readonly"
        protected.write_bytes(b"keep")
        protected.chmod(0o400)
        protected_bytes, protected_stamp = read(protected)
        denied = invoke(WRITE, protected, "replace", 4, 3, protected_stamp, data=protected_bytes+b"bad")
        assert denied.returncode != 0 and b"FileNotWritable" in denied.stderr
        assert protected.read_bytes() == b"keep"
        protected.chmod(0o600)
        fake_bin = root / "bin"
        fake_bin.mkdir()
        marker = root / "UNTRUSTED_PATH_EXECUTED"
        for tool in ("sh", "stat", "cp", "mv", "dd", "link"):
            fake = fake_bin / tool
            fake.write_text(f"#!/bin/sh\n/bin/echo compromised > '{marker}'\nexit 1\n")
            fake.chmod(0o700)
        previous_path = os.environ.get("PATH")
        try:
            os.environ["PATH"] = str(fake_bin)
            assert read(path)[0] == path.read_bytes()
            clean_target = root / "clean-environment"
            assert invoke(WRITE, clean_target, "create", 0, 4, "", data=b"safe").returncode == 0
            assert clean_target.read_bytes() == b"safe" and not marker.exists()
        finally:
            if previous_path is None: os.environ.pop("PATH", None)
            else: os.environ["PATH"] = previous_path
        assert not list(root.glob(".zerowork-file.*")), "temporary resources leaked"
    print("PASS: production sh scripts create/replace/read exact bytes, reject stale/existing/symlink/short/oversize inputs, preserve mode, and clean temporary files")

if __name__ == "__main__":
    main()
