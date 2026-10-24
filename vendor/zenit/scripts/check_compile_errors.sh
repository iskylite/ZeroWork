#!/usr/bin/env bash
# Compile-error test cases: locks Signal-first props API compile-time error text
# (docs/SIGNAL_API_DESIGN.md §4.6). Each tests/compile_errors/*.zig starts with
# `// expect: <substring>`; cases must fail to compile with error containing substring.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ZIG="${ZIG:-zig}"
fail=0
for f in tests/compile_errors/*.zig; do
    expect="$(head -1 "$f" | sed -n 's#^// expect: ##p')"
    if [[ -z "$expect" ]]; then
        echo "  [FAIL] $f: missing '// expect:' header"; fail=1; continue
    fi
    if out="$("$ZIG" test --dep reactive -Mroot="$f" --dep zenit_reflection -Mreactive=src/ui/reactive.zig -Mzenit_reflection=src/reflection.zig 2>&1)"; then
        echo "  [FAIL] $f: compiled successfully, expected an error"; fail=1; continue
    fi
    if grep -qF -- "$expect" <<<"$out"; then
        echo "  [ok]   $f"
    else
        echo "  [FAIL] $f: error text did not contain: $expect"
        grep "error:" <<<"$out" | head -3 | sed 's/^/         /'
        fail=1
    fi
done
exit $fail
