// GENERATED FILE, do not edit: generated from divider.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Divider view. Styles and geometry in styles.yss, shared types and tests in mod.zig.
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");
const S = @import("_styles.yss.zig");
const DividerOrientation = mod.DividerOrientation;
const DividerVariant = mod.DividerVariant;
const DividerSpacing = mod.DividerSpacing;
const LabelPosition = mod.LabelPosition;

/// Label only applies to horizontal dividers
fn kindOf(orientation: DividerOrientation, variant: DividerVariant, label: []const u8, label_position: LabelPosition) S.Kind {
    if (label.len > 0 and orientation == .horizontal) return switch (label_position) {
        .left => .label_left,
        .center => .label_center,
        .right => .label_right,
    };
    return if (variant == .solid) .solid else .patterned;
}

/// Divider: horizontal / vertical, solid / dashed / dotted, can have label (only horizontal,
/// left/center/right).
/// W.Divider(.{ .label = "OR" })
pub fn Divider(args: anytype) ui.view.ComponentOf(__yix_Divider) {
    return ui.view.component(__yix_Divider, ui.reactive.props.coerce(DividerProps, args));
}
pub const DividerProps = struct {
    orientation: ui.Source(DividerOrientation) = .{ .value = .horizontal },
    variant: ui.Source(DividerVariant) = .{ .value = .solid },
    spacing: ui.Source(DividerSpacing) = .{ .value = .md },
    label: ui.Source([]const u8) = .{ .value = "" },
    label_position: ui.Source(LabelPosition) = .{ .value = .center },
    color: ui.Source(?ui.Color) = .{ .value = null },
    thickness: ui.Source(f32) = .{ .value = 1 },
    dash_length: ui.Source(f32) = .{ .value = 8 },
    dash_gap: ui.Source(f32) = .{ .value = 8 },
};
fn __yix_Divider(__yix_props: DividerProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const orientation = __yix_props.orientation;
    const variant = __yix_props.variant;
    const spacing = __yix_props.spacing;
    const label = __yix_props.label;
    const labelPosition = __yix_props.label_position;
    const color = __yix_props.color;
    const thickness = __yix_props.thickness;
    const dashLength = __yix_props.dash_length;
    const dashGap = __yix_props.dash_gap;
    const kind = __yix_d1: {
        const __yix_T = @TypeOf(kindOf(orientation.peek(), variant.peek(), label.peek(), labelPosition.peek()));
        break :__yix_d1 try scope.derive(__yix_T, .{ .orientation = orientation, .variant = variant, .label = label, .labelPosition = labelPosition, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return kindOf(__yix_ctx.orientation.get(), __yix_ctx.variant.get(), __yix_ctx.label.get(), __yix_ctx.labelPosition.get());
        } }.__yix_compute);
    };
    const patterned = __yix_d2: {
        const __yix_T = @TypeOf(kind.peek() == .patterned);
        break :__yix_d2 try scope.derive(__yix_T, .{ .kind = kind, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.kind.get() == .patterned;
        } }.__yix_compute);
    };
    const lead = __yix_d3: {
        const __yix_T = @TypeOf(kind.peek() == .label_center or kind.peek() == .label_right);
        break :__yix_d3 try scope.derive(__yix_T, .{ .kind = kind, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.kind.get() == .label_center or __yix_ctx.kind.get() == .label_right;
        } }.__yix_compute);
    };
    const labeled = __yix_d4: {
        const __yix_T = @TypeOf(kind.peek() == .label_left or kind.peek() == .label_center or kind.peek() == .label_right);
        break :__yix_d4 try scope.derive(__yix_T, .{ .kind = kind, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.kind.get() == .label_left or __yix_ctx.kind.get() == .label_center or __yix_ctx.kind.get() == .label_right;
        } }.__yix_compute);
    };
    const trail = __yix_d5: {
        const __yix_T = @TypeOf(kind.peek() == .label_left or kind.peek() == .label_center);
        break :__yix_d5 try scope.derive(__yix_T, .{ .kind = kind, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.kind.get() == .label_left or __yix_ctx.kind.get() == .label_center;
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.box(.{ .style = S.root.of(.{ .kind = kind, .orientation = orientation, .thickness = thickness, .color = color, .spacing = spacing, .dash_gap = dashGap }), }, .{
            ui.view.lazyIf(patterned, .{ .orientation = orientation, .variant = variant, .color = color, .thickness = thickness, .dashLength = dashLength, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.repeat(.{ .orientation = __yix_b1_0.orientation, .variant = __yix_b1_0.variant, .color = __yix_b1_0.color, .thickness = __yix_b1_0.thickness, .dashLength = __yix_b1_0.dashLength, }, @as(usize, S.dash_count), struct { fn __yix_row(__yix_row_1: anytype, _: usize, __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.box(.{ .style = S.dash.of(.{ .orientation = __yix_row_1.orientation, .variant = __yix_row_1.variant, .thickness = __yix_row_1.thickness, .length = __yix_row_1.dashLength, .color = __yix_row_1.color }), }, .{ })); } }.__yix_row) }); } }.__yix_b, null),
            ui.view.lazyIf(lead, .{ .color = color, .thickness = thickness, }, struct { fn __yix_b(__yix_b3_0: anytype, __yix_bs3_0: *ui.Scope, __yix_bc3_0: *ui.Cx, __yix_bk3_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs3_0, __yix_bc3_0, __yix_bk3_0, .{ ui.view.box(.{ .style = S.label_line.of(.{ .thickness = __yix_b3_0.thickness, .color = __yix_b3_0.color }), }, .{ }) }); } }.__yix_b, null),
            ui.view.lazyIf(labeled, .{ .label = label, }, struct { fn __yix_b(__yix_b4_0: anytype, __yix_bs4_0: *ui.Scope, __yix_bc4_0: *ui.Cx, __yix_bk4_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs4_0, __yix_bc4_0, __yix_bk4_0, .{ ui.view.text(.{ .style = S.label_text, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b4_0.label), ""), .{ __yix_b4_0.label, })) }); } }.__yix_b, null),
            ui.view.lazyIf(trail, .{ .color = color, .thickness = thickness, }, struct { fn __yix_b(__yix_b5_0: anytype, __yix_bs5_0: *ui.Scope, __yix_bc5_0: *ui.Cx, __yix_bk5_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs5_0, __yix_bc5_0, __yix_bk5_0, .{ ui.view.box(.{ .style = S.label_line.of(.{ .thickness = __yix_b5_0.thickness, .color = __yix_b5_0.color }), }, .{ }) }); } }.__yix_b, null),
        }));
    __yix_root.meta.ownership.meta.component_name = "Divider";
    return __yix_root;

}

//# yix-map-data [[953,948]]

//# yix-map divider.yix
