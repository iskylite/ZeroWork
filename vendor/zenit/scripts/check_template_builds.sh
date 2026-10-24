#!/usr/bin/env bash
# Verify templates/minimal-app, the first external user touch point, actually builds and runs.
#
# -- Why needed --
# The template has no other automation and CI never touches it, so onboarding can break while all
# internal gates stay green: repo examples build via the repo's build.zig directly, not via
# attach().
# Known trap: a build.zig.zon comment suggesting `.path = "/abs/path/to/zenit"` fails, since Zig
# 0.15.2 rejects absolute paths (expects a path relative to the build root).
#
# -- Why copy outside the repo --
# In place, `.path = "../../"` points at the repo root, so the build is self-referential and misses
# copy-to-outside path issues. Copy outside the repo and rewrite the path relative to this repo to
# match an external user's setup.
set -euo pipefail

ZENIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# realpath: macOS mktemp gives /var/folders/..., /var is symlink to /private/var. Unresolved, below
# calculated relative path winds extra layer; Zig can't find package during dependency resolution
# (reports "no module named 'zenit'", not path error, hard to think this way).
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

APP="$WORK/myapp"
cp -r "$ZENIT_ROOT/templates/minimal-app" "$APP"

# Rewrite dependency path: point to this repo, must be relative (Zig rejects absolute).
REL="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$ZENIT_ROOT" "$APP")"
python3 - "$APP/build.zig.zon" "$REL" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s2 = re.sub(r'\.zenit = \.\{ \.path = "[^"]*" \}', f'.zenit = .{{ .path = "{sys.argv[2]}" }}', s)
assert s2 != s, "未能改写 .zenit 依赖路径——模板结构变了？"
p.write_text(s2)
PY

cd "$APP"
echo "==> zig build（模板默认目标）"
zig build

test -x zig-out/bin/myapp || { echo "FAIL: 未产出可执行文件 zig-out/bin/myapp" >&2; exit 1; }

if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "==> zig build app（.app bundle）"
    zig build app
    test -d "zig-out/My App.app" || { echo "FAIL: 未产出 .app bundle" >&2; exit 1; }
fi

# -- README's complete example must also compile --
# It's the first real code new users see; broken impacts most. Reuse same template scaffolding to
# compile.
echo
echo "==> README 的完整示例"
python3 "$ZENIT_ROOT/scripts/extract_readme_example.py" "$ZENIT_ROOT/README.md" "$APP/src/main.zig"
zig build

echo
echo "✓ 模板在仓库外可构建（exe + .app bundle）；README 完整示例可编译"
