#!/usr/bin/env bash
# Deletion/architecture gate. Asserts semantic invariants (removed APIs, fields, dependency
# boundaries) rather than freezing implementation file line counts. File size is a review
# signal; the stable assertions block PRs.
#
# Usage: scripts/check_v04_deletions.sh [phase]
#   phase: P1|P2|P3|P4|P5|P6|P9C|all (default all = check all)
#
# Exit codes: 0 pass; 1 deprecated remnants; 2 script error

set -euo pipefail

PHASE="${1:-all}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0

check_file_absent() {
    local f="$1"
    local phase_tag="$2"
    if [[ -f "$f" ]]; then
        echo "  [FAIL $phase_tag] file still exists: $f"
        fail=1
    else
        echo "  [ok   $phase_tag] file deleted: $f"
    fi
}

check_symbol_absent() {
    local sym="$1"
    local phase_tag="$2"
    local search_dir="${3:-src/}"
    # Exclude self + mentions in comments (v0.3 deprecated comments naming symbols is legal)
    local hits
    hits=$(grep -rn "\\b${sym}\\b" "$search_dir" 2>/dev/null \
        | grep -v "DEPRECATED\|废弃\|删除\|deleted\|deprecated\|//" \
        | grep -v ".md:" || true)
    if [[ -n "$hits" ]]; then
        echo "  [FAIL $phase_tag] symbol still referenced: $sym"
        echo "$hits" | head -5 | sed 's/^/      /'
        fail=1
    else
        echo "  [ok   $phase_tag] symbol absent: $sym"
    fi
}

# Ratchet note (no longer a CI threshold). Large files were shrunk only by extracting pure
# functions with isolated unit tests, no logic changes. Three items intentionally stopped:
# hooks.zig (tests moved to a separate file); display_list_lowering.zig (no extractable tests,
# dense impl; its defer OOM handling cannot propagate errors, so a mismatched scope silently
# corrupts); node.zig (struct extraction to node/parts.zig costs a 104-line import/alias block,
# coupling cost > lines saved).
# Principle: **further squeezing reduces code quality**. Only tackle with a structural cause
# (e.g. alias modularization), not to minimize numbers.

if [[ "$PHASE" == "P1" || "$PHASE" == "all" ]]; then
    echo "=== v0.4-P1: layout main path / fitResizeAfterLayout ==="
    check_symbol_absent "fitResizeAfterLayout" "P1"
    # v0.5-P1 strict enforce: reactive Store.patch dead code removal (plan main doc required)
    check_symbol_absent "Store\\.patch" "P1"
fi

