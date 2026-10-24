/// Group Component: composition container HOC.
/// Combines child components into visual unit:
/// - gap = -1 overlaps child borders (avoid double border)
/// - first: zero right corners (TR=0, BR=0), keep left
/// - last: zero left corners (TL=0, BL=0), keep right
/// - between: zero all
/// - only: keep all
/// - no outer border; doesn't affect other child styles.
/// Reference: React Group (CMC UI Kit) attached mode.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Color = core.Color;
const Sizing = core.Sizing;
const Scope = core.Scope;
const Padding = core.Padding;
const BorderSideColors = @import("../../core/types.zig").BorderSideColors;

/// Group direction.
pub const GroupOrientation = enum {
    horizontal,
    vertical,
};

/// Child position in Group.
pub const GroupItemPosition = enum {
    first,
    between,
    last,
    only,
};

/// Group properties.
pub const GroupProps = struct {
    /// Direction.
    orientation: GroupOrientation = .horizontal,
    /// Width.
    width: Sizing = .{ .fit = .{} },
    /// Alignment.
    align_items: core.AlignItems = .stretch,
};

/// Group mount return value.
pub const GroupResult = struct {
    container: *Node,
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: GroupResult) core.ViewParts {
        return .{ .root = self.container, .slot = self.container };
    }
};

pub fn Group(props: anytype) GroupBuilder {
    return .{ .props = @import("../../reactive.zig").props.coerce(GroupProps, props) };
}

pub const GroupBuilder = struct {
    props: GroupProps,

    pub fn mount(self: GroupBuilder, scope: *Scope, cx: *Cx) !GroupResult {
        const p = self.props;
        const dir: core.Direction = if (p.orientation == .horizontal) .row else .column;

        const container = try view.render(scope, cx, view.box(.{ .style = .{
            .width = p.width,
            .height = .{ .fit = .{} },
            .direction = dir,
            .align_items = p.align_items,
            .no_cross_stretch = p.orientation == .vertical and p.width == .fit,
            .gap = 0,
        } }, {}));
        container.meta.ownership.meta.component_name = "Group";

        return .{ .container = container };
    }
};

/// Add child node to Group; set per-corner radius by position.
/// Horizontal layout (radii order: TL, TR, BR, BL):
/// - first: keep TL/BL, zero TR/BR
/// - last: keep TR/BR, zero TL/BL
/// - between: zero all
/// - only: keep all.
pub fn addGroupItem(
    container: *Node,
    allocator: Allocator,
    child: *Node,
    pos: GroupItemPosition,
    radius: f32,
) !void {
    const ext = try child.style.ensureExtFallible(allocator);
    const horizontal = container.style.direction == .row;
    // Attached vertical controls share the container's cross-axis width.
    // Buttons normally opt out of inherited stretch when used independently.
    if (!horizontal and container.style.align_items == .stretch and child.style.width == .fit) {
        const bounds = child.style.width.fit;
        child.setStyleInline(allocator, .{
            .width = .{ .grow = .{ .min = bounds.min, .max = bounds.max } },
            .no_cross_stretch = false,
        });
    }
    const overlap = @max(@as(f32, 1), child.style.border.width);
    var side_colors = ext.border_side_colors orelse BorderSideColors{};

    ext.corner_radius = switch (pos) {
        .only => .{ .all = radius },
        .first => if (horizontal)
            .{ .each = .{ radius, 0, 0, radius } }
        else
            .{ .each = .{ radius, radius, 0, 0 } },
        .last => if (horizontal)
            .{ .each = .{ 0, radius, radius, 0 } }
        else
            .{ .each = .{ 0, 0, radius, radius } },
        .between => .{ .all = 0 },
    };

    // Zero border.radius (per-corner controlled by ext.corner_radius).
    child.style.border.radius = 0;
    child.setMargin(Padding.ZERO);
    switch (pos) {
        .first => {
            if (horizontal) {
                side_colors.right = Color.TRANSPARENT;
            } else {
                side_colors.bottom = Color.TRANSPARENT;
            }
        },
        .only => {},
        .between, .last => {
            if (horizontal) {
                child.setMarginLeft(-overlap);
                if (pos == .between) side_colors.right = Color.TRANSPARENT;
            } else {
                child.setMarginTop(-overlap);
                if (pos == .between) side_colors.bottom = Color.TRANSPARENT;
            }
        },
    }

    ext.border_side_colors = side_colors;
    ext.hit_shape = .auto;
    ext.clip_shape = .auto;

    try container.appendChild(allocator, child);
}

// ========== Tests ==========

