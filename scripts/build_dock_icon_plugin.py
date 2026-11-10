#!/usr/bin/env python3
"""Build and sign the Dock tile plug-in without changing an installed app."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def build(app, identifier, identity):
    plist = app / 'Contents/Info.plist'
    info = plistlib.loads(plist.read_bytes())
    plugin = app / 'Contents/PlugIns/ZeroWorkDockIcon.docktileplugin'
    binary = plugin / 'Contents/MacOS/ZeroWorkDockIcon'
    resources = plugin / 'Contents/Resources'
    binary.parent.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    for name in ['AppIcon.png', 'AppIcon-light.png', 'AppIcon-dark.png']:
        shutil.copyfile(ROOT / 'assets/macos' / name, resources / name)
    (plugin / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'ZeroWorkDockIcon',
        'CFBundleIdentifier': identifier + '.dockicon',
        'CFBundleName': 'ZeroWork Dock Icon',
        'CFBundlePackageType': 'BNDL',
        'CFBundleVersion': info.get('CFBundleVersion', '1'),
        'NSPrincipalClass': 'ZWDockIconPlugin',
        'LSMinimumSystemVersion': '13.0',
        'ZeroWorkApplicationIdentifier': identifier,
    }))
    subprocess.run([
        '/usr/bin/xcrun', 'clang', '-target', 'arm64-apple-macos13.0',
        '-Os', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
        '-Wno-unused-parameter', '-bundle',
        str(ROOT / 'src/platform/dock_icon_plugin.m'),
        '-framework', 'AppKit', '-o', str(binary),
    ], check=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity,
                    '--identifier', identifier + '.dockicon', str(plugin)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(plugin)], check=True)
    info['NSDockTilePlugIn'] = 'ZeroWorkDockIcon.docktileplugin'
    plist.write_bytes(plistlib.dumps(info))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--identifier', required=True)
    parser.add_argument('--identity', required=True)
    args = parser.parse_args()
    build(args.app, args.identifier, args.identity)
