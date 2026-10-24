// GENERATED FILE, do not edit: generated from timeline.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Timeline view (with row key). Styling in styles.yss; public types and tests in
//! mod.zig.
const std = @import("std");
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");
const S = @import("_styles.yss.zig");
const TimelineStatus = mod.TimelineStatus;
const TimelineItem = mod.TimelineItem;

/// Row key: content + borrowed string address (row borrows title / description / time
/// slices: must rebuild when caller provides same content at different address; can't
/// keep row pointing to old string)
fn rowKey(it: TimelineItem) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(&[_]u8{@intFromEnum(it.status)});
    for ([_]?[]const u8{ it.title, it.description, it.time }) |field| {
        const f = field orelse "";
        h.update(&[_]u8{@intFromBool(field != null)});
        h.update(std.mem.asBytes(&f.len));
        h.update(f);
        h.update(std.mem.asBytes(&@intFromPtr(f.ptr)));
    }
    return h.final();
}

/// Timeline row: status dot + connector line (none on last) + title / description /
/// time. Status only via dot color, inaccessible to AT users, state explicitly: checked =
/// done, selected = in progress, disabled = not started.
pub fn TimelineRow(args: anytype) ui.view.ComponentOf(__yix_TimelineRow) {
    return ui.view.component(__yix_TimelineRow, ui.reactive.props.coerce(TimelineRowProps, args));
}
pub const TimelineRowProps = struct {
    title: ui.Source([]const u8) = .{ .value = "" },
    description: ui.Source(?[]const u8) = .{ .value = null },
    time: ui.Source(?[]const u8) = .{ .value = null },
    status: ui.Source(TimelineStatus) = .{ .value = .pending },
    is_last: ui.Source(bool) = .{ .value = false },
};
fn __yix_TimelineRow(__yix_props: TimelineRowProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const title = __yix_props.title;
    const description = __yix_props.description;
    const time = __yix_props.time;
    const status = __yix_props.status;
    const isLast = __yix_props.is_last;
    const has_line = __yix_d1: {
        const __yix_T = @TypeOf(!isLast.peek());
        break :__yix_d1 try scope.derive(__yix_T, .{ .isLast = isLast, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return !__yix_ctx.isLast.get();
        } }.__yix_compute);
    };
    const completed = __yix_d2: {
        const __yix_T = @TypeOf(status.peek() == .completed);
        break :__yix_d2 try scope.derive(__yix_T, .{ .status = status, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.status.get() == .completed;
        } }.__yix_compute);
    };
    const active = __yix_d3: {
        const __yix_T = @TypeOf(status.peek() == .active);
        break :__yix_d3 try scope.derive(__yix_T, .{ .status = status, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.status.get() == .active;
        } }.__yix_compute);
    };
    const pending = __yix_d4: {
        const __yix_T = @TypeOf(status.peek() == .pending);
        break :__yix_d4 try scope.derive(__yix_T, .{ .status = status, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.status.get() == .pending;
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = S.row, .a11y = .{ .role = .listitem, .label = title, .description = description, .value_text = time, .checked = completed, .selected = active, .disabled = pending }, }, .{
            ui.view.col(.{ .style = S.indicator, }, .{
                ui.view.box(.{ .style = S.Row.slot(.dot, .{ .status = status }), }, .{ }),
                ui.view.lazyIf(has_line, .{ .status = status, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.box(.{ .style = S.Row.slot(.line, .{ .status = __yix_b1_0.status }), }, .{ }) }); } }.__yix_b, null),
            }),
            ui.view.col(.{ .style = S.Content.of(.{ .last = isLast }), }, .{
                ui.view.text(.{ .style = S.Row.slot(.title, .{ .status = status }), }, ui.view.fmt(ui.view.yixFormat(@TypeOf(title), ""), .{ title, })),
                ui.view.lazyIfSome(description, .{ }, struct { fn __yix_b(__yix_b2_0: anytype, d: anytype, __yix_bs2_0: *ui.Scope, __yix_bc2_0: *ui.Cx, __yix_bk2_0: ui.view.Sink) anyerror!void { _ = __yix_b2_0; return ui.view.emit(__yix_bs2_0, __yix_bc2_0, __yix_bk2_0, .{ ui.view.text(.{ .style = S.description, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(d), ""), .{ d, })) }); } }.__yix_b, null),
                ui.view.lazyIfSome(time, .{ }, struct { fn __yix_b(__yix_b3_0: anytype, t: anytype, __yix_bs3_0: *ui.Scope, __yix_bc3_0: *ui.Cx, __yix_bk3_0: ui.view.Sink) anyerror!void { _ = __yix_b3_0; return ui.view.emit(__yix_bs3_0, __yix_bc3_0, __yix_bk3_0, .{ ui.view.text(.{ .style = S.time, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(t), ""), .{ t, })) }); } }.__yix_b, null),
            }),
        }));
    __yix_root.meta.ownership.meta.component_name = "TimelineRow";
    return __yix_root;

}

