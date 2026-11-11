#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t zerowork-embedded-host)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -fobjc-arc -Wno-deprecated-declarations \
  -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation \
  "$ROOT/e2e/web_embedded_host_test.m" \
  -framework Cocoa -framework Metal -framework IOSurface -framework QuartzCore \
  -framework CoreVideo -framework UniformTypeIdentifiers \
  -o "$TEST_DIR/web-embedded-host-test"
"$TEST_DIR/web-embedded-host-test"
