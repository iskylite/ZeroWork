//! Explicit presentation modes; hiding never cancels conversation work.
const std = @import("std");
pub const Mode = enum { hidden, preview, pinned };
pub const State = struct {
    mode: Mode = .hidden,
    hover_blocked: bool = false,
    leave_at: ?i64 = null,
    pub fn toggle(self: *State) void {
        if (self.mode == .pinned) self.hide() else {
            self.mode = .pinned;
            self.leave_at = null;
        }
    }
    pub fn pin(self: *State) void {
        self.mode = .pinned;
        self.leave_at = null;
    }
    pub fn hide(self: *State) void {
        self.mode = .hidden;
        self.hover_blocked = true;
        self.leave_at = null;
    }
    pub fn hover(self: *State, strip: bool, panel: bool, now: i64) void {
        if (!strip) self.hover_blocked = false;
        if (self.mode == .pinned) return;
        if (strip or panel) {
            self.leave_at = null;
            if (strip and !self.hover_blocked) self.mode = .preview;
        } else if (self.mode == .preview) {
            if (self.leave_at == null) self.leave_at = now;
            if (now - self.leave_at.? >= 180) self.mode = .hidden;
        }
    }
};
test "hover preview bridges the gap and expires; explicit activation stays pinned" {
    var s: State = .{};
    s.hover(true, false, 0);
    try std.testing.expectEqual(Mode.preview, s.mode);
    s.hover(false, false, 20);
    s.hover(false, true, 90);
    s.hover(false, false, 100);
    s.hover(false, false, 281);
    try std.testing.expectEqual(Mode.hidden, s.mode);
    s.toggle();
    s.hover(false, false, 1000);
    try std.testing.expectEqual(Mode.pinned, s.mode);
    s.toggle();
    s.hover(true, false, 1001);
    try std.testing.expectEqual(Mode.hidden, s.mode);
    s.hover(false, false, 1002);
    s.hover(true, false, 1003);
    s.pin();
    try std.testing.expectEqual(Mode.pinned, s.mode);
}
