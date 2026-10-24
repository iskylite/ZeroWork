#!/usr/bin/env bash
# Style literal ratchet: **bare** color/font-size literals in examples/ may only decrease.
# Convention (docs/STYLING.md): view code consumes tokens (styles.zig named style functions) and
# doesn't write bare `Color.hex(...)` / `.font_size = <number>` literals.
#
# Intentional off-token values use the `ui.arb.px(...)` / `ui.arb.hex(...)` escape hatch (parallel
# to Panda arbitrary values); these don't match the regex below and pass.
#
# Storybook is excepted: it is a component gallery with deliberate style demos.
#
# .yix view files also count (style blocks can hold file-level Zig); .yss style recipes count per
# their syntax (`#rrggbb` / `font-size: <number>`). Ratchet only until baseline reaches 0; tighten
# BASELINE whenever the count drops.
#
# Exit codes: 0 pass; 1 literal count exceeds baseline; 2 script error

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 2026-10-03: all non-storybook examples dropped to zero.
BASELINE=0

scan() {
    rg -n "$@" -g '!examples/storybook/**' examples || {
        status=$?
        # rg 1 means no match; zero literals pass, tool error means script failure.
        if (( status != 1 )); then exit 2; fi
    }
}
zig_hits=$(scan -g '*.zig' -g '*.yix' 'Color\.hex\(|\.font_size = [0-9]')
yss_hits=$(scan -g '*.yss' '#[0-9a-fA-F]{6}\b|font-size: *[0-9]')
matches=$(printf '%s\n%s' "$zig_hits" "$yss_hits" | sed '/^$/d')
count=0
if [[ -n "$matches" ]]; then
    count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
fi

if (( count > BASELINE )); then
    echo "[FAIL] examples/ 样式字面量 ${count} 处 > 基线 ${BASELINE}"
    echo "       新增的字面量请改走 token（styles.zig 具名样式函数，见 docs/STYLING.md）："
    printf '%s\n' "$matches"
    exit 1
fi

echo "[ok] examples/ 样式字面量 ${count} 处 (基线 ${BASELINE})"
if (( count < BASELINE )); then
    echo "     基线可收紧：BASELINE=${count}（scripts/check_style_literals.sh）"
fi