test "Group: vertical buttons share intrinsic group width" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(400, 300);
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 }, .direction = .column }, .{});
    ctx.root = root;
    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();
    const group = try Group(.{ .orientation = .vertical }).mount(scope, ctx);
    try root.appendChild(alloc, group.container);
    const Button = @import("../button/mod.zig").Button;
    const top = try Button(.{ .label = "Top" }).mount(scope, ctx);
    const middle = try Button(.{ .label = "Middle" }).mount(scope, ctx);
    const bottom = try Button(.{ .label = "Bottom" }).mount(scope, ctx);
    try addGroupItem(group.container, alloc, top, .first, 8);
    try addGroupItem(group.container, alloc, middle, .between, 8);
    try addGroupItem(group.container, alloc, bottom, .last, 8);
    ctx.layout();
    try std.testing.expect(top.rectFromWorldOrFallback().w > 0 and top.rectFromWorldOrFallback().w < root.rectFromWorldOrFallback().w);
    try std.testing.expectApproxEqAbs(group.container.rectFromWorldOrFallback().w, top.rectFromWorldOrFallback().w, 0.01);
    try std.testing.expectApproxEqAbs(top.rectFromWorldOrFallback().w, middle.rectFromWorldOrFallback().w, 0.01);
    try std.testing.expectApproxEqAbs(top.rectFromWorldOrFallback().w, bottom.rectFromWorldOrFallback().w, 0.01);
}

test "Group: structure" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const result = try Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, result.container);

    try std.testing.expectEqual(@as(f32, 0), result.container.style.gap);
    try std.testing.expectEqual(@as(f32, 0), result.container.style.border.width);
}

test "Group: addGroupItem per-corner radius" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 200 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const result = try Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, result.container);

    const c1 = try box(ctx, .{ .border = .{ .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});
    const c2 = try box(ctx, .{ .border = .{ .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});
    const c3 = try box(ctx, .{ .border = .{ .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});

    try addGroupItem(result.container, alloc, c1, .first, 8);
    try addGroupItem(result.container, alloc, c2, .between, 8);
    try addGroupItem(result.container, alloc, c3, .last, 8);

    // first: TL=8, TR=0, BR=0, BL=8
    const r1 = c1.style.effectiveRadii();
    try std.testing.expectEqual(@as(f32, 8), r1[0]);
    try std.testing.expectEqual(@as(f32, 0), r1[1]);
    try std.testing.expectEqual(@as(f32, 0), r1[2]);
    try std.testing.expectEqual(@as(f32, 8), r1[3]);

    // between: all 0
    const r2 = c2.style.effectiveRadii();
    try std.testing.expectEqual(@as(f32, 0), r2[0]);

    // last: TL=0, TR=8, BR=8, BL=0
    const r3 = c3.style.effectiveRadii();
    try std.testing.expectEqual(@as(f32, 0), r3[0]);
    try std.testing.expectEqual(@as(f32, 8), r3[1]);
    try std.testing.expectEqual(@as(f32, 8), r3[2]);
    try std.testing.expectEqual(@as(f32, 0), r3[3]);

    // border width/color not modified.
    try std.testing.expectEqual(@as(f32, 1), c1.style.border.width);
    try std.testing.expectEqual(Color.hex(0xE5E5E5), c2.style.border.color);
    try std.testing.expectEqual(@as(f32, -1), c2.style.margin.left);
    try std.testing.expectEqual(@as(f32, -1), c3.style.margin.left);
}

test "Group: overlap follows child border width" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 240 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const result = try Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, result.container);

    const c1 = try box(ctx, .{ .border = .{ .radius = 8, .width = 2, .color = Color.hex(0xE5E5E5) } }, .{});
    const c2 = try box(ctx, .{ .border = .{ .radius = 8, .width = 2, .color = Color.hex(0xE5E5E5) } }, .{});

    try addGroupItem(result.container, alloc, c1, .first, 8);
    try addGroupItem(result.container, alloc, c2, .last, 8);

    try std.testing.expectEqual(@as(f32, -2), c2.style.margin.left);
}

test "Group: attached seam keeps leading border on later items" {
    const alloc = std.testing.allocator;
    var ctx = try Cx.init(alloc, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 240 }, .height = .{ .px = 120 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(alloc, null, ctx.owner);
    defer scope.dispose();

    const result = try Group(.{}).mount(scope, ctx);
    try root.appendChild(alloc, result.container);

    const c1 = try box(ctx, .{ .border = .{ .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});
    const c2 = try box(ctx, .{ .border = .{ .radius = 8, .width = 1, .color = Color.hex(0xE5E5E5) } }, .{});

    try addGroupItem(result.container, alloc, c1, .first, 8);
    try addGroupItem(result.container, alloc, c2, .last, 8);

    try std.testing.expect(c1.style.border_side_colors() != null);
    try std.testing.expect(c2.style.border_side_colors() != null);
    try std.testing.expect(Color.eql(c1.style.border_side_colors().?.right.?, Color.TRANSPARENT));
    try std.testing.expect(c2.style.border_side_colors().?.left == null);
    try std.testing.expect(c2.style.border_side_colors().?.top == null);
}

// Per-allocation OOM sweep; see src/ui/components/oom_sweep.zig.
test "group: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("group", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try Group(.{}).mount(scope, cx)).container;
        }
    }.m);
}
