#!/usr/bin/env bash
# Release gate: confirm this working copy can legally be publicly distributed (icons).
#
# This repo holds two icon sets:
#   private/zenit-icons-untitled/  Untitled UI private package, **not for public**
#   src/ui/icons_oss/  Lucide (ISC), public default, redistributable with attribution
#
# build.zig.zon paths cover whole `"src"` (no exclude form in Zig) and omit `private/`, so the Zig
# package payload is isolated; a public Git source export must still exclude the private package.
#
# usage: bash scripts/check_oss_icon_license.sh   # check current copy
#
# **Not run in everyday internal CI** (private assets present, always red); final gate of public
# export.
#
# exit code: 0 can publish, 1 cannot (with reason)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0
say_fail() { echo "[FAIL] $*" >&2; fail=1; }
say_ok()   { echo "[ok]   $*"; }

echo "=== 图标授权发布门禁 ==="

# 1. paid collections must not exist in copy to be published
if [[ -d private/zenit-icons-untitled ]] && find private/zenit-icons-untitled/icons -maxdepth 1 -name '*.svg' -print -quit | grep -q .; then
    n=$(find private/zenit-icons-untitled/icons -maxdepth 1 -name '*.svg' | wc -l | tr -d ' ')
    say_fail "private/zenit-icons-untitled/ 仍有 ${n} 个付费 SVG，不能进入公开 Git source。"
    echo "       修复：公开导出必须排除整个 private/ 目录；私有包单独托管。" >&2
else
    say_ok "Untitled 私有包不在公开副本中"
fi

# 2. open-source collections and their LICENSE must be complete
if [[ ! -d src/ui/icons_oss ]]; then
    say_fail "src/ui/icons_oss/ 不存在 —— 没有可分发的图标集"
else
    n=$(find src/ui/icons_oss -maxdepth 1 -name '*.svg' | wc -l | tr -d ' ')
    if [[ "$n" -lt 100 ]]; then
        say_fail "src/ui/icons_oss/ 只有 ${n} 个 SVG，疑似不完整"
    else
        say_ok "src/ui/icons_oss/ 含 ${n} 个 Lucide SVG"
    fi
    if [[ ! -s src/ui/icons_oss/LICENSE ]]; then
        say_fail "src/ui/icons_oss/LICENSE 缺失 —— ISC 要求声明随副本分发"
    else
        grep -qi 'ISC License' src/ui/icons_oss/LICENSE \
            && say_ok "src/ui/icons_oss/LICENSE 在位（ISC）" \
            || say_fail "src/ui/icons_oss/LICENSE 内容不像 ISC 授权文本"
    fi
fi

# 3. public artifacts must be in place; private artifacts must not enter public copy.
if [[ -f src/ui/icons_lucide_generated.zig ]]; then
    if grep -q '@embedFile("icons_oss/' src/ui/icons_lucide_generated.zig; then
        say_ok "Lucide 生成物使用 icons_oss/ embed 前缀"
    else
        say_fail "icons_lucide_generated.zig 的 embed 前缀不是 icons_oss/"
    fi
else
    say_fail "src/ui/icons_lucide_generated.zig 不存在"
fi

if [[ -f src/ui/icons_common_generated.zig ]] && grep -q '@embedFile("icons_common/' src/ui/icons_common_generated.zig; then
    say_ok "公共基础图标生成物使用 icons_common/"
else
    say_fail "公共基础图标生成物缺失或 embed 路径错误"
fi

grep -q ') orelse "lucide";' build.zig \
    && say_ok "公开默认 icon provider 是 Lucide" \
    || say_fail "build.zig 没有把 Lucide 设为默认 icon provider"

# 4. root LICENSING.md must declare third-party icon attribution
if grep -q 'Lucide icon set' LICENSING.md 2>/dev/null; then
    say_ok "根 LICENSING.md 含 Lucide 第三方声明"
else
    say_fail "根 LICENSING.md 缺少 Lucide 第三方声明"
fi

echo
if [[ "$fail" -eq 0 ]]; then
    echo "✓ 图标授权就绪，可以公开分发。"
else
    echo "✗ 此副本**不可**公开分发，见上面的 FAIL。" >&2
fi
exit "$fail"
