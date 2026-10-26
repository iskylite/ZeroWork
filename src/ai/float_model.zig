const std = @import("std");
const status = @import("status.zig");
const error_feedback = @import("error_feedback.zig");

pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };
pub const minimum_width: f32 = 520;
pub const minimum_height: f32 = 354;
pub const Edge = enum {
    n,
    s,
    w,
    e,
    nw,
    ne,
    sw,
    se,

    pub fn west(self: Edge) bool {
        return self == .w or self == .nw or self == .sw;
    }
    pub fn east(self: Edge) bool {
        return self == .e or self == .ne or self == .se;
    }
    pub fn north(self: Edge) bool {
        return self == .n or self == .nw or self == .ne;
    }
    pub fn south(self: Edge) bool {
        return self == .s or self == .sw or self == .se;
    }
};
pub const Geometry = struct { desired: ?Rect, clamped: ?Rect, restore: ?Rect };

pub fn safeBounds(pane: Rect, window: Rect) Rect {
    const left = @max(pane.x, window.x) + 8;
    const top = @max(pane.y, window.y) + 8;
    return .{ .x = left, .y = top, .width = @max(0, @min(pane.x + pane.width, window.x + window.width) - 8 - left), .height = @max(0, @min(pane.y + pane.height, window.y + window.height) - 8 - top) };
}

pub fn clampRect(value: Rect, pane: Rect, window: Rect) Rect {
    const bounds = safeBounds(pane, window);
    const width = std.math.clamp(value.width, @min(minimum_width, bounds.width), bounds.width);
    const height = std.math.clamp(value.height, @min(minimum_height, bounds.height), bounds.height);
    return .{ .x = std.math.clamp(value.x, bounds.x, bounds.x + bounds.width - width), .y = std.math.clamp(value.y, bounds.y, bounds.y + bounds.height - height), .width = width, .height = height };
}

