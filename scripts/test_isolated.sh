#!/bin/sh
# Test recordings and configuration must never enter the user's App data.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zerowork-unit.XXXXXX")
TASK_DIR=$(CDPATH= cd -- "$TASK_DIR" && pwd -P)
trap 'rm -rf "$TASK_DIR"' EXIT HUP INT TERM
cd "$ROOT"
if [ "$#" -eq 0 ]; then set -- test test-ui; fi
ZEROWORK_DATA_DIR="$TASK_DIR/data" zig build "$@"
