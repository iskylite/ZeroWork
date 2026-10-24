#!/usr/bin/env bash
# Compare two bench JSONs, exit 1 if min_ns regression exceeds threshold.
#
# Usage: scripts/check_bench_regression.sh <baseline.json> <current.json> [threshold_pct]
# threshold_pct defaults to 15 (current.min > baseline.min * 1.15 counts as regression).
#
# Why a threshold alone is insufficient: on unmodified code, **18 of 62 benches varied >15%**
# across 11 runs; a11y_tree_children_50 swung 87% (2613->4875ns). Large jitter is not limited
# to nanoseconds: element_create_append_100 at 12.7us shows 25%.
#
# Single sample + 15% threshold gives periodic false reds, worse than no gate (everyone
# learns to ignore it).
#
# Two safeguards:
#   1. NOISE_FLOOR_NS: below the floor only report, don't block (timer resolution masks
#      differences).
#   2. BENCH_RERUN_CMD: suspect benches are **retested to confirm**: if set, the script reruns
#      the bench and retests; red only if still over threshold, else cleared as outlier ([flaky]).
#      Only suspects are retested, so extra cost is one bench run.
# Without BENCH_RERUN_CMD it degrades to a single verdict and prints a hint.

set -euo pipefail

BASELINE="${1:?baseline.json required}"
CURRENT="${2:?current.json required}"
THRESHOLD_PCT="${3:-15}"
# Benchmark with both old/new min_ns below this value report only don't block (see [noise] branch
# below).
NOISE_FLOOR_NS="${NOISE_FLOOR_NS:-200}"
# Over-threshold retest command: set then rerun and double-check, output to $BENCH_RERUN_OUT.
# Example: BENCH_RERUN_CMD='zig build bench -- json=%OUT%'
BENCH_RERUN_CMD="${BENCH_RERUN_CMD:-}"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required" >&2
    exit 2
fi

# -- fail closed: explicitly validate both inputs first --
# Input validation inside `done < <(jq ...)` process substitution does not propagate failure
# to the main shell (set -e is a no-op on <(...)), and read treats empty input as normal end,
# so the script would print 'All bench checks passed.' and exit 0.
# Three cases passed silently: current.json missing / corrupted / results empty array.
# The last is the worst: no bench ran, jq doesn't even error, the gate is void.
validate_bench_json() {
    local role="$1" path="$2"
    if [[ ! -f "$path" ]]; then
        echo "ERROR: $role JSON not found: $path" >&2
        exit 2
    fi
    if ! jq -e . "$path" >/dev/null 2>&1; then
        echo "ERROR: $role JSON is not valid JSON: $path" >&2
        exit 2
    fi
    if ! jq -e '.results | type == "array"' "$path" >/dev/null 2>&1; then
        echo "ERROR: $role JSON missing '.results' array: $path" >&2
        exit 2
    fi
    local n
    n=$(jq -r '.results | length' "$path")
    if [[ "$n" -eq 0 ]]; then
        echo "ERROR: $role JSON has zero benchmark results: $path" >&2
        echo "       (bench 可能构建失败或未产出 —— 拒绝以空结果放行门禁)" >&2
        exit 2
    fi
    echo "  [validated] $role: $n benchmarks ($path)"
}

validate_bench_json "baseline" "$BASELINE"
validate_bench_json "current"  "$CURRENT"

