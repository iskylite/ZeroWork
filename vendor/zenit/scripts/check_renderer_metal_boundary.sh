#!/usr/bin/env bash
# R0 ratchet: Metal references outside reviewed backend paths may only decrease.
set -euo pipefail

cd "$(dirname "$0")/.."
APPROVED="scripts/renderer_metal_approved_paths.txt"
BASELINE="scripts/renderer_metal_leak_baseline.txt"
CURRENT="$(mktemp /tmp/zenit-renderer-metal-current.XXXXXX)"

cleanup() {
  rm -f "$CURRENT"
}
trap cleanup EXIT

PATTERN='Backend\.metal_bindings|\bmtl\.|MTL[A-Z][A-Za-z0-9_]*|metal_[a-zA-Z0-9_]+'
# Check code only, not comments: strip everything after // before matching.
# 2026-09-22: text_renderer.zig had a comment line mentioning 'leaked MTLBuffer/PSO/CoreText
# resources', matched as new Metal dependency—mentioning Metal type in comment is not a dependency.
# (Inline strings with // don't exist in src/render; if they do, it's conservative false-positive,
# not false-negative.)
{ rg -n "$PATTERN" src/render --glob '*.zig' || true; } |
  awk -F: '{ line=$0; sub(/\/\/.*/, "", line); if (line ~ /Backend\.metal_bindings|[^a-zA-Z0-9_]mtl\.|MTL[A-Z]|metal_[a-zA-Z0-9_]/) print }' |
  awk -F: '{ count[$1]++ } END { for (path in count) print count[path], path }' |
  sort -k2 >"$CURRENT"

LEAK_TOTAL=0
APPROVED_TOTAL=0
while read -r count path; do
  if grep -qxF "$path" "$APPROVED"; then
    APPROVED_TOTAL=$((APPROVED_TOTAL + count))
    continue
  fi

  limit="$(awk -v wanted="$path" '$2 == wanted { print $1 }' "$BASELINE")"
  if [[ -z "$limit" ]]; then
    echo "new Metal dependency outside an approved backend path: $path ($count refs)" >&2
    exit 1
  fi
  if (( count > limit )); then
    echo "Metal dependency grew: $path has $count refs (R0 limit $limit)" >&2
    exit 1
  fi
  LEAK_TOTAL=$((LEAK_TOTAL + count))
done <"$CURRENT"

BASELINE_TOTAL="$(awk '{ sum += $1 } END { print sum + 0 }' "$BASELINE")"
if (( LEAK_TOTAL > BASELINE_TOTAL )); then
  echo "renderer Metal leak total grew: $LEAK_TOTAL > $BASELINE_TOTAL" >&2
  exit 1
fi

echo "renderer Metal boundary ratchet: PASS (outside=$LEAK_TOTAL/$BASELINE_TOTAL, approved=$APPROVED_TOTAL)"
