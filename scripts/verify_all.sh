#!/bin/bash
# 全量验收：47 张 mockup 构建 + 生产构建 + 全部测试
set -e
cd "$(dirname "$0")/.."
echo "== mockups =="
scripts/build_all_mockups.sh | tail -1
echo "== production build =="
zig build
echo "== tests =="
./scripts/test_isolated.sh test
echo "ALL GREEN"
