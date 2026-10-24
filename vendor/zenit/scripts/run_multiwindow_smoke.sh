#!/usr/bin/env bash
# run_multiwindow_smoke.sh -- multi-window delivery smoke test
#
# Asserts: two native windows coexist in one process, window_id does not collide (a11y/system
# API routing precondition), both render, closing A leaves B running, closing B exits
# cleanly; covers both window creation methods, active window switch, and app-wide quit
# resource cleanup.
# Usage: bash scripts/run_multiwindow_smoke.sh [frames=120]
set -uo pipefail
cd "$(dirname "$0")/.."

FRAMES="${1:-120}"

echo "==> build multi_window"
zig build multi-window || { echo "build failed"; exit 1; }

echo "==> run smoke (${FRAMES} frames)"
LOG=$(ZENIT_SMOKE_FRAMES="$FRAMES" "./zig-out/Multi Window.app/Contents/MacOS/multi_window" 2>&1)
RC=$?

if [ $RC -ne 0 ]; then
  echo "FAIL: app exited rc=$RC"
  echo "$LOG" | tail -20
  exit 1
fi

echo "$LOG" | grep -q "two windows up" || { echo "FAIL: 缺双窗口启动标记"; exit 1; }
echo "$LOG" | grep -q "smoke ok" || { echo "FAIL: 缺双窗口渲染完成标记"; exit 1; }
echo "$LOG" | grep -q "single-close ok" || { echo "FAIL: 关闭单窗后 survivor 未继续"; exit 1; }
echo "$LOG" | grep -q "last-window exit ok" || { echo "FAIL: 最后窗口退出契约未完成"; exit 1; }
echo "$LOG" | grep -q "app-quit cleanup ok" || { echo "FAIL: App 退出统一析构契约未完成"; exit 1; }
if echo "$LOG" | grep -q "window_id collision"; then
  echo "FAIL: window_id 冲突"; exit 1
fi

echo "$LOG" | grep -E "two windows up|smoke ok|single-close ok|last-window exit ok|app-quit cleanup ok"
echo "PASS: multi-window smoke"
