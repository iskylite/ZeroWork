#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# This gate measures only deterministic in-process samples. It deliberately does
# not claim external RSS or UI CPU values; those require an OS-level harness.
exec zig build vt-perf -- "$@"
