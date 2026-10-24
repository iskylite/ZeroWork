const std = @import("std");
const core = @import("core.zig");
const animation = @import("animation/mod.zig");
const snapshot_layer = @import("components/snapshot_layer.zig");

const Cx = core.Cx;
const Node = core.Node;
const Scope = core.Scope;
const Snapshot = core.Snapshot;
pub const Transition = struct {
    pub fn dissolve(
        scope: *Scope,
        cx: *Cx,
        outgoing: *Node,
        duration_s: f32,
    ) !void {
        // captureDisplayed prefers promoted_cached_commands / cached_commands; for a complex
        // editor-like subtree with much promoted content it captures the complete visual; naked
        // Snapshot.capture misses the promoted subtree and yields an empty shell. Via the cache
        // path, commands are in parent-relative space and bounds.y already includes the node.rect.y
        // offset; composing capture_origin as (world_origin + bounds - local_offset) double-adds
        // rect.y. Use outgoing.globalRect directly as the anchor for the true screen position.
        const snapshot = (try Snapshot.captureDisplayed(cx, outgoing)) orelse return;
        const gr = outgoing.globalRect();
        var layer = try snapshot_layer.SnapshotLayer(.{
            .snapshot = snapshot,
            .anchor = .{ .x = gr.x, .y = gr.y },
        }).mount(scope, cx);
        layer.animateOpacityAndDismiss(1.0, 0.0, duration_s);
    }

    pub fn crossfade(
        scope: *Scope,
        cx: *Cx,
        outgoing: *Node,
        incoming: *Node,
        duration_s: f32,
    ) !void {
        try dissolve(scope, cx, outgoing, duration_s);
        reveal(scope, cx, incoming, duration_s);
    }

    pub fn reveal(
        _: *Scope,
        cx: *Cx,
        incoming: *Node,
        duration_s: f32,
    ) void {
        incoming.setOpacity(0.0);
        animation.animateNode(incoming, cx.allocator, .{
            .prop = .opacity,
            .from = 0.0,
            .to = 1.0,
            .duration = duration_s,
            .easing = .linear,
        });
    }
};

pub const SnapshotTransition = Transition;

/// This frame has a composite layer moving the snapshot to (x, y) with size w*h; the layer
/// draws the snapshot content. Snapshot position is not baked into rect geometry: it is
/// carried by the begin_opacity_layer wrapping it via draw_x / draw_y (rect keeps snapshot
/// local coords, encoder uses a transform to move the layer to the anchor), same invariant
/// as snapshot_layer.zig tests.
fn drewSnapshotAt(cx: *Cx, x: f32, y: f32, w: f32, h: f32) bool {
    var in_layer = false;
    for (cx.lowerForEncoderPaintTable()) |cmd| {
        if (cmd.kind == .control and cmd.control_kind == .begin_opacity_layer) {
            in_layer = @abs(cmd.draw_x - x) < 0.01 and @abs(cmd.draw_y - y) < 0.01 and @abs(cmd.draw_w - w) < 0.01 and @abs(cmd.draw_h - h) < 0.01;
        } else if (cmd.kind == .control and cmd.control_kind == .end_opacity_layer) {
            in_layer = false;
        } else if (in_layer and cmd.isFillRect() and @abs(cmd.geom.w - w) < 0.01 and @abs(cmd.geom.h - h) < 0.01) {
            return true;
        }
    }
    return false;
}

test "Transition.dissolve keeps content visible after source unmount" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 160);

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer if (!scope.disposed) scope.dispose();

    const root = try core.box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 160 },
    }, .{});
    cx.root = root;

    const outgoing = try core.box(cx, .{
        .width = .{ .px = 36 },
        .height = .{ .px = 22 },
        .background = core.Color.rgb(220, 70, 60),
    }, .{});
    outgoing.style.translate_x = 18;
    outgoing.style.translate_y = 14;
    try root.appendChild(cx.allocator, outgoing);

    _ = cx.render();
    cx.frame_time_ms = 0;
    try Transition.dissolve(scope, cx, outgoing, 0.2);
    cx.detachChild(root, outgoing);
    cx.freeNode(outgoing);

    cx.frame_time_ms = 16;
    _ = cx.render();
    try std.testing.expect(drewSnapshotAt(cx, 18, 14, 36, 22));

    cx.frame_time_ms = 266;
    _ = cx.render();
    _ = cx.drainDeferredWork(cx.deferredBudgetUs());
    cx.frame_time_ms = 282;
    _ = cx.render();
    try std.testing.expect(!drewSnapshotAt(cx, 18, 14, 36, 22));
    try std.testing.expectEqual(@as(usize, 0), root.children.items.len);
}

test "Transition.crossfade reveals incoming while outgoing dissolves" {
    var cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(240, 160);

    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer if (!scope.disposed) scope.dispose();

    const root = try core.box(cx, .{
        .width = .{ .px = 240 },
        .height = .{ .px = 160 },
    }, .{});
    cx.root = root;

    const outgoing = try core.box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 24 },
        .background = core.Color.rgb(220, 70, 60),
    }, .{});
    outgoing.style.translate_x = 24;
    outgoing.style.translate_y = 18;
    try root.appendChild(cx.allocator, outgoing);

    const incoming = try core.box(cx, .{
        .width = .{ .px = 40 },
        .height = .{ .px = 24 },
        .background = core.Color.rgb(60, 140, 230),
    }, .{});
    incoming.style.translate_x = 24;
    incoming.style.translate_y = 18;
    try root.appendChild(cx.allocator, incoming);

    _ = cx.render();
    cx.frame_time_ms = 0;
    try Transition.crossfade(scope, cx, outgoing, incoming, 0.2);
    cx.detachChild(root, outgoing);
    cx.freeNode(outgoing);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), incoming.getOpacity(), 0.001);

    cx.frame_time_ms = 16;
    _ = cx.render();
    cx.frame_time_ms = 266;
    _ = cx.render();
    _ = cx.drainDeferredWork(cx.deferredBudgetUs());
    cx.frame_time_ms = 282;
    _ = cx.render();

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), incoming.getOpacity(), 0.01);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
}
