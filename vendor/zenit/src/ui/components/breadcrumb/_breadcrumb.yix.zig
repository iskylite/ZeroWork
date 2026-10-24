// GENERATED FILE, do not edit: generated from breadcrumb.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Breadcrumb view. Styling in styles.yss; public types and tests in mod.zig.
const std = @import("std");
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");
const S = @import("_styles.yss.zig");
const BreadcrumbItem = mod.BreadcrumbItem;

/// Row key: content + borrowed string address (row borrows id / label slices:
/// must rebuild when other levels change or this level's string moves; can't keep
/// row pointing to old string)
fn crumbKey(it: BreadcrumbItem) u64 {
    var h = std.hash.Wyhash.init(0);
    for ([_][]const u8{ it.id, it.label }) |f| {
        h.update(std.mem.asBytes(&f.len));
        h.update(f);
        h.update(std.mem.asBytes(&@intFromPtr(f.ptr)));
    }
    return h.final();
}

/// Level: link or current page + separator (none after current). Current uses
/// listitem not unexposed: unfocusable no-role node dropped entirely by projection.
/// Separator is decoration, unexposed to AT (VoiceOver reads each "/").
fn Crumb(args: anytype) ui.view.ComponentOf(__yix_Crumb) {
    return ui.view.component(__yix_Crumb, ui.reactive.props.coerce(CrumbProps, args));
}
const CrumbProps = struct {
    label: ui.Source([]const u8),
    current: ui.Source(bool),
    separator: ui.Source([]const u8),
    on_pick: ?ui.Handler(void) = null,
};
fn __yix_Crumb(__yix_props: CrumbProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const label = __yix_props.label;
    const current = __yix_props.current;
    const separator = __yix_props.separator;
    const onPick = __yix_props.on_pick;
    const role = __yix_d1: {
        const __yix_T = @TypeOf(if (current.peek()) ui.A11yRole.listitem else ui.A11yRole.link);
        break :__yix_d1 try scope.derive(__yix_T, .{ .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return if (__yix_ctx.current.get()) ui.A11yRole.listitem else ui.A11yRole.link;
        } }.__yix_compute);
    };
    const linked = __yix_d2: {
        const __yix_T = @TypeOf(!current.peek());
        break :__yix_d2 try scope.derive(__yix_T, .{ .current = current, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return !__yix_ctx.current.get();
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = S.crumb, }, .{
            ui.view.text(.{ .style = S.Crumb.slot(.label, .{ .current = current }), .box = S.Crumb.slot(.link, .{ .current = current }), .a11y = .{ .role = role, .label = label, .selected = current }, .on_click = try ui.on.bind(scope, .{ .current = current, .onPick = onPick, .__yix_owner = scope.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); if (!__yix_ctx.current.peek()) { ui.on.fire(__yix_ctx.onPick, .{}); }  } }.__yix_run), }, ui.view.fmt(ui.view.yixFormat(@TypeOf(label), ""), .{ label, })),
            ui.view.lazyIf(linked, .{ .separator = separator, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ .style = S.separator, .a11y = .{ .hidden = true }, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b1_0.separator), ""), .{ __yix_b1_0.separator, })) }); } }.__yix_b, null),
        }));
    __yix_root.meta.ownership.meta.component_name = "Crumb";
    return __yix_root;

}

/// Breadcrumb: current page position in hierarchy; last level is current (not
/// clickable), clicking earlier levels reports their id.
/// `W.Breadcrumb(.{ .items = path, .on_select = cx.on(S, s, S.go) })`
pub fn Breadcrumb(args: anytype) ui.view.ComponentOf(__yix_Breadcrumb) {
    return ui.view.component(__yix_Breadcrumb, ui.reactive.props.coerce(BreadcrumbProps, args));
}
pub const BreadcrumbProps = struct {
    items: ui.Source([]const BreadcrumbItem) = .{ .value = &.{} },
    separator: ui.Source([]const u8) = .{ .value = "/" },
    on_select: ?ui.Handler([]const u8) = null,
};
fn __yix_Breadcrumb(__yix_props: BreadcrumbProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const items = __yix_props.items;
    const separator = __yix_props.separator;
    const onSelect = __yix_props.on_select;
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = S.root, .a11y = .{ .role = .navigation, .label = "Breadcrumb" }, }, .{
            __yix_e1: { const __yix_items_1 = items; break :__yix_e1 ui.view.eachWith(.{ .items = items, .separator = separator, .onSelect = onSelect, }, __yix_items_1, struct { fn __yix_k(item: ui.view.yixItem(@TypeOf(__yix_items_1))) u64 { return ui.view.keyOf(crumbKey(item)); } }.__yix_k, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), i: ui.Source(usize), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, Crumb(.{ .label = __yix_d1: {
        const __yix_T = if (ui.view.attrType(Crumb, "label")) |__yix_A| __yix_A else @TypeOf(item.peek().label);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().label;
        } }.__yix_compute);
    }, .current = __yix_d2: {
        const __yix_T = if (ui.view.attrType(Crumb, "current")) |__yix_A| __yix_A else @TypeOf(i.peek() + 1 == __yix_row_1.items.peek().len);
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .i = i, .items = __yix_row_1.items, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.i.get() + 1 == __yix_ctx.items.get().len;
        } }.__yix_compute);
    }, .separator = __yix_row_1.separator, .on_pick = if (comptime ui.view.isEventProp(Crumb, "on_pick")) try ui.on.bindAny(__yix_scope_1, .{ .onSelect = __yix_row_1.onSelect, .item = item, .__yix_owner = __yix_scope_1.owner, }, struct { fn __yix_run(__yix_ctx: anytype) void { __yix_ctx.__yix_owner.beginBatch(); defer __yix_ctx.__yix_owner.endBatch(); ui.on.fire(__yix_ctx.onSelect, .{__yix_ctx.item.peek().id});  } }.__yix_run) else __yix_d3: {
        const __yix_T = if (ui.view.attrType(Crumb, "on_pick")) |__yix_A| __yix_A else @TypeOf(__yix_row_1.onSelect(item.peek().id));
        break :__yix_d3 try __yix_scope_1.derive(__yix_T, .{ .onSelect = __yix_row_1.onSelect, .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.onSelect(__yix_ctx.item.get().id);
        } }.__yix_compute);
    }, })); } }.__yix_row); },
        }));
    __yix_root.meta.ownership.meta.component_name = "Breadcrumb";
    return __yix_root;

}

//# yix-map-data [[963,958],[3652,1871]]

//# yix-map breadcrumb.yix
