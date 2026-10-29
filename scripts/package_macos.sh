#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
SIGNING_IDENTITY=$(python3 scripts/macos_signing.py identity)
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
cp "$STAGING/build/bin/zw_execution.so" "$APP/Contents/MacOS/zw_execution.so"
cp "$STAGING/build/bin/zw_secret_consume.so" "$APP/Contents/MacOS/zw_secret_consume.so"
cp "$STAGING/build/bin/zw_execution_guard" "$APP/Contents/MacOS/zw_execution_guard"
cp -R "$STAGING/build/share/zerowork/ssh-bootstrap" "$APP/Contents/Resources/ssh-bootstrap"
cp assets/macos/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp vendor/DEPENDENCIES.md "$APP/Contents/Resources/DEPENDENCIES.md"
cp docs/UI_V3/assets/fonts/Inter-OFL.txt "$APP/Contents/Resources/Inter-OFL.txt"
cp docs/UI_V3/assets/fonts/JetBrainsMono-OFL.txt "$APP/Contents/Resources/JetBrainsMono-OFL.txt"
xcrun strip -S "$APP/Contents/MacOS/ZeroWork" "$APP/Contents/MacOS/zw_ipc.so" "$APP/Contents/MacOS/zw_execution.so" "$APP/Contents/MacOS/zw_secret_consume.so" "$APP/Contents/MacOS/zw_execution_guard"
python3 scripts/verify_release_environment.py "$APP/Contents/MacOS/ZeroWork"
python3 scripts/verify_release_environment.py "$APP/Contents/MacOS/zw_ipc.so"
python3 scripts/verify_release_environment.py "$APP/Contents/MacOS/zw_execution.so"
python3 scripts/verify_release_environment.py "$APP/Contents/MacOS/zw_secret_consume.so"
python3 scripts/verify_release_environment.py "$APP/Contents/MacOS/zw_execution_guard"
python3 - "$APP" "$VERSION" <<'PY'
import pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]);version=sys.argv[2]
info={'CFBundleExecutable':'ZeroWork','CFBundleIdentifier':'com.zerowork.app','CFBundleName':'ZeroWork','CFBundleIconFile':'AppIcon','CFBundlePackageType':'APPL','CFBundleShortVersionString':version,'CFBundleVersion':version,'LSMinimumSystemVersion':'14.0','LSArchitecturePriority':['arm64']}
with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
binary=(app/'Contents/MacOS/ZeroWork').read_bytes()
for marker in [b'fixture_probe',b'fixture_uprobe',b'/zerowork/windows']:
    if marker in binary: raise SystemExit('Refusing to package a fixture or Harness build')
PY
# Always resolve a persistent identity before the build; never fall back to ad-hoc.
codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier com.zerowork.app "$APP"
codesign --verify --deep --strict "$APP"
python3 scripts/build_ssh_bootstrap.py --output "$APP/Contents/Resources/ssh-bootstrap/v1" --verify-only
SIGNING_NOTICE="应用已使用固定代码签名证书签名；本打包流程未执行 Apple 公证。"
ln -s /Applications "$STAGING/image/Applications"
cat > "$STAGING/image/安装说明.txt" <<TXT
ZeroWork $VERSION · Apple Silicon · macOS 14 或更新版本

将 ZeroWork.app 拖入 Applications，即可安装。

首次打开被 macOS 拦截时：
1. 从「应用程序」打开 ZeroWork；如果提示无法验证开发者或 Apple 无法检查是否包含恶意软件，关闭提示。
2. 确认应用来自可信来源后，打开「系统设置」→「隐私与安全性」，向下滚动到「安全性」区域。
3. 找到 ZeroWork 被阻止的提示，点击「仍要打开」，按系统提示完成身份验证，并在再次出现的提示中点击「打开」。
4. 系统会保存此次允许，之后通常可直接打开。如果没有看到「仍要打开」，请先再次尝试打开 ZeroWork，再返回此页面。
操作参考：https://support.apple.com/zh-cn/102445

本安装包不包含测试 Harness、测试插件、服务器密码或用户配置。
应用数据存于 ~/Library/Application Support/com.zerowork.app，诊断日志与缓存存于 Library/Logs 和 Library/Caches 下同名目录。
已保存的 SSH 密码、密钥口令、TOTP 秘钥和 AI API Key 存于 macOS 钥匙串。
首次启动兼容迁移旧 ~/.zerowork。仅将 App 移到废纸篓会保留数据；彻底清理请在设置 → 数据中选择“清除全部应用数据…”。
$SIGNING_NOTICE
TXT
hdiutil create -volname "ZeroWork $VERSION" -srcfolder "$STAGING/image" -format UDZO "$DMG"
hdiutil verify "$DMG"
(cd "$OUT" && shasum -a 256 "ZeroWork-$VERSION-arm64.dmg" > "ZeroWork-$VERSION-arm64.dmg.sha256")
echo "Created $DMG"
