#!/usr/bin/env python3
"""Build the stable Keychain agent independently of the application build."""
import argparse
from pathlib import Path
import subprocess
import plistlib

ROOT = Path(__file__).resolve().parent.parent


def build(app, identifier, identity):
    plist = app / 'Contents/Info.plist'
    info = plistlib.loads(plist.read_bytes())
    info['ZeroWorkCredentialAgent'] = True
    plist.write_bytes(plistlib.dumps(info))
    helper = app / 'Contents/Helpers/ZeroWorkCredentials'
    helper.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        '/usr/bin/xcrun', 'clang', '-target', 'arm64-apple-macos13.0', '-Os',
        '-Wall', '-Wextra', '-Werror', str(ROOT / 'src/platform/macos_credential_agent.m'),
        '-framework', 'Security', '-framework', 'CoreFoundation', '-o', str(helper),
    ], check=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity,
                    '--identifier', identifier + '.credentials', str(helper)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(helper)], check=True)
    return helper


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--identifier', required=True)
    parser.add_argument('--identity', required=True)
    args = parser.parse_args()
    build(args.app, args.identifier, args.identity)
