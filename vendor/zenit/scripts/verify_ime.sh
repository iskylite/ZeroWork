#!/usr/bin/env bash
# IME real-device verification: true input methods (Pinyin/Japanese) traverse the full
# NSTextInputClient path:
#   CGEvent keyboard -> input method preedit(setMarkedText) -> space selects candidate ->
#   insertText commit -> Input document.
#
# Unlike e2e injection, marked text / candidate window / commit all come from the
# **real system input method** (covers replacementRange behavior).
# The storybook test harness focuses/reads back via file RPC (real hit-test + direct
# doc state read); only typing uses global CGEvent, avoiding pixel guessing.
#
# Prerequisites: GUI session + accessibility permission + Simplified Pinyin or
# Japanese Romaji enabled.
# Side effects: seizes keyboard focus ~8s; input method restored at end. Don't touch
# the keyboard during the run.
# Usage: bash scripts/verify_ime.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOG=/tmp/zenit-ime-verify.log
RPCDIR=/tmp/zenit_ime_rpc
PASS=0; FAIL=0
check() { if [ "$2" = 0 ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi }

TIS_HELPER=$(mktemp -t zenit-tis).swift
cat > "$TIS_HELPER" <<'EOF'
// 输入法查询/切换：current | list | select <inputSourceID>
import Carbon
import Foundation
func sources() -> [TISInputSource] {
    let filter = [kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
    return TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
}
func sid(_ s: TISInputSource) -> String {
    unsafeBitCast(TISGetInputSourceProperty(s, kTISPropertyInputSourceID), to: CFString.self) as String
}
let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "current":
    print(sid(TISCopyCurrentKeyboardInputSource().takeRetainedValue()))
case "list":
    for s in sources() { print(sid(s)) }
case "select":
    guard let target = sources().first(where: { sid($0) == args[2] }) else { exit(1) }
    exit(TISSelectInputSource(target) == noErr ? 0 : 1)
default: exit(2)
}
EOF

KEY_HELPER=$(mktemp -t zenit-keys).swift
cat > "$KEY_HELPER" <<'EOF'
// CGEvent 键盘序列：每个参数是 keycode 或 cmd+keycode，间隔 80ms 给输入法反应
import CoreGraphics
import Foundation
let src = CGEventSource(stateID: .hidSystemState)
for a in CommandLine.arguments.dropFirst() {
    // "shift" = 单击 Shift（拼音输入法的中/英切换）：需要 flagsChanged 语义
    if a == "shift" {
        let d = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: true)!
        d.flags = .maskShift
        d.post(tap: .cghidEventTap)
        let u = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: false)!
        u.flags = []
        u.post(tap: .cghidEventTap)
        usleep(150_000)
        continue
    }
    let cmd = a.hasPrefix("cmd+")
    let code = CGKeyCode(UInt16(cmd ? String(a.dropFirst(4)) : a)!)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        // 显式覆盖 flags：CGEvent 默认继承**物理**修饰键状态 —— 用户此刻
        // 真按着 Cmd 的话，合成的空格会变成 Cmd+Space 呼出 Spotlight（实锤）。
        e.flags = cmd ? .maskCommand : []
        e.post(tap: .cghidEventTap)
    }
    usleep(80_000)
}
EOF

# ---- storybook test-harness file RPC ----
RPC_SEQ=0
rpc() { # $1 = path, $2 = body json (inner), $3 = method (default POST; /health is GET)
  RPC_SEQ=$((RPC_SEQ+1))
  local id="ime$RPC_SEQ"
  python3 - "$RPCDIR" "$id" "$1" "$2" "${3:-POST}" <<'PYEOF'
import json, sys, time, os
d, rid, path, body, method = sys.argv[1:6]
tmp = os.path.join(d, f"req-{rid}.tmp")
req = os.path.join(d, f"req-{rid}.json")
with open(tmp, "w") as f:
    json.dump({"method": method, "path": path, "body_json": body}, f)
os.rename(tmp, req)
res = os.path.join(d, f"res-{rid}.json")
for _ in range(200):
    if os.path.exists(res):
        print(open(res).read()); os.remove(res); sys.exit(0)
    time.sleep(0.05)
sys.exit(1)
PYEOF
}

