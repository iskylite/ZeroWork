#!/usr/bin/env bash
# Detached views only; never creates or activates a native window.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t zenit-memory-contract)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -fobjc-arc -Wno-deprecated-declarations -g -O0 -UNDEBUG \
  -fsanitize=address,undefined \
  "$ROOT/native/macos/tests/memory_diagnostics_test.m" \
  -framework Cocoa -framework Metal -framework IOSurface -framework QuartzCore -framework CoreVideo \
  -framework UniformTypeIdentifiers -o "$TEST_DIR/memory-test"
"$TEST_DIR/memory-test"
