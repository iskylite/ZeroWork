// GENERATED FILE, do not edit: generated from modal.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Modal's dialog panel: title bar (title + close button) and body slot. Popover, toggle pipeline
//! and focus trap in mod.zig, styles in styles.yss.
const ui = @import("../../ui.zig");
const S = @import("_styles.yss.zig");

/// Dialog panel. hasTitle determined at mount by mod.zig (when title statically empty, no title
/// bar, thus no close button).
/// title is mount-time snapshot: title changes after mount and dialog's a11y name written by
/// mod.zig's bindTextLabel (name points to text node's own copy,
/// pointing at source data directly would dangle after source update). Icon / 'X' glyph not
/// readable name, close button's a11y name states Close.
pub fn ModalPanel(args: anytype) ui.view.SlottedOf(__yix_ModalPanel) {
    return ui.view.slotted(__yix_ModalPanel, ui.reactive.props.coerce(ModalPanelProps, args));
}
pub const ModalPanelProps = struct {
    title: ui.Source([]const u8),
    has_title: ui.Source(bool),
    width: ui.Source(f32),
    max_height: ui.Source(f32),
    background: ui.Source(?ui.Color) = .{ .value = null },
    close_icon_asset: ui.Source(?ui.SvgAsset) = .{ .value = null },
    on_close: ui.Handler(void),
};
fn __yix_ModalPanel(__yix_props: ModalPanelProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!ui.view.ViewParts {
    const title = __yix_props.title;
    const hasTitle = __yix_props.has_title;
    const width = __yix_props.width;
    const maxHeight = __yix_props.max_height;
    const background = __yix_props.background;
    const closeIconAsset = __yix_props.close_icon_asset;
    const onClose = __yix_props.on_close;
    var __yix_slot_children: ?ui.view.SlotPoint = null;
    const __yix_root = try ui.view.render(scope, cx, ui.view.box(.{ .style = .{ S.dialog.of(.{ .width = width, .max_height = maxHeight, .background = background }) }, .a11y = .{ .role = .dialog, .modal = true }, }, .{
            ui.view.lazyIf(hasTitle, .{ .title = title, .closeIconAsset = closeIconAsset, .onClose = onClose, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.box(.{ .style = S.header, }, .{
                    ui.view.text(.{ .style = S.title, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b1_0.title), ""), .{ __yix_b1_0.title, })),
                    ui.view.box(.{ .style = S.close_button, .on_click = __yix_b1_0.onClose, .test_id = "modal.close", .a11y = .{ .role = .button, .label = "Close" }, }, .{
                        ui.view.lazyIfSome(__yix_b1_0.closeIconAsset, .{ }, struct { fn __yix_b(__yix_b2_0: anytype, asset: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { _ = __yix_b2_0; return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.icon(.{ .style = S.close_icon, }, asset) }); } }.__yix_b, struct { fn __yix_b(__yix_b2_1: anytype, __yix_bs2_1: *ui.Scope, __yix_bc2_1: *ui.Cx, __yix_bk2_1: ui.view.Sink) anyerror!void { _ = __yix_b2_1; return ui.view.emit(__yix_bs2_1, __yix_bc2_1, __yix_bk2_1, .{ ui.view.text(.{ .box = S.close_glyph_box, .style = S.close_glyph, }, ui.view.fmt("✕", .{ })) }); } }.__yix_b),
                    }),
                }) }); } }.__yix_b, null),
            ui.view.slotEnd(&__yix_slot_children, ui.view.box(.{ .style = S.body, }, .{ })),
        }));
    __yix_root.meta.ownership.meta.component_name = "ModalPanel";
    return ui.view.slottedParts(__yix_root, __yix_slot_children, .{ });

}

//# yix-map-data [[671,666]]

//# yix-map modal.yix
