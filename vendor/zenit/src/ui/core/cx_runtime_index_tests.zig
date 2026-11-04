//! Focused regressions for interaction dirty invalidation during paint-only frames.
const std = @import("std");
const core = @import("../core.zig");
const index = @import("cx_runtime_index.zig");
const dirty = @import("node_dirty.zig");

fn scene() !*core.Cx {
    const cx = try core.Cx.init(std.testing.allocator, std.testing.io);
    errdefer cx.deinit();
    cx.setViewport(240, 100);
    cx.root = try core.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    return cx;
}

fn frame(cx: *core.Cx) void {
    cx.frame_time_ms += 16;
    _ = cx.render();
}

test "interaction dirty hotpath: fixed text and settled hidden trees keep the loose memo" {
    const t = std.testing;
    const a = try scene();
    defer a.deinit();
    const b = try scene();
    defer b.deinit();
    const run = try core.text(a, "123", .{});
    run.setStyleInline(a.allocator, .{ .position = .absolute, .width = .{ .px = 80 }, .height = .{ .px = 20 } });
    try a.root.?.appendChild(a.allocator, run);
    // Cover both zero-size clip settlement paths: a child skipped before
    // traversal and a hooked child settled inside its own tick.
    const hidden = try core.box(a, .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 }, .overflow_hidden = true }, .{});
    try hidden.appendChild(a.allocator, try core.box(a, .{}, .{}));
    try a.root.?.appendChild(a.allocator, hidden);
    const hooked_hidden = try core.box(a, .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 }, .overflow_hidden = true }, .{});
    hooked_hidden.addBeforeRenderScoped(struct {
        fn beforeRender(_: *core.Node) void {}
    }.beforeRender, .self);
    try a.root.?.appendChild(a.allocator, hooked_hidden);
    const peer = try core.box(b, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try b.root.?.appendChild(b.allocator, peer);
    frame(a);
    frame(b);
    try t.expect(!index.subtreeHasLooseInteractionDirty(a, a.root.?));
    try t.expect(!index.subtreeHasLooseInteractionDirty(b, b.root.?));
    const a_scans = a.loose_interaction_memo.scans;
    const b_scans = b.loose_interaction_memo.scans;
    const generation = dirty.g_loose_interaction_gen;
    const bounds = run.globalRect();
    for (0..20) |i| {
        var props = run.getText().?;
        props.content = if (i % 2 == 0) "456" else "123";
        run.setTextFixedBounds(props);
        frame(a);
        peer.markRenderDirty();
        frame(b);
        try t.expectEqual(@as(u32, 0), a.perf.interaction_full_rebuild_count);
        try t.expectEqual(@as(u32, 0), a.perf.interaction_partial_rebuild_count);
        try t.expect(!index.subtreeHasLooseInteractionDirty(a, a.root.?));
        try t.expect(!index.subtreeHasLooseInteractionDirty(b, b.root.?));
    }
    try t.expectEqual(bounds, run.globalRect());
    try t.expectEqual(generation, dirty.g_loose_interaction_gen);
    try t.expectEqual(a_scans, a.loose_interaction_memo.scans);
    try t.expectEqual(b_scans, b.loose_interaction_memo.scans);
}

test "interaction dirty hotpath: clean runtime rebuilds do not evict another window memo" {
    const t = std.testing;
    const a = try scene();
    defer a.deinit();
    const b = try scene();
    defer b.deinit();
    frame(a);
    frame(b);
    try t.expect(!index.subtreeHasLooseInteractionDirty(a, a.root.?));
    try t.expect(!index.subtreeHasLooseInteractionDirty(b, b.root.?));
    const generation = dirty.g_loose_interaction_gen;
    const a_scans = a.loose_interaction_memo.scans;
    const b_scans = b.loose_interaction_memo.scans;
    for (0..5) |_| {
        try index.fullRebuildRuntimeIndexes(a, a.root.?);
        try t.expect(!index.subtreeHasLooseInteractionDirty(a, a.root.?));
        try t.expect(!index.subtreeHasLooseInteractionDirty(b, b.root.?));
    }
    try t.expectEqual(generation, dirty.g_loose_interaction_gen);
    try t.expectEqual(a_scans, a.loose_interaction_memo.scans);
    try t.expectEqual(b_scans, b.loose_interaction_memo.scans);
}

