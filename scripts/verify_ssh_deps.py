#!/usr/bin/env python3
"""Bind vendored SSH sources, build recipe/configuration and static archives.

Run normally before linking; --record is used only after build_ssh_deps.sh
successfully rebuilds both libraries. The receipt is a local build artifact.
"""
import argparse
import hashlib
import json
import os
import shlex
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RECEIPT = ROOT / 'vendor/.ssh-build-receipt.json'
ARTIFACTS = ('vendor/libssh2/src/.libs/libssh2.a', 'vendor/mbedtls/library/libmbedcrypto.a',
             'vendor/libssh2/src/libssh2_config.h')
DEFAULTS = {'CC': 'xcrun clang -arch arm64 -mmacosx-version-min=14.0',
            'AR': 'xcrun ar', 'RANLIB': 'xcrun ranlib'}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs():
    names = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others',
                                    '--exclude-standard', 'vendor/libssh2', 'vendor/mbedtls'], cwd=ROOT).split(b'\0')
    paths = {os.fsdecode(n) for n in names if n}
    paths.update(('scripts/build_ssh_deps.sh', 'scripts/verify_ssh_deps.py'))
    h = hashlib.sha256()
    for name in sorted(paths):
        p = ROOT / name
        h.update(name.encode() + b'\0')
        h.update(bytes.fromhex(digest(p)))
    return h.hexdigest()


def snapshot():
    return {'schema': 1, 'source_sha256': inputs(),
            'recipe': {key: os.environ.get(key) or value for key, value in DEFAULTS.items()},
            'environment': {key: os.environ.get(key, '') for key in ('CFLAGS', 'CPPFLAGS', 'LDFLAGS', 'LIBS', 'SDKROOT', 'MACOSX_DEPLOYMENT_TARGET')},
            'compiler': subprocess.check_output(shlex.split(os.environ.get('CC') or DEFAULTS['CC']) + ['--version'], text=True),
            'sdk': subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip(),
            'artifacts': {p: digest(ROOT / p) for p in ARTIFACTS}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record', action='store_true')
    args = parser.parse_args()
    try:
        current = snapshot()
        if args.record:
            tmp = RECEIPT.with_suffix('.tmp')
            tmp.write_text(json.dumps(current, indent=2) + '\n')
            tmp.replace(RECEIPT)
            print('SSH dependency receipt recorded')
        else:
            saved = json.loads(RECEIPT.read_text())
            changed = [key for key in current if saved.get(key) != current[key]]
            if changed:
                raise ValueError('mismatch: ' + ', '.join(changed))
            print('SSH sources/configuration/archives verified')
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f'SSH dependency verification failed: {exc}\nRun scripts/build_ssh_deps.sh before building.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
