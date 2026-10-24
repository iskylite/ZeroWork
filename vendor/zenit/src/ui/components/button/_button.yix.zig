// GENERATED FILE, do not edit: generated from button.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Button view. Styles and drawing in styles.yss, shared types and tests in mod.zig.
const ui = @import("../../ui.zig");
const core = @import("../../core.zig");
const S = @import("_styles.yss.zig");
const ButtonVariant = S.ButtonVariant;
const ButtonSize = S.ButtonSize;

/// Button semantics: name taken from a11yLabel, else label (falls back to child text if neither),
/// disabled, loading (busy)
fn a11yOf(name: []const u8, text: []const u8, disabled: bool, loading: bool) ui.A11yProps {
    const resolved = if (name.len > 0) name else text;
    return .{ .role = .button, .label = if (resolved.len > 0) resolved else null, .disabled = disabled, .busy = loading };
}

/// Button: W.Button(.{ .label = "Save", .disabled = ui.not(dirty), .on_click = cx.on(S, s, S.save)
/// }).
/// label / variant / loading / disabled can come from signals; disabled or loading suppresses click
/// response, loading shows spinner and hides icon.
/// Hover / pressed (held with pointer still inside) changes background; base_style / hover_style /
/// pressed_style override recipe (style reserved for root node attrs).
/// on_event is low-level generic event callback (not called when disabled, called when loading);
/// event_context is its context.
/// a11yLabel names the button for assistive tech without rendering text (icon-only buttons).
pub fn Button(args: anytype) ui.view.ComponentOf(__yix_Button) {
    return ui.view.component(__yix_Button, ui.reactive.props.coerce(ButtonProps, args));
}
pub const ButtonProps = struct {
    label: ui.Source([]const u8) = .{ .value = "" },
    variant: ui.Source(ButtonVariant) = .{ .value = .primary },
    size: ui.Source(ButtonSize) = .{ .value = .md },
    icon_only: ui.Source(bool) = .{ .value = false },
    loading: ui.Source(bool) = .{ .value = false },
    disabled: ui.Source(bool) = .{ .value = false },
    focus_ring: ui.Source(ui.FocusRingConfig) = .{ .value = .{} },
    block: ui.Source(bool) = .{ .value = false },
    on_click: ?ui.Handler(void) = null,
    icon: ui.Source(?u32) = .{ .value = null },
    icon_asset: ui.Source(?ui.SvgAsset) = .{ .value = null },
    icon_size: ui.Source(?f32) = .{ .value = null },
    icon_tint: ui.Source(?ui.Color) = .{ .value = null },
    on_event: ui.Source(?core.GenericEventCallback) = .{ .value = null },
    event_context: ui.Source(?*anyopaque) = .{ .value = null },
    base_style: ui.Source(core.StyleOverride) = .{ .value = .{} },
    hover_style: ui.Source(?core.StyleOverride) = .{ .value = null },
    pressed_style: ui.Source(?core.StyleOverride) = .{ .value = null },
    a11y_label: ui.Source([]const u8) = .{ .value = "" },
    /// Text children of the tag go into this parameter (ui.view.textChild)
    pub const text_child = "label";
};
fn __yix_Button(__yix_props: ButtonProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const label = __yix_props.label;
    const variant = __yix_props.variant;
    const size = __yix_props.size;
    const iconOnly = __yix_props.icon_only;
    const loading = __yix_props.loading;
    const disabled = __yix_props.disabled;
    const focusRing = __yix_props.focus_ring;
    const block = __yix_props.block;
    const onClick = __yix_props.on_click;
    const icon = __yix_props.icon;
    const iconAsset = __yix_props.icon_asset;
    const iconSize = __yix_props.icon_size;
    const iconTint = __yix_props.icon_tint;
    const onEvent = __yix_props.on_event;
    const eventContext = __yix_props.event_context;
    const baseStyle = __yix_props.base_style;
    const hoverStyle = __yix_props.hover_style;
    const pressedStyle = __yix_props.pressed_style;
    const a11yLabel = __yix_props.a11y_label;
    const has_svg = __yix_d1: {
        const __yix_T = @TypeOf(iconAsset.peek() != null);
        break :__yix_d1 try scope.derive(__yix_T, .{ .iconAsset = iconAsset, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.iconAsset.get() != null;
        } }.__yix_compute);
    };
    const has_texture = __yix_d2: {
        const __yix_T = @TypeOf(iconAsset.peek() == null and icon.peek() != null);
        break :__yix_d2 try scope.derive(__yix_T, .{ .iconAsset = iconAsset, .icon = icon, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.iconAsset.get() == null and __yix_ctx.icon.get() != null;
        } }.__yix_compute);
    };
    const icon_slot = __yix_d3: {
        const __yix_T = @TypeOf(iconAsset.peek() != null or icon.peek() != null or loading.peek());
        break :__yix_d3 try scope.derive(__yix_T, .{ .iconAsset = iconAsset, .icon = icon, .loading = loading, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.iconAsset.get() != null or __yix_ctx.icon.get() != null or __yix_ctx.loading.get();
        } }.__yix_compute);
    };
    const content_slot = __yix_d4: {
        const __yix_T = @TypeOf(label.peek().len != 0 or !icon_slot.peek());
        break :__yix_d4 try scope.derive(__yix_T, .{ .label = label, .icon_slot = icon_slot, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.label.get().len != 0 or !__yix_ctx.icon_slot.get();
        } }.__yix_compute);
    };
    const shape = __yix_d5: {
        const __yix_T = @TypeOf(S.Shape{ .variant = variant.peek(), .size = size.peek(), .icon_only = iconOnly.peek(), .leading_icon = !iconOnly.peek() and icon_slot.peek() and label.peek().len != 0, .disabled = disabled.peek(), .block = block.peek(), .style = baseStyle.peek(), .hover_style = hoverStyle.peek(), .pressed_style = pressedStyle.peek() });
        break :__yix_d5 try scope.derive(__yix_T, .{ .variant = variant, .size = size, .iconOnly = iconOnly, .icon_slot = icon_slot, .label = label, .disabled = disabled, .block = block, .baseStyle = baseStyle, .hoverStyle = hoverStyle, .pressedStyle = pressedStyle, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return S.Shape{ .variant = __yix_ctx.variant.get(), .size = __yix_ctx.size.get(), .icon_only = __yix_ctx.iconOnly.get(), .leading_icon = !__yix_ctx.iconOnly.get() and __yix_ctx.icon_slot.get() and __yix_ctx.label.get().len != 0, .disabled = __yix_ctx.disabled.get(), .block = __yix_ctx.block.get(), .style = __yix_ctx.baseStyle.get(), .hover_style = __yix_ctx.hoverStyle.get(), .pressed_style = __yix_ctx.pressedStyle.get() };
        } }.__yix_compute);
    };
    const look = __yix_d6: {
        const __yix_T = @TypeOf(S.Look{ .variant = variant.peek(), .size = size.peek(), .disabled = disabled.peek(), .style = baseStyle.peek(), .tint = iconTint.peek(), .icon_size = iconSize.peek() });
        break :__yix_d6 try scope.derive(__yix_T, .{ .variant = variant, .size = size, .disabled = disabled, .baseStyle = baseStyle, .iconTint = iconTint, .iconSize = iconSize, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return S.Look{ .variant = __yix_ctx.variant.get(), .size = __yix_ctx.size.get(), .disabled = __yix_ctx.disabled.get(), .style = __yix_ctx.baseStyle.get(), .tint = __yix_ctx.iconTint.get(), .icon_size = __yix_ctx.iconSize.get() };
        } }.__yix_compute);
    };
    const slot = __yix_d7: {
        const __yix_T = @TypeOf(S.Slot{ .size = size.peek(), .icon_only = iconOnly.peek() });
        break :__yix_d7 try scope.derive(__yix_T, .{ .size = size, .iconOnly = iconOnly, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return S.Slot{ .size = __yix_ctx.size.get(), .icon_only = __yix_ctx.iconOnly.get() };
        } }.__yix_compute);
    };
    const semantics = __yix_d8: {
        const __yix_T = @TypeOf(a11yOf(a11yLabel.peek(), label.peek(), disabled.peek(), loading.peek()));
        break :__yix_d8 try scope.derive(__yix_T, .{ .a11yLabel = a11yLabel, .label = label, .disabled = disabled, .loading = loading, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return a11yOf(__yix_ctx.a11yLabel.get(), __yix_ctx.label.get(), __yix_ctx.disabled.get(), __yix_ctx.loading.get());
        } }.__yix_compute);
    };
    const enabled = __yix_d9: {
        const __yix_T = @TypeOf(!disabled.peek());
        break :__yix_d9 try scope.derive(__yix_T, .{ .disabled = disabled, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return !__yix_ctx.disabled.get();
        } }.__yix_compute);
    };
    const idle = __yix_d10: {
        const __yix_T = @TypeOf(!loading.peek());
        break :__yix_d10 try scope.derive(__yix_T, .{ .loading = loading, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return !__yix_ctx.loading.get();
        } }.__yix_compute);
    };
    const events = __yix_d11: {
        const __yix_T = @TypeOf(if (disabled.peek()) null else onEvent.peek());
        break :__yix_d11 try scope.derive(__yix_T, .{ .disabled = disabled, .onEvent = onEvent, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.disabled.get()) null else __yix_ctx.onEvent.get();
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = .{ ui.view.statesBy(shape, S.root), S.fade }, .focusable = enabled, .focus_ring = focusRing, .a11y = semantics, .on_click = try ui.on.bind(scope, .{ .disabled = disabled, .loading = loading, .onClick = onClick, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.disabled.peek() and !__yix_ctx.loading.peek()) { ui.on.fire(__yix_ctx.onClick, .{}); }  } }.__yix_run), .on_event = events, .event_context = eventContext, }, .{
            ui.view.lazyIf(icon_slot, .{ .size = size, .loading = loading, .icon = icon, .iconAsset = iconAsset, .has_svg = has_svg, .has_texture = has_texture, .look = look, .slot = slot, .idle = idle, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.box(.{ .style = ui.view.styleBy(__yix_b1_0.slot, S.iconSlot), }, .{
                    ui.view.lazyIf(__yix_b1_0.has_svg, .{ .iconAsset = __yix_b1_0.iconAsset, .look = __yix_b1_0.look, .idle = __yix_b1_0.idle, }, struct { fn __yix_b(__yix_b2_0: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.icon(.{ .style = ui.view.styleBy(__yix_b2_0.look, S.icon), .tint = ui.view.tintBy(__yix_b2_0.look, S.iconTint), .visible = __yix_b2_0.idle, }, __yix_b2_0.iconAsset) }); } }.__yix_b, null),
                    ui.view.lazyIf(__yix_b1_0.has_texture, .{ .icon = __yix_b1_0.icon, .look = __yix_b1_0.look, .idle = __yix_b1_0.idle, }, struct { fn __yix_b(__yix_b3_0: anytype, __yix_bs3_0: *ui.Scope, __yix_bc3_0: *ui.Cx, __yix_bk3_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs3_0, __yix_bc3_0, __yix_bk3_0, .{ ui.view.image(.{ .style = ui.view.styleBy(__yix_b3_0.look, S.icon), .tint = ui.view.tintBy(__yix_b3_0.look, S.iconTint), .visible = __yix_b3_0.idle, }, __yix_b3_0.icon) }); } }.__yix_b, null),
                    ui.view.lazyIf(__yix_b1_0.loading, .{ .size = __yix_b1_0.size, .look = __yix_b1_0.look, }, struct { fn __yix_b(__yix_b4_0: anytype, __yix_bs4_0: *ui.Scope, __yix_bc4_0: *ui.Cx, __yix_bk4_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs4_0, __yix_bc4_0, __yix_bk4_0, .{ ui.view.box(.{ .style = ui.view.styleBy(__yix_b4_0.size, S.spinnerBox), }, .{
                            ui.view.canvas(.{ .style = S.spinner_canvas, }, ui.view.paint(.{ .data = __yix_b4_0.look, .animate = true, }, S.drawSpinner)),
                        }) }); } }.__yix_b, null),
                }) }); } }.__yix_b, null),
            ui.view.lazyIf(content_slot, .{ .label = label, .size = size, .look = look, }, struct { fn __yix_b(__yix_b5_0: anytype, __yix_bs5_0: *ui.Scope, __yix_bc5_0: *ui.Cx, __yix_bk5_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs5_0, __yix_bc5_0, __yix_bk5_0, .{ ui.view.row(.{ .style = ui.view.styleBy(__yix_b5_0.size, S.contentSlot), }, .{
                    ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(__yix_b5_0.label.peek().len != 0);
        break :__yix_d1 try __yix_bs5_0.derive(__yix_T, .{ .label = __yix_b5_0.label, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.label.get().len != 0;
        } }.__yix_compute);
    }, .{ .label = __yix_b5_0.label, .look = __yix_b5_0.look, }, struct { fn __yix_b(__yix_b6_0: anytype, __yix_bs6_0: *ui.Scope, __yix_bc6_0: *ui.Cx, __yix_bk6_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs6_0, __yix_bc6_0, __yix_bk6_0, .{ ui.view.text(.{ .style = ui.view.styleBy(__yix_b6_0.look, S.label), }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b6_0.label), ""), .{ __yix_b6_0.label, })) }); } }.__yix_b, null),
                }) }); } }.__yix_b, null),
        }));
    __yix_root.meta.ownership.meta.component_name = "Button";
    return __yix_root;

}

//# yix-map-data [[1337,1332]]

//# yix-map button.yix
