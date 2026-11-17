#!/usr/bin/env python3
import hashlib
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
VENDOR = ROOT / "vendor" / "zenit"
EXPECTED_COUNT = 3508
EXPECTED_SHA256 = "66cabdb315835611918e6d7c953fd8af03f08f3b8a9f4cc83bdd32d2ad77aaf2"

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
