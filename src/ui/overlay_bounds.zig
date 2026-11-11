const ui = @import("ui");

pub fn visibleRect(node: *const ui.Node) ?ui.ComputedRect {
    if (!node.isDisplayedInTree() or node.isPaintSkipped()) return null;
    const rect = node.globalRect();
    return if (rect.w > 0 and rect.h > 0) rect else null;
}

pub fn intersects(a: ui.ComputedRect, b: ui.ComputedRect) bool {
    return a.w > 0 and a.h > 0 and b.w > 0 and b.h > 0 and
        a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

pub fn blocks(cx: *const ui.Cx, node: *ui.Node) bool {
    const rect = visibleRect(node) orelse return false;
    for (&cx.overlay_stack.layers) |*maybe| if (maybe.*) |*layer| {
        if (layer.suspended or layer.state == .exiting or (layer.config.scoped_dialog and !layer.config.scoped_mask)) continue;
        const barrier = layer.barrier_node orelse continue;
        if (!barrier.frame_state.state_bits.flags.hit_test_visible or node.isDescendantOf(barrier)) continue;
        if (visibleRect(barrier)) |covered| if (intersects(rect, covered)) return true;
    };
    return false;
}
