#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

printf '%s\n' "[gate] checking tracked vendor integrity"
python3 scripts/verify_vendor_zenit.py
printf '%s\n' "[gate] rebuilding pinned SSH dependencies"
./scripts/build_ssh_deps.sh
printf '%s\n' "[gate] running Zig 0.17 unit and contract tests"
./scripts/test_isolated.sh test
printf '%s\n' "[gate] all source gates passed"
# Keep generated dependency outputs out of the working tree after verification.
git clean -fd vendor/libssh2 zig-pkg
