/// Stack Components
///
/// Stack layout components: VStack (vertical), HStack (horizontal)
///
/// Features:
/// - direction: vertical / horizontal
/// - spacing: gap
/// - alignment: align, justify
/// - reverse: reverse
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Padding = core.Padding;
const Direction = core.Direction;
const Alignment = core.Alignment;
const Justify = core.Justify;
const Sizing = core.Sizing;
const Scope = @import("../../reactive.zig").Scope;
const views = @import("_stack.yix.zig");

/// Vertical stack: `ui.view.with(W.VStack(.{ .gap = 8 }), .{ ... })`. Props:
/// gap/justify/align_items/width/height/padding/background/reverse, all can be signals. View in
/// stack.yix, styles in styles.yss.
pub const VStack = views.VStack;
/// Horizontal stack: same as VStack, plus wrap (line break); align_items defaults center.
pub const HStack = views.HStack;
/// Flexible spacer: `W.stack.Spacer(.{})`, fixed size when min_size given.
pub const Spacer = views.Spacer;

// ========== Tests ==========

test "VStack: 信号驱动的间距与背景；静态 props 不建 effect" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const before = ctx.owner.graph.countByKind().get(.effect);
    const a = try VStack(.{ .gap = 4, .background = Color.hex(0x112233) }).mount(scope, ctx);
    defer ctx.freeNode(a);
    try std.testing.expectEqual(before, ctx.owner.graph.countByKind().get(.effect));
    try std.testing.expectEqual(Color.hex(0x112233), a.getBackground());
    const gap = try scope.createSignal(f32, 2);
    const b = try HStack(.{ .gap = gap, .wrap = true }).mount(scope, ctx);
    defer ctx.freeNode(b);
    try std.testing.expectEqual(@as(f32, 2), b.style.gap);
    gap.set(9);
    try std.testing.expectEqual(@as(f32, 9), b.style.gap);
    try std.testing.expectEqual(core.FlexWrap.wrap, b.style.flex_wrap());
    try std.testing.expectEqualStrings("HStack", b.meta.ownership.meta.component_name.?);
}

test "VStack: basic" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const stack = try VStack(.{ .gap = 10 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, stack);

    // Create child elements
    const item1 = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    const item2 = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 30 } }, .{});
    try stack.appendChild(std.testing.allocator, item1);
    try stack.appendChild(std.testing.allocator, item2);

    ctx.layout();

    try std.testing.expectEqual(@as(usize, 2), stack.children.items.len);
    try std.testing.expectEqual(Direction.column, stack.style.direction);
}

test "HStack: basic" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const stack = try HStack(.{ .gap = 8, .align_items = .center }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, stack);

    const item1 = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 30 } }, .{});
    const item2 = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 40 } }, .{});
    try stack.appendChild(std.testing.allocator, item1);
    try stack.appendChild(std.testing.allocator, item2);

    ctx.layout();

    try std.testing.expectEqual(Direction.row, stack.style.direction);
    try std.testing.expectEqual(Alignment.center, stack.style.align_items);
}

test "VStack: reverse" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const stack = try VStack(.{ .reverse = true }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, stack);

    try std.testing.expectEqual(Direction.column_reverse, stack.style.direction);
}

test "HStack: justify space-between" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const stack = try HStack(.{
        .justify = .space_between,
        .width = 300,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, stack);

    try std.testing.expectEqual(Justify.space_between, stack.style.justify);
}

test "Spacer: fills space" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const stack = try HStack(.{ .width = 300 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, stack);

    const left = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 30 } }, .{});
    const spacer = try Spacer(.{}).mount(scope, ctx);
    const right = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 30 } }, .{});

    try stack.appendChild(std.testing.allocator, left);
    try stack.appendChild(std.testing.allocator, spacer);
    try stack.appendChild(std.testing.allocator, right);

    try std.testing.expectEqual(@as(f32, 1), spacer.style.flex);
}

// Per-allocation point OOM sweep, see src/ui/components/oom_sweep.zig
test "vstack: mount 在任意分配点失败时不泄漏（sweep）" {
    try @import("../oom_sweep.zig").sweepMount("vstack", struct {
        fn m(scope: *Scope, cx: *Cx) anyerror!?*Node {
            return try VStack(.{ .gap = 4, .padding = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 } }).mount(scope, cx);
        }
    }.m);
}
