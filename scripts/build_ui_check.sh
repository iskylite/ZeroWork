#!/bin/sh
# Build a fresh signed instance; never overwrite an executable in a live bundle.
# Usage: build_ui_check.sh [--name NAME] [--bundle-id ID] [--data-dir /absolute/path]
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTANCE_NAME=ZeroWork-UI-Check
BUNDLE_ID=com.zerowork.uicheck
DATA_DIR=${ZEROWORK_DATA_DIR-}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name|--bundle-id|--data-dir)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
            case "$1" in
                --name) INSTANCE_NAME=$2 ;;
                --bundle-id) BUNDLE_ID=$2 ;;
                --data-dir) DATA_DIR=$2 ;;
            esac
            shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
# Reject traversal and malformed identifiers before constructing paths.
case "$INSTANCE_NAME" in ''|.|..|*[!A-Za-z0-9._-]*) echo "Instance name must contain only letters, digits, dot, underscore or hyphen" >&2; exit 2 ;; esac
case "$BUNDLE_ID" in ''|*[!A-Za-z0-9.-]*) echo "Invalid bundle identifier" >&2; exit 2 ;; esac
case "$DATA_DIR" in ''|/*) ;; *) echo "Data directory must be absolute" >&2; exit 2 ;; esac
cd "$ROOT"
SIGNING_IDENTITY=$(python3 scripts/macos_signing.py identity)
mkdir -p "$ROOT/dist/ui-check-builds"
STAGE=$(mktemp -d "$ROOT/dist/ui-check-builds/build.XXXXXXXX")
# A different bundle ID does not isolate Keychain. Overrides are honored only
# by test-mode builds; always pair that mode with an explicit instance root.
if [ -z "$DATA_DIR" ]; then DATA_DIR="$STAGE/data"; fi
zig build -j2 -Dtest-mode=true --summary all
APP="$STAGE/$INSTANCE_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/assets/macos/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp zig-out/bin/zerowork "$APP/Contents/MacOS/ZeroWork"
cp zig-out/bin/zw_ipc.so "$APP/Contents/MacOS/zw_ipc.so"
cp zig-out/bin/zw_execution.so "$APP/Contents/MacOS/zw_execution.so"
cp zig-out/bin/zw_execution_guard "$APP/Contents/MacOS/zw_execution_guard"
cmp zig-out/bin/zerowork "$APP/Contents/MacOS/ZeroWork"
python3 - "$APP" "$INSTANCE_NAME" "$BUNDLE_ID" "$DATA_DIR" <<'PY'
import plistlib, sys
from pathlib import Path
app, name, bundle_id, data_dir = sys.argv[1:]
plist = {
    'CFBundleExecutable': 'ZeroWork',
    'CFBundleIdentifier': bundle_id,
    'CFBundleName': name,
    'CFBundleIconFile': 'AppIcon',
    'CFBundlePackageType': 'APPL',
    'LSMinimumSystemVersion': '14.0',
    'NSLocalNetworkUsageDescription': 'ZeroWork 需要连接局域网中的 SSH 主机以建立终端和文件传输会话。',
}
if data_dir:
    # LaunchServices injects instance storage while CFBundleExecutable remains
    # the signed Mach-O binary required by macOS application launching.
    plist['LSEnvironment'] = {'ZEROWORK_DATA_DIR': data_dir}
with (Path(app) / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(plist, f)
PY
codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"
python3 - "$APP" "$BUNDLE_ID" "$DATA_DIR" <<'PY'
import hashlib, json, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
root = Path.cwd()
app = Path(sys.argv[1])
exe = app / 'Contents/MacOS/ZeroWork'
source = root / 'zig-out/bin/zerowork'
hash_file = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
manifest = {
    'built_at': datetime.now(timezone.utc).isoformat(),
    'entry_point': 'src/main.zig',
    'bundle_path': str(app),
    'bundle_identifier': sys.argv[2],
    'data_directory': sys.argv[3],
    'test_mode': True,
    'credential_scope': 'isolated-instance',
    'binary_sha256': hash_file(exe),
    'unsigned_source_sha256': hash_file(source),
    'copy_verified_before_signing': True,
    'git_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'working_tree_status': subprocess.check_output(['git', 'status', '--short'], text=True),
}
encoded = json.dumps(manifest, indent=2) + '\n'
(app.parent / 'ui-check-build.json').write_text(encoded)
(root / 'dist/ui-check-build.json').write_text(encoded)
print(f'Built and signature-verified: {app}')
print(f'Binary SHA256: {manifest["binary_sha256"]}')
PY
