#!/usr/bin/env bash
# GPU resource leak soak: measure RSS slope under continuous rendering, fail closed.
#
# Why: the framework defaults to `idle_skip_frames = true`, and an idle window barely commits
# frames, so an idle run never triggers GPU leaks (e.g. a Metal double retain). The soak must force
# every frame to commit. `zig build test` is not a substitute: the GPA leak check is blind to the
# page_allocator fallback path; these bugs only show with a real window + continuous frame loop.
#
# Usage:
#   bash scripts/run_soak.sh [seconds] [max_kb_per_sec]
# Defaults: 30 seconds, threshold 40 KB/s.
#
# Note: needs a real WindowServer (local dev environment); headless CI can't run it. The CI-side
# equivalent gate is the `zig build test` GPA leak check + standalone table reclaim assertion.

set -euo pipefail

DURATION="${1:-30}"
MAX_KB_PER_SEC="${2:-40}"
EXAMPLE_SRC="examples/hello_button/main.zig"
BACKUP="$(mktemp -t zenit_soak_backup)"
APP=""

stop_app() {
    local pid="$1"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then return; fi
    kill "$pid" 2>/dev/null || true
    local attempt=0
    while kill -0 "$pid" 2>/dev/null && [[ $attempt -lt 20 ]]; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

cleanup() {
    # always restore temporarily-modified example regardless of success/failure
    if [[ -f "$BACKUP" ]]; then
        cp "$BACKUP" "$EXAMPLE_SRC"
        rm -f "$BACKUP"
    fi
    stop_app "$APP"
}
trap cleanup EXIT

if [[ ! -f "$EXAMPLE_SRC" ]]; then
    echo "ERROR: $EXAMPLE_SRC not found (run from repo root)" >&2
    exit 2
fi
cp "$EXAMPLE_SRC" "$BACKUP"

# turn off idle gating -- otherwise entire soak is meaningless (see file header).
if ! grep -q "idle_skip_frames" "$EXAMPLE_SRC"; then
    /usr/bin/sed -i '' \
        's|\.window = \.{ \.width = 640, \.height = 480, \.title = "Hello Button" },|&\
        .idle_skip_frames = false, // soak: 强制每帧提交|' \
        "$EXAMPLE_SRC"
fi
grep -q "idle_skip_frames = false" "$EXAMPLE_SRC" || {
    echo "ERROR: failed to disable idle_skip_frames — soak would be a no-op" >&2
    exit 2
}

echo "Building hello-button (idle_skip_frames=false)…"
zig build hello-button >/dev/null

BIN="zig-out/Hello Button.app/Contents/MacOS/hello_button"
test -x "$BIN" || { echo "ERROR: $BIN not executable" >&2; exit 2; }

"$BIN" >/dev/null 2>&1 &
APP=$!
sleep 3 # skip startup one-time allocations (fonts/atlas/pipeline)

if ! kill -0 "$APP" 2>/dev/null; then
    echo "ERROR: app died during startup" >&2
    exit 1
fi

BASE_RSS=$(ps -o rss= -p "$APP" | tr -d ' ')
echo "baseline rss=${BASE_RSS}KB, sampling for ${DURATION}s…"

# use second-half slope not total growth: after startup still one-time allocation (font atlas
# expansion, lazy PSO creation, texture pool warmup) raises RSS then flattens. Real per-frame leak
# is **continuously linear**, second-half slope also high; one-time allocation second-half slope
# near 0. Catches 275 KB/s linear leak while not hurt by normal warmup.
elapsed=0
step=5
HALF=$((DURATION / 2))
MID_RSS=""
while [[ $elapsed -lt $DURATION ]]; do
    sleep $step
    elapsed=$((elapsed + step))
    if ! kill -0 "$APP" 2>/dev/null; then
        echo "ERROR: app died after ${elapsed}s (crash or drawable starvation)" >&2
        exit 1
    fi
    RSS=$(ps -o rss= -p "$APP" | tr -d ' ')
    echo "  t=${elapsed}s rss=${RSS}KB (+$((RSS - BASE_RSS))KB)"
    if [[ -z "$MID_RSS" && $elapsed -ge $HALF ]]; then
        MID_RSS="$RSS"
        MID_T="$elapsed"
    fi
done

FINAL_RSS=$(ps -o rss= -p "$APP" | tr -d ' ')
stop_app "$APP"
APP=""

GROWTH=$((FINAL_RSS - BASE_RSS))
: "${MID_RSS:=$BASE_RSS}"
: "${MID_T:=0}"
TAIL_SECS=$((DURATION - MID_T))
[[ $TAIL_SECS -gt 0 ]] || TAIL_SECS=1
TAIL_GROWTH=$((FINAL_RSS - MID_RSS))
RATE=$(awk -v g="$TAIL_GROWTH" -v d="$TAIL_SECS" 'BEGIN{printf "%.1f", g/d}')

echo
echo "total growth=${GROWTH}KB over ${DURATION}s"
echo "tail slope (last ${TAIL_SECS}s)=${TAIL_GROWTH}KB → ${RATE} KB/s (threshold ${MAX_KB_PER_SEC} KB/s)"

if awk -v r="$RATE" -v m="$MAX_KB_PER_SEC" 'BEGIN{exit !(r > m)}'; then
    echo "SOAK FAILED: RSS growth ${RATE} KB/s exceeds ${MAX_KB_PER_SEC} KB/s." >&2
    echo "  Likely a per-frame GPU object leak (an MTL object created each frame without release)." >&2
    exit 1
fi

echo "Soak passed."
