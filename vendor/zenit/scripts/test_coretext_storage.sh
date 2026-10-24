#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t zenit-coretext-storage)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -fobjc-arc "$ROOT/native/macos/tests/coretext_storage_test.m" \
  -framework CoreText -framework CoreGraphics -framework Foundation -framework ImageIO \
  -o "$TEST_DIR/coretext-storage-test"
# Optional absolute PNG path; no window or desktop interaction is required.
"$TEST_DIR/coretext-storage-test" "$@"
