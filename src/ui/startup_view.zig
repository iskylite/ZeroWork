const std = @import("std");
const ui = @import("ui");
const styles = @import("startup_styles.zig");
const theme = @import("app_theme.zig");
const timing = @import("startup_transition.zig");

pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    logo: *ui.Node,
    name: *ui.Node,
    status: *ui.Node,
    transition: timing.Transition = .{},

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope) !*View {
        const root = try ui.box(cx, styles.root(), .{});
        root.meta.ownership.meta.test_id = "startup.overlay";
        const identity = try ui.box(cx, styles.identity(), .{});
        identity.meta.ownership.meta.test_id = "startup.identity";
        try root.appendChild(cx.allocator, identity);
        const logo = try ui.box(cx, styles.logo(), .{});
        logo.meta.ownership.meta.test_id = "startup.logo";
        try identity.appendChild(cx.allocator, logo);
        const name = try ui.text(cx, "ZeroWork", styles.name());
        try identity.appendChild(cx.allocator, name);
        const status = try ui.text(cx, "正在准备工作区…", styles.status());
        status.setStyleInline(cx.allocator, .{ .margin = .{ .top = 8 } });
        try identity.appendChild(cx.allocator, status);
        return scope.createState(View, .{ .cx = cx, .root = root, .logo = logo, .name = name, .status = status });
    }

    /// Called after the background has been published, at the safe layout hook.
    pub fn update(self: *View, settled: bool) void {
        if (self.transition.finished) return;
        const now: u64 = @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
        const opacity = self.transition.sample(now, settled, self.cx.reduced_motion);
        if (opacity == 0) {
            self.root.setDisplay(.none);
        } else {
            self.root.setStyleInline(self.cx.allocator, .{ .opacity = opacity, .background = theme.baseColors().app.withAlpha(255) });
            self.name.setTextColor(theme.baseColors().fg_1);
            self.status.setTextColor(theme.baseColors().fg_2);
            const elapsed: f32 = @floatFromInt(now -| self.transition.started_ms.?);
            const pulse: f32 = if (self.cx.reduced_motion) 1 else 0.86 - 0.14 * @cos(elapsed * (2 * std.math.pi / 1600.0));
            self.logo.setStyleInline(self.cx.allocator, .{ .opacity = pulse });
            self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
        }
    }
};
