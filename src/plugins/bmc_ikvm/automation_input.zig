//! Bounded, owned automation actions. Coordinates have already been mapped from
//! a validated Observation; this layer never interprets local window pixels.
//! Text means US ASCII key strokes, never paste, IME composition or Enter.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const content = @import("../../host/content_context.zig");

pub const Proof = content.AutomationProof;
pub const Authority = struct {
    owner: identity.SessionHandle,
    binding_generation: u64,
    transport_generation: u64,
    control_generation: u64,
    input_epoch: u64,
    geometry_generation: u64 = 0,
    expires_at_ms: u64 = std.math.maxInt(u64),
    proof: Proof,
};
pub const Point = struct { x: u16, y: u16 };
pub const Button = enum(u8) { left = 1, middle = 2, right = 4 };
pub const Click = struct { point: Point, button: Button = .left, count: u8 = 1 };
pub const Drag = struct {
    points: [32]Point = @splat(.{ .x = 0, .y = 0 }),
    count: u8,
    button: Button = .left,
    pub fn init(points: []const Point, button: Button) !Drag {
        if (points.len < 2 or points.len > 32) return error.InvalidDrag;
        var result: Drag = .{ .count = @intCast(points.len), .button = button };
        @memcpy(result.points[0..points.len], points);
        return result;
    }
};
pub const Wheel = struct { point: Point, steps_x: i8 = 0, steps_y: i8 = 0 };
pub const Chord = struct {
    keys: [8]u32 = @splat(0),
    count: u8,
    pub fn init(keys: []const u32) !Chord {
        if (keys.len == 0 or keys.len > 8) return error.InvalidChord;
        var result: Chord = .{ .count = @intCast(keys.len) };
        @memcpy(result.keys[0..keys.len], keys);
        return result;
    }
};
pub const Layout = enum { us_ascii };
pub const max_text_bytes = 256;
pub const Text = struct {
    bytes: [max_text_bytes]u8 = @splat(0),
    length: u16,
    layout: Layout = .us_ascii,
    pub fn init(bytes: []const u8, layout: Layout) !Text {
        if (bytes.len == 0 or bytes.len > max_text_bytes) return error.InvalidTextLength;
        var result: Text = .{ .length = @intCast(bytes.len), .layout = layout };
        @memcpy(result.bytes[0..bytes.len], bytes);
        return result;
    }
};
pub const Action = union(enum) {
    pointer_move: Point,
    click: Click,
    drag: Drag,
    wheel: Wheel,
    key: u32,
    chord: Chord,
    text: Text,
};
pub const Request = struct { operation_id: u64, action: Action };
pub const Status = enum { accepted, sent, cancelled_unsent, outcome_unknown };
pub const Receipt = struct {
    owner: identity.SessionHandle,
    operation_id: u64,
    status: Status = .accepted,
    sent_events: u16 = 0,
    total_events: u16,
    sent_monotonic_ms: u64 = 0,
    sent_monotonic_ns: u64 = 0,
    /// A transport error or partial outer WebSocket frame can reach the peer
    /// without a complete RFB packet being acknowledged locally.
    possibly_written: bool = false,
};
pub const Key = struct { keysym: u32, down: bool };
pub const Pointer = struct { x: u16, y: u16, buttons: u8 };
pub const Event = union(enum) { key: Key, pointer: Pointer };
pub const Batch = struct {
    pub const capacity = max_text_bytes * 4;
    events: [capacity]Event = undefined,
    count: u16 = 0,
    pub fn fingerprint(self: *const Batch) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (self.events[0..self.count]) |event| switch (event) {
            .key => |value| {
                var bytes: [6]u8 = .{ 4, @intFromBool(value.down), 0, 0, 0, 0 };
                std.mem.writeInt(u32, bytes[2..6], value.keysym, .big);
                hasher.update(&bytes);
            },
            .pointer => |value| {
                var bytes: [6]u8 = .{ 5, value.buttons, 0, 0, 0, 0 };
                std.mem.writeInt(u16, bytes[2..4], value.x, .big);
                std.mem.writeInt(u16, bytes[4..6], value.y, .big);
                hasher.update(&bytes);
            },
        };
        return hasher.finalResult();
    }
    fn append(self: *Batch, event: Event) !void {
        if (self.count == capacity) return error.ActionTooLarge;
        self.events[self.count] = event;
        self.count += 1;
    }
    fn pointer(self: *Batch, point: Point, buttons: u8) !void {
        try self.append(.{ .pointer = .{ .x = point.x, .y = point.y, .buttons = buttons } });
    }
    fn key(self: *Batch, symbol: u32, down: bool) !void {
        try self.append(.{ .key = .{ .keysym = symbol, .down = down } });
    }
};