if [[ "$PHASE" == "P2" || "$PHASE" == "all" ]]; then
    echo "=== v0.5-P2: render IR removal (Stage B 已完成 2026-05-07) ==="
    # Stage B done: RenderCommand IR completely dead, encoder consumes DisplayItem directly.
    # render_command.zig physically deleted (commit 3636323). display_list_replay.zig
    # physically deleted (2026-05-08), renamed to display_list_lowering.zig because after
    # RenderCommand IR death, no "replay" semantics remain, only local->world lowering.

    # render_command.zig banned from recreation
    check_file_absent "src/ui/core/render_command.zig" "P2"

    # RenderCommand IR enum 0-refs enforce -- word-boundary exclude RenderCommandEncoder
    # (Metal API / encoder struct name)
    rc_refs=$( { rg "\bRenderCommand\b" --type zig -c . </dev/null 2>/dev/null || true; } | awk -F: 'BEGIN{s=0} {s+=$2} END {print s+0}')
    rc_files=$( { rg "\bRenderCommand\b" --type zig -l . </dev/null 2>/dev/null || true; } | wc -l | tr -d ' ')
    if [[ "$rc_refs" -gt 0 ]]; then
        echo "  [FAIL P2] RenderCommand refs regressed: $rc_refs > 0 (IR 已删，不允许重建)"
        fail=1
    else
        echo "  [ok   P2] RenderCommand refs 0 (IR 彻底死)"
    fi
    if [[ "$rc_files" -gt 0 ]]; then
        echo "  [FAIL P2] RenderCommand consumer files regressed: $rc_files > 0"
        fail=1
    else
        echo "  [ok   P2] RenderCommand consumer files 0"
    fi
    # command_encoder.zig ratchet, capped at 2600 (margin over the 2585 actual).
    # Zero-encoder-state pure function clusters live in separate files with their own unit tests:
    #   paint_fingerprint.zig  damage bounds / content fingerprint / struct folding
    #   local_sort.zig         local-sort geometry bounds
    #   path_polygon.zig       path -> clip polygon flattening
    #   font_selector.zig      font tier selection (zero coupling to encoder)
    #   command_encoder_test.zig  16 unit tests
    # Other extractions: backdrop_blur, offscreen_texture, opacity_layer.
    echo "  [info P2] command_encoder.zig $(wc -l < src/render/command_encoder.zig | tr -d ' ') lines (review signal only)"

    # compositor_plan: Stage A deleted
    if [[ -e src/ui/core/compositor_plan.zig ]]; then
        echo "  [FAIL P2] compositor_plan.zig regressed: file recreated after Stage A delete"
        fail=1
    else
        echo "  [ok   P2] compositor_plan.zig deleted (Stage A complete)"
    fi
    check_symbol_absent "CompositorPlan" "P2"

    # display_list_lowering.zig: physically deleted display_list_replay.zig (2026-05-08),
    # renamed to reflect lost IR means only local->world lowering remains. Line count is
    # review signal, not CI contract. 2026-07: bracket_debug extraction 606->560;
    # appendLoweredBoth helper 560->592 (replaces cx.lowerForEncoderPaintTable loops).
    if [[ -e src/ui/core/render_engine/display_list_replay.zig ]]; then
        echo "  [FAIL P2] display_list_replay.zig regressed: file recreated after rename to display_list_lowering.zig"
        fail=1
    else
        echo "  [ok   P2] display_list_replay.zig physically deleted (renamed to display_list_lowering.zig)"
    fi
    echo "  [info P2] display_list_lowering.zig $(wc -l < src/ui/core/render_engine/display_list_lowering.zig | tr -d ' ') lines (review signal only)"
fi

