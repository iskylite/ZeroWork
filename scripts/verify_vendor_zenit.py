#!/usr/bin/env python3
import hashlib
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
VENDOR = ROOT / "vendor" / "zenit"
EXPECTED_COUNT = 3507
EXPECTED_SHA256 = "e245e28f73d0d4ba3f90652d23fa95cf4fcaa20e6529207720f38bbf66c4b64a"

paths = subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "vendor/zenit"], cwd=ROOT, text=True
).splitlines()
paths = sorted(set(paths))

digest = hashlib.sha256()
for tracked in sorted(paths):
    path = ROOT / tracked
    relative = path.relative_to(VENDOR).as_posix().encode()
    data = path.read_bytes()
    digest.update(len(relative).to_bytes(8, "big"))
    digest.update(relative)
    digest.update(len(data).to_bytes(8, "big"))
    digest.update(data)

actual = digest.hexdigest()
if len(paths) != EXPECTED_COUNT or actual != EXPECTED_SHA256:
    print(
        f"Zenit vendor verification failed: files={len(paths)} sha256={actual}",
        file=sys.stderr,
    )
    raise SystemExit(1)
print(f"Zenit vendor verified: files={len(paths)} sha256={actual}")
