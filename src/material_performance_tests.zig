//! Deterministic workload and lifecycle gates. Timings are diagnostic CPU data;
//! structural assertions, not machine-dependent milliseconds, gate correctness.
const std = @import("std");
const ui = @import("ui");
const theme = @import("ui/app_theme.zig");
const material = @import("ui/layer_materials.zig");
comptime {
    _ = @import("ai/composer_usage_cache.zig");
}
const Mode = enum { sidebar, ai_results, hidden_ai, file_virtual, floats };

test "idle hidden loading animation stops and resumes with its visible ancestor" {
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(200, 200);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const parent = try ui.box(cx, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } }, .{});
    try cx.root.?.appendChild(a, parent);
    const spinner = try ui.widgets.Spinner(.{}).mount(scope, cx);
    try parent.appendChild(a, spinner);
    for (0..4) |_| _ = tick(cx);
    try std.testing.expect(cx.hasPendingSceneWork());
    spinner.setDisplay(.none);
    for (0..4) |_| _ = tick(cx);
    try std.testing.expect(!cx.hasPendingSceneWork());
    spinner.setDisplay(.flex);
    for (0..4) |_| _ = tick(cx);
    try std.testing.expect(cx.hasPendingSceneWork());
    parent.setDisplay(.none);
    for (0..4) |_| _ = tick(cx);
    try std.testing.expect(!cx.hasPendingSceneWork());
    parent.setDisplay(.flex);
    for (0..4) |_| _ = tick(cx);
    try std.testing.expect(cx.hasPendingSceneWork());
}

