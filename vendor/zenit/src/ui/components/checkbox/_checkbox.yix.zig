//! Checkbox view. Styles in styles.yss (CheckboxParts), tests in mod.zig.
const ui = @import("../../ui.zig");
const S = @import("_styles.yss.zig");

/// Checkbox: W.Checkbox(.{ .label = "Agree", .checked = agree }).
/// checked is controlled value: pass bool = component self-holds, pass signal = interaction writes
/// directly, ui.split = parent decides;
/// on_change only reports settled value. indeterminate read-only (controlled by parent, parent
/// decides after click whether to clear).
/// Disabled suppresses click / space / enter, exits Tab order.
pub fn Checkbox(args: anytype) ui.view.ComponentOf(__yix_Checkbox) {
    return ui.view.component(__yix_Checkbox, ui.reactive.props.coerce(CheckboxProps, args));
}
pub const CheckboxProps = struct {
    checked: ui.Model(bool) = .{ .local = false },
    indeterminate: ui.Source(bool) = .{ .value = false },
    label: ui.Source([]const u8) = .{ .value = "" },
    disabled: ui.Source(bool) = .{ .value = false },
    focus_ring: ui.Source(ui.FocusRingConfig) = .{ .value = .{} },
    on_change: ?ui.Handler(bool) = null,
    check_icon_asset: ui.Source(?ui.SvgAsset) = .{ .value = null },
    box_size: ui.Source(f32) = .{ .value = 18 },
    label_font_size: ui.Source(f32) = .{ .value = 14 },
    /// Text children of the tag go into this parameter (ui.view.textChild)
    pub const text_child = "label";
};
fn __yix_Checkbox(__yix_props: CheckboxProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const indeterminate = __yix_props.indeterminate;
    const label = __yix_props.label;
    const disabled = __yix_props.disabled;
    const focusRing = __yix_props.focus_ring;
    const onChange = __yix_props.on_change;
    const checkIconAsset = __yix_props.check_icon_asset;
    const boxSize = __yix_props.box_size;
    const labelFontSize = __yix_props.label_font_size;
    const __yix_model_checked = try ui.reactive.resolveModelFor(bool, scope, __yix_props.checked);
    const checked = __yix_model_checked.read;
    const on = __yix_d1: {
        const __yix_T = @TypeOf(checked.peek() or indeterminate.peek());
        break :__yix_d1 try scope.derive(__yix_T, .{ .checked = checked, .indeterminate = indeterminate, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.checked.get() or __yix_ctx.indeterminate.get();
        } }.__yix_compute);
    };
    const mixed = __yix_d2: {
        const __yix_T = @TypeOf(indeterminate.peek() and !checked.peek());
        break :__yix_d2 try scope.derive(__yix_T, .{ .indeterminate = indeterminate, .checked = checked, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.indeterminate.get() and !__yix_ctx.checked.get();
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = S.CheckboxParts.slot(.root, .{ .disabled = disabled }), .tag = .button, .focusable = __yix_d3: {
        const __yix_T = @TypeOf(!disabled.peek());
        break :__yix_d3 try scope.derive(__yix_T, .{ .disabled = disabled, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return !__yix_ctx.disabled.get();
        } }.__yix_compute);
    }, .focus_ring = focusRing, .a11y = .{ .role = .checkbox, .checked = checked, .indeterminate = mixed, .disabled = disabled, .label = label }, .on_click = try ui.on.bind(scope, .{ .disabled = disabled, .checked = checked, .__yix_model_checked = __yix_model_checked, .onChange = onChange, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.disabled.peek()) { __yix_ctx.__yix_model_checked.propose(!__yix_ctx.checked.peek(), __yix_ctx.onChange); }  } }.__yix_run), }, .{
            ui.view.box(.{ .style = .{ S.CheckboxParts.slot(.box, .{ .on = on, .disabled = disabled }), ui.view.styleBy(boxSize, S.checkboxSize) }, }, .{
                ui.view.icon(.{ .style = .{ S.CheckboxParts.slot(.check, .{ .shown = checked }), ui.view.styleBy(boxSize, S.checkboxCheckSize) }, }, __yix_d4: {
        const __yix_T = @TypeOf(checkIconAsset.peek() orelse ui.icons.check);
        break :__yix_d4 try scope.derive(__yix_T, .{ .checkIconAsset = checkIconAsset, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.checkIconAsset.get() orelse ui.icons.check;
        } }.__yix_compute);
    }),
                ui.view.box(.{ .style = .{ S.CheckboxParts.slot(.indet, .{ .shown = mixed }), ui.view.styleBy(boxSize, S.checkboxSize) }, }, .{
                    ui.view.icon(.{ .style = .{ S.CheckboxParts.slot(.check, .{ .shown = true }), ui.view.styleBy(boxSize, S.checkboxCheckSize) }, }, ui.icons.minus),
                }),
            }),
            ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(label.peek().len != 0);
        break :__yix_d1 try scope.derive(__yix_T, .{ .label = label, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.label.get().len != 0;
        } }.__yix_compute);
    }, .{ .label = label, .disabled = disabled, .labelFontSize = labelFontSize, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ .style = .{ S.CheckboxParts.slot(.label, .{ .disabled = __yix_b1_0.disabled }), ui.view.styleBy(__yix_b1_0.labelFontSize, S.checkboxLabelSize) }, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b1_0.label), ""), .{ __yix_b1_0.label, })) }); } }.__yix_b, null),
        }));
    __yix_root.meta.ownership.meta.component_name = "Checkbox";
    return __yix_root;

}

//# yix-map-data [[565,560]]

//# yix-map src/ui/components/checkbox/checkbox.yix