test "interaction dirty hotpath: duplicate dirty marks retain memo until real bit changes" {
    const t = std.testing;
    const cx = try scene();
    defer cx.deinit();
    const target = try core.box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } }, .{});
    try cx.root.?.appendChild(cx.allocator, target);
    frame(cx);
    try t.expect(!index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
    target.markSizingDirty();
    try t.expect(index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
    const layout_generation = dirty.g_loose_interaction_gen;
    const layout_scans = cx.loose_interaction_memo.scans;
    for (0..10) |_| {
        target.markSizingDirty();
        target.markLayoutDirty();
        try t.expect(index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
    }
    try t.expectEqual(layout_generation, dirty.g_loose_interaction_gen);
    try t.expectEqual(layout_scans, cx.loose_interaction_memo.scans);
    target.markInteractionDirty();
    try t.expect(dirty.g_loose_interaction_gen != layout_generation);
    try t.expect(index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
    const interaction_generation = dirty.g_loose_interaction_gen;
    const interaction_scans = cx.loose_interaction_memo.scans;
    for (0..10) |_| {
        target.markInteractionDirty();
        target.markHitSemanticsDirty();
        try t.expect(index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
    }
    try t.expectEqual(interaction_generation, dirty.g_loose_interaction_gen);
    try t.expectEqual(interaction_scans, cx.loose_interaction_memo.scans);
    frame(cx);
    try t.expect(!index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
    target.markHitSemanticsDirty();
    try t.expect(index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
    frame(cx);
    try t.expect(!index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
}

test "interaction dirty hotpath: loose geometry below isolation still refreshes real hits" {
    const t = std.testing;
    const cx = try scene();
    defer cx.deinit();
    const island = try core.box(cx, .{ .position = .absolute, .width = .{ .px = 200 }, .height = .{ .px = 80 }, .layout_isolation = true }, .{});
    const target = try core.box(cx, .{ .position = .absolute, .width = .{ .px = 20 }, .height = .{ .px = 20 } }, .{});
    target.setFocusable(true);
    try island.appendChild(cx.allocator, target);
    try cx.root.?.appendChild(cx.allocator, island);
    frame(cx);
    try t.expect(cx.hitTest(5, 5) == target);
    try t.expect(!index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
    const generation = dirty.g_loose_interaction_gen;
    target.style.translate_x = 80;
    target.markLayoutDirty();
    try t.expect(dirty.g_loose_interaction_gen != generation);
    try t.expect(!cx.root.?.frame_state.state_bits.dirty.core.subtree_layout);
    try t.expect(index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
    frame(cx);
    try t.expect(cx.hitTest(85, 5) == target);
    try t.expect(cx.hitTest(5, 5) != target);
    try t.expect(!index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
}

test "interaction dirty hotpath: semantics and hidden reveal remain authoritative" {
    const t = std.testing;
    const cx = try scene();
    defer cx.deinit();
    const panel = try core.box(cx, .{ .position = .absolute, .width = .{ .px = 80 }, .height = .{ .px = 60 }, .overflow_hidden = true }, .{});
    const target = try core.box(cx, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 } }, .{});
    try panel.appendChild(cx.allocator, target);
    try cx.root.?.appendChild(cx.allocator, panel);
    frame(cx);
    try t.expect(cx.hitTest(5, 5) != target);
    target.behavior.events.on_click = core.Cx.simpleHandler(struct {
        fn click(_: *anyopaque) void {}
    }.click, target);
    target.markHitSemanticsDirty();
    try t.expect(index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
    frame(cx);
    try t.expect(cx.hitTest(5, 5) == target);
    target.setHitTestVisible(false);
    frame(cx);
    try t.expect(cx.hitTest(5, 5) != target);
    panel.setDisplay(.none);
    frame(cx);
    target.setHitTestVisible(true);
    target.markHitSemanticsDirty();
    frame(cx);
    try t.expect(cx.hitTest(5, 5) != target);
    panel.setDisplay(.flex);
    frame(cx);
    try t.expect(cx.hitTest(5, 5) == target);
    try t.expect(!index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
}

test "interaction dirty hotpath: append and detach invalidate warmed interaction indexes" {
    const t = std.testing;
    const cx = try scene();
    defer cx.deinit();
    frame(cx);
    try t.expect(!index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
    const target = try core.box(cx, .{ .position = .absolute, .width = .{ .px = 20 }, .height = .{ .px = 20 } }, .{});
    target.setFocusable(true);
    try cx.root.?.appendChild(cx.allocator, target);
    frame(cx);
    const handle = cx.node_registry.handleFor(target);
    try t.expect(cx.hitTest(5, 5) == target);
    try t.expect(cx.node_registry.resolve(handle, null) == target);
    cx.detachChild(cx.root.?, target);
    defer cx.destroyDetached(target);
    frame(cx);
    try t.expect(cx.hitTest(5, 5) != target);
    try t.expect(cx.node_registry.resolve(handle, null) == null);
    try t.expect(!index.subtreeHasLooseInteractionDirty(cx, cx.root.?));
}