echo "==> 输入法盘点"
ORIG_SOURCE=$(swift "$TIS_HELPER" current)
echo "    当前：${ORIG_SOURCE}（结束后恢复）"
IME_ID=""; EXPECT=""
# prefer Japanese Romaji: that input method ID is pinned to Hiragana mode, no cross-session
# persistent EN/JP toggle like Pinyin (empirical: Pinyin pass-through English and compose Shift
# can't toggle it).
if swift "$TIS_HELPER" list | grep -q "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"; then
  IME_ID="com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"; EXPECT="日本語|にほんご" # nihongo + 回车（Kotoeri live conversion 提交汉字，老版本提交假名）
elif swift "$TIS_HELPER" list | grep -q "com.apple.inputmethod.SCIM.ITABC"; then
  IME_ID="com.apple.inputmethod.SCIM.ITABC"; EXPECT="你好"   # nihao + 空格
else
  echo "  SKIP  未启用日文/拼音输入法，无法验证"; exit 3
fi
echo "    使用：${IME_ID}，期望提交：${EXPECT}"

restore() {
  swift "$TIS_HELPER" select "$ORIG_SOURCE" || true
  kill "${APP_PID:-0}" 2>/dev/null || true
  rm -f "$TIS_HELPER" "$KEY_HELPER"
}
trap restore EXIT

echo "==> 构建 storybook (-Dtest-mode=true) + 启动"
zig build -Dtest-mode=true storybook >/dev/null
rm -rf "$RPCDIR"; mkdir -p "$RPCDIR"
ZENIT_E2E_FILE_RPC_DIR="$RPCDIR" "./zig-out/zenit Storybook.app/Contents/MacOS/storybook" >"$LOG" 2>&1 &
APP_PID=$!
sleep 2
rpc /health '{}' GET | grep -q ok || { echo "harness 未就绪"; exit 1; }

echo "==> harness 聚焦 Input story（真实 hit-test，无像素猜测）"
rpc /click '{"test_id":"nav.input"}' >/dev/null
sleep 0.3
rpc /click '{"test_id":"story.input.name"}' >/dev/null
sleep 0.3

echo "==> 置前 + 切到 $IME_ID + 合成键盘输入"
osascript -e 'tell application "System Events" to tell process "storybook" to set frontmost to true' >/dev/null
swift "$TIS_HELPER" select "$IME_ID"
sleep 0.8

type_and_read() { # output input_state json
  if [ "$IME_ID" = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese" ]; then
    # nihongo = 45 34 4 31 45 5 31; return 36 commits hiragana as-is
    swift "$KEY_HELPER" 45 34 4 31 45 5 31
    sleep 0.8
    swift "$KEY_HELPER" 36
  else
    # nihao = 45 34 4 0 31; space 49 selects first candidate to commit
    swift "$KEY_HELPER" 45 34 4 0 31
    sleep 0.8
    swift "$KEY_HELPER" 49
  fi
  sleep 0.8
  rpc /input_state '{"test_id":"story.input.name"}'
}

STATE=$(type_and_read)
if echo "$STATE" | grep -q '"buffer":"nihao' ; then
  # Pinyin is in English mode (CN/EN state persists across sessions): press Shift to switch to
  # Chinese, clear and retry once
  echo "    检测到英文直通（buffer=nihao ），Shift 切中文模式后重试"
  swift "$KEY_HELPER" cmd+0 51 # Cmd+A + Delete to clear
  sleep 0.3
  swift "$KEY_HELPER" shift
  sleep 0.5
  STATE=$(type_and_read)
fi
swift "$TIS_HELPER" select "$ORIG_SOURCE"

echo "==> harness 回读输入框文档"
echo "    input_state: $STATE"
if echo "$STATE" | grep -qE "$EXPECT"; then
  check "IME 提交文本包含 $EXPECT" 0
else
  check "IME 提交文本包含 $EXPECT" 1
  screencapture -x /tmp/zenit-ime-fail.png
  echo "    失败现场截图：/tmp/zenit-ime-fail.png（检查系统弹框/候选窗）"
fi
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
