const std = @import("std");
const ui = @import("ui");
const zenit_app = @import("zenit_app");
var layer: ?*ui.Node = null;

pub fn route(app: *zenit_app.App, path: []const u8, out: []u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/review/retained-mount"))
        return mount(app, out) catch |err| failure(out, err);
    if (std.mem.eql(u8, path, "/review/retained-frame-failure"))
        return abortFrame(app, out) catch |err| failure(out, err);
    return null;
}
fn failure(out: []u8, err: anyerror) ?[]const u8 {
    return std.fmt.bufPrint(out, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch null;
}
fn mount(app: *zenit_app.App, out: []u8) ![]const u8 {
    if (layer != null) return error.AlreadyMounted;
    const node = try ui.box(app.cx, .{
        .position = .absolute,
        .width = .{ .px = 200 },
        .height = .{ .px = 100 },
        .background = ui.Color.rgba(0, 255, 0, 255),
    }, .{});
    layer = node;
    const ext = try node.style.ensureExtFallible(app.cx.allocator);
    ext.inset = .{ .left = .{ .px = 400 }, .top = .{ .px = 350 } };
    ext.composited_group = true;
    node.meta.ownership.meta.test_id = "review.retained.layer";
    try app.cx.root.?.appendChild(app.cx.allocator, node);
    app.cx.root.?.markLayoutDirty();
    app.cx.needs_redraw = true;
    return std.fmt.bufPrint(out, "{{\"mounted\":true}}", .{});
}
fn abortFrame(app: *zenit_app.App, out: []u8) ![]const u8 {
    const node = layer orelse return error.NotMounted;
    app.renderer.frame_sync.drain(3);
    // Warm the pool's three-frame reuse window with real green submissions.
    // All are completed before fault injection, so this probe is independent
    // of the separate in-flight buffer-slot failure under review.
    for (0..3) |_| {
        node.markRenderDirty();
        try app.renderer.frame(app.cx, app.viewport_w, app.viewport_h, app.scale);
    }
    app.renderer.frame_sync.drain(3);
    node.setBackground(ui.Color.rgba(255, 0, 0, 255));
    var result: []const u8 = "accepted";
    for (0..3) |_| {
        node.markRenderDirty();
        app.renderer.fail_after_encode_for_testing = true;
        app.renderer.frame(app.cx, app.viewport_w, app.viewport_h, app.scale) catch |err| {
            result = @errorName(err);
        };
    }
    var primed: usize = 0;
    for (app.renderer.offscreen_pool.entries) |entry| {
        if (entry) |e| if (e.retained_primed) {
            primed += 1;
        };
    }
    node.markRenderDirty();
    app.cx.needs_redraw = true;
    return std.fmt.bufPrint(out, "{{\"failure\":\"{s}\",\"uncommitted_cache_entries\":{d}}}", .{ result, primed });
}