fn tick(cx: *ui.Cx) []const ui.DisplayItem {
    cx.frame_count += 1;
    cx.frame_time_ms += 16;
    return cx.render();
}
fn row(node: *ui.Node, _: usize, _: *ui.Cx) void {
    node.setText(.{ .content = "file.txt  12 KB  2026-11-03", .font_size = 12, .color = theme.current().fg_1 });
}
fn workload(mode: Mode, enabled: bool) !void {
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setTheme(theme.widgetTheme(.sauber));
    cx.setViewport(1440, 900);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const label = try ui.text(cx, "frame0000", .{ .font_size = 12 });
    try cx.root.?.appendChild(a, label);
    const nested = mode == .ai_results or mode == .hidden_ai or mode == .floats;
    const pane = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 350 }, .top = .{ .px = 60 } }, .width = .{ .px = 600 }, .height = .{ .px = 456 }, .direction = .column, .background = if (nested) theme.current().overlay else ui.Color.TRANSPARENT, .glass = if (nested) theme.overlayGlass() else null, .border = .{ .radius = 14 }, .overflow = if (mode == .floats) .visible else .hidden }, .{});
    try cx.root.?.appendChild(a, pane);
    var scroll: ?ui.widgets.ScrollAreaResult = null;
    var expanded: [30]bool = @splat(true);
    if (mode == .file_virtual) {
        material.card(pane, .surface_1);
        const list = try ui.widgets.VirtualList(.{ .item_count = @as(usize, 10000), .item_height = 30, .height = 400, .overscan = 2 }).mountWithContext(scope, cx, null, row, null);
        try pane.appendChild(a, list.container);
        scroll = .{ .container = list.container, .content = list.state.content_node, .state = list.state.scroll_state };
    } else if (mode == .floats) {
        var parent = pane;
        for (0..2) |_| {
            const box = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 420 }, .top = .{ .px = 80 } }, .width = .{ .px = 300 }, .height = .{ .px = 220 }, .background = theme.current().overlay, .glass = theme.overlayGlass(), .border = .{ .radius = 12 } }, .{});
            try parent.appendChild(a, box);
            parent = box;
        }
    } else {
        const list = try ui.widgets.ScrollArea(.{ .height = 400, .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        try pane.appendChild(a, list.container);
        list.content.setStyleInline(a, .{ .direction = .column, .gap = 6 });
        scroll = list;
        if (mode == .sidebar) {
            for (0..40) |_| {
                const group = try @import("ui/sidebar_view.zig").GroupRow.mount(cx, scope, .{ .reference = null, .name = "Performance fixture", .count = 3, .collapsed = false }, .{});
                for (0..3) |_| try group.members.appendChild(a, try ui.text(cx, "Synthetic host row", .{ .font_size = 12 }));
                try list.content.appendChild(a, group.root);
            }
        } else for (&expanded) |*open| {
            const node = try @import("ui/ai_step_view.zig").mount(cx, scope, .{ .title = "Completed tool", .projection = "Local fixture", .detail = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten", .phase = .succeeded, .elapsed_ms = 100, .expanded = open });
            try list.content.appendChild(a, node);
        }
    }
    var policy: ?*material.Policy = null;
    if (enabled) {
        try material.Policy.mount(cx, scope);
        policy = @ptrCast(@alignCast(cx.after_layout_hooks.items[cx.after_layout_hooks.items.len - 1].ctx));
    }
    for (0..32) |_| _ = tick(cx);
    if (mode == .hidden_ai) {
        pane.setDisplay(.none);
        for (0..2) |_| _ = tick(cx);
    }
    if (scroll) |s| {
        s.state.viewport_height = s.container.globalRect().h;
        s.state.content_height = s.content.globalRect().h;
    }
    const rebuilds = if (policy) |p| p.stats.scene_rebuilds else 0;
    const builds = if (policy) |p| p.stats.geometry_builds else 0;
    var times: [40]f64 = undefined;
    var commands: usize = 0;
    for (&times, 0..) |*elapsed, index| {
        if (scroll != null and mode != .hidden_ai) {
            const s = scroll.?;
            ui.widgets.setScrollY(s.state, s.content, s.state.maxScrollY() * @as(f32, @floatFromInt(index % 8)) / 7);
        }
        var buffer: [32]u8 = undefined;
        try label.setTextContent(a, try std.fmt.bufPrint(&buffer, "frame{d:0>4}", .{index}));
        const before = std.Io.Clock.awake.now(cx.io).nanoseconds;
        const items = tick(cx);
        elapsed.* = @as(f64, @floatFromInt(std.Io.Clock.awake.now(cx.io).nanoseconds - before)) / 1_000_000;
        commands = @max(commands, items.len);
    }
    if (policy) |p| {
        try std.testing.expectEqual(rebuilds, p.stats.scene_rebuilds);
        if (mode == .ai_results or mode == .sidebar or mode == .file_virtual) try std.testing.expectEqual(@as(usize, 0), p.paints.items.len);
        if (mode == .floats or mode == .hidden_ai) try std.testing.expectEqual(builds, p.stats.geometry_builds);
        if (mode == .floats) try std.testing.expect(commands < 200);
    }
    var sum: f64 = 0;
    for (times) |t| sum += t;
    std.mem.sort(f64, &times, {}, std.sort.asc(f64));
    std.debug.print("MATERIAL_PERF {s} policy={} mean_ms={d:.2} p95_ms={d:.2} commands={d}\n", .{ @tagName(mode), enabled, sum / times.len, times[37], commands });
}
test "material retained workload cache and clipped scroll regression" {
    const old = theme.materialParameters();
    const old_theme = theme.currentName();
    defer {
        _ = theme.setMaterialParameters(old.transparency, old.blur);
        theme.select(old_theme);
    }
    theme.select(.sauber);
    _ = theme.setMaterialParameters(50, 24);
    for (std.enums.values(Mode)) |mode| for ([_]bool{ false, true }) |enabled| try workload(mode, enabled);
}
test "material destroyed surfaces release retained background records" {
    const old = theme.materialParameters();
    defer _ = theme.setMaterialParameters(old.transparency, old.blur);
    _ = theme.setMaterialParameters(50, 24);
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(800, 600);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const parent = try ui.box(cx, .{ .position = .absolute, .width = .{ .px = 400 }, .height = .{ .px = 300 }, .background = theme.current().surface_2 }, .{});
    material.card(parent, .surface_2);
    try cx.root.?.appendChild(a, parent);
    try material.Policy.mount(cx, scope);
    const policy: *material.Policy = @ptrCast(@alignCast(cx.after_layout_hooks.items[cx.after_layout_hooks.items.len - 1].ctx));
    for (0..12) |_| {
        const dialog = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 200 }, .top = .{ .px = 100 } }, .width = .{ .px = 300 }, .height = .{ .px = 200 }, .background = theme.current().overlay, .glass = theme.overlayGlass() }, .{});
        try cx.root.?.appendChild(a, dialog);
        _ = tick(cx);
        _ = tick(cx);
        try std.testing.expectEqual(@as(usize, 1), policy.paints.items.len);
        cx.detachChild(cx.root.?, dialog);
        cx.destroyDetached(dialog);
        _ = tick(cx);
        try std.testing.expectEqual(@as(usize, 0), policy.paints.items.len);
        try std.testing.expectEqual(@as(usize, 0), policy.paint_ids.count());
    }
}

test "material idle AI entry leaves the retained scene clean" {
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(800, 600);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const entry = try @import("ui/ai_strip_view.zig").View.mount(cx, scope, .{ .context = cx, .callback = struct {
        fn open(_: *anyopaque) void {}
    }.open });
    try cx.root.?.appendChild(a, entry.root);
    for (0..32) |_| {
        entry.update(.{ .x = 50, .y = 20, .w = 600, .h = 456 }, true, .idle, 0, false);
        _ = tick(cx);
    }
    try std.testing.expect(!cx.hasPendingSceneWork());
    entry.update(.{ .x = 50, .y = 20, .w = 600, .h = 456 }, true, .idle, 0, false);
    try std.testing.expect(!cx.hasPendingSceneWork());
    entry.update(.{ .x = 50, .y = 20, .w = 600, .h = 456 }, true, .working, 0, false);
    try std.testing.expect(cx.hasPendingSceneWork());
}