pub fn resized(start: Rect, edge: Edge, dx: f32, dy: f32, pane: Rect, window: Rect) Rect {
    const bounds = safeBounds(pane, window);
    const base = clampRect(start, pane, window);
    var left = base.x;
    var right = base.x + base.width;
    var top = base.y;
    var bottom = base.y + base.height;
    const min_width = @min(minimum_width, bounds.width);
    const min_height = @min(minimum_height, bounds.height);
    if (edge.west()) left = std.math.clamp(left + dx, bounds.x, right - min_width);
    if (edge.east()) right = std.math.clamp(right + dx, left + min_width, bounds.x + bounds.width);
    if (edge.north()) top = std.math.clamp(top + dy, bounds.y, bottom - min_height);
    if (edge.south()) bottom = std.math.clamp(bottom + dy, top + min_height, bounds.y + bounds.height);
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

pub const Model = struct {
    visible: bool = false,
    expanded: bool = false,
    maximized: bool = false,
    desired: ?Rect = null,
    clamped: ?Rect = null,
    restore: ?Rect = null,
    status: status.Status = .{},
    feedback: error_feedback.Feedback = .{},
    prompt: []const u8 = "",
    card_count: usize = 0,
    anchor: enum { pane_top_center, status_chip } = .pane_top_center,

    pub fn toggle(self: *Model) void {
        self.visible = !self.visible;
    }
    pub fn setExpanded(self: *Model, expanded: bool) void {
        self.expanded = expanded;
    }
    pub fn setPrompt(self: *Model, prompt: []const u8) void {
        self.prompt = prompt;
    }

    pub fn setCardCount(self: *Model, count: usize) void {
        self.card_count = count;
    }
    pub fn rect(self: Model, pane: Rect, window: Rect) Rect {
        const bounds = safeBounds(pane, window);
        if (self.maximized) return bounds;
        if (self.expanded) if (self.desired) |value| return clampRect(value, pane, window);
        const width: f32 = @min(if (self.expanded) @as(f32, 600) else 100, bounds.width);
        const height: f32 = @min(if (self.expanded) @as(f32, 456) else 14, bounds.height);
        const x = std.math.clamp(pane.x + (pane.width - width) / 2, bounds.x, bounds.x + bounds.width - width);
        const y = std.math.clamp(pane.y + 14, bounds.y, bounds.y + bounds.height - height);
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    /// Bounds changes only re-clamp; they never erase the owner's requested rectangle.
    pub fn updateBounds(self: *Model, pane: Rect, window: Rect) void {
        self.clamped = self.rect(pane, window);
    }
    pub fn geometry(self: Model) Geometry {
        return .{ .desired = self.desired, .clamped = self.clamped, .restore = self.restore };
    }
    pub fn restoreGeometry(self: *Model, value: Geometry) void {
        self.desired = value.desired;
        self.clamped = value.clamped;
        self.restore = value.restore;
    }
    pub fn setRectangle(self: *Model, value: Rect, pane: Rect, window: Rect) void {
        self.desired = clampRect(value, pane, window);
        self.updateBounds(pane, window);
    }
    pub fn resetPosition(self: *Model, pane: Rect, window: Rect) void {
        if (self.maximized) return;
        var value = Rect{ .x = 0, .y = 0, .width = 600, .height = 456 };
        value.x = pane.x + (pane.width - value.width) / 2;
        value.y = pane.y + 14;
        self.setRectangle(value, pane, window);
    }
    pub fn toggleMaximized(self: *Model, pane: Rect, window: Rect) void {
        if (self.maximized) {
            self.desired = self.restore orelse self.desired;
            self.restore = null;
        } else self.restore = self.desired orelse self.rect(pane, window);
        self.maximized = !self.maximized;
        self.updateBounds(pane, window);
    }

    pub fn showError(self: *Model, info: @import("error.zig").Info) void {
        self.feedback.show(info);
        self.status.state = .failed;
        self.status.message = info.message;
        self.visible = true;
    }

    pub fn retryVisible(self: Model) bool {
        return self.feedback.retry_available and self.feedback.info != null;
    }

    pub fn beginRetry(self: *Model) bool {
        if (!self.retryVisible()) return false;
        self.status.state = .thinking;
        self.status.message = "Retrying";
        self.feedback.retry_available = false;
        return true;
    }

    pub fn markSuccess(self: *Model, message: []const u8) void {
        self.feedback.dismiss();
        self.status.state = .success;
        self.status.message = message;
    }

    pub fn dismissError(self: *Model) void {
        self.feedback.dismiss();
        self.status.state = .idle;
        self.status.message = "";
    }

    pub fn tick(self: *Model) void {
        status.nextPulse(&self.status);
    }
};

test "AI maximize and restore preserve the default owner pane rectangle" {
    var model: Model = .{ .expanded = true };
    const pane: Rect = .{ .x = 240, .y = 62, .width = 1190, .height = 790 };
    const window: Rect = .{ .x = 0, .y = 0, .width = 1440, .height = 900 };
    const original = model.rect(pane, window);
    model.maximized = true;
    try std.testing.expectEqualDeep(Rect{ .x = 248, .y = 70, .width = 1174, .height = 774 }, model.rect(pane, window));
    model.maximized = false;
    try std.testing.expectEqualDeep(original, model.rect(pane, window));
}

test "AI default float centers below its own pane strip and clamps within the pane" {
    const model: Model = .{ .expanded = true };
    const window: Rect = .{ .x = 0, .y = 0, .width = 1440, .height = 900 };
    const pane: Rect = .{ .x = 240, .y = 62, .width = 1190, .height = 790 };
    const normal = model.rect(pane, window);
    try std.testing.expectEqualDeep(Rect{ .x = 535, .y = 76, .width = 600, .height = 456 }, normal);
    const small: Rect = .{ .x = 240, .y = 62, .width = 400, .height = 250 };
    const clamped = model.rect(small, window);
    try std.testing.expect(clamped.x >= small.x + 8 and clamped.y >= small.y + 8);
    try std.testing.expect(clamped.x + clamped.width <= small.x + small.width - 8);
    try std.testing.expect(clamped.y + clamped.height <= small.y + small.height - 8);
}

test "AI float model toggles and pulses status" {
    var model: Model = .{};
    model.toggle();
    try std.testing.expect(model.visible);
    model.status.state = .thinking;
    model.tick();
    try std.testing.expectEqual(@as(u8, 1), model.status.pulse);
    model.setExpanded(true);
    model.setCardCount(2);
    try std.testing.expect(model.expanded);
    try std.testing.expect(model.visible);
    try std.testing.expectEqual(@as(usize, 2), model.card_count);
    model.showError(.{ .kind = .network, .message = "offline" });
    try std.testing.expect(model.feedback.retry_available);
    try std.testing.expect(model.beginRetry());
    try std.testing.expectEqual(status.State.thinking, model.status.state);
    try std.testing.expect(!model.retryVisible());
    model.dismissError();
    try std.testing.expectEqual(status.State.idle, model.status.state);
    try std.testing.expect(!model.retryVisible());
    model.markSuccess("Done");
    model.setCardCount(0);
    try std.testing.expect(model.visible);
    model.toggle();
    try std.testing.expect(!model.visible);
}

test "retained response cards do not reopen a user collapsed AI panel" {
    var model: Model = .{};
    model.toggle();
    model.setCardCount(2);
    model.markSuccess("Done");
    model.toggle();
    model.setCardCount(2);
    try std.testing.expect(!model.visible);
    try std.testing.expectEqual(@as(usize, 2), model.card_count);
}
