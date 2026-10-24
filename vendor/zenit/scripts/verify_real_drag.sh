#!/usr/bin/env bash
# verify real drag - drag real files from Finder into the storybook window.
#
# This path is **not coverable by e2e**: e2e dragAt injects into the SDK event queue,
# bypassing the macOS NSDragging pasteboard protocol. This script uses the full path:
# Finder drag session -> NSDraggingDestination callback -> pushDragEvent ->
# view.dragEventQueue -> macos_get_drag_event -> SDK event queue -> Cx.handleDrag ->
# dispatcher -> FileUpload.onDropFiles
#
# Criterion (sole truth): with ZENIT_DEBUG_DRAG=1 stderr shows
# [DRAG] kind=3 x=.. y=.. paths=/private/tmp/...; kind 0/1/2/3 = entered/updated/
# exited/dropped, only kind=3 has paths.
#
# Prerequisites:
# 1. the terminal has Accessibility permission (System Settings -> Privacy & Security).
# 2. a GUI session (no headless/pure ssh).
#
# Semi-automatic: the script builds, launches the window, stages a test file and
# watches logs; window placement, drop zone location and drag coordinates come from
# the user, since storybook nav and drop zone position vary with window geometry and
# the a11y tree doesn't export nav rows.
#
# Usage: bash scripts/verify_real_drag.sh, then follow prompts using
# scripts/cgevent.swift to send the drag (see printed example).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRAGDIR=/tmp/zenit-dragdir
LOG=/tmp/zenit-drag-verify.log

echo "==> 准备测试文件 $DRAGDIR"
rm -rf "$DRAGDIR"
mkdir -p "$DRAGDIR"
printf 'a\n' > "$DRAGDIR/aaa.txt"
printf 'b\n' > "$DRAGDIR/bbb.txt"

echo "==> 构建 storybook"
zig build storybook

echo "==> 启动 storybook（ZENIT_DEBUG_DRAG=1），日志 -> $LOG"
ZENIT_DEBUG_DRAG=1 "./zig-out/zenit Storybook.app/Contents/MacOS/storybook" > "$LOG" 2>&1 &
APP_PID=$!
sleep 3

echo "==> 在 Finder 里打开 $DRAGDIR"
osascript <<EOF >/dev/null
tell application "Finder"
	activate
	set target of window 1 to (POSIX file "$DRAGDIR" as alias)
	set current view of window 1 to list view
end tell
delay 1
tell application "System Events"
	tell process "Finder"
		set position of window 1 to {20, 120}
		set size of window 1 to {560, 500}
	end tell
end tell
EOF

cat <<'GUIDE'

================ 接下来手动做（或用 cgevent.swift 驱动）================

1) 把 storybook 窗口移到不与 Finder 重叠的位置，在左侧 nav 里点 "FileUpload"。
   （可用 `swift scripts/cgevent.swift click <x> <y>`；坐标用
     `screencapture -x -R <x>,<y>,<w>,<h> /tmp/shot.png` 截图后量出来 ——
     注意 System Events 报的窗口原点与 screencapture 的屏幕坐标可能差几十像素，
     以截图为准。）

2) 单文件拖放：
     swift scripts/cgevent.swift drag <finder行x> <finder行y> <dropzone中心x> <dropzone中心y>

3) 多文件拖放（先建立 2 行选区再拖，中间别松手）：
     swift scripts/cgevent.swift dragmulti <x> <行1y> <行2y> <dropzone中心x> <dropzone中心y>
   注意：Finder 里按住选中行停顿太久，选区会塌缩成单个文件 —— 实测踩过，
   拖之前可用 `osascript -e 'tell application "Finder" to count of (selection as list)'` 确认是 2。

4) 悬停高亮（on_drag_enter）：
     swift scripts/cgevent.swift draghold <sx> <sy> <ex> <ey> 4
   在 hold 期间截图，drop zone 边框应明显变深。

5) 非 drop target 区域：拖到 drop zone 以外，日志会出现 kind=3，
   但组件列表**不应**新增行（Cx.handleDrag 命中不到 drop target）。

================ 判据 ================

  grep '\[DRAG\]' /tmp/zenit-drag-verify.log

  出现 `kind=3 ... paths=/private/tmp/zenit-dragdir/aaa.txt` 才算原生路径通了；
  再看 storybook 窗口里 FileUpload 是否真的多出对应文件行。

GUIDE

echo "storybook pid=$APP_PID（验证完 kill 它）"
