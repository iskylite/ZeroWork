#!/usr/bin/env bash
# Open every Storybook story in a production (non-test-mode) build under the
# Metal API validation layer; any validation message fails the gate.
#
# Catches undefined behaviour that only "works" with validation off, e.g.
# blitting/sampling a framebufferOnly drawable or misaligned buffer offsets.
#
#   bash scripts/check_metal_validation.sh            # all stories, 3 s each
#   ZENIT_MTL_STORIES="glassbox notification" ZENIT_MTL_SECONDS=6 bash scripts/check_metal_validation.sh
set -euo pipefail
cd "$(dirname "$0")/.."

seconds="${ZENIT_MTL_SECONDS:-3}"
stories="${ZENIT_MTL_STORIES:-$(grep -o '\.key = "[a-z0-9_]*"' examples/storybook/main.zig | cut -d'"' -f2 | sort -u)}"
app="zig-out/zenit Storybook.app/Contents/MacOS/storybook"
log_dir="$(mktemp -d "${TMPDIR:-/tmp}/zenit-mtl-validation.XXXXXX")"

if [[ "${ZENIT_MTL_SKIP_BUILD:-0}" != 1 ]]; then
  zig build storybook
fi
[[ -x "$app" ]] || { echo "missing $app" >&2; exit 66; }

failed=0
count=0
for story in $stories; do
  count=$((count + 1))
  log="$log_dir/$story.log"
  MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=nslog ZENIT_STORYBOOK_STORY="$story" "$app" >"$log" 2>&1 &
  pid=$!
  sleep "$seconds"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if ! grep -q "API Validation Enabled" "$log"; then
    echo "FAIL $story: Metal validation layer did not start" >&2
    failed=$((failed + 1))
    continue
  fi
  errors=$(grep -c 'Validation$' "$log" || true)
  if [[ "$errors" != 0 ]]; then
    failed=$((failed + 1))
    echo "FAIL $story: $errors validation message(s)" >&2
    grep -A1 'Validation$' "$log" | grep -v -E 'Validation$|^--' | sed -E 's/^.*storybook\[[0-9:]+\] //; s/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -5 >&2
  fi
done

if [[ "$failed" != 0 ]]; then
  echo "Metal validation: $failed of $count stories reported errors (logs: $log_dir)" >&2
  exit 1
fi
echo "Metal validation: $count stories, 0 messages"
rm -rf "$log_dir"
