#!/usr/bin/env bash
# Capture the same four states in either hand-written or generated counter.
set -euo pipefail
cd "$(dirname "$0")/.."
counter_mode="${1:-counter-reactive}"
case "$counter_mode" in
    counter-reactive) app_name="Reactive Counter"; app_binary="counter_reactive" ;;
    yix-counter) app_name="Yix Counter"; app_binary="yix_counter" ;;
    *) echo "usage: $0 [counter-reactive|yix-counter] [output-directory]" >&2; exit 64 ;;
esac
zig build -Dtest-mode=true "$counter_mode"
shot_directory="${2:-reports/view-dsl/counter/$counter_mode}"
mkdir -p "$shot_directory"
shot_directory="$(cd "$shot_directory" && pwd)"
rpc_directory="$(mktemp -d /tmp/zenit_counter_rpc.XXXXXX)"
app_pid=""
cleanup() {
    if [[ -n "$app_pid" ]]; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    rm -rf "$rpc_directory"
    if rg -q 'error\(gpa\):.*leaked|panic:' "$shot_directory/app.log"; then
        echo "counter capture: app panic or leaked allocation; see $shot_directory/app.log" >&2
        exit 87
    fi
}
trap cleanup EXIT
ZENIT_E2E_FILE_RPC_DIR="$rpc_directory" ZENIT_E2E_ISOLATE_POINTER=1 "zig-out/$app_name.app/Contents/MacOS/$app_binary" >"$shot_directory/app.log" 2>&1 &
app_pid=$!
ZENIT_E2E_FILE_RPC_DIR="$rpc_directory" ZENIT_SHOT_DIR="$shot_directory" bun e2e/counter-reactive.capture.ts
