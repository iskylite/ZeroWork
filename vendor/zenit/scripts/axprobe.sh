#!/usr/bin/env bash
# axprobe.sh: compiles (if needed) and runs tools/axprobe/axprobe.swift. Usage same as axprobe, see
# its file header.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/tools/axprobe/axprobe.swift"
BIN="$ROOT/.zig-cache/axprobe/axprobe"
if [[ ! -x "$BIN" || "$SRC" -nt "$BIN" ]]; then
  mkdir -p "$(dirname "$BIN")"
  swiftc -O "$SRC" -o "$BIN"
fi
exec "$BIN" "$@"