/// Timeline: `W.Timeline(.{ .items = activity })`. items can come from signals: reconcile
/// by row key (reuse rows where content and borrowed address unchanged; rebuild when
/// caller provides same content at different address, row doesn't point to freed old
/// string), last row by index (reused rows add/remove connectors as list grows/shrinks).
pub fn Timeline(args: anytype) ui.view.ComponentOf(__yix_Timeline) {
    return ui.view.component(__yix_Timeline, ui.reactive.props.coerce(TimelineProps, args));
}
pub const TimelineProps = struct {
    items: ui.Source([]const TimelineItem) = .{ .value = &.{} },
};
fn __yix_Timeline(__yix_props: TimelineProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const items = __yix_props.items;
    const __yix_root = try ui.view.render(scope, cx, ui.view.col(.{ .style = S.list, .a11y = .{ .role = .list, .label = "Timeline" }, }, .{
            __yix_e1: { const __yix_items_1 = items; break :__yix_e1 ui.view.eachWith(.{ .items = items, }, __yix_items_1, struct { fn __yix_k(item: ui.view.yixItem(@TypeOf(__yix_items_1))) u64 { return ui.view.keyOf(rowKey(item)); } }.__yix_k, struct { fn __yix_row(__yix_row_1: anytype, item: ui.Source(ui.view.yixItem(@TypeOf(__yix_items_1))), i: ui.Source(usize), __yix_scope_1: *ui.Scope, __yix_cx_1: *ui.Cx) anyerror!*ui.Node { return ui.view.render(__yix_scope_1, __yix_cx_1, TimelineRow(.{ .title = __yix_d1: {
        const __yix_T = if (ui.view.attrType(TimelineRow, "title")) |__yix_A| __yix_A else @TypeOf(item.peek().title);
        break :__yix_d1 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().title;
        } }.__yix_compute);
    }, .description = __yix_d2: {
        const __yix_T = if (ui.view.attrType(TimelineRow, "description")) |__yix_A| __yix_A else @TypeOf(item.peek().description);
        break :__yix_d2 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().description;
        } }.__yix_compute);
    }, .time = __yix_d3: {
        const __yix_T = if (ui.view.attrType(TimelineRow, "time")) |__yix_A| __yix_A else @TypeOf(item.peek().time);
        break :__yix_d3 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().time;
        } }.__yix_compute);
    }, .status = __yix_d4: {
        const __yix_T = if (ui.view.attrType(TimelineRow, "status")) |__yix_A| __yix_A else @TypeOf(item.peek().status);
        break :__yix_d4 try __yix_scope_1.derive(__yix_T, .{ .item = item, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.item.get().status;
        } }.__yix_compute);
    }, .is_last = __yix_d5: {
        const __yix_T = if (ui.view.attrType(TimelineRow, "is_last")) |__yix_A| __yix_A else @TypeOf(i.peek() + 1 == __yix_row_1.items.peek().len);
        break :__yix_d5 try __yix_scope_1.derive(__yix_T, .{ .i = i, .items = __yix_row_1.items, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.i.get() + 1 == __yix_ctx.items.get().len;
        } }.__yix_compute);
    }, })); } }.__yix_row); },
        }));
    __yix_root.meta.ownership.meta.component_name = "Timeline";
    return __yix_root;

}

//# yix-map-data [[1193,1188],[5491,2671]]

//# yix-map timeline.yix
