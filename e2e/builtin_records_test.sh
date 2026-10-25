#!/bin/sh
# Standalone tests need no UI aggregator, network, external service or app UI.
set -eu
cd "$(dirname "$0")/.."
builtin_records_tmp=$(mktemp -d /tmp/zw-builtin-records-test.XXXXXX)
trap 'rm -rf "$builtin_records_tmp"' EXIT HUP INT TERM
zig translate-c -I vendor/libghostty-vt/include vendor/libghostty-vt/include/ghostty/vt.h > "$builtin_records_tmp/vt.zig"
zig test --dep generated_ghostty_vt -Mroot=src/builtin_records_tests.zig -Mgenerated_ghostty_vt="$builtin_records_tmp/vt.zig" -L vendor/libghostty-vt -lghostty-vt -lc --test-filter builtin_records