if [[ "$PHASE" == "P3" || "$PHASE" == "all" ]]; then
    echo "=== v0.4-P3: Node god-object split (DEFERRED → v0.5) ==="
    # Node top-level field ratchet (count only top-level Node struct fields, not sub-struct or
    # helper fields). Intent: prevent Node god-object backflow. Each field audited:
    #   world_id / world_ref      ElementId lacks World identity, causes cross-window false match
    #   alive_sentinel            survival sentinel: immediate panic on double-free vs silent UAF
    #   deferred_disposal /       lifecycle: deferred free + freeing mark, fixes reentry like
    #   pending_free_cx /         'free self in own callback'
    #   freeing
    #   cursor_query /            cursor region query callback + context
    #   cursor_query_context
    #   on_capture_lost           pointer capture lost notification
    # These are per-node identity/lifecycle/callbacks that SoA cannot hold, not convenience
    # fields. A permanently red ratchet has no teeth and breaks the CONTRIBUTING gate.
    #
    # Still 'prohibit growth': new fields first try SoA in World (see node.zig header field
    # disposition contract); if they must live on Node, add a rationale line here before
    # raising the limit.
    fc=$(awk '/^pub const Node = struct/,/^};/' src/ui/core/node.zig | grep -E "^    [a-z_]+: " | wc -l | tr -d ' ')
    if [[ "$fc" -gt 18 ]]; then
        echo "  [FAIL P3] Node fields grew: $fc > 18 (2026-09-22 重基线，禁再增长)"
        fail=1
    else
        echo "  [ok   P3] Node has $fc fields ≤ 18 (ratchet 上限)"
    fi

    # v0.5-P3 N-2 ratchet (2026-05-03): frame_state.rect semantics downgrade to 'internal scratch +
    # fallback storage', external consumers must use rectFromWorldOrFallback. Current 94 references
    # all in legal positions (layout_engine 73 + node.zig fallback 5 + core.zig sync/integrity 7 +
    # render_context fallback 3 + tests perturb 4 + node_animator anytype 2). True field deletion
    # requires layout_engine LayoutTable switch, multi-session epic. Ratchet: 94 no growth; decrease
    # when reducing.
    #
    # v0.5-P3 N-2 (2026-05-03): frame_state.rect field physically deleted -- Node lacks field.
    # Remaining references only in comments (8) + node_animator.zig MockNode duck-typing (3) = 11.
    # MockNode defines its own frame_state.rect is test mock fixture internal detail. 2026-05-10:
    # test_harness/tree_serializer.zig doc comment +1 -> 12.
    if awk '/^pub const NodeFrameState = struct/,/^};/' src/ui/core/node.zig \
        | rg -q '^\s*rect\s*:'; then
        echo "  [FAIL P3] NodeFrameState.rect field regressed"
        fail=1
    else
        echo "  [ok   P3] NodeFrameState.rect field remains deleted"
    fi

    # v0.5-P3 Node god-object line count ratchet (2026-05-04). True decomposition N-3+ multi-session
    # epic; intermediate ratchet prevents dead method bounce. 2026-05-13 (v0.9-sec a stage 1): +50
    # lines add NodeContent SoA write hooks + accessor (setText/setImage/setIcon + get*); 1945 ->
    # 2000. 2026-05-13 (v0.9-sec a stage 2 end): +10 lines setText smart fixup path (distinguish
    # inline_buf vs external slice); 2000 -> 2020. 2026-05-13 (v0.9-sec a stage 3): +60 lines read
    # hooks + standalone fallback (NodeContent in-place fields deleted, content all World.content /
    # fallback); 2020 -> 2090. 2026-05-13 (v0.9-sec b stage 2): +25 lines PaintState SoA write hooks
    # + getBackground/getOpacity accessor; 2090 -> 2120. Fields deleted but supporting infra grows
    # (read callback set + three setX/getX groups via SoA); line reduction needs extracting these
    # hooks to separate file (e.g. content_accessor.zig), v0.9-sec a stage 4 candidate (out of
    # scope). 2026-05-16 (v0.9-sec b stage 3a): +14 lines setBackgroundRaw/setOpacityRaw
    # side-effect-free write entry (for internal/animation/builder, avoid setter transition+dirty);
    # 2120 -> 2130. 2026-05-16 (v0.9-sec b stage 4): +64 lines paint state SoA inversion infra --
    # read route callback (g_paint_bg_read/opacity_read) + standalone fallback hashmap
    # (g_standalone_paint_bg/opacity, dual to sec a content fallback) +
    # getBackground/getOpacity/setXRaw all via World/standalone (no in-place field touch).
    # Style.background/opacity fields physically deleted (types.zig), source-of-truth inverted to
    # World.paint_state. node.zig line growth is accessor infra concentrated here; Style struct
    # shrinks. 2130 -> 2200. Later candidate: god-object split (accessor extracted to
    # paint_accessor.zig). 2026-05-16 (v0.9 god-object split): sec a content + sec b paint
    # callback/standalone-fallback/route all extracted to paint_content_accessor.zig; node.zig top 6
    # content + 4 paint methods reduced to thin one-liner delegate. 2194 -> 2031 (-163). Ratchet
    # tightened 2200 -> 2040 lock net decrease, prevent backflow. 2026-05-16 (v0.10-sec L stage 1):
    # NodeLayoutOutput etc 5 struct moved to node_layout_output.zig (re-export kept) + add
    # LayoutOutput SoA mirror callback/registrar +
    # getLayoutOutput/setLayoutOutput/syncLayoutOutputMirror accessor. Struct move line savings
    # offset by accessor/callback, net 2031 -> 2040. Ratchet set 2050 leave stage 1 margin; stage 3
    # after visuals deletion yields net big drop, tighten then. 2026-05-17 (v0.12-sec N1 stage 1):
    # dirty propagation 15 methods extracted to node_dirty.zig (Node-typed free function + node.zig
    # thin delegate). 2045 -> 1811 (-234). Ratchet tightened 2050 -> 1820. 2026-05-17 (v0.12-sec N2
    # stage 2): render cache 6 methods + TextHashSnapshot extracted to node_render_cache.zig
    # (buildCachedRenderSlice converted to module-level free fn). 1811 -> 1657 (-154). Ratchet
    # tightened 1820 -> 1670. 2026-05-17 (v0.12-sec N3 stage 3): interaction/hit 17 methods
    # (non-contiguous, per-method migration) + invalidateCustomClipGeometryCache extracted to
    # node_interaction.zig. 1657 -> 1571 (-86). Ratchet tightened 1670 -> 1580. 2026-05-17
    # (v0.12-sec N4 stage 4): lifecycle (create/destroy/release*/fire*/clearNodeScopes) +
    # geometry/rect (rectFromWorldOrFallback/setLayout*/globalRect) + rect callback unit +
    # standalone fallback rect storage (sec L pitfall core, move whole to prevent half) extracted to
    # node_lifecycle.zig. 1571 -> 1384 (-187). Ratchet tightened 1580 -> 1395. 2026-05-17 (v0.12-sec
    # N5 stage 5, final): tree structure 7 methods (append/remove*/replaceChildOrder/isDescendantOf)
    # + structure callback unit extracted to node_tree.zig. 1384 -> 1333 (-51). v0.12 epic close:
    # node.zig 2045 -> 1333 (-712, -35%), 5 submodules
    # (dirty/render_cache/interaction/lifecycle/tree). Ratchet tightened 1395 -> 1340 final lock.
    echo "  [info P3] node.zig $(wc -l < src/ui/core/node.zig | tr -d ' ') lines (review signal only)"