pub fn validKeysym(value: u32) bool {
    return (value >= 0x20 and value <= 0x7e) or switch (value) {
        0xff08,
        0xff09,
        0xff0d,
        0xff1b,
        0xffff,
        0xff50...0xff57,
        0xff63,
        0xffbe...0xffd5,
        0xffe1...0xffe4,
        0xffe9...0xffec,
        => true,
        else => false,
    };
}
/// Compile completely before taking a queue slot: malformed/unsupported text
/// and queue pressure can never leave half of a chord or a dangling down.
pub fn compile(action: Action) !Batch {
    var batch: Batch = .{};
    switch (action) {
        .pointer_move => |point| try batch.pointer(point, 0),
        .click => |value| {
            if (value.count == 0 or value.count > 2) return error.InvalidClick;
            try batch.pointer(value.point, 0);
            for (0..value.count) |_| {
                try batch.pointer(value.point, @backingInt(value.button));
                try batch.pointer(value.point, 0);
            }
        },
        .drag => |value| {
            if (value.count < 2 or value.count > value.points.len) return error.InvalidDrag;
            try batch.pointer(value.points[0], 0);
            try batch.pointer(value.points[0], @backingInt(value.button));
            for (value.points[1..value.count]) |point| try batch.pointer(point, @backingInt(value.button));
            try batch.pointer(value.points[value.count - 1], 0);
        },
        .wheel => |value| {
            if (value.steps_x < -16 or value.steps_x > 16 or value.steps_y < -16 or value.steps_y > 16 or (value.steps_x == 0 and value.steps_y == 0)) return error.InvalidWheel;
            for (0..@as(usize, @abs(value.steps_y))) |_| {
                try batch.pointer(value.point, if (value.steps_y > 0) 8 else 16);
                try batch.pointer(value.point, 0);
            }
            for (0..@as(usize, @abs(value.steps_x))) |_| {
                try batch.pointer(value.point, if (value.steps_x > 0) 64 else 32);
                try batch.pointer(value.point, 0);
            }
        },
        .key => |symbol| {
            if (!validKeysym(symbol)) return error.UnsupportedKey;
            try batch.key(symbol, true);
            try batch.key(symbol, false);
        },
        .chord => |value| {
            if (value.count == 0 or value.count > value.keys.len) return error.InvalidChord;
            for (value.keys[0..value.count], 0..) |symbol, index| {
                if (!validKeysym(symbol)) return error.UnsupportedKey;
                for (value.keys[0..index]) |prior| if (prior == symbol) return error.InvalidChord;
                try batch.key(symbol, true);
            }
            var index: usize = value.count;
            while (index != 0) {
                index -= 1;
                try batch.key(value.keys[index], false);
            }
        },
        .text => |value| {
            if (value.length == 0 or value.length > value.bytes.len) return error.InvalidTextLength;
            for (value.bytes[0..value.length]) |byte| {
                if (byte < 0x20 or byte > 0x7e) return error.UnsupportedText;
                const shifted = (byte >= 'A' and byte <= 'Z') or std.mem.indexOfScalar(u8, "~!@#$%^&*()_+{}|:\"<>?", byte) != null;
                if (shifted) try batch.key(0xffe1, true);
                try batch.key(byte, true);
                try batch.key(byte, false);
                if (shifted) try batch.key(0xffe1, false);
            }
        },
    }
    return batch;
}
