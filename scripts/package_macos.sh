#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(python3 -c 'import pathlib,re; print(re.search(r"\.version\s*=\s*\"([^\"]+)\"", pathlib.Path("build.zig.zon").read_text()).group(1))')
OUT="${1:-$ROOT/dist}"
DMG="$OUT/ZeroWork-$VERSION-arm64.dmg"
[ ! -e "$DMG" ] || { echo "Refusing to overwrite $DMG" >&2; exit 1; }
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/zerowork-package.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
APP="$STAGING/image/ZeroWork.app"

python3 scripts/verify_vendor_zenit.py
if [ ! -s vendor/libssh2/src/.libs/libssh2.a ] || [ ! -s vendor/mbedtls/library/libmbedcrypto.a ]; then
  sh scripts/build_ssh_deps.sh
fi
zig build -j2 -Doptimize=ReleaseFast --prefix "$STAGING/build" --summary all
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT"
cp "$STAGING/build/bin/zerowork" "$APP/Contents/MacOS/ZeroWork"
cp "$STAGING/build/bin/zw_ipc.so" "$APP/Contents/MacOS/zw_ipc.so"
cp assets/macos/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp vendor/DEPENDENCIES.md "$APP/Contents/Resources/DEPENDENCIES.md"
cp docs/UI_V3/assets/fonts/Inter-OFL.txt "$APP/Contents/Resources/Inter-OFL.txt"
cp docs/UI_V3/assets/fonts/JetBrainsMono-OFL.txt "$APP/Contents/Resources/JetBrainsMono-OFL.txt"
xcrun strip -S "$APP/Contents/MacOS/ZeroWork" "$APP/Contents/MacOS/zw_ipc.so"
python3 scripts/verify_release_environment.py "$APP/Contents/MacOS/ZeroWork"
python3 scripts/verify_release_environment.py "$APP/Contents/MacOS/zw_ipc.so"
python3 - "$APP" "$VERSION" <<'PY'
import pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]);version=sys.argv[2]
info={'CFBundleExecutable':'ZeroWork','CFBundleIdentifier':'com.zerowork.app','CFBundleName':'ZeroWork','CFBundleIconFile':'AppIcon','CFBundlePackageType':'APPL','CFBundleShortVersionString':version,'CFBundleVersion':version,'LSMinimumSystemVersion':'14.0','LSArchitecturePriority':['arm64']}
with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
binary=(app/'Contents/MacOS/ZeroWork').read_bytes()
for marker in [b'fixture_probe',b'fixture_uprobe',b'/zerowork/windows']:
    if marker in binary: raise SystemExit('Refusing to package a fixture or Harness build')
PY
codesign --force --deep --sign - --identifier com.zerowork.app "$APP"
codesign --verify --deep --strict "$APP"
ln -s /Applications "$STAGING/image/Applications"
cat > "$STAGING/image/安装说明.txt" <<TXT
ZeroWork $VERSION · Apple Silicon · macOS 14 或更新版本

将 ZeroWork.app 拖入 Applications，即可安装。
本安装包不包含测试 Harness、测试插件、服务器密码或用户配置。
应用数据存于 ~/Library/Application Support/com.zerowork.app，诊断日志与缓存存于 Library/Logs 和 Library/Caches 下同名目录。
已保存的 SSH 密码、密钥口令、TOTP 秘钥和 AI API Key 存于 macOS 钥匙串。
首次启动兼容迁移旧 ~/.zerowork。仅将 App 移到废纸篓会保留数据；彻底清理请在设置 → 数据中选择“清除全部应用数据…”。
应用使用本机 ad-hoc 签名，未经过 Apple Developer ID 签名或公证。
TXT
hdiutil create -volname "ZeroWork $VERSION" -srcfolder "$STAGING/image" -format UDZO "$DMG"
hdiutil verify "$DMG"
(cd "$OUT" && shasum -a 256 "ZeroWork-$VERSION-arm64.dmg" > "ZeroWork-$VERSION-arm64.dmg.sha256")
echo "Created $DMG"
