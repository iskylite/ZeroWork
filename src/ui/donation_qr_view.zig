//! Native black/white rectangles, sliced along terminal rows for scrolling,
//! clipping and replay. The four-module quiet zone never follows app themes.
const std = @import("std");
const ui = @import("ui");
const qr = @import("donation_qr.zig");
const styles = @import("builtin_records_styles.zig");

pub const View = struct {
    root: ?*ui.Node = null,
    slice: ?qr.Slice = null,
    height: f32 = 0,

    pub fn hide(self: *View) void {
        if (self.root) |root| root.setDisplay(.none);
    }

    pub fn update(self: *View, cx: *ui.Cx, parent: *ui.Node, slice: qr.Slice, x: f32, y: f32, height: f32) !void {
        if (self.root == null or self.slice == null or !std.meta.eql(self.slice.?, slice) or self.height != height) {
            if (self.root) |root| {
                cx.detachChild(parent, root);
                cx.destroyDetached(root);
                self.root = null;
            }
            const size = qr.extent * slice.scale;
            const root = try ui.boxStyled(cx, styles.donationQr, .{});
            errdefer cx.destroyDetached(root);
            root.meta.ownership.meta.test_id = "terminal.dots.qr";
            const bottom = @min(size, slice.offset + height);
            for (0..qr.modules) |module_y| {
                const top = @as(f32, @floatFromInt(module_y + qr.quiet_zone)) * slice.scale;
                const from = @max(top, slice.offset);
                const to = @min(top + slice.scale, bottom);
                if (to <= from) continue;
                var col: usize = 0;
                while (col < qr.modules) {
                    if (!qr.dark(col, module_y)) {
                        col += 1;
                        continue;
                    }
                    const start = col;
                    while (col < qr.modules and qr.dark(col, module_y)) : (col += 1) {}
                    const run = try ui.boxStyled(cx, styles.donationModule, .{});
                    errdefer cx.destroyDetached(run);
                    styles.place(cx, run, @as(f32, @floatFromInt(start + qr.quiet_zone)) * slice.scale, from - slice.offset, @as(f32, @floatFromInt(col - start)) * slice.scale, to - from);
                    try root.appendChild(cx.allocator, run);
                }
            }
            try parent.appendChild(cx.allocator, root);
            self.root = root;
            self.slice = slice;
            self.height = height;
        }
        const root = self.root.?;
        root.setDisplay(.flex);
        styles.place(cx, root, x, y, qr.extent * slice.scale, @min(height, qr.extent * slice.scale - slice.offset));
    }
};