fail=0
suspects=()
while read -r name; do
    # Use min_ns compare — stronger noise resistance than median; CI runs multiple take min
    base=$(jq -r --arg n "$name" '.results[] | select(.name==$n) | .min_ns' "$BASELINE")
    curr=$(jq -r --arg n "$name" '.results[] | select(.name==$n) | .min_ns' "$CURRENT")
    if [[ -z "$base" || "$base" == "null" ]]; then
        echo "  [skip] $name (no baseline)"
        continue
    fi
    # baseline = 0 usually ReleaseFast dead-code-eliminates entire bench body
    if awk -v b="$base" 'BEGIN{exit !(b == 0)}'; then
        echo "  [skip] $name (baseline=0; bench likely DCE'd)"
        continue
    fi
    # Noise floor: when new/old min_ns are both below NOISE_FLOOR_NS, report only, don't block.
    #
    # On **unchanged** code, frame_dashboard_drawcall_count was 46% off baseline,
    # element_table_unlink_relink 37%, encode_stream_100_rect_homogeneous 22% -- all <200ns
    # microbenchmarks where timer resolution and scheduling jitter mask real differences.
    # A 15% threshold there only makes CI permanently red and trains everyone to ignore it.
    #
    # Over-floor benchmarks (long-running, stable signal) are still strictly gated.
    # The baseline alone misses scale jumps (e.g. 60ns -> 10us): if current is over the floor,
    # the signal is big enough and must enter normal regression judgement.
    if awk -v b="$base" -v c="$curr" -v f="$NOISE_FLOOR_NS" 'BEGIN{exit !(b < f && c < f)}'; then
        ratio_n=$(awk -v c="$curr" -v b="$base" 'BEGIN{printf "%.1f", (c/b)*100}')
        echo "  [noise]   $name: ${base}ns → ${curr}ns (${ratio_n}%; <${NOISE_FLOOR_NS}ns 不阻塞)"
        continue
    fi

    # Calculate ratio = curr / base * 100
    ratio=$(awk -v c="$curr" -v b="$base" 'BEGIN{printf "%.1f", (c/b)*100}')
    pct_over=$(awk -v c="$curr" -v b="$base" -v t="$THRESHOLD_PCT" 'BEGIN{printf "%.1f", ((c/b)-1)*100}')

    if awk -v c="$curr" -v b="$base" -v t="$THRESHOLD_PCT" 'BEGIN{exit !(c > b*(1+t/100))}'; then
        echo "  [over]    $name: ${base}ns → ${curr}ns (+${pct_over}%, threshold ${THRESHOLD_PCT}%) — 待复测确认"
        suspects+=("$name")
    else
        echo "  [ok]      $name: ${base}ns → ${curr}ns (${ratio}%)"
    fi
done < <(jq -r '.results[].name' "$CURRENT")

# ── retest confirm ────────────────────────────────────────────────────────
# Only over-threshold benches need second verify, so one retest round covers all suspect.
if [[ ${#suspects[@]} -eq 0 ]]; then
    echo "All bench checks passed."
    exit 0
fi

if [[ -z "$BENCH_RERUN_CMD" ]]; then
    echo ""
    echo "  ⚠ 未设置 BENCH_RERUN_CMD，无法复测确认，按单次结果判定。"
    echo "    实测该套 bench 有 18/62 抖动 >15%，单次超标很可能是离群。"
    echo "    建议：BENCH_RERUN_CMD='zig build bench -- json=%OUT%' 重跑本脚本。"
    for s in "${suspects[@]}"; do
        echo "  [REGRESS] $s"
    done
    echo "Bench regression detected." >&2
    exit 1
fi

echo ""
echo "── 复测确认 ${#suspects[@]} 个超标 bench ──"
rerun_out=$(mktemp -t bench_rerun.XXXXXX.json)
trap 'rm -f "$rerun_out"' EXIT
rerun_cmd="${BENCH_RERUN_CMD//%OUT%/$rerun_out}"
if ! eval "$rerun_cmd" >/dev/null 2>&1; then
    echo "  ✗ 复测命令执行失败：$rerun_cmd" >&2
    echo "Bench regression detected (复测不可用，按单次结果判定)." >&2
    exit 1
fi
validate_bench_json "rerun" "$rerun_out"

for name in "${suspects[@]}"; do
    base=$(jq -r --arg n "$name" '.results[] | select(.name==$n) | .min_ns' "$BASELINE")
    again=$(jq -r --arg n "$name" '.results[] | select(.name==$n) | .min_ns' "$rerun_out")
    if [[ -z "$again" || "$again" == "null" ]]; then
        echo "  [REGRESS] $name: 复测数据缺失，保守判红"
        fail=1
        continue
    fi
    pct2=$(awk -v c="$again" -v b="$base" 'BEGIN{printf "%.1f", ((c/b)-1)*100}')
    if awk -v c="$again" -v b="$base" -v t="$THRESHOLD_PCT" 'BEGIN{exit !(c > b*(1+t/100))}'; then
        echo "  [REGRESS] $name: 复测仍超标 ${base}ns → ${again}ns (+${pct2}%) —— 判定为真回退"
        fail=1
    else
        echo "  [flaky]   $name: 复测回到 ${again}ns (+${pct2}%) —— 首次为离群，不阻塞"
    fi
done

if [[ $fail -ne 0 ]]; then
    echo "Bench regression detected." >&2
    exit 1
fi
echo "All bench checks passed (含复测确认)."
