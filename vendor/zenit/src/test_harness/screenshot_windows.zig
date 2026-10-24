//! UI-thread-only window instance registry. Tokens never expose native handles as identity.
const std = @import("std");
const JsonWriter = @import("json_writer.zig").JsonWriter;
pub const Capture = *const fn (*anyopaque, []const u8) bool;
pub const Closing = *const fn (*anyopaque) bool;
pub const CaptureError = error{ InvalidWindowId, WindowNotFound, WindowClosing, NoBoundTarget, CaptureUnsupported, CaptureFailed };
pub const Registry = struct {
    const Entry = struct {
        owner: *anyopaque,
        native_id: u64,
        id: [80]u8 = undefined,
        id_len: usize = 0,
        capture: ?Capture,
        closing: Closing,
        fn token(self: *const Entry) []const u8 {
            return self.id[0..self.id_len];
        }
    };
    entries: [256]?Entry = @splat(null),
    session: ?u128 = null,
    serial: u64 = 0,
    bound: ?*anyopaque = null,

    pub fn register(self: *Registry, session: u128, owner: *anyopaque, native_id: u64, capture_fn: ?Capture, closing: Closing) void {
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            if (entry.owner == owner) return;
        };
        if (self.session == null) self.session = session;
        self.serial = std.math.add(u64, self.serial, 1) catch @panic("harness window identity exhausted");
        for (&self.entries) |*slot| if (slot.* == null) {
            var entry: Entry = .{ .owner = owner, .native_id = native_id, .capture = capture_fn, .closing = closing };
            entry.id_len = (std.fmt.bufPrint(&entry.id, "{x}-{x}", .{ self.session.?, self.serial }) catch unreachable).len;
            slot.* = entry;
            return;
        };
        @panic("harness window registry capacity exhausted");
    }
    pub fn unregister(self: *Registry, owner: *anyopaque) void {
        for (&self.entries) |*slot| if (slot.*) |entry| {
            if (entry.owner == owner) slot.* = null;
        };
        if (self.bound == owner) self.bound = null;
    }
    pub fn validToken(token: []const u8) bool {
        var parts = std.mem.splitScalar(u8, token, '-');
        const session = parts.next() orelse return false;
        const serial = parts.next() orelse return false;
        if (session.len == 0 or session.len > 32 or serial.len == 0 or serial.len > 16 or parts.next() != null) return false;
        for (session) |c| if (!std.ascii.isHex(c)) return false;
        for (serial) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }
    pub fn capture(self: *Registry, id: ?[]const u8, path: []const u8) CaptureError!void {
        if (id) |token| {
            if (!validToken(token)) return error.InvalidWindowId;
        } else if (self.bound == null) return error.NoBoundTarget;
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            const matches = if (id) |token| std.mem.eql(u8, token, entry.token()) else entry.owner == self.bound;
            if (!matches) continue;
            if (entry.closing(entry.owner)) return error.WindowClosing;
            const callback = entry.capture orelse return error.CaptureUnsupported;
            if (!callback(entry.owner, path)) return error.CaptureFailed;
            return;
        };
        return error.WindowNotFound;
    }
    pub fn writeJson(self: *Registry, writer: *JsonWriter) void {
        writer.beginObject();
        writer.key("windows");
        writer.beginArray();
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            writer.beginObject();
            writer.key("window_id");
            writer.string(entry.token());
            var native: [32]u8 = undefined;
            writer.key("native_id");
            writer.string(std.fmt.bufPrint(&native, "{d}", .{entry.native_id}) catch unreachable);
            writer.key("bound");
            writer.boolean(self.bound == entry.owner);
            writer.key("closing");
            writer.boolean(entry.closing(entry.owner));
            writer.endObject();
        };
        writer.endArray();
        writer.endObject();
    }
};

test "window screenshots preserve target identity and never fall back" {
    const Fake = struct {
        closing: bool = false,
        count: usize = 0,
        succeeds: bool = true,
        fn isClosing(ptr: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.closing;
        }
        fn capture(ptr: *anyopaque, _: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
            return self.succeeds;
        }
    };
    var registry: Registry = .{};
    var a: Fake = .{};
    var b: Fake = .{};
    registry.register(123, &a, 10, Fake.capture, Fake.isClosing);
    registry.register(123, &b, 20, Fake.capture, Fake.isClosing);
    registry.bound = &b;
    const old = registry.entries[0].?;
    try registry.capture(old.token(), "a.png");
    try std.testing.expectEqual(@as(usize, 1), a.count);
    try std.testing.expectEqual(@as(usize, 0), b.count);
    try std.testing.expect(registry.bound == @as(*anyopaque, &b));
    try registry.capture(null, "b.png");
    a.closing = true;
    try std.testing.expectError(error.WindowClosing, registry.capture(old.token(), "x"));
    registry.unregister(&a);
    a.closing = false;
    registry.register(123, &a, 10, Fake.capture, Fake.isClosing);
    try std.testing.expectError(error.WindowNotFound, registry.capture(old.token(), "x"));
    try std.testing.expectError(error.InvalidWindowId, registry.capture("10", "x"));
    registry.unregister(&b);
    try std.testing.expectError(error.NoBoundTarget, registry.capture(null, "x"));
    a.succeeds = false;
    try std.testing.expectError(error.CaptureFailed, registry.capture(registry.entries[0].?.token(), "x"));
    registry.register(123, &b, 20, null, Fake.isClosing);
    const unsupported = registry.entries[1].?;
    try std.testing.expectError(error.CaptureUnsupported, registry.capture(unsupported.token(), "x"));
    b.closing = true;
    try std.testing.expectError(error.WindowClosing, registry.capture(unsupported.token(), "x"));
    var restarted: Registry = .{};
    restarted.register(124, &b, 20, null, Fake.isClosing);
    try std.testing.expect(!std.mem.eql(u8, old.token(), restarted.entries[0].?.token()));
}
