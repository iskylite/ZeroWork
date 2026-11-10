#!/bin/sh
# Signed, isolated integration test; never modifies the installed application.
set -eu
cd "$(dirname "$0")/.."
STAGE=$(mktemp -d /private/tmp/zerowork-dock-test.XXXXXXXX)
APP="$STAGE/ZeroWorkDockTest.app"
IDENTIFIER="com.zerowork.docktest.$$"
cleanup() {
    defaults delete "$IDENTIFIER" >/dev/null 2>&1 || true
    rm -rf "$STAGE"
}
trap cleanup EXIT
IDENTITY=$(python3 scripts/macos_signing.py identity)
mkdir -p "$APP/Contents/MacOS"
python3 - "$APP" "$IDENTIFIER" <<'PY'
from pathlib import Path
import plistlib, sys
info = {'CFBundleExecutable': 'DockTest', 'CFBundleIdentifier': sys.argv[2],
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1'}
(Path(sys.argv[1]) / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
    src/platform/dock_icon_plugin_tests.m src/platform/app_icon.m \
    -framework AppKit -o "$APP/Contents/MacOS/DockTest"
python3 scripts/build_dock_icon_plugin.py "$APP" --identifier "$IDENTIFIER" --identity "$IDENTITY"
codesign --force --sign "$IDENTITY" --identifier "$IDENTIFIER" "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/DockTest"
codesign --verify --deep --strict "$APP"
