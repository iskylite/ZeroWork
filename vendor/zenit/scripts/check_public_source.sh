#!/usr/bin/env bash
# Audit publishable Git files, or every file of an extracted source archive.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  "") ;;
  --archive) export ZENIT_PUBLIC_SOURCE_ARCHIVE=1 ;;
  *) echo "usage: bash scripts/check_public_source.sh [--archive]" >&2; exit 2 ;;
esac
python3 - <<'PY'
import os, pathlib, re, subprocess, sys
root = pathlib.Path.cwd().resolve()
git_root = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
if os.environ.get('ZENIT_PUBLIC_SOURCE_ARCHIVE') != '1' and git_root.returncode == 0 and pathlib.Path(git_root.stdout.strip()).resolve() == root:
    raw = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'])
    files = sorted(set(os.fsdecode(p) for p in raw.split(b'\0') if p))
else:
    files = [str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() or p.is_symlink()]
forbidden_roots = ('private/', 'docs/internal/', 'docs/reviews/', 'docs/research/', 'scripts/glass_native_model/')
research_path = re.compile(r'(?:^|/)(?:[^/]*calibrat[^/]*|glass-review-report\.[^/]+)$|^e2e/native_(?:liquid_glass|glass_motion)\.swift$')
forbidden_names = {'.git', '.DS_Store', '.zig-cache', 'zig-cache', 'zig-pkg', 'zig-out', '__pycache__',
                   'node_modules', '.claude', '.codex', '.agents', '.ci-evidence', 'release-evidence',
                   '.zig-local-cache', '.zig-global-cache', '.bench-output', '.codex-worktrees'}
artifact_suffixes = {'.o', '.a', '.so', '.dylib', '.exe', '.log', '.pyc', '.pyo', '.swp', '.swo', '.bundle', '.zip'}
credential = re.compile(rb'-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[0-9A-Za-z]{20,}|github_pat_[0-9A-Za-z_]{20,}|sk-[0-9A-Za-z]{20,}')
local_path = re.compile(rb'/Users/(?!(?:USER|user|username|you|test)/)[A-Za-z0-9_.-]+/|/private/tmp/claude-[0-9]+|/tmp/zenit-zig[0-9]+(?:/|\b)|http://192\.168\.[0-9.]+')
problems = []
for name in files:
    file = root / name
    if not file.exists() and not file.is_symlink():
        continue  # tracked deletion
    parts = pathlib.PurePosixPath(name).parts
    if file.is_symlink(): problems.append((name, 'symbolic link')); continue
    if any(name.startswith(p) for p in forbidden_roots) or research_path.search(name) or any(p in forbidden_names for p in parts):
        problems.append((name, 'private/cache path')); continue
    if any(p.startswith('.env') or p.startswith('._') or p.endswith(('.app', '.dSYM')) for p in parts) or file.suffix in artifact_suffixes:
        problems.append((name, 'secret/build artifact path')); continue
    data = file.read_bytes()
    if credential.search(data): problems.append((name, 'possible credential/private key'))
    if b'\0' not in data and local_path.search(data): problems.append((name, 'machine-specific path/host'))
required = ['LICENSE', 'LICENSING.md', 'templates/LICENSE', 'examples/LICENSE',
            'src/ui/icons_oss/LICENSE', 'vendor/unicode/LICENSE.txt', 'vendor/zls/LICENSE',
            'vendor/zls/PROVENANCE.md', 'vendor/zls/tests/build_system/zig017.py',
            'tools/fixtures/fonts/Lora-OFL.txt', 'tools/yix_lsp.zig', 'tests/yix/lsp/smoke.py']
for name in required:
    if not (root / name).is_file() or not (root / name).stat().st_size:
        problems.append((name, 'required source/license missing'))
if problems:
    for name, reason in problems: print('FAIL ' + reason + ': ' + name, file=sys.stderr)
    sys.exit(1)
print(f'Public source audit: PASS ({len(files)} candidate files; ZLS and license notices present)')
PY
