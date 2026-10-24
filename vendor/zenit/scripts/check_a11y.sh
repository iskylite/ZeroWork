#!/usr/bin/env bash
# check_a11y.sh: a11y out-of-process acceptance gate (design: docs/A11Y_ARCHITECTURE.md
# section 8). Uses the same cross-process AX channel as VoiceOver (tools/axprobe)
# and asserts the system actually receives:
#  1. Semantic snapshot: hello_button pre/post-press AX tree (role/name/value)
#     matches golden;
#  2. Fetch latency: with 30ms drawable backpressure, AXChildren p95 still < 2ms;
#     the control group (old behavior, wait one frame per request) must be visibly
#     slower, proving backpressure is real; not slower (window obscured, idle, etc.)
#     -> "undetermined", never pass;
#  3. AX action under backpressure: a deferred press in the in-frame service window
#     must fire in the next pump;
#  4. Modal isolation: closed dialog unreadable; open shows only the dialog
#     (AXApplicationDialog), background (sidebar nav) leaves the AX tree;
#  5. Virtual list (semantic set, AXTable): AXRowCount reports the data total
#     (100000), not the visible dozen rows;
#  6. Virtual list scroll by row: AXScrollToVisible on a cell below the viewport
#     moves visible rows by exactly one and reads the new position right after the
#     set (matches NSTableView).
#
# The terminal needs 'Accessibility' permission; without it exit 77 (skip, not
# pass). Usage: bash scripts/check_a11y.sh [--update-golden]. Exit:
# 0 pass / 1 fail / 2 undetermined / 77 skip.
set -uo pipefail
cd "$(dirname "$0")/.."

UPDATE_GOLDEN=0
[[ "${1:-}" == "--update-golden" ]] && UPDATE_GOLDEN=1

AXPROBE=scripts/axprobe.sh
GOLDEN_DIR=tests/a11y
WORK="$(mktemp -d -t zenit-a11y.XXXXXX)"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# Permission check: axprobe exits 2 and prints hint when no permission.
if ! swift -e 'import ApplicationServices; exit(AXIsProcessTrusted() ? 0 : 1)' 2>/dev/null; then
  echo "SKIP: 当前终端没有「辅助功能」权限（系统设置 > 隐私与安全性 > 辅助功能）"
  exit 77
fi

# VoiceOver running sends hundreds requests/sec to foreground app; control group
# (old behavior, wait one frame per request) gets dragged by its queue to minutes;
# [2] actually unmeasurable.
if pgrep -qx VoiceOver; then
  echo "SKIP: VoiceOver 正在运行，请先关闭（Command+F5）再跑门禁"
  exit 77
fi

echo "==> build (ReleaseFast)"
zig build hello-button storybook virtual-list-perf -Doptimize=ReleaseFast >"$WORK/build.log" 2>&1 || {
  echo "FAIL: build"; tail -20 "$WORK/build.log"; exit 1
}

# launch <bundle> [ENV=VAL ...]: start app, pid recorded in PIDS and $LAUNCHED.
# Can't write PID=$(launch ...): command substitution runs in subshell, PIDS append
# doesn't reach here, cleanup at exit can't kill these apps (measured orphaned
# hello_button process).
LAUNCHED=""
launch() {
  local bundle="$1"; shift
  local dir="zig-out/$bundle.app/Contents/MacOS"
  local exe="$dir/$(ls "$dir" | head -1)"
  env "$@" "$exe" >"$WORK/$(basename "$exe").$RANDOM.log" 2>&1 &
  LAUNCHED=$!
  PIDS+=("$LAUNCHED")
}

wait_ready() {
  local pid="$1" tries=0
  until "$AXPROBE" snapshot "$pid" 2>/dev/null | grep -q "^AX"; do
    tries=$((tries + 1))
    if [[ $tries -gt 50 ]]; then echo "FAIL: app $pid 未在 10s 内暴露 AX 树"; exit 1; fi
    sleep 0.2
  done
}

p95_ms() { sed -n 's/.*p95=\([0-9.]*\)ms.*/\1/p'; }
p50_ms() { sed -n 's/.*p50=\([0-9.]*\)ms.*/\1/p'; }

FAILED=0

echo "==> [1] hello_button 语义快照"
launch "Hello Button"; PID=$LAUNCHED
wait_ready "$PID"
{
  echo "# initial"
  "$AXPROBE" snapshot "$PID"
  "$AXPROBE" do "$PID" 'Button[Click me]' AXPress >/dev/null
  sleep 0.3
  echo "# after AXPress"
  "$AXPROBE" snapshot "$PID"
} >"$WORK/hello_button.snapshot"
kill "$PID" 2>/dev/null
if [[ $UPDATE_GOLDEN -eq 1 ]]; then
  mkdir -p "$GOLDEN_DIR"
  cp "$WORK/hello_button.snapshot" "$GOLDEN_DIR/hello_button.snapshot"
  echo "updated $GOLDEN_DIR/hello_button.snapshot"
