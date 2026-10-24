#!/usr/bin/env bash
# Hidden AppKit windows only: no desktop ordering, real input or fullscreen Space.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t zenit-fs-header)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -fobjc-arc -Wno-deprecated-declarations \
  -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation \
  "$ROOT/native/macos/tests/fullscreen_header_lifecycle_test.m" \
  -framework Cocoa -framework Metal -framework IOSurface -framework QuartzCore -framework CoreVideo \
  -framework UniformTypeIdentifiers -o "$TEST_DIR/fullscreen-header-test"
ZENIT_E2E_BACKGROUND=1 "$TEST_DIR/fullscreen-header-test" "$@"
