#!/usr/bin/env bash
# Rich clipboard + drag-out real-machine verification (true system paths that e2e injection cannot
# reach).
#
# Covers three paths:
#   A. Clipboard get: external (swift/NSPasteboard) pre-stages HTML -> probe reads it at startup
#   B. Clipboard set: probe writes text+HTML -> external process reads both types
#   C. Drag-out: mousedown in probe window starts beginDrag(file_url) -> CGEvent drags to a Finder
#   target dir -> pass if the dir has payload.txt (Finder copied it)
#
# Preconditions: GUI session; C needs terminal accessibility permission (same as
# verify_real_drag.sh). Usage: bash scripts/verify_interop_probe.sh [--skip-drag]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKIP_DRAG="${1:-}"
LOG=/tmp/zenit-interop-probe.log
SRC=/tmp/zenit-dragout
DST=/tmp/zenit-dragout-dest
PASS=0
FAIL=0
check() { # $1 label, $2 = 0/1 ok
  if [ "$2" = 0 ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

echo "==> 构建 interop-probe"
zig build interop-probe >/dev/null

echo "==> A. 外部预置 HTML 剪贴板"
swift - <<'EOF'
import AppKit
let pb = NSPasteboard.general
pb.clearContents()
let item = NSPasteboardItem()
item.setString("external-html-marker <i>from swift</i>", forType: .html)
item.setString("external-plain", forType: .string)
pb.writeObjects([item])
EOF

echo "==> 启动 probe（读 HTML → 写富剪贴板）"
rm -f "$LOG"
ZENIT_DEBUG_DRAG=1 "./zig-out/zenit Interop Probe.app/Contents/MacOS/interop_probe" >"$LOG" 2>&1 &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do grep -q "rich-set" "$LOG" 2>/dev/null && break; sleep 0.2; done

grep -q '\[PROBE\] read-html: .*external-html-marker' "$LOG"; check "A: probe 读到外部 HTML" $?
grep -q '\[PROBE\] rich-set-ok' "$LOG"; check "B1: probe 富写入返回 ok" $?

echo "==> B. 外部读回 probe 写入的两种 representation"
swift - <<'EOF'
import AppKit
let pb = NSPasteboard.general
let plain = pb.string(forType: .string) ?? "<nil>"
let html = pb.string(forType: .html) ?? "<nil>"
print("plain=\(plain)")
print("html=\(html)")
guard plain == "zenit-probe-plain", html.contains("zenit-probe-html") else { exit(1) }
EOF
check "B2: 外部进程读回 plain+HTML 双 representation" $?

if [ "$SKIP_DRAG" = "--skip-drag" ]; then
  echo "==> C. 拖出验证已跳过（--skip-drag）"
else
  echo "==> C. 文件拖出到 Finder"
  rm -rf "$SRC" "$DST"; mkdir -p "$SRC" "$DST"
  printf 'zenit drag-out payload\n' > "$SRC/payload.txt"

  # Arrange probe window and Finder target window (fixed coords, CGEvent uses global screen coords).
  osascript >/dev/null <<EOF
tell application "System Events"
  tell process "interop_probe"
    set frontmost to true
    set position of window 1 to {60, 120}
    set size of window 1 to {400, 300}
  end tell
end tell
tell application "Finder"
  activate
  set w to make new Finder window
  set target of w to (POSIX file "$DST" as alias)
  set current view of w to list view
end tell
tell application "System Events"
  tell process "Finder"
    set position of window 1 to {620, 120}
    set size of window 1 to {420, 400}
  end tell
end tell
EOF
  sleep 1
  # Probe window left half drag source (180, 270) (right half normal click, no drag) -> Finder
  # window list (850, 320) (measured 830 off by 20px hitting sidebar). draghold: hold then step move
  # (memory: step drag + mousedown immediate start).
  swift scripts/cgevent.swift draghold 180 270 850 320 1.0 || \
    swift scripts/cgevent.swift drag 180 270 850 320

  ok=1
  for _ in $(seq 1 25); do
    if [ -f "$DST/payload.txt" ]; then ok=0; break; fi
    sleep 0.4
  done
  check "C: Finder 目标目录收到 payload.txt" $ok
  grep -q '\[PROBE\] beginDrag ok' "$LOG"; check "C: probe beginDrag 会话已建立" $?
  osascript -e 'tell application "Finder" to close every window' >/dev/null 2>&1 || true
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