fi

if [[ "$PHASE" == "P4" || "$PHASE" == "all" ]]; then
    echo "=== v0.4-P4: Builder API removal (DEFERRED → v0.5) ==="
    # v0.4-P4 investigation: ScrollAreaBuilder 24 test + 5 production = 29 callsite changes.
    # GridBuilder + CardGridBuilder similar scale. Actual deletion effort exceeds single-phase
    # budget; deferred to v0.5 with public API finalization. Current ratchet: ref counts
    # locked, zero on actual deletion. CardGridBuilder actually deleted -- enforce no regression.
    check_symbol_absent "CardGridBuilder" "P4"

    # Original deletion intent: eliminate builder setter chains. As of 2026-10-02
    # Signal-first, all components standardized to `X(props).mount(...)`; Builder carries
    # mount-family methods (ScrollArea/Grid reverted to this form). Invariant: 'component
    # Builder has no setters' (Input/Textarea migrated, inventory cleared).
    # Validate mount/view adapter signatures and reject setter returns, including
    # pointer receivers and multiline declarations. The checker mutation-tests
    # its permitted adapters so this cannot become a name-only escape hatch.
    if ! python3 tools/check_component_builder_methods.py; then
        echo "  [FAIL P4] component builder setter (props go in the literal)"
        fail=1
    else
        echo "  [ok   P4] component builders carry no setters"
    fi

    # The split is structural: tests stay in their own module and are explicitly
    # collected. Adding more coverage must not break the gate.
    hooks_tests=$(rg -c '^test "' src/ui/hooks_test.zig 2>/dev/null || true)
    if [[ -z "$hooks_tests" || "$hooks_tests" -lt 20 ]] || ! rg -q '@import\("hooks_test\.zig"\)' src/ui/ui.zig; then
        echo "  [FAIL P4] hooks test split lost coverage: expected at least 20 tests and explicit ui.zig import"
        fail=1
    else
        echo "  [ok   P4] hooks test split preserves $hooks_tests explicitly collected tests"
    fi
fi

