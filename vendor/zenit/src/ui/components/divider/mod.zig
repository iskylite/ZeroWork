/// Divider Component
///
/// Separator line component for content areas.
///
/// Features:
/// - Orientation: horizontal / vertical
/// - Style: solid, dashed, dotted
/// - Spacing: none, sm, md, lg
/// - Label support
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const theme = core.theme;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;

/// Divider orientation.
pub const DividerOrientation = enum {
    horizontal,
    vertical,
};

/// Divider style.
pub const DividerVariant = enum {
    solid,
    dashed,
    dotted,
};

/// Divider spacing.
pub const DividerSpacing = enum {
    none,
    sm,
    md,
    lg,

    pub fn value(self: DividerSpacing) f32 {
        return switch (self) {
            .none => 0,
            .sm => 8,
            .md => 16,
            .lg => 24,
        };
    }
};

/// Label position.
pub const LabelPosition = enum {
    left,
    center,
    right,
};

/// Create divider: `W.Divider(.{ .label = "OR" })`. Props: orientation / variant / spacing / label
/// (empty string = no label, can pass signal) / label_position / color (null = border_strong token,
/// follows theme) / thickness / dash_length / dash_gap. View in divider.yix, styles in styles.yss.
pub const Divider = @import("_divider.yix.zig").Divider;

// ========== Tests ==========

test "Divider: horizontal simple" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const divider_node = try Divider(.{ .orientation = .horizontal })
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, divider_node);

    ctx.layout();

    // Horizontal divider height should be thickness.
    try std.testing.expectEqual(@as(f32, 1), divider_node.style.height.px);
}

test "Divider: vertical" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const divider_node = try Divider(.{ .orientation = .vertical, .thickness = 2 })
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, divider_node);

    // Vertical divider width should be thickness.
    try std.testing.expectEqual(@as(f32, 2), divider_node.style.width.px);
}

test "Divider: with label center" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const divider_node = try Divider(.{ .label = "OR", .label_position = .center })
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, divider_node);

    // Center label: line + label + line.
    try std.testing.expectEqual(@as(usize, 3), divider_node.children.items.len);
    try std.testing.expectEqualStrings("OR", divider_node.children.items[1].getText().?.content);
}

test "Divider: with label left" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const divider_node = try Divider(.{ .label = "Section", .label_position = .left })
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, divider_node);

    // Left label: label + line.
    try std.testing.expectEqual(@as(usize, 2), divider_node.children.items.len);
    try std.testing.expectEqualStrings("Section", divider_node.children.items[0].getText().?.content);
}

test "Divider: custom color" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const custom_color = Color.hex(0xff0000);
    const divider_node = try Divider(.{ .color = custom_color })
        .mount(scope, ctx);

    try root.appendChild(std.testing.allocator, divider_node);

    // Background should be custom color (red = 0xff0000).
    try std.testing.expectEqual(@as(u8, 255), divider_node.getBackground().r);
    try std.testing.expectEqual(@as(u8, 0), divider_node.getBackground().g);
}

fn findText(n: *Node) ?[]const u8 {
    if (n.getText()) |t| return t.content;
    for (n.children.items) |c| if (findText(c)) |s| return s;
    return null;
}

test "Divider: dashed 是裁剪容器里的定长段，颜色缺省跟随主题" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setTheme(&theme.light);
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const d = try Divider(.{ .variant = .dashed, .thickness = 2, .dash_length = 6 }).mount(scope, ctx);
    ctx.root = d;
    defer {
        ctx.root = null;
        ctx.freeNode(d);
    }
    try std.testing.expect(d.style.overflow_hidden);
    try std.testing.expectEqual(@as(usize, 128), d.children.items.len);
    const seg = d.children.items[0];
    try std.testing.expectEqual(@as(f32, 6), seg.style.width.px);
    try std.testing.expectEqual(@as(f32, 2), seg.style.height.px);
    try std.testing.expectEqual(theme.light.tokens.color.border_strong, seg.getBackground());
    ctx.setTheme(&theme.dark);
    try std.testing.expectEqual(theme.dark.tokens.color.border_strong, seg.getBackground());
}

test "Divider: 静态 props 不建 effect" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const before = ctx.owner.graph.countByKind();
    inline for (.{ Divider(.{}), Divider(.{ .label = "OR" }), Divider(.{ .variant = .dotted }) }) |el| {
        const n = try el.mount(scope, ctx);
        ctx.freeNode(n);
    }
    const after = ctx.owner.graph.countByKind();
    try std.testing.expectEqual(before.get(.effect), after.get(.effect));
    try std.testing.expectEqual(before.get(.memo), after.get(.memo));
}

// Test collection from styles.yss, this line required, see docs/STYLING.md.
test {
    _ = @import("_styles.yss.zig");
}

test "Divider: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("divider", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try Divider(.{ .orientation = .horizontal }).mount(scope, cx);
        }
    }.m);
}

test "Divider: dynamic label text" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const caption = try scope.createText("Today", .{});
    const d = try Divider(.{ .label = caption }).mount(scope, ctx);
    defer ctx.freeNode(d);
    caption.set("Yesterday");
    try std.testing.expectEqualStrings("Yesterday", findText(d).?);
}

test "divider: 带标签（静态 / 动态）的 mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("divider(label)", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            const caption = try scope.createText("Today", .{});
            const a = try Divider(.{ .label = "OR", .label_position = .left }).mount(scope, cx);
            errdefer cx.freeNode(a);
            const b = try Divider(.{ .label = caption }).mount(scope, cx);
            a.appendChild(cx.allocator, b) catch |err| {
                cx.freeNode(b);
                return err;
            };
            return a;
        }
    }.m);
}
