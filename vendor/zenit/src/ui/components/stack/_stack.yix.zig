// GENERATED FILE, do not edit: generated from stack.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! VStack / HStack / Spacer views. Children passed via ui.view.with(W.VStack(...), .{ ... }) or Yix
//! tag children.
const ui = @import("../../ui.zig");
const S = @import("_styles.yss.zig");

/// Vertical stack: <W.VStack gap={8}>…</W.VStack>
pub fn VStack(args: anytype) ui.view.SlottedOf(__yix_VStack) {
    return ui.view.slotted(__yix_VStack, ui.reactive.props.coerce(VStackProps, args));
}
pub const VStackProps = struct {
    gap: ui.Source(f32) = .{ .value = 0 },
    justify: ui.Source(ui.JustifyContent) = .{ .value = .start },
    align_items: ui.Source(ui.AlignItems) = .{ .value = .stretch },
    width: ui.Source(?f32) = .{ .value = null },
    height: ui.Source(?f32) = .{ .value = null },
    padding: ui.Source(?ui.Padding) = .{ .value = null },
    background: ui.Source(?ui.Color) = .{ .value = null },
    reverse: ui.Source(bool) = .{ .value = false },
};
fn __yix_VStack(__yix_props: VStackProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!ui.view.ViewParts {
    const gap = __yix_props.gap;
    const justify = __yix_props.justify;
    const alignItems = __yix_props.align_items;
    const width = __yix_props.width;
    const height = __yix_props.height;
    const padding = __yix_props.padding;
    const background = __yix_props.background;
    const reverse = __yix_props.reverse;
    const direction = __yix_d1: {
        const __yix_T = @TypeOf(if (reverse.peek()) ui.Direction.column_reverse else .column);
        break :__yix_d1 try scope.derive(__yix_T, .{ .reverse = reverse, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.reverse.get()) ui.Direction.column_reverse else .column;
        } }.__yix_compute);
    };
    var __yix_slot_children: ?ui.view.SlotPoint = null;
    const __yix_root = try ui.view.render(scope, cx, ui.view.slotEnd(&__yix_slot_children, ui.view.box(.{ .style = S.stack.of(.{ .direction = direction, .gap = gap, .justify = justify, .align_items = alignItems, .width = width, .height = height, .padding = padding, .background = background }), }, .{ })));
    __yix_root.meta.ownership.meta.component_name = "VStack";
    return ui.view.slottedParts(__yix_root, __yix_slot_children, .{ });

}

/// Horizontal stack: <W.HStack gap={8} wrap>…</W.HStack>
pub fn HStack(args: anytype) ui.view.SlottedOf(__yix_HStack) {
    return ui.view.slotted(__yix_HStack, ui.reactive.props.coerce(HStackProps, args));
}
pub const HStackProps = struct {
    gap: ui.Source(f32) = .{ .value = 0 },
    justify: ui.Source(ui.JustifyContent) = .{ .value = .start },
    align_items: ui.Source(ui.AlignItems) = .{ .value = .center },
    width: ui.Source(?f32) = .{ .value = null },
    height: ui.Source(?f32) = .{ .value = null },
    padding: ui.Source(?ui.Padding) = .{ .value = null },
    background: ui.Source(?ui.Color) = .{ .value = null },
    reverse: ui.Source(bool) = .{ .value = false },
    wrap: ui.Source(bool) = .{ .value = false },
};
fn __yix_HStack(__yix_props: HStackProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!ui.view.ViewParts {
    const gap = __yix_props.gap;
    const justify = __yix_props.justify;
    const alignItems = __yix_props.align_items;
    const width = __yix_props.width;
    const height = __yix_props.height;
    const padding = __yix_props.padding;
    const background = __yix_props.background;
    const reverse = __yix_props.reverse;
    const wrap = __yix_props.wrap;
    const direction = __yix_d1: {
        const __yix_T = @TypeOf(if (reverse.peek()) ui.Direction.row_reverse else .row);
        break :__yix_d1 try scope.derive(__yix_T, .{ .reverse = reverse, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.reverse.get()) ui.Direction.row_reverse else .row;
        } }.__yix_compute);
    };
    var __yix_slot_children: ?ui.view.SlotPoint = null;
    const __yix_root = try ui.view.render(scope, cx, ui.view.slotEnd(&__yix_slot_children, ui.view.box(.{ .style = S.stack.of(.{ .direction = direction, .gap = gap, .justify = justify, .align_items = alignItems, .width = width, .height = height, .padding = padding, .background = background, .wrap = wrap }), }, .{ })));
    __yix_root.meta.ownership.meta.component_name = "HStack";
    return ui.view.slottedParts(__yix_root, __yix_slot_children, .{ });

}

/// Elastic spacing: occupies remaining space in stack
pub fn Spacer(args: anytype) ui.view.ComponentOf(__yix_Spacer) {
    return ui.view.component(__yix_Spacer, ui.reactive.props.coerce(SpacerProps, args));
}
pub const SpacerProps = struct {
    min_size: ui.Source(f32) = .{ .value = 0 },
};
fn __yix_Spacer(__yix_props: SpacerProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const minSize = __yix_props.min_size;
    const __yix_root = try ui.view.render(scope, cx, ui.view.box(.{ .style = S.spacer.of(.{ .min_size = minSize }), }, .{ }));
    __yix_root.meta.ownership.meta.component_name = "Spacer";
    return __yix_root;

}

//# yix-map-data [[251,246],[2259,905],[4347,1590]]

//# yix-map stack.yix
