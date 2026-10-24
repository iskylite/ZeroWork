#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t zenit-window-geometry)"
trap 'rm -rf "$TEST_DIR"' EXIT
clang -std=c11 -Wall -Wextra -Werror -fsanitize=undefined \
  "$ROOT/native/windows/tests/window_geometry_test.c" -o "$TEST_DIR/window-geometry"
"$TEST_DIR/window-geometry"
