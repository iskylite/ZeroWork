/// Form layout container
///
/// Pure layout component that provides uniform arrangement for FormField elements.
/// Similar to SwiftUI's Form container.
///
/// Usage:
/// ```zig
/// const form_node = try Form(.{ .layout = .vertical, .gap = 16 }).mount(scope, cx);
/// try form_node.appendChild(allocator, field1_wrapper);
/// try form_node.appendChild(allocator, field2_wrapper);
/// ```
const std = @import("std");
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const Sizing = core.Sizing;
const Scope = core.Scope;
const Padding = core.Padding;

/// Form layout direction.
pub const FormLayout = enum {
    /// Fields arranged vertically (default).
    vertical,
    /// Fields arranged horizontally.
    horizontal,
};

/// Form config.
pub const FormProps = struct {
    /// Layout direction.
    layout: FormLayout = .vertical,
    /// Field spacing.
    gap: f32 = 16,
    /// Padding.
    padding: ?Padding = null,
    /// Width.
    width: ?f32 = null,
};

/// Form mount result.
pub const FormResult = struct {
    /// Root container node.
    node: *Node,
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: FormResult) core.ViewParts {
        return .{ .root = self.node, .slot = self.node };
    }
};

/// Create Form layout container.
pub fn Form(props: anytype) FormBuilder {
    return .{ .props = @import("../../reactive.zig").props.coerce(FormProps, props) };
}

pub const FormBuilder = struct {
    props: FormProps,

    pub fn mount(self: FormBuilder, scope: *Scope, cx: *Cx) !FormResult {
        const p = self.props;

        const wrapper = try view.render(scope, cx, view.box(.{ .style = core.BoxStyle{
            .width = if (p.width) |w| .{ .px = w } else .{ .grow = .{} },
            .height = .{ .fit = .{} },
            .direction = switch (p.layout) {
                .vertical => .column,
                .horizontal => .row,
            },
            .gap = p.gap,
            .padding = p.padding orelse Padding.all(0),
        } }, {}));
        wrapper.meta.ownership.meta.component_name = "Form";

        return .{ .node = wrapper };
    }
};

/// Form group title.
pub fn FormSection(title: []const u8, scope: *Scope, cx: *Cx) !*Node {
    const S = @import("styles.zig");
    const section = try view.render(scope, cx, view.col(.{ .style = S.section }, .{
        view.text(.{ .style = S.sectionTitle }, title),
        view.box(.{ .style = S.sectionDivider }, {}),
    }));
    section.meta.ownership.meta.component_name = "FormSection";
    return section;
}

// ========== Tests ==========

test "Form: vertical layout" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Form(.{ .layout = .vertical, .gap = 16 }).mount(scope, ctx);
    try root.appendChild(allocator, result.node);

    try std.testing.expectEqualStrings("Form", result.node.meta.ownership.meta.component_name.?);
    try std.testing.expectEqual(core.Direction.column, result.node.style.direction);
    try std.testing.expectEqual(@as(f32, 16), result.node.style.gap);
}

test "Form: horizontal layout" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try Form(.{ .layout = .horizontal, .gap = 8 }).mount(scope, ctx);
    try root.appendChild(allocator, result.node);

    try std.testing.expectEqual(core.Direction.row, result.node.style.direction);
    try std.testing.expectEqual(@as(f32, 8), result.node.style.gap);
}

test "FormSection: title and divider" {
    const allocator = std.testing.allocator;
    var ctx = try Cx.init(allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(allocator, null, ctx.owner);
    defer scope.dispose();
    const section = try FormSection("Personal Info", scope, ctx);
    try root.appendChild(allocator, section);

    // Section should have 2 children: title + divider.
    try std.testing.expectEqual(@as(usize, 2), section.children.items.len);

    // Title text.
    const title_node = section.children.items[0];
    try std.testing.expectEqualStrings("Personal Info", title_node.getText().?.content);

    // Divider height 1px.
    const divider = section.children.items[1];
    try std.testing.expectEqual(Sizing{ .px = 1 }, divider.style.height);
}

// Per-allocation OOM sweep, see src/ui/components/oom_sweep.zig.
test "form: mount 在任意分配点失败时不泄漏（sweep）" {
    const sw = @import("../oom_sweep.zig");
    try sw.sweepMount("form", struct {
        fn m(scope: *sw.Scope, cx: *sw.Cx) anyerror!?*sw.Node {
            return (try Form(.{}).mount(scope, cx)).node;
        }
    }.m);
}
