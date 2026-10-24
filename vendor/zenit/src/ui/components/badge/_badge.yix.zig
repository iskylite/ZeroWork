// GENERATED FILE, do not edit: generated from badge.yix; after editing the source run `zig build gen-yix` (yix-lsp regenerates it on save).
//! Badge / StatusBadge view. Styles in styles.yss, shared types and tests in mod.zig.
const std = @import("std");
const ui = @import("../../ui.zig");
const mod = @import("mod.zig");
const S = @import("_styles.yss.zig");
const BadgeStatus = mod.BadgeStatus;
const BadgeSize = mod.BadgeSize;

/// Badge text display: shows label if non-empty, else shows count if present ("N+" if exceeds
/// max_count); dot mode doesn't display.
/// Value type (count written to inline buffer, text borrows slice from source), can go directly in
/// computed and interpolate.
const Label = struct {
    text: []const u8 = "",
    digits: [24]u8 = undefined,
    digits_len: usize = 0,

    pub fn format(self: Label, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(if (self.text.len > 0) self.text else self.digits[0..self.digits_len]);
    }
};

fn labelOf(text: []const u8, count: ?u32, max_count: u32, dot: bool) Label {
    if (dot) return .{};
    if (text.len > 0) return .{ .text = text };
    const c = count orelse return .{};
    var out: Label = .{};
    const s = if (c > max_count)
        std.fmt.bufPrint(&out.digits, "{d}+", .{max_count}) catch unreachable
    else
        std.fmt.bufPrint(&out.digits, "{d}", .{c}) catch unreachable;
    out.digits_len = s.len;
    return out;
}

/// Badge: status (info / success / warning / error) x size (sm / md), switchable to 8x8 dot.
/// Root node carries text (text node + capsule box style), test_id lookup gets the text-bearing
/// node.
/// W.Badge(.{ .count = unread, .dot = ui.map(unread, isZero) })
pub fn Badge(args: anytype) ui.view.ComponentOf(__yix_Badge) {
    return ui.view.component(__yix_Badge, ui.reactive.props.coerce(BadgeProps, args));
}
pub const BadgeProps = struct {
    label: ui.Source([]const u8) = .{ .value = "" },
    count: ui.Source(?u32) = .{ .value = null },
    max_count: ui.Source(u32) = .{ .value = 99 },
    status: ui.Source(BadgeStatus) = .{ .value = .info },
    size: ui.Source(BadgeSize) = .{ .value = .md },
    dot: ui.Source(bool) = .{ .value = false },
    /// Text children of the tag go into this parameter (ui.view.textChild)
    pub const text_child = "label";
};
fn __yix_Badge(__yix_props: BadgeProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const label = __yix_props.label;
    const count = __yix_props.count;
    const maxCount = __yix_props.max_count;
    const status = __yix_props.status;
    const size = __yix_props.size;
    const dot = __yix_props.dot;
    const shown = __yix_d1: {
        const __yix_T = @TypeOf(labelOf(label.peek(), count.peek(), maxCount.peek(), dot.peek()));
        break :__yix_d1 try scope.derive(__yix_T, .{ .label = label, .count = count, .maxCount = maxCount, .dot = dot, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return labelOf(__yix_ctx.label.get(), __yix_ctx.count.get(), __yix_ctx.maxCount.get(), __yix_ctx.dot.get());
        } }.__yix_compute);
    };
    const __yix_root = try ui.view.render(scope, cx, ui.view.text(.{ .style = S.Badge.slot(.label, .{ .status = status, .size = size }), .box = S.Badge.slot(.root, .{ .status = status, .size = size, .dot = dot }), }, ui.view.fmt(ui.view.yixFormat(@TypeOf(shown), ""), .{ shown, })));
    __yix_root.meta.ownership.meta.component_name = "Badge";
    return __yix_root;

}

/// Status badge: status dot + label (label doesn't occupy space when empty).
pub fn StatusBadge(args: anytype) ui.view.ComponentOf(__yix_StatusBadge) {
    return ui.view.component(__yix_StatusBadge, ui.reactive.props.coerce(StatusBadgeProps, args));
}
pub const StatusBadgeProps = struct {
    status: ui.Source(BadgeStatus) = .{ .value = .info },
    label: ui.Source([]const u8) = .{ .value = "" },
    /// Text children of the tag go into this parameter (ui.view.textChild)
    pub const text_child = "label";
};
fn __yix_StatusBadge(__yix_props: StatusBadgeProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    const status = __yix_props.status;
    const label = __yix_props.label;
    const __yix_root = try ui.view.render(scope, cx, ui.view.row(.{ .style = S.status_row, }, .{
            ui.view.box(.{ .style = S.StatusDot.of(.{ .status = status }), }, .{ }),
            ui.view.lazyIf(__yix_d1: {
        const __yix_T = @TypeOf(label.peek().len != 0);
        break :__yix_d1 try scope.derive(__yix_T, .{ .label = label, }, struct { fn __yix_compute(__yix_ctx: anytype) __yix_T {
            return __yix_ctx.label.get().len != 0;
        } }.__yix_compute);
    }, .{ .label = label, }, struct { fn __yix_b(__yix_b1_0: anytype, __yix_bs1_0: *ui.Scope, __yix_bc1_0: *ui.Cx, __yix_bk1_0: ui.view.Sink) anyerror!void { return ui.view.emit(__yix_bs1_0, __yix_bc1_0, __yix_bk1_0, .{ ui.view.text(.{ .style = S.status_label, }, ui.view.fmt(ui.view.yixFormat(@TypeOf(__yix_b1_0.label), ""), .{ __yix_b1_0.label, })) }); } }.__yix_b, null),
        }));
    __yix_root.meta.ownership.meta.component_name = "StatusBadge";
    return __yix_root;

}

//# yix-map-data [[1573,1568],[3410,2054]]

//# yix-map badge.yix
