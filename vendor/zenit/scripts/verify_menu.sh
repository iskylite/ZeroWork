#!/usr/bin/env bash
# Native menu real-hardware verification: model/mock/link tests pass, but true AppKit menu clicks
# and shortcuts are not covered elsewhere.
#
# Chain: NSMenu (true menu bar) click / Cmd+P shortcut
#   -> window_bridge menu target-action -> menu_command event
#   -> Cx.handleCommand -> ActionDispatcher -> probe on_action print
#
# Criterion: probe stdout shows "[PROBE] action ping" (twice: once click, once shortcut).
# Prerequisites: GUI session + accessibility permission (System Events clicks menu). Usage: bash
# scripts/verify_menu.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOG=/tmp/zenit-menu-verify.log
PASS=0; FAIL=0
check() { if [ "$2" = 0 ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi }

echo "==> 构建 + 启动 interop_probe"
zig build interop-probe >/dev/null
"./zig-out/zenit Interop Probe.app/Contents/MacOS/interop_probe" >"$LOG" 2>&1 &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null || true' EXIT
sleep 2
grep -q "menu-set failed" "$LOG" && { echo "setMenuModel 失败"; exit 1; }

echo "==> System Events 点击真菜单栏 Probe → Ping"
osascript >/dev/null <<'EOF'
tell application "System Events"
  tell process "interop_probe"
    set frontmost to true
    delay 0.3
    click menu item "Ping" of menu "Probe" of menu bar item "Probe" of menu bar 1
  end tell
end tell
EOF
sleep 0.8
N1=$(grep -c '\[PROBE\] action ping' "$LOG" || true)
[ "$N1" -ge 1 ] && check "真菜单栏点击 → menu_command → action" 0 || check "真菜单栏点击 → menu_command → action" 1

echo "==> CGEvent Cmd+P 快捷键"
osascript >/dev/null <<'EOF'
tell application "System Events"
  tell process "interop_probe"
    set frontmost to true
    set position of window 1 to {60, 120}
  end tell
end tell
EOF
sleep 0.3
# Click window **right half** for key state (left half is drag source zone, opens drag session
# consuming keyboard events)
swift scripts/cgevent.swift click 360 300
sleep 0.4
# p = keycode 35; flags explicit maskCommand (see verify_ime.sh physical modifier inheritance pit)
swift - <<'EOF'
import CoreGraphics
let src = CGEventSource(stateID: .hidSystemState)
for down in [true, false] {
    let e = CGEvent(keyboardEventSource: src, virtualKey: 35, keyDown: down)!
    e.flags = .maskCommand
    e.post(tap: .cghidEventTap)
}
EOF
sleep 0.8
N2=$(grep -c '\[PROBE\] action ping' "$LOG" || true)
[ "$N2" -ge $((N1 + 1)) ] && check "Cmd+P 快捷键 → menu_command → action" 0 || check "Cmd+P 快捷键 → menu_command → action" 1

echo
echo "Results: $PASS passed, $FAIL failed  (action 触发总数: $N2)"
[ "$FAIL" = 0 ]
