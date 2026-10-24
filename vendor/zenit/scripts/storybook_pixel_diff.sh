#!/usr/bin/env bash
# Component refactor regression guard: screenshot each storybook story, compare baseline
# vs current build pixel-by-pixel.
#
# Usage:
#   bash scripts/storybook_pixel_diff.sh capture <storybook.app exe> <output dir>
#                                           [key,key,...]
#   bash scripts/storybook_pixel_diff.sh compare <baseline dir> <current dir>
#                                            [noise baseline dir]
#
# compare with a third dir (second baseline screenshot): stories noisy in the baseline
# itself (animation, cursor blink, time-related) are marked noisy, not counted as failed.
# Node tree (<key>.tree.json) is reported separately. Needs a test-mode build (`zig
# build -Dtest-mode=true storybook`) and a macOS session.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
capture)
    app="$2"; out="$3"; keys="${4:-}"
    mkdir -p "$out"; out="$(cd "$out" && pwd)"
    rpc="$(mktemp -d /tmp/zenit_sbshot_rpc.XXXXXX)"
    ZENIT_E2E_FILE_RPC_DIR="$rpc" ZENIT_E2E_ISOLATE_POINTER=1 "$app" >"$out/app.log" 2>&1 &
    pid=$!
    trap 'kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true; rm -rf "$rpc"' EXIT
    ZENIT_E2E_FILE_RPC_DIR="$rpc" ZENIT_SHOT_DIR="$out" ZENIT_SHOT_KEYS="$keys" bun e2e/storybook-shots.capture.ts
    ;;
compare)
    python3 - "$2" "$3" "${4:-}" <<'PY'
import sys, os, glob
from PIL import Image, ImageChops
base, cur, noise = sys.argv[1], sys.argv[2], sys.argv[3]
def diff(a, b):
    with Image.open(a) as x, Image.open(b) as y:
        x, y = x.convert("RGBA"), y.convert("RGBA")
        if x.size != y.size: return -1, None
        d = ImageChops.difference(x, y)
        m = d.getchannel("R")
        for c in "GBA": m = ImageChops.lighter(m, d.getchannel(c))
        return sum(v != 0 for v in m.tobytes()), m.getbbox()
bad = noisy = same = 0
for f in sorted(glob.glob(os.path.join(base, "*.png"))):
    k = os.path.basename(f)[:-4]
    g = os.path.join(cur, k + ".png")
    if not os.path.exists(g): print(f"MISSING {k}"); bad += 1; continue
    n, box = diff(f, g)
    tb, tc = os.path.join(base, k + ".tree.json"), os.path.join(cur, k + ".tree.json")
    tree = "tree=same" if os.path.exists(tb) and os.path.exists(tc) and open(tb).read() == open(tc).read() else "tree=DIFF"
    if n == 0: same += 1; continue
    if noise and os.path.exists(os.path.join(noise, k + ".png")) and diff(f, os.path.join(noise, k + ".png"))[0] != 0:
        noisy += 1; print(f"noisy {k}: {n}px {tree}"); continue
    bad += 1; print(f"DIFF  {k}: {n}px bbox={box} {tree}")
print(f"same={same} noisy={noisy} diff={bad}")
sys.exit(1 if bad else 0)
PY
    ;;
*) sed -n 2,11p "$0"; exit 64 ;;
esac
