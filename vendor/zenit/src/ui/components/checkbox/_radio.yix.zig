// GENERATED FILE, do not edit: generated from radio.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Radio / RadioGroup view. Styling in styles.yss (RadioParts / RadioGroupLayout);
//! public types and tests in mod.zig.
const std = @import("std");
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");
const S = @import("_styles.yss.zig");
const RadioOption = mod.RadioOption;

/// Standalone Radio: display only (selection logic via RadioGroup).
/// `W.Radio(.{ .label = "A", .checked = ui.map(sel, isA) })`
pub fn Radio(args: anytype) ui.view.ComponentOf(__yix_Radio) {
    return ui.view.component(__yix_Radio, ui.reactive.props.coerce(RadioProps, args));
}
pub const RadioProps = struct {
    checked: ui.Source(bool) = .{ .value = false },
    label: ui.Source([]const u8) = .{ .value = "" },
    disabled: ui.Source(bool) = .{ .value = false },
    /// Text children of the tag go into this parameter (ui.view.textChild)
    pub const text_child = "label";
};
fn __yix_Radio(__yix_props: RadioProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const checked = __yix_props.checked;
    const label = __yix_props.label;
    const disabled = __yix_props.disabled;
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = S.RadioParts.slot(.root, .{ .disabled = disabled }), .a11y = .{ .role = .radio, .checked = checked, .disabled = disabled, .label = label }, }, .{
            ui.view.box(.{ .style = S.RadioParts.slot(.circle, .{ .checked = checked }), }, .{
                ui.view.box(.{ .style = S.RadioParts.slot(.dot, .{ .checked = checked }), }, .{ }),
            }),
            ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(label.peek().len != 0);
        break :__yix_d1 try scope.derive(__yix_T, .{ .label = label, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.label.get().len != 0;
        } }.__yix_compute);
    }, .{ .label = label, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ .style = S.RadioParts.slot(.label, .{}), }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b1_0.label), ""), .{ __yix_b1_0.label, })) }); } }.__yix_b, null),
        }));
    __yix_root.meta.ownership.meta.component_name = "Radio";
    return __yix_root;

}

/// RadioGroup option: button semantic node, focusable, focus ring; unhovered
/// highlights circle border on hover. Caller's `testId` lands on root node (this
/// button semantic node).
fn RadioChoice(args: anytype) ui.view.ComponentOf(__yix_RadioChoice) {
    return ui.view.component(__yix_RadioChoice, ui.reactive.props.coerce(RadioChoiceProps, args));
}
const RadioChoiceProps = struct {
    label: ui.Source([]const u8),
    checked: ui.Source(bool),
    disabled: ui.Source(bool),
    on_pick: ?ui.Handler(void) = null,
    focus_ring: ui.Source(ui.FocusRingConfig) = .{ .value = .{} },
};
fn __yix_RadioChoice(__yix_props: RadioChoiceProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const label = __yix_props.label;
    const checked = __yix_props.checked;
    const disabled = __yix_props.disabled;
    const onPick = __yix_props.on_pick;
    const focusRing = __yix_props.focus_ring;
    const hovered = try scope.createSignalFor(bool, false);
    const enabled = __yix_d1: {
        const __yix_T = @TypeOf(!disabled.peek());
        break :__yix_d1 try scope.derive(__yix_T, .{ .disabled = disabled, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return !__yix_ctx.disabled.get();
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = S.RadioParts.slot(.root, .{ .disabled = disabled }), .tag = .button, .focusable = enabled, .focus_ring = focusRing, .a11y = .{ .role = .radio, .label = label, .checked = checked, .disabled = disabled }, .on_click = onPick, .on_hover = try ui.on.bind(scope, .{ .hovered = hovered, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.hovered.set(true);  } }.__yix_run), .on_leave = try ui.on.bind(scope, .{ .hovered = hovered, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); __yix_ctx.hovered.set(false);  } }.__yix_run), }, .{
            ui.view.box(.{ .style = S.RadioParts.slot(.circle, .{ .checked = checked, .hovered = hovered }), }, .{
                ui.view.box(.{ .style = S.RadioParts.slot(.dot, .{ .checked = checked }), }, .{ }),
            }),
            ui.view.text(.{ .style = S.RadioParts.slot(.label, .{}), }, ui.view.fmt(ui.view.yixFormat(@TypeOf(label), ""), .{ label, })),
        }));
    __yix_root.meta.ownership.meta.component_name = "RadioChoice";
    return __yix_root;

}

fn isSelected(value: ?[]const u8, option: []const u8) bool {
    const v = value orelse return false;
    return std.mem.eql(u8, v, option);
}

