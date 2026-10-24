/// Timeline Component
///
/// Timeline component for displaying event flow.
///
/// Features:
/// - Vertical layout
/// - Status dot + connection line
/// - Title + description + time.
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;

// View in timeline.yix, styles in styles.yss.

/// Timeline item status.
pub const TimelineStatus = enum {
    completed,
    active,
    pending,

    pub fn dotColor(self: TimelineStatus, t: *const theme.ThemeTokens) Color {
        return switch (self) {
            .completed => t.tokens.color.success,
            .active => t.tokens.color.accent,
            .pending => t.tokens.color.border,
        };
    }

    pub fn lineColor(self: TimelineStatus, t: *const theme.ThemeTokens) Color {
        return switch (self) {
            .completed => t.tokens.color.success,
            .active, .pending => t.tokens.color.border,
        };
    }
};

/// Timeline item.
pub const TimelineItem = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    time: ?[]const u8 = null,
    status: TimelineStatus = .pending,
};

const views = @import("_timeline.yix.zig");
/// Create Timeline: `W.Timeline(.{ .items = activity })`.
pub const Timeline = views.Timeline;
pub const TimelineProps = views.TimelineProps;
/// One row (Yix component): `W.timeline.TimelineRow(.{ .title = "Deploy", .status = .active })`.
pub const TimelineRow = views.TimelineRow;

// ========== Tests ==========

const test_items = [_]TimelineItem{
    .{ .title = "Created", .description = "Project initialized", .time = "2024-01-01", .status = .completed },
    .{ .title = "In Progress", .description = "Development ongoing", .status = .active },
    .{ .title = "Review", .status = .pending },
    .{ .title = "Deploy", .status = .pending },
};

test "Timeline: basic structure" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const tl = try Timeline(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tl);

    // 4 rows.
    try std.testing.expectEqual(@as(usize, 4), tl.children.items.len);
}

test "Timeline: last item no line" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 500 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const tl = try Timeline(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tl);

    // Last row's indicator column has only dot; earlier rows have dot + connection line.
    const first_row = tl.children.items[0];
    const first_indicator = first_row.children.items[0];
    try std.testing.expectEqual(@as(usize, 2), first_indicator.children.items.len);

    const last_row = tl.children.items[3];
    const last_indicator = last_row.children.items[0];
    try std.testing.expectEqual(@as(usize, 1), last_indicator.children.items.len);
    try std.testing.expectEqualStrings("TimelineRow", last_row.meta.ownership.meta.component_name.?);
    // Status spoken via a11y.
    try std.testing.expect(first_row.behavior.interaction.a11y.?.checked.?);
    try std.testing.expect(last_row.behavior.interaction.a11y.?.disabled);
    try std.testing.expectEqualStrings("2024-01-01", first_row.behavior.interaction.a11y.?.value_text.?);
}

test "Timeline: single item" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const single = [_]TimelineItem{
        .{ .title = "Only", .status = .active },
    };

    const tl = try Timeline(.{
        .items = &single,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, tl);
    try std.testing.expectEqual(@as(usize, 1), tl.children.items.len);
}

test "Timeline: 静态 items 不建 effect / memo（行的条件、a11y、样式一次定型）" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const before = ctx.owner.graph.countByKind();
    const tl = try Timeline(.{ .items = &test_items }).mount(scope, ctx);
    defer ctx.freeNode(tl);
    const after = ctx.owner.graph.countByKind();
    try std.testing.expectEqual(before.get(.effect), after.get(.effect));
    try std.testing.expectEqual(before.get(.memo), after.get(.memo));
}

// Test collection from styles.yss, this line required, see docs/STYLING.md.
test {
    _ = @import("_styles.yss.zig");
}

// Per-allocation OOM sweep, see src/ui/components/oom_sweep.zig.
test "timeline: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("timeline", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const items = [_]TimelineItem{ .{ .title = "start", .time = "09:00", .status = .completed }, .{ .title = "mid", .description = "desc" }, .{ .title = "end" } };
            return try Timeline(.{ .items = &items }).mount(scope, cx);
        }
    }.m);
}

fn rows(tl: *Node, out: []*Node) usize {
    var n: usize = 0;
    for (tl.children.items) |c| {
        const name = c.meta.ownership.meta.component_name orelse continue;
        if (!std.mem.eql(u8, name, "TimelineRow")) continue;
        out[n] = c;
        n += 1;
    }
    return n;
}

fn hasLine(row: *Node) bool {
    var n: usize = 0;
    for (row.children.items[0].children.items) |c| n += @intFromBool(c.tag != .anchor);
    return n == 2;
}

test "Timeline: items 来自信号——按行 key 调和，列表变长时原来的最后一行长出连接线（同一节点）" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const feed = try scope.createSignal([]const TimelineItem, test_items[0..2]);
    const tl = try Timeline(.{ .items = feed }).mount(scope, ctx);
    defer ctx.freeNode(tl);
    var buf: [8]*Node = undefined;
    try std.testing.expectEqual(@as(usize, 2), rows(tl, &buf));
    const second = buf[1];
    try std.testing.expect(!hasLine(second));
    feed.set(&test_items);
    try std.testing.expectEqual(@as(usize, 4), rows(tl, &buf));
    try std.testing.expectEqual(second.id, buf[1].id); // Reuse.
    try std.testing.expect(hasLine(second));
    try std.testing.expect(second.behavior.interaction.a11y.?.selected);
    try std.testing.expect(!hasLine(buf[3]));
}

test "Timeline: 一次更新里只换了字符串地址的行也重建（行不留指向旧字符串的借用）" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const a = std.testing.allocator;
    const title = try a.dupe(u8, "Created");
    defer a.free(title);
    const copy = try a.dupe(u8, "Created");
    defer a.free(copy);
    // Second item content changed (signal notifies); first item content same, string address
    // changed.
    const first = [_]TimelineItem{ .{ .title = title }, .{ .title = "Review" } };
    const moved = [_]TimelineItem{ .{ .title = copy }, .{ .title = "Deploy" } };
    const feed = try scope.createSignal([]const TimelineItem, &first);
    const tl = try Timeline(.{ .items = feed }).mount(scope, ctx);
    defer ctx.freeNode(tl);
    var buf: [2]*Node = undefined;
    _ = rows(tl, &buf);
    const before = buf[0].id;
    feed.set(&moved);
    _ = rows(tl, &buf);
    // Compare id not pointer: rebuilt new node might land in same memory just freed.
    try std.testing.expect(before != buf[0].id);
}

test "timeline: 动态 items 的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("timeline(dynamic)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const feed = try scope.createSignal([]const TimelineItem, &test_items);
            return try Timeline(.{ .items = feed }).mount(scope, cx);
        }
    }.m);
}