elif diff -u "$GOLDEN_DIR/hello_button.snapshot" "$WORK/hello_button.snapshot"; then
  echo "PASS: 语义快照一致"
else
  echo "FAIL: 语义快照与 golden 不一致（确认是预期变化后用 --update-golden 更新）"
  FAILED=1
fi

echo "==> [2] 背压下的拉取时延（ZENIT_DEBUG_DRAWABLE_DELAY_MS=30）"
launch "zenit Storybook" ZENIT_DEBUG_DRAWABLE_DELAY_MS=30 ZENIT_AX_FRAME_SERVICE=0; CTRL=$LAUNCHED
wait_ready "$CTRL"
"$AXPROBE" latency "$CTRL" --n 3 >/dev/null
CTRL_LINE=$("$AXPROBE" latency "$CTRL" --n 15 --attr AXChildren --query 'Button[Checkbox]')
kill "$CTRL" 2>/dev/null
CTRL_P50=$(echo "$CTRL_LINE" | p50_ms)
echo "control (旧行为): $CTRL_LINE"
if ! awk -v v="$CTRL_P50" 'BEGIN { exit !(v >= 20) }'; then
  echo "INCONCLUSIVE: 对照组 p50=${CTRL_P50}ms < 20ms，背压没有复现（窗口被遮挡停帧？把 storybook 窗口放到可见位置重跑）"
  exit 2
fi

launch "zenit Storybook" ZENIT_DEBUG_DRAWABLE_DELAY_MS=30; TREAT=$LAUNCHED
wait_ready "$TREAT"
"$AXPROBE" latency "$TREAT" --n 3 >/dev/null
TREAT_LINE=$("$AXPROBE" latency "$TREAT" --n 40 --attr AXChildren --query 'Button[Checkbox]')
TREAT_P95=$(echo "$TREAT_LINE" | p95_ms)
echo "service window: $TREAT_LINE"
if awk -v v="$TREAT_P95" 'BEGIN { exit !(v < 2) }'; then
  echo "PASS: AXChildren p95=${TREAT_P95}ms < 2ms"
else
  echo "FAIL: AXChildren p95=${TREAT_P95}ms，AX 帧内服务窗口没有生效"
  FAILED=1
fi

echo "==> [3] 背压下推迟的 AX press 生效"
if "$AXPROBE" snapshot "$TREAT" | grep -q 'AXStaticText = "Slider"'; then
  echo "FAIL: 前置条件不成立（press 之前已在 Slider story）"; FAILED=1
else
  "$AXPROBE" do "$TREAT" 'Button[Slider]' AXPress >/dev/null
  sleep 0.5
  if "$AXPROBE" snapshot "$TREAT" | grep -q 'AXStaticText = "Slider"'; then
    echo "PASS: press 生效（面包屑切到 Slider）"
  else
    echo "FAIL: press 被推迟后没有执行"
    FAILED=1
  fi
fi

kill "$TREAT" 2>/dev/null

echo "==> [4] 模态隔离"
launch "zenit Storybook"; SB=$LAUNCHED
wait_ready "$SB"
"$AXPROBE" do "$SB" 'Button[Modal]' AXPress >/dev/null
sleep 0.8
if "$AXPROBE" snapshot "$SB" | grep -q 'Modal body content'; then
  echo "FAIL: 关着的对话框内容仍可读"; FAILED=1
fi
"$AXPROBE" do "$SB" 'Button[Open Modal]' AXPress >/dev/null
sleep 0.8
OPEN_SNAPSHOT=$("$AXPROBE" snapshot "$SB")
if echo "$OPEN_SNAPSHOT" | grep -q 'AXGroup/AXApplicationDialog' &&
   ! echo "$OPEN_SNAPSHOT" | grep -q 'AXButton "Checkbox"'; then
  echo "PASS: 打开后只剩对话框，背景 inert"
else
  echo "FAIL: 模态隔离不成立"; echo "$OPEN_SNAPSHOT" | head -12; FAILED=1
fi
kill "$SB" 2>/dev/null

echo "==> [5] 虚拟化列表逻辑总数"
launch "100k Virtual List"; VL=$LAUNCHED
wait_ready "$VL"
ROWS=$("$AXPROBE" find "$VL" 'Table' | sed -n 's/^AXRowCount = //p')
if [[ "$ROWS" == "100000" ]]; then
  echo "PASS: AXRowCount=100000"
else
  echo "FAIL: AXRowCount=${ROWS:-<missing>}"; FAILED=1
fi

echo "==> [6] 虚拟化列表逐行滚动（VoiceOver 每步对单元格设 AXScrollToVisible）"
if STEP=$("$AXPROBE" scrollstep "$VL"); then
  echo "$STEP" | tail -1
else
  echo "$STEP"; FAILED=1
fi
kill "$VL" 2>/dev/null

if [[ $FAILED -ne 0 ]]; then echo "FAIL: a11y 门禁"; exit 1; fi
echo "PASS: a11y 门禁"
