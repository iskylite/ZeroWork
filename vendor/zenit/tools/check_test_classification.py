#!/usr/bin/env python3
"""Audit project test skips and focused tests without scanning installed dependencies."""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP = re.compile(r'return error\.SkipZigTest')
FOCUS = re.compile(r'QUARANTINED|\b(?:test|describe|it)\.only\b')


def violations(source):
    comments = []
    for line_number, line in enumerate(source.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith('//'):
            comments.append(line)
            continue
        reason = 'SKIP-REASON:' in '\n'.join(comments + [line])
        if FOCUS.search(line) or (SKIP.search(line) and not reason):
            yield line_number, stripped
        comments = []


def self_test():
    cases = [
        ('// SKIP-REASON: unavailable font\n// on minimal CI images\nreturn error.SkipZigTest;', False),
        ('return error.SkipZigTest; // SKIP-REASON: disabled probe', False),
        ('// SKIP-REASON: font\nconst x = 1;\nreturn error.SkipZigTest;', True),
        ('return error.SkipZigTest;', True),
        ('test.only("x", f); // SKIP-REASON: no waiver for focus', True),
        ('// documents test.only without executing it\ntest("x", f);', False),
    ]
    for source, rejected in cases:
        assert bool(list(violations(source))) == rejected, source
    print('test classification mutation tests: PASS')


if __name__ == '__main__':
    self_test()
    # Git's source inventory includes new worktree files, excludes ignored
    # node_modules/build artifacts, and preserves a fail-closed project audit.
    files = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', 'src', 'e2e', 'examples', 'tools'], cwd=ROOT).split(b'\0')
    bad = []
    for raw in files:
        if not raw:
            continue
        path = ROOT / raw.decode()
        if not path.is_file() or path.suffix not in ('.zig', '.ts', '.js'):
            continue
        for line, source in violations(path.read_text(encoding='utf8', errors='ignore')):
            bad.append(f'{path.relative_to(ROOT)}:{line}: {source}')
    if bad:
        print('\n'.join(bad), file=sys.stderr)
        print('unclassified skip, quarantine, or focused test found', file=sys.stderr)
        sys.exit(1)
    print('test classification contract: PASS')
