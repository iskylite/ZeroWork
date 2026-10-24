#!/bin/sh
# 设计稿预览：构建 → 打包 → 启动单页 mockup 预览程序。
# 用法: scripts/preview_mockup.sh <name> [--bg]
#   <name>  docs/SPEC/html/mockup-<name>.html 的短名（如 main、settings-ai）
#   --bg    不等待退出（后台保持运行，供截图观察）
set -eu

NAME="${1:?usage: preview_mockup.sh <mockup-name> [--bg]}"
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
# 每个 mockup 独立 .app 路径：多个子智能体并行预览时互不干扰。
APP="$ROOT/dist/preview-$NAME.app"

cd "$ROOT"
zig build mockup -Dmockup="$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "zig-out/bin/mockup-$NAME" "$APP/Contents/MacOS/MockupPreview"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MockupPreview</string>
<key>CFBundleIdentifier</key><string>com.zerowork.mockup</string>
<key>CFBundleName</key><string>MockupPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

open "$APP"
sleep 1.5
PID=$(pgrep -f "preview-$NAME.app/Contents/MacOS/MockupPreview" | head -1 || true)
echo "preview $NAME pid=${PID:-unknown}"
if [ "${2:-}" != "--bg" ]; then
  [ -n "$PID" ] && wait "$PID" 2>/dev/null || true
fi