if [[ "$PHASE" == "P5" || "$PHASE" == "all" ]]; then
    echo "=== v0.4-P5: text legacy removal (✅ v0.5 §5 完成) ==="
    # measureTextWidth free function is deleted; external callers use measureTextWidthByFontKind
    # (converges to private measureProportional) or cx.shapeText (GlyphRun + ShapingCache).
    # The gate matches the exact deleted API shape, not a bare name plus path whitelist: same-named
    # unrelated methods (FontSelector.measureTextWidth, Cx.measureTextWidth) are legal.
    # Rules:
    #   (a) No file may declare a free function measureTextWidth (method form
    #       `pub fn measureTextWidth(self: ...)` is legal; first param not self = deleted form).
    #   (b) No call of the qualified/free form (text_layout.measureTextWidth(...) or bare
    #       measureTextWidth(...)).
    # Names with suffix measureTextWidthByFontKind / ...WithSpans / ...Callback /
    # measureMonospaceTextWidth are excluded by \b + following `(` or `,` shape.

    # (a) Free function declaration: pub fn measureTextWidth( with first param not self
    mtw_free_decl=$( (rg -n "^\s*(pub )?fn measureTextWidth\s*\(" --type zig . </dev/null 2>/dev/null || true) \
        | (grep -v "fn measureTextWidth\s*(\s*self\s*:" || true) \
        | wc -l | tr -d ' ')
    if [[ "$mtw_free_decl" != "0" ]]; then
        echo "  [FAIL P5] measureTextWidth 自由函数声明复活: $mtw_free_decl 处 (Phase E 已物理删，替代品 measureTextWidthByFontKind)"
        (rg -n "^\s*(pub )?fn measureTextWidth\s*\(" --type zig . </dev/null 2>/dev/null || true) \
            | (grep -v "fn measureTextWidth\s*(\s*self\s*:" || true) | head -5 | sed 's/^/      /'
        fail=1
    else
        echo "  [ok   P5] measureTextWidth 自由函数声明 0 处 (真删完工)"
    fi

    # (b) Free function / module-qualified calls. Exclude `.measureTextWidth(` method calls
    # (preceded by `.`, receiver not text_layout module alias).
    mtw_free_call=$( (rg -n "(^|[^.\w])measureTextWidth\s*\(|\btext_layout\.measureTextWidth\s*\(" --type zig . </dev/null 2>/dev/null || true) \
        | (grep -v "fn measureTextWidth" || true) \
        | wc -l | tr -d ' ')
    if [[ "$mtw_free_call" != "0" ]]; then
        echo "  [FAIL P5] measureTextWidth 自由函数调用点复活: $mtw_free_call 处"
        (rg -n "(^|[^.\w])measureTextWidth\s*\(|\btext_layout\.measureTextWidth\s*\(" --type zig . </dev/null 2>/dev/null || true) \
            | (grep -v "fn measureTextWidth" || true) | head -5 | sed 's/^/      /'
        fail=1
    else
        echo "  [ok   P5] measureTextWidth 自由函数调用点 0 处 (caller 全走 measureTextWidthByFontKind / cx.shapeText)"
    fi
    check_symbol_absent "isBreakable" "P5"
fi

if [[ "$PHASE" == "P6" || "$PHASE" == "all" ]]; then
    echo "=== v0.4-P6: a11y + select 旧版 removal ==="
    # Both files physically deleted (2026-04-26):
    # - src/ui/components/select.zig -> select_headless (mountSelectHeadless replacement)
    # - src/ui/accessibility.zig -> AccessibilityBridge inlined to src/ui/focus.zig
    check_file_absent "src/ui/accessibility.zig" "P6"
    check_file_absent "src/ui/components/select.zig" "P6"
fi

if [[ "$PHASE" == "P9C" || "$PHASE" == "all" ]]; then
    echo "=== v0.9-§c: LoweringBuffers.main 物理删 + display_list 降私有 ==="
    # c3 (2026-05-13): LoweringBuffers.main field renamed to _dead_main placeholder;
    # no active append/read. Next epic deletes RenderContext.lowering_buffer param, then
    # field can be physically deleted.
    if grep -q '^    main: std\.ArrayList(display_list_mod\.DisplayItem)' src/ui/core.zig; then
        echo "  [FAIL P9C] LoweringBuffers.main 仍存在 (应 rename 为 _dead_main 或删除)"
        fail=1
    else
        echo "  [ok   P9C] LoweringBuffers.main 字段已删除"
    fi
    # c4: display_list.zig used only internally by core/ (including src/ui/core.zig itself)
    out_of_core=$( { grep -rln '@import.*display_list' src/ --include='*.zig' || true; } | { grep -vE 'src/ui/core/|src/ui/core\.zig$' || true; } | wc -l | tr -d ' ')
    if [[ "$out_of_core" -gt 0 ]]; then
        echo "  [FAIL P9C] display_list.zig 仍被 core/ 外模块 import ($out_of_core 个文件)"
        fail=1
    else
        echo "  [ok   P9C] display_list.zig 仅 core/ 内部使用 (out_of_core=0)"
    fi
fi

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "architecture invariant gate FAILED ($PHASE)"
    exit 1
fi

echo ""
echo "architecture invariant gate passed ($PHASE)"
