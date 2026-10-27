#!/bin/sh
# 汇总验收（阶段一）：逐一构建全部 47 个 mockup 预览程序。
# 用法: scripts/build_all_mockups.sh [--keep]
#   默认在第一个失败处停止并返回 1；--keep 继续构建其余并列出全部失败。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

KEEP="${1:-}"
FAIL=0
FAILED=""

for source in tools/mockups/*.zig; do
  [ -f "$source" ] || { echo "No mockup sources found" >&2; exit 1; }
  stem=$(basename "$source" .zig)
  case "$stem" in common|runner) continue ;; esac
  name=$(printf '%s' "$stem" | tr '_' '-')
  if zig build mockup -Dmockup="$name" >/tmp/mockup-build-$name.log 2>&1; then
    echo "OK   $name"
  else
    echo "FAIL $name (see /tmp/mockup-build-$name.log)"
    FAIL=$((FAIL + 1))
    FAILED="$FAILED $name"
    [ "$KEEP" != "--keep" ] && exit 1
  fi
done

if [ "$FAIL" -gt 0 ]; then
  echo "== $FAIL failed:$FAILED"
  exit 1
fi
echo "== all mockups built"
