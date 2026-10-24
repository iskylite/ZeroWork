// GENERATED FILE, do not edit: generated from switch.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Switch view. Styles in styles.yss (SwitchParts), tests in mod.zig.
const ui = @import("../../ui.zig");
const S = @import("_styles.yss.zig");

/// Switch: W.Switch(.{ .label = "Wi-Fi", .checked = wifi }).
/// checked is controlled value: pass bool = component self-holds, pass signal = interaction writes
/// directly, ui.split = parent decides;
/// on_change only reports settled value. Disabled suppresses click / space / enter, exits Tab
/// order.
pub fn Switch(args: anytype) ui.view.ComponentOf(__yix_Switch) {
    return ui.view.component(__yix_Switch, ui.reactive.props.coerce(SwitchProps, args));
}
pub const SwitchProps = struct {
    checked: ui.Model(bool) = .{ .local = false },
    label: ui.Source([]const u8) = .{ .value = "" },
    disabled: ui.Source(bool) = .{ .value = false },
    focus_ring: ui.Source(ui.FocusRingConfig) = .{ .value = .{} },
    on_change: ?ui.Handler(bool) = null,
    /// Text children of the tag go into this parameter (ui.view.textChild)
    pub const text_child = "label";
};
fn __yix_Switch(__yix_props: SwitchProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const label = __yix_props.label;
    const disabled = __yix_props.disabled;
    const focusRing = __yix_props.focus_ring;
    const onChange = __yix_props.on_change;
    const __yix_model_checked = try ui.reactive.resolveModelFor(bool, scope, __yix_props.checked);
    const checked = __yix_model_checked.read;
    const enabled = __yix_d1: {
        const __yix_T = @TypeOf(!disabled.peek());
        break :__yix_d1 try scope.derive(__yix_T, .{ .disabled = disabled, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return !__yix_ctx.disabled.get();
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = S.SwitchParts.slot(.root, .{ .disabled = disabled }), .tag = .button, .focusable = enabled, .focus_ring = focusRing, .a11y = .{ .role = .switch_role, .checked = checked, .disabled = disabled, .label = label }, .on_click = try ui.on.bind(scope, .{ .disabled = disabled, .checked = checked, .__yix_model_checked = __yix_model_checked, .onChange = onChange, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.disabled.peek()) { __yix_ctx.__yix_model_checked.propose(!__yix_ctx.checked.peek(), __yix_ctx.onChange); }  } }.__yix_run), }, .{
            ui.view.box(.{ .style = S.SwitchParts.slot(.track, .{ .checked = checked }), }, .{
                ui.view.box(.{ .style = S.SwitchParts.slot(.thumb, .{ .checked = checked }), }, .{ }),
            }),
            ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(label.peek().len != 0);
        break :__yix_d1 try scope.derive(__yix_T, .{ .label = label, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.label.get().len != 0;
        } }.__yix_compute);
    }, .{ .checked = checked, .label = label, .disabled = disabled, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ .style = S.SwitchParts.slot(.label, .{ .checked = __yix_b1_0.checked, .disabled = __yix_b1_0.disabled }), }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b1_0.label), ""), .{ __yix_b1_0.label, })) }); } }.__yix_b, null),
        }));
    __yix_root.meta.ownership.meta.component_name = "Switch";
    return __yix_root;

}

//# yix-map-data [[459,454]]

//# yix-map switch.yix
