// GENERATED FILE, do not edit: generated from view.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
const ui = @import("ui");

/// Design background is transparent (#FFFFFF00), PNG export lands on white. Comparison needs
/// white background on both sides, else RMSE is drowned by background difference. Use ui.arb
/// to mark an intentional arbitrary value: a legal escape hatch to align with the visual
/// design, not a lazy literal avoiding token migration (see scripts/check_style_literals.sh).
const S = struct {
    // Outer container provides clean white background + places component at (0,0) origin,
    // aligns screenshot crop with design export.
    fn canvas(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .fill(), .height = .fill(), .background = ui.arb.hex(0xFFFFFF), .align_items = .start };
    }
    fn layerRow(_: *const ui.theme.Values) ui.BoxStyle {
        return .{
            .width = .fixed(220),
            .height = .fixed(24),
            .align_items = .center,
            .gap = 6,
            .padding = .{ .top = 0, .right = 6, .bottom = 0, .left = 8 },
            .border = .{ .radius = 4, .width = 0, .color = ui.arb.hexA(0x000000, 0) },
        };
    }
    fn square(comptime px: f32) fn (*const ui.theme.Values) ui.BoxStyle {
        return struct {
            fn f(_: *const ui.theme.Values) ui.BoxStyle {
                return .{ .width = .fixed(px), .height = .fixed(px) };
            }
        }.f;
    }
    fn spacer(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .fill(), .height = .fixed(1) };
    }
    fn rail(_: *const ui.theme.Values) ui.BoxStyle {
        return .{ .width = .fixed(48), .height = .fixed(12) };
    }
    fn iconTint(_: *const ui.theme.Values) ui.Color {
        return ui.arb.hex(0x92929B);
    }
    fn label(_: *const ui.theme.Values) ui.TextStyle {
        return .{ .color = ui.arb.hex(0x17171B), .font_size = ui.arb.px(12), .font_weight = 400 };
    }
};

/// Pencil `Layer Row` (exzZc) value-by-value restore. Spacer: width fill_container ->
/// fill; Rail: three icons all enabled:false, invisible in design, keep placeholder
/// size.
pub fn DesignProbe(args: anytype) ui.view.ComponentOf(__yix_DesignProbe) {
    return ui.view.component(__yix_DesignProbe, ui.reactive.props.coerce(DesignProbeProps, args));
}
pub const DesignProbeProps = struct {
};
fn __yix_DesignProbe(__yix_props: DesignProbeProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ .style = S.canvas, }, .{
            ui.view.row(.{ .style = S.layerRow, .test_id = "probe.layer_row", }, .{
                ui.view.icon(.{ .style = S.square(10), .tint = S.iconTint, }, ui.icons.chevron_down),
                ui.view.icon(.{ .style = S.square(13), .tint = S.iconTint, }, ui.icons.square_dashed),
                ui.view.text(.{ .style = S.label, }, ui.view.fmt("Layer", .{ })),
                ui.view.box(.{ .style = S.spacer, }, .{ }),
                ui.view.box(.{ .style = S.rail, }, .{ }),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "DesignProbe";
    return __yix_root;

}

//# yix-map-data [[2065,2065]]

//# yix-map view.yix
