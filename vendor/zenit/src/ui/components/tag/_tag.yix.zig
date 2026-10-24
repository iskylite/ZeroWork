// GENERATED FILE, do not edit: generated from tag.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Tag view. Styles in styles.yss, shared types and tests in mod.zig.
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");
const S = @import("_styles.yss.zig");
const TagColor = mod.TagColor;
const TagVariant = mod.TagVariant;
const TagSize = mod.TagSize;

/// Tag: color (can switch with state) x outline variant x size, can close.
/// W.Tag(.{ .label = "Beta", .color = .accent, .closable = true, .on_close = remove })
pub fn Tag(args: anytype) ui.view.ComponentOf(__yix_Tag) {
    return ui.view.component(__yix_Tag, ui.reactive.props.coerce(TagProps, args));
}
pub const TagProps = struct {
    label: ui.Source([]const u8) = .{ .value = "" },
    variant: ui.Source(TagVariant) = .{ .value = .default },
    color: ui.Source(TagColor) = .{ .value = .neutral },
    size: ui.Source(TagSize) = .{ .value = .md },
    closable: ui.Source(bool) = .{ .value = false },
    on_close: ?ui.Handler(void) = null,
    close_icon_asset: ui.Source(?ui.SvgAsset) = .{ .value = null },
    /// Text children of the tag go into this parameter (ui.view.textChild)
    pub const text_child = "label";
};
fn __yix_Tag(__yix_props: TagProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const label = __yix_props.label;
    const variant = __yix_props.variant;
    const color = __yix_props.color;
    const size = __yix_props.size;
    const closable = __yix_props.closable;
    const onClose = __yix_props.on_close;
    const closeIconAsset = __yix_props.close_icon_asset;
    const p = ui.view.slotParts(S.Tag, .{ .color = color, .kind = variant, .size = size });
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = p.root, }, .{
            ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(label.peek().len != 0);
        break :__yix_d1 try scope.derive(__yix_T, .{ .label = label, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.label.get().len != 0;
        } }.__yix_compute);
    }, .{ .label = label, .p = p, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ .style = __yix_b1_0.p.label, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b1_0.label), ""), .{ __yix_b1_0.label, })) }); } }.__yix_b, null),
            ui.view.lazyIf(closable, .{ .onClose = onClose, .closeIconAsset = closeIconAsset, .p = p, }, struct { fn __yix_b(__yix_b2_0: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.box(.{ .style = __yix_b2_0.p.close, .a11y = .{ .role = .button, .label = "Remove" }, .on_click = __yix_b2_0.onClose, }, .{
                    ui.view.lazyIfSome(__yix_b2_0.closeIconAsset, .{ .p = __yix_b2_0.p, }, struct { fn __yix_b(__yix_b3_0: anytype, asset: anytype, __yix_bs3_0: *ui.Scope, __yix_bc3_0: *ui.Cx, __yix_bk3_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs3_0, __yix_bc3_0, __yix_bk3_0, .{ ui.view.icon(.{ .style = __yix_b3_0.p.close_icon, }, asset) }); } }.__yix_b, struct { fn __yix_b(__yix_b3_1: anytype, __yix_bs3_1: *ui.Scope, __yix_bc3_1: *ui.Cx, __yix_bk3_1: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs3_1, __yix_bc3_1, __yix_bk3_1, .{ ui.view.text(.{ .style = __yix_b3_1.p.close_text, }, ui.view.fmt("x", .{ })) }); } }.__yix_b),
                }) }); } }.__yix_b, null),
        }));
    __yix_root.meta.ownership.meta.component_name = "Tag";
    return __yix_root;

}

//# yix-map-data [[441,436]]

//# yix-map tag.yix
