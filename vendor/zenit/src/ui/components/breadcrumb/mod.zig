/// Breadcrumb Component
///
/// Breadcrumb navigation showing current page position in hierarchy. View in breadcrumb.yix, styles
/// in styles.yss.
///
/// Features:
/// - Clickable navigation links (report item id)
/// - Custom separator
/// - Last item is current page (unclickable)
/// - Path from signals (content is the key: items with unchanged content don't rebuild)
const std = @import("std");
const core = @import("../../core.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const reactive = @import("../../reactive.zig");
const Scope = reactive.Scope;

/// Breadcrumb item
pub const BreadcrumbItem = struct {
    id: []const u8,
    label: []const u8,
};

/// Create Breadcrumb: `W.Breadcrumb(.{ .items = path, .on_select = cx.on(S, s, S.go) })`
pub const Breadcrumb = @import("_breadcrumb.yix.zig").Breadcrumb;
pub const BreadcrumbProps = @import("_breadcrumb.yix.zig").BreadcrumbProps;

// ========== Testing ==========

const test_items = [_]BreadcrumbItem{
    .{ .id = "home", .label = "Home" },
    .{ .id = "docs", .label = "Documents" },
    .{ .id = "file", .label = "Report.pdf" },
};

/// Each level (row node; control flow anchor has no children)
fn crumbs(bc: *Node) usize {
    var n: usize = 0;
    for (bc.children.items) |c| n += @intFromBool(c.children.items.len > 0);
    return n;
}

fn crumbAt(bc: *Node, i: usize) *Node {
    var k: usize = 0;
    for (bc.children.items) |c| {
        if (c.children.items.len == 0) continue;
        if (k == i) return c;
        k += 1;
    }
    unreachable;
}

fn linkOf(bc: *Node, i: usize) *Node {
    return crumbAt(bc, i).children.items[0];
}

fn separators(bc: *Node) usize {
    var n: usize = 0;
    for (bc.children.items) |c| {
        for (c.children.items) |x| {
            if (x.behavior.interaction.a11y) |a| n += @intFromBool(a.hidden);
        }
    }
    return n;
}

test "Breadcrumb: basic" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const bc = try Breadcrumb(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, bc);

    // 3 levels; first two each have a separator
    try std.testing.expectEqual(@as(usize, 3), crumbs(bc));
    try std.testing.expectEqual(@as(usize, 2), separators(bc));
    try std.testing.expectEqual(core.A11yRole.navigation, bc.behavior.interaction.a11y.?.role);
}

test "Breadcrumb: last item not clickable" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const bc = try Breadcrumb(.{
        .items = &test_items,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, bc);

    // Last level has no pointer cursor, reports listitem + selected; earlier ones are links
    const last = linkOf(bc, 2);
    try std.testing.expectEqual(core.CursorShape.inherit, last.style.cursor);
    try std.testing.expect(last.behavior.interaction.a11y.?.selected);
    try std.testing.expectEqual(core.A11yRole.link, linkOf(bc, 0).behavior.interaction.a11y.?.role);
    try std.testing.expectEqual(core.CursorShape.pointer, linkOf(bc, 0).style.cursor);
}

test "Breadcrumb: single item" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 50 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const single = [_]BreadcrumbItem{
        .{ .id = "home", .label = "Home" },
    };

    const bc = try Breadcrumb(.{
        .items = &single,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, bc);

    // 1 level, no separator
    try std.testing.expectEqual(@as(usize, 1), crumbs(bc));
    try std.testing.expectEqual(@as(usize, 0), separators(bc));
}

test "Breadcrumb: on_select gets the item id; a path signal rebuilds the crumbs" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const short = [_]BreadcrumbItem{ .{ .id = "home", .label = "Home" }, .{ .id = "docs", .label = "Documents" } };
    const path = try scope.createSignal([]const BreadcrumbItem, &test_items);
    const Nav = struct {
        path: *reactive.Signal([]const BreadcrumbItem),
        short: []const BreadcrumbItem,
        last: ?[]const u8 = null,
        fn go(self: *@This(), id: []const u8) void {
            self.last = id;
            self.path.set(self.short); // change path in callback: sync rebuild frees click context
        }
    };
    var nav = Nav{ .path = path, .short = &short };
    const bc = try Breadcrumb(.{ .items = path, .on_select = ctx.on(Nav, &nav, Nav.go) }).mount(scope, ctx);
    defer ctx.freeNode(bc);
    try std.testing.expectEqual(@as(usize, 3), crumbs(bc));
    const docs = linkOf(bc, 1);
    docs.behavior.events.on_click.?.invoke();
    try std.testing.expectEqualStrings("docs", nav.last.?);
    try std.testing.expectEqual(@as(usize, 2), crumbs(bc));
    // Former second level becomes current page: same node (reuse by content key), index signal
    // makes it report selected and remove separator
    try std.testing.expectEqual(docs, linkOf(bc, 1));
    try std.testing.expect(linkOf(bc, 1).behavior.interaction.a11y.?.selected);
    try std.testing.expectEqual(@as(usize, 1), separators(bc));
}

test "Breadcrumb: 一次更新里只换了字符串地址的级也重建（不留指向旧字符串的借用）" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const a = std.testing.allocator;
    const home = try a.dupe(u8, "Home");
    defer a.free(home);
    const copy = try a.dupe(u8, "Home");
    defer a.free(copy);
    // Second level content changed (signal will notify); first level content same, string changed
    // address
    const first = [_]BreadcrumbItem{ .{ .id = home, .label = home }, .{ .id = "docs", .label = "Docs" } };
    const moved = [_]BreadcrumbItem{ .{ .id = copy, .label = copy }, .{ .id = "src", .label = "Src" } };
    const path = try scope.createSignal([]const BreadcrumbItem, &first);
    const bc = try Breadcrumb(.{ .items = path }).mount(scope, ctx);
    defer ctx.freeNode(bc);
    const before = crumbAt(bc, 0).id;
    path.set(&moved);
    // Compare id not pointer: rebuilt new node may land on same freed memory
    try std.testing.expect(before != crumbAt(bc, 0).id);
}

test "breadcrumb: 动态路径的 mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("breadcrumb(dynamic)", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            const path = try scope.createSignal([]const BreadcrumbItem, &test_items);
            var sink: u8 = 0;
            _ = &sink;
            return try Breadcrumb(.{ .items = path, .on_select = cx.on(u8, &sink, struct {
                fn f(_: *u8, _: []const u8) void {}
            }.f) }).mount(scope, cx);
        }
    }.m);
}

// Per-allocation OOM sweep, see src/ui/components/oom_sweep.zig
test "breadcrumb: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("breadcrumb", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return try Breadcrumb(.{ .items = &test_items }).mount(scope, cx);
        }
    }.m);
}