/// Radio group: `W.RadioGroup(.{ .options = &opts, .value = theme_choice })`.
/// value is controlled (option's value string, borrows option); on_change only
/// reports the landed selection. Reconciles by content: same content in a new array
/// doesn't rebuild (keeps hover / focus / transition), changed content rebuilds.
/// Ignores selection when group or option is disabled.
pub fn RadioGroup(args: anytype) ui.view.ComponentOf(__yix_RadioGroup) {
    return ui.view.component(__yix_RadioGroup, ui.reactive.props.coerce(RadioGroupProps, args));
}
pub const RadioGroupProps = struct {
    options: ui.Source([]const RadioOption) = .{ .value = &.{} },
    value: ui.Model(?[]const u8) = .{ .local = null },
    disabled: ui.Source(bool) = .{ .value = false },
    horizontal: ui.Source(bool) = .{ .value = false },
    focus_ring: ui.Source(ui.FocusRingConfig) = .{ .value = .{} },
    on_change: ?ui.Handler([]const u8) = null,
};
fn __yix_RadioGroup(__yix_props: RadioGroupProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const options = __yix_props.options;
    const disabled = __yix_props.disabled;
    const horizontal = __yix_props.horizontal;
    const focusRing = __yix_props.focus_ring;
    const onChange = __yix_props.on_change;
    const __yix_model_value = try ui.reactive.resolveModelFor(?[]const u8, scope, __yix_props.value);
    const value = __yix_model_value.read;
    const __yix_root = try ui.view.render(scope, cx, ui.view.box(.{ .style = S.RadioGroupLayout.of(.{ .horizontal = horizontal }), .a11y = .{ .role = .radiogroup, .required = true }, }, .{
            __yix_e1: { const __yix_items_1 = options; break :__yix_e1 ui.view.eachWith(.{ .value = value, .disabled = disabled, .focusRing = focusRing, .onChange = onChange, .__yix_model_value = __yix_model_value, }, __yix_items_1, struct { fn __yix_k(opt: ui.view.yixItem(@TypeOf(__yix_items_1))) u64 { return ui.view.keyOf(.{ opt.value, opt.label, opt.disabled }); } }.__yix_k, struct { fn __yix_row(__yix_row_1: anytype, opt: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, ui.view.templateAttrs(.{ .test_id = __yix_d4: {
        const __yix_T = if (ui.view.attrType(RadioChoice, "test_id")) |__yix_A| __yix_A else @TypeOf(opt.peek().test_id);
        break :__yix_d4 try __yix_scope_1.derive(__yix_T, .{ .opt = opt, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.opt.get().test_id;
        } }.__yix_compute);
    }, }, RadioChoice(.{ .focus_ring = __yix_row_1.focusRing, .label = __yix_d1: {
        const __yix_T = if (ui.view.attrType(RadioChoice, "label")) |__yix_A| __yix_A else @TypeOf(opt.peek().label);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .opt = opt, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.opt.get().label;
        } }.__yix_compute);
    }, .checked = __yix_d2: {
        const __yix_T = if (ui.view.attrType(RadioChoice, "checked")) |__yix_A| __yix_A else @TypeOf(isSelected(__yix_row_1.value.peek(), opt.peek().value));
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .value = __yix_row_1.value, .opt = opt, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return isSelected(__yix_ctx.value.get(), __yix_ctx.opt.get().value);
        } }.__yix_compute);
    }, .disabled = __yix_d3: {
        const __yix_T = if (ui.view.attrType(RadioChoice, "disabled")) |__yix_A| __yix_A else @TypeOf(__yix_row_1.disabled.peek() or opt.peek().disabled);
        break :__yix_d3 try __yix_scope_1.derive(__yix_T, .{ .disabled = __yix_row_1.disabled, .opt = opt, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.disabled.get() or __yix_ctx.opt.get().disabled;
        } }.__yix_compute);
    }, .on_pick = ui.view.eventProp(RadioChoice, "on_pick", try ui.on.bindAny(__yix_scope_1, .{ .disabled = __yix_row_1.disabled, .opt = opt, .value = __yix_row_1.value, .__yix_model_value = __yix_row_1.__yix_model_value, .onChange = __yix_row_1.onChange, .__yix_owner = __yix_scope_1.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.disabled.peek() and !__yix_ctx.opt.peek().disabled) { __yix_ctx.__yix_model_value.propose(__yix_ctx.opt.peek().value, __yix_ctx.onChange); }  } }.__yix_run)), }))); } }.__yix_row); },
        }));
    __yix_root.meta.ownership.meta.component_name = "RadioGroup";
    return __yix_root;

}

//# yix-map-data [[430,425],[2509,1162],[5417,2608]]

//# yix-map radio.yix
