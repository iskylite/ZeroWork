// GENERATED FILE, do not edit: generated from menu.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Menu's row view: divider and menu item. Popover, keyboard nav and selection pipeline in mod.zig,
//! styles in styles.yss.
const ui = @import("../../ui.zig");
const S = @import("_styles.yss.zig");

/// Divider: vertical padding, line itself 1px
pub fn MenuSeparator(args: anytype) ui.view.ComponentOf(__yix_MenuSeparator) {
    return ui.view.component(__yix_MenuSeparator, ui.reactive.props.coerce(MenuSeparatorProps, args));
}
pub const MenuSeparatorProps = struct {
};
fn __yix_MenuSeparator(__yix_props: MenuSeparatorProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    _ = __yix_props;
    const __yix_root = try ui.view.render(scope, cx, ui.view.box(.{ .style = S.separator, .a11y = .{ .role = .separator }, }, .{
            ui.view.box(.{ .style = S.separator_line, }, .{ }),
        }));
    __yix_root.meta.ownership.meta.component_name = "MenuSeparator";
    return __yix_root;

}

/// One menu item. highlighted is menu's current virtual highlight index (keyboard move, pointer
/// enter both write it), when == index shows highlight.
/// Report disabled items as-is (AT users otherwise retry activating unresponsive item), shortcut
/// goes to a11y description.
pub fn MenuEntry(args: anytype) ui.view.ComponentOf(__yix_MenuEntry) {
    return ui.view.component(__yix_MenuEntry, ui.reactive.props.coerce(MenuEntryProps, args));
}
pub const MenuEntryProps = struct {
    label: ui.Source([]const u8),
    index: ui.Source(usize),
    highlighted: ui.Source(usize),
    danger: ui.Source(bool) = .{ .value = false },
    disabled: ui.Source(bool) = .{ .value = false },
    shortcut: ui.Source(?[]const u8) = .{ .value = null },
    icon_asset: ui.Source(?ui.SvgAsset) = .{ .value = null },
    on_pick: ui.Handler(usize),
    on_enter: ui.Handler(usize),
};
fn __yix_MenuEntry(__yix_props: MenuEntryProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const label = __yix_props.label;
    const index = __yix_props.index;
    const highlighted = __yix_props.highlighted;
    const danger = __yix_props.danger;
    const disabled = __yix_props.disabled;
    const shortcut = __yix_props.shortcut;
    const iconAsset = __yix_props.icon_asset;
    const onPick = __yix_props.on_pick;
    const onEnter = __yix_props.on_enter;
    const lit = __yix_d1: {
        const __yix_T = @TypeOf(highlighted.peek() == index.peek());
        break :__yix_d1 try scope.derive(__yix_T, .{ .highlighted = highlighted, .index = index, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.highlighted.get() == __yix_ctx.index.get();
        } }.__yix_compute);
    };
    const p = ui.view.slotParts(S.MenuRow, .{ .danger = danger, .disabled = disabled, .lit = lit });
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = p.root, .a11y = .{ .role = .menuitem, .label = label, .disabled = disabled, .description = shortcut }, .on_click = try ui.on.bind(scope, .{ .disabled = disabled, .onPick = onPick, .index = index, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.disabled.peek()) { ui.on.fire(__yix_ctx.onPick, .{__yix_ctx.index.peek()}); }  } }.__yix_run), .on_hover = try ui.on.bind(scope, .{ .disabled = disabled, .onEnter = onEnter, .index = index, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.disabled.peek()) { ui.on.fire(__yix_ctx.onEnter, .{__yix_ctx.index.peek()}); }  } }.__yix_run), }, .{
            ui.view.row(.{ .style = S.item_left, }, .{
                ui.view.lazyIfSome(iconAsset, .{ .p = p, }, struct { fn __yix_b(__yix_b1_0: anytype, asset: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.icon(.{ .style = __yix_b1_0.p.icon, }, asset) }); } }.__yix_b, null),
                ui.view.text(.{ .style = p.label, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(label), ""), .{ label, })),
            }),
            ui.view.lazyIfSome(shortcut, .{ }, struct { fn __yix_b(__yix_b2_0: anytype, keys: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { _ = __yix_b2_0; return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.text(.{ .style = S.shortcut, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(keys), ""), .{ keys, })) }); } }.__yix_b, null),
        }));
    __yix_root.meta.ownership.meta.component_name = "MenuEntry";
    return __yix_root;

}

//# yix-map-data [[253,248],[1191,670]]

//# yix-map menu.yix
