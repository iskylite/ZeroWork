//! Explicit presentation modes; hiding never cancels conversation work.
const std = @import("std");
pub const Mode = enum { hidden, preview, pinned };
pub const enter_delay_ms = 140;
pub const leave_delay_ms = 220;
pub const State = struct {
    mode: Mode = .hidden,
    hover_blocked: bool = false,
    leave_at: ?i64 = null,
    enter_at: ?i64 = null,
    pub fn toggle(self: *State) void {
        if (self.mode == .pinned) self.hide() else {
            self.mode = .pinned;
            self.leave_at = null;
            self.enter_at = null;
        }
    }
    pub fn pin(self: *State) void {
        self.mode = .pinned;
        self.leave_at = null;
        self.enter_at = null;
    }
    pub fn hide(self: *State) void {
        self.mode = .hidden;
        self.hover_blocked = true;
        self.leave_at = null;
        self.enter_at = null;
    }
    pub fn hover(self: *State, strip: bool, panel: bool, now: i64) void {
        if (!strip) {
            self.hover_blocked = false;
            self.enter_at = null;
        }
        if (self.mode == .pinned) return;
        if (strip or panel) {
            self.leave_at = null;
            if (strip and !self.hover_blocked and self.mode == .hidden) {
                if (self.enter_at == null) self.enter_at = now;
                if (now - self.enter_at.? >= enter_delay_ms) {
                    self.mode = .preview;
                    self.enter_at = null;
                }
            }
        } else if (self.mode == .preview) {
            if (self.leave_at == null) self.leave_at = now;
            if (now - self.leave_at.? >= leave_delay_ms) self.mode = .hidden;
        }
    }
};
/// Reverses from the current opacity instead of restarting when hover changes.
pub const Reveal = struct {
    target: bool = false,
    from: f32 = 0,
    started_at: i64 = 0,
    pub const Frame = struct { opacity: f32, moving: bool };
    fn sample(self: Reveal, now: i64) Frame {
        const duration: f32 = if (self.target) 180 else 130;
        const t = std.math.clamp(@as(f32, @floatFromInt(now - self.started_at)) / duration, 0, 1);
        const eased = 1 - (1 - t) * (1 - t) * (1 - t);
        const end: f32 = if (self.target) 1 else 0;
        return .{ .opacity = self.from + (end - self.from) * eased, .moving = t < 1 and self.from != end };
    }
    pub fn update(self: *Reveal, visible: bool, now: i64, reduced_motion: bool) Frame {
        const current = self.sample(now);
        if (self.target != visible) {
            self.from = current.opacity;
            self.target = visible;
            self.started_at = now;
        }
        if (reduced_motion) {
            self.from = if (visible) 1 else 0;
            return .{ .opacity = self.from, .moving = false };
        }
        return self.sample(now);
    }
};
test "hover preview bridges the gap and expires; explicit activation stays pinned" {
    var s: State = .{};
    s.hover(true, false, 0);
    try std.testing.expectEqual(Mode.hidden, s.mode);
    s.hover(true, false, 140);
    try std.testing.expectEqual(Mode.preview, s.mode);
    s.hover(false, false, 160);
    s.hover(false, true, 230);
    s.hover(false, false, 240);
    s.hover(false, false, 461);
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

test "hover flyby stays hidden and reveal reverses continuously" {
    var s: State = .{};
    s.hover(true, false, 0);
    s.hover(false, false, 80);
    s.hover(true, false, 200);
    s.hover(true, false, 300);
    try std.testing.expectEqual(Mode.hidden, s.mode);
    s.hover(true, false, 340);
    try std.testing.expectEqual(Mode.preview, s.mode);
    var reveal: Reveal = .{};
    _ = reveal.update(true, 1000, false);
    const entering = reveal.update(true, 1090, false);
    const reversing = reveal.update(false, 1090, false);
    try std.testing.expect(entering.opacity > 0 and entering.opacity < 1);
    try std.testing.expectEqual(entering.opacity, reversing.opacity);
    const fading = reveal.update(false, 1130, false);
    try std.testing.expect(fading.opacity < entering.opacity);
    try std.testing.expectEqual(fading.opacity, reveal.update(true, 1130, false).opacity);
    try std.testing.expectEqual(@as(f32, 1), reveal.update(true, 1400, false).opacity);
    try std.testing.expectEqual(@as(f32, 0), reveal.update(false, 1401, true).opacity);
}
