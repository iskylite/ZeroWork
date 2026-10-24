#!/usr/bin/env bash
# A passing runner must fail the gate when allocator deinit reports a leak.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d /tmp/zenit-e2e-leak-contract.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
cat >"$TEST_DIR/app" <<'APP'
#!/usr/bin/env bash
trap 'printf "%s\n" "$LEAK_LINE" >&2; exit 0' TERM
while true; do sleep 0.1 & wait "$!"; done
APP
cat >"$TEST_DIR/bun" <<'BUN'
#!/bin/sh
sleep 0.4
exit 0
BUN
chmod +x "$TEST_DIR/app" "$TEST_DIR/bun"
check() {
  local name="$1" line="$2" expected="$3" rc=0
  LEAK_LINE="$line" ZENIT_E2E_SKIP_BUILD=1 \
    ZENIT_E2E_APP="$TEST_DIR/app" ZENIT_E2E_BUN="$TEST_DIR/bun" \
    ZENIT_E2E_APP_LOG="$TEST_DIR/$name.log" \
    ZENIT_E2E_EVIDENCE_DIR="$TEST_DIR/$name" \
    ZENIT_CRASH_REPORT_DIR="$TEST_DIR/no-crash-reports" \
    bash scripts/run_storybook_e2e.sh >"$TEST_DIR/$name-run.log" 2>&1 || rc=$?
  if (( rc != expected )); then
    cat "$TEST_DIR/$name-run.log" >&2
    echo "$name: expected exit $expected, got $rc" >&2
    exit 1
  fi
  if (( expected == 87 )); then
    grep -q '"status": "FAIL"' "$TEST_DIR/$name/manifest.json"
    grep -q '"failure_kind": "gpa_leak_at_exit"' "$TEST_DIR/$name/manifest.json"
  else
    grep -q '"status": "PASS"' "$TEST_DIR/$name/manifest.json"
  fi
  zig build evidence-validate -- "$TEST_DIR/$name/manifest.json" --require-artifacts
  echo "PASS: $name"
}
check zig015 'error(gpa): memory address 0x1234 leaked:' 87
check zig017 'error(DebugAllocator): memory address 0x1234 leaked:' 87
check unrelated-scope 'error(example): simulated leaked fixture' 0
check no-leak 'error(DebugAllocator): unrelated diagnostic' 0
echo "E2E allocator leak contract: 4/4 PASS"
