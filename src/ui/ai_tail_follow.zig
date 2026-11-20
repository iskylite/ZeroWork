//! Follow new assistant output until the reader deliberately scrolls away.
const ui = @import("ui");
pub const Follow = struct {
    scroll: ui.widgets.ScrollAreaResult,
    following: bool = true,
    input_serial: u64 = 0,
    has_unread: bool = false,
    unread_eligible: bool = false,

    pub fn reset(self: *Follow) void {
        self.following = true;
        self.has_unread = false;
        self.unread_eligible = false;
        self.input_serial = self.scroll.state.input_serial;
    }

    /// Preserve the current position without replaying earlier scroll input.
    pub fn pause(self: *Follow) void {
        self.syncInput();
        self.following = false;
    }

    /// Record actual new output before its content is laid out.
    pub fn noteOutput(self: *Follow) void {
        self.syncInput();
        if (self.atBottom()) {
            self.has_unread = false;
            self.unread_eligible = false;
        } else if (self.unread_eligible) {
            self.has_unread = true;
        }
    }

    /// Return to the latest output and resume following subsequent output.
    pub fn jumpToLatest(self: *Follow) void {
        self.reset();
        self.update();
    }

    fn atBottom(self: *const Follow) bool {
        const state = self.scroll.state;
        return state.scroll_y >= state.maxScrollY() - 1;
    }

    fn syncInput(self: *Follow) void {
        const state = self.scroll.state;
        if (state.input_serial != self.input_serial) {
            self.following = self.atBottom();
            self.unread_eligible = !self.following;
            self.input_serial = state.input_serial;
            if (self.following) self.has_unread = false;
        }
    }

    /// Run after layout; never infer reader intent from content growth.
    pub fn update(self: *Follow) void {
        const state = self.scroll.state;
        self.syncInput();
        state.content_height = self.scroll.content.globalRect().h;
        state.viewport_height = self.scroll.container.globalRect().h;
        if (self.following and @abs(state.scroll_y - state.maxScrollY()) > 0.1) ui.widgets.setScrollY(state, self.scroll.content, state.maxScrollY());
        if (self.atBottom()) {
            self.has_unread = false;
            self.unread_eligible = false;
        }
    }
};

test "AI tail unread follows output and real scroll intent" {
    const std = @import("std");
    const a = std.testing.allocator;
    const Fixture = struct {
        cx: *ui.Cx,
        scope: *ui.Scope,
        follow: Follow,

        fn init(self: *@This()) !void {
            const cx = try ui.Cx.init(a, std.testing.io);
            const scope = try ui.Scope.init(a, null, cx.owner);
            cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
            cx.setViewport(600, 1000);
            const area = try ui.widgets.ScrollArea(.{ .height = 120, .direction = .vertical }).mount(scope, cx);
            area.container.setStyleInline(a, .{ .width = .fill(), .height = .{ .px = 120 }, .flex_shrink = 0 });
            area.content.setStyleInline(a, .{ .width = .fill(), .direction = .column });
            try cx.root.?.appendChild(a, area.container);
            self.* = .{ .cx = cx, .scope = scope, .follow = .{ .scroll = area } };
        }

        fn append(self: *@This(), height: f32) !void {
            const row = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = height }, .flex_shrink = 0 }, .{});
            try self.follow.scroll.content.appendChild(a, row);
        }

        fn settle(self: *@This()) void {
            for (0..3) |_| {
                self.cx.advanceFrameClock();
                self.cx.layout();
                self.follow.update();
                _ = self.cx.render();
            }
        }

        fn scroll(self: *@This(), delta: f32) void {
            const rect = self.follow.scroll.container.globalRect();
            self.cx.handleScroll(.{ .x = rect.x + 30, .y = rect.y + rect.h / 2, .dy = delta, .dx = 0 });
        }

        fn deinit(self: *@This()) void {
            self.scope.dispose();
            self.cx.deinit();
        }
    };

    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.append(600);
    f.settle();
    f.follow.noteOutput();
    try std.testing.expect(!f.follow.has_unread);

    f.scroll(80);
    f.settle();
    try std.testing.expect(!f.follow.following and !f.follow.has_unread);
    try f.append(20); // Layout changes alone are not new output.
    f.settle();
    try std.testing.expect(!f.follow.has_unread);
    f.follow.noteOutput();
    try std.testing.expect(f.follow.has_unread);

    // A larger viewport can reach the bottom without any scroll input.
    f.follow.scroll.container.setStyleInline(a, .{ .height = .{ .px = 900 } });
    f.settle();
    try std.testing.expect(!f.follow.has_unread);
    f.follow.scroll.container.setStyleInline(a, .{ .height = .{ .px = 120 } });
    f.settle();
    f.follow.noteOutput();
    try std.testing.expect(!f.follow.has_unread);

    // An output arriving before the next layout still sees the user's scroll.
    f.scroll(-40);
    f.follow.noteOutput();
    try std.testing.expect(f.follow.has_unread);
    f.follow.jumpToLatest();
    try std.testing.expect(f.follow.following and !f.follow.has_unread);
    try std.testing.expectApproxEqAbs(f.follow.scroll.state.maxScrollY(), f.follow.scroll.state.scroll_y, 0.01);
    f.settle();

    f.scroll(80);
    f.follow.pause();
    f.follow.noteOutput();
    try std.testing.expect(f.follow.has_unread);
    f.scroll(-10000);
    f.settle();
    try std.testing.expect(f.follow.following and !f.follow.has_unread);

    f.follow.pause();
    f.follow.noteOutput();
    try std.testing.expect(!f.follow.has_unread); // Pausing at bottom is not a scroll.
    f.follow.reset();
    f.settle();
    try std.testing.expect(f.follow.following and !f.follow.has_unread);
}
