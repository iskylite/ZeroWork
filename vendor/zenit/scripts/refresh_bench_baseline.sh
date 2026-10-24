#!/usr/bin/env bash
# Resample src/bench/baselines/main.json -- the bench gate comparison baseline.
#
# -- Why this script --
# The baseline is a manual artifact with no auto-update. An untraceable baseline makes a red gate
# indistinguishable between code regression and machine change, which trains everyone to ignore the
# gate.
#
# Bench JSON carries commit/host/unix_time fields (see runner.zig); this script fills them
# correctly.
#
# Usage: bash scripts/refresh_bench_baseline.sh; afterwards the commit message **must** explain why
# you resampled (real perf change? machine swap? new bench?), else the next red is again
# unexplainable.
#
# Exit: 0 success.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: 工作树不干净。baseline 必须在干净树上采，否则记录的 commit 对不上实际测的代码。" >&2
    exit 1
fi

COMMIT="$(git rev-parse --short HEAD)"
HOST="$(uname -m)-$(sw_vers -productVersion 2>/dev/null || uname -s)"

echo "在 $COMMIT ($HOST) 上重采 baseline…"
ZENIT_BENCH_COMMIT="$COMMIT" ZENIT_BENCH_HOST="$HOST" \
    zig build bench -- json=src/bench/baselines/main.json

echo
echo "完成。新 baseline:"
head -4 src/bench/baselines/main.json
echo
echo "⚠ 提交前请在 commit message 里写明重采原因。"
