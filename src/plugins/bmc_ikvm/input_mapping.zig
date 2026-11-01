//! Pure logical-pixel geometry and US physical-key mapping for the native KVM.
//! Retina backing scale never enters these transforms. Text/IME commits are
//! deliberately separate from physical keys and are not translated into BIOS keys.
const std = @import("std");
const input = @import("remote_input.zig");

pub const Mode = enum { fit, original };
pub const Point = struct { x: f32, y: f32 };
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and p.y >= self.y and p.x < self.x + self.width and p.y < self.y + self.height;
    }
};
pub const Geometry = struct {
    viewport: Rect,
    image: Rect,
    scale: f32,
    width: u32,
    height: u32,
    scroll_x: f32,
    scroll_y: f32,

    pub fn calculate(viewport: Rect, width: u32, height: u32, mode: Mode, scroll: Point) ?Geometry {
        if (width == 0 or height == 0 or viewport.width <= 0 or viewport.height <= 0) return null;
        if (!std.math.isFinite(viewport.width) or !std.math.isFinite(viewport.height)) return null;
        const fw: f32 = @floatFromInt(width);
        const fh: f32 = @floatFromInt(height);
        const scale: f32 = if (mode == .fit) @min(viewport.width / fw, viewport.height / fh) else 1;
        const dw = fw * scale;
        const dh = fh * scale;
        const sx = if (mode == .fit) 0 else std.math.clamp(scroll.x, 0, @max(0, dw - viewport.width));
        const sy = if (mode == .fit) 0 else std.math.clamp(scroll.y, 0, @max(0, dh - viewport.height));
        return .{
            .viewport = viewport,
            .image = .{ .x = viewport.x + @max(0, (viewport.width - dw) / 2) - sx, .y = viewport.y + @max(0, (viewport.height - dh) / 2) - sy, .width = dw, .height = dh },
            .scale = scale,
            .width = width,
            .height = height,
            .scroll_x = sx,
            .scroll_y = sy,
        };
    }

    /// New presses in a black bar are local. A drag that began in the image may
    /// continue outside the viewport and clamps to the remote edge until up.
    pub fn remote(self: Geometry, point: Point, dragging: bool) ?input.Pointer {
        if (!dragging and (!self.viewport.contains(point) or !self.image.contains(point))) return null;
        const x = std.math.clamp(@floor((point.x - self.image.x) / self.scale), 0, @as(f32, @floatFromInt(self.width - 1)));
        const y = std.math.clamp(@floor((point.y - self.image.y) / self.scale), 0, @as(f32, @floatFromInt(self.height - 1)));
        return .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .buttons = 0 };
    }
};

pub const Modifiers = struct { shift: bool = false, ctrl: bool = false, alt: bool = false, super: bool = false };
pub fn isReleaseShortcut(raw: u16, modifiers: Modifiers) bool {
    return raw == 53 and modifiers.ctrl and modifiers.alt;
}

/// The values are the project's actual zenit KeyCode/macOS physical keycodes.
/// Command maps to Super, never Control. Unsupported physical keys return null.
pub fn keysym(raw: u16, shift: bool) ?u32 {
    const pair: ?[2]u8 = switch (raw) {
        0 => .{ 'a', 'A' },
        1 => .{ 's', 'S' },
        2 => .{ 'd', 'D' },
        3 => .{ 'f', 'F' },
        4 => .{ 'h', 'H' },
        5 => .{ 'g', 'G' },
        6 => .{ 'z', 'Z' },
        7 => .{ 'x', 'X' },
        8 => .{ 'c', 'C' },
        9 => .{ 'v', 'V' },
        11 => .{ 'b', 'B' },
        12 => .{ 'q', 'Q' },
        13 => .{ 'w', 'W' },
        14 => .{ 'e', 'E' },
        15 => .{ 'r', 'R' },
        16 => .{ 'y', 'Y' },
        17 => .{ 't', 'T' },
        31 => .{ 'o', 'O' },
        32 => .{ 'u', 'U' },
        34 => .{ 'i', 'I' },
        35 => .{ 'p', 'P' },
        37 => .{ 'l', 'L' },
        38 => .{ 'j', 'J' },
        40 => .{ 'k', 'K' },
        45 => .{ 'n', 'N' },
        46 => .{ 'm', 'M' },
        18 => .{ '1', '!' },
        19 => .{ '2', '@' },
        20 => .{ '3', '#' },
        21 => .{ '4', '$' },
        23 => .{ '5', '%' },
        22 => .{ '6', '^' },
        26 => .{ '7', '&' },
        28 => .{ '8', '*' },
        25 => .{ '9', '(' },
        29 => .{ '0', ')' },
        44 => .{ '/', '?' },
        27 => .{ '-', '_' },
        24 => .{ '=', '+' },
        33 => .{ '[', '{' },
        30 => .{ ']', '}' },
        47 => .{ '.', '>' },
        43 => .{ ',', '<' },
        41 => .{ ';', ':' },
        39 => .{ '\'', '"' },
        42 => .{ '\\', '|' },
        50 => .{ '`', '~' },
        else => null,
    };
    if (pair) |value| return value[@intFromBool(shift)];
    return switch (raw) {
        36 => 0xff0d,
        48 => 0xff09,
        49 => 0x20,
        51 => 0xff08,
        53 => 0xff1b,
        117 => 0xffff,
        123 => 0xff51,
        124 => 0xff53,
        125 => 0xff54,
        126 => 0xff52,
        56 => 0xffe1,
        60 => 0xffe2,
        59 => 0xffe3,
        62 => 0xffe4,
        58 => 0xffe9,
        61 => 0xffea,
        55 => 0xffeb,
        54 => 0xffec,
        115 => 0xff50,
        119 => 0xff57,
        116 => 0xff55,
        121 => 0xff56,
        114 => 0xff63,
        122 => 0xffbe,
        120 => 0xffbf,
        99 => 0xffc0,
        118 => 0xffc1,
        96 => 0xffc2,
        97 => 0xffc3,
        98 => 0xffc4,
        100 => 0xffc5,
        101 => 0xffc6,
        109 => 0xffc7,
        103 => 0xffc8,
        111 => 0xffc9,
        else => null,
    };
}

const modifier_codes = [_]u16{ 56, 60, 59, 62, 58, 61, 55, 54 };
pub const KeyBatch = struct {
    events: [17]input.Key = undefined,
    len: u8 = 0,
    pub fn slice(self: *const KeyBatch) []const input.Key {
        return self.events[0..self.len];
    }
    fn append(self: *KeyBatch, value: input.Key) void {
        std.debug.assert(self.len < self.events.len);
        self.events[self.len] = value;
        self.len += 1;
    }
};

pub const Keyboard = struct {
    pressed: [128]u32 = @splat(0),
    required_modifiers: [128]u4 = @splat(0),
    remote_modifiers: u8 = 0,
    pub fn clear(self: *Keyboard) void {
        self.* = .{};
    }
    pub fn key(self: *Keyboard, raw: u16, modifiers: Modifiers, down: bool) ?input.Key {
        if (raw >= self.pressed.len) return null;
        const symbol = if (self.pressed[raw] != 0) self.pressed[raw] else keysym(raw, modifiers.shift) orelse return null;
        // Repeats and the final up keep the first down's symbol, even if Shift
        // changes while the physical key remains held.
        if (down) self.pressed[raw] = symbol else self.pressed[raw] = 0;
        return .{ .keysym = symbol, .down = down };
    }

    /// Native key events carry an aggregate modifier snapshot even when a
    /// modifier was held before capture or no separate flagsChanged arrived.
    /// Preserve explicit left/right transitions. Inferred modifiers belong to
    /// the active ordinary keys and are released with their final up, so a
    /// flags-only synthetic chord cannot leave a remote modifier held forever.
    /// The caller must handle the local release shortcut before calling this.
    pub fn keyBatch(self: *Keyboard, raw: u16, modifiers: Modifiers, down: bool) ?KeyBatch {
        const value = self.key(raw, modifiers, down) orelse return null;
        var flags = modifierFlags(modifiers);
        var modifier_group: ?u2 = null;
        for (modifier_codes, 0..) |code, index| {
            if (code == raw) {
                modifier_group = @intCast(index / 2);
                break;
            }
        }
        if (modifier_group) |group| {
            if (down) flags |= @as(u4, 1) << group;
        } else if (down) self.required_modifiers[raw] = flags;

        var result: KeyBatch = .{};
        self.syncModifiers(&result, flags);
        if (modifier_group == null) {
            result.append(value);
            if (!down) {
                self.required_modifiers[raw] = 0;
                self.syncModifiers(&result, flags);
            }
        }
        return result;
    }

    fn syncModifiers(self: *Keyboard, batch: *KeyBatch, flags: u4) void {
        // A missing aggregate flag is also authoritative when an explicit
        // modifier-up packet was lost. Do not retain an obsolete physical down.
        for (0..4) |group| {
            const bit = @as(u4, 1) << @as(u2, @intCast(group));
            if (flags & bit == 0) {
                self.pressed[modifier_codes[group * 2]] = 0;
                self.pressed[modifier_codes[group * 2 + 1]] = 0;
                for (&self.required_modifiers) |*required| required.* &= ~bit;
            }
        }
        var required: u4 = 0;
        for (self.required_modifiers) |value| required |= value;
        var desired: u8 = 0;
        for (0..4) |group| {
            const left: u3 = @intCast(group * 2);
            const right: u3 = @intCast(group * 2 + 1);
            const physical_left = self.pressed[modifier_codes[group * 2]] != 0;
            const physical_right = self.pressed[modifier_codes[group * 2 + 1]] != 0;
            if (physical_left) desired |= @as(u8, 1) << left;
            if (physical_right) desired |= @as(u8, 1) << right;
            if (!physical_left and !physical_right and required & flags & (@as(u4, 1) << @as(u2, @intCast(group))) != 0) desired |= @as(u8, 1) << left;
        }
        // Release obsolete sides before adopting a different physical side.
        for (modifier_codes, 0..) |code, index| {
            const bit = @as(u8, 1) << @as(u3, @intCast(index));
            if (self.remote_modifiers & bit != 0 and desired & bit == 0) batch.append(.{ .keysym = keysym(code, false).?, .down = false });
        }
        for (modifier_codes, 0..) |code, index| {
            const bit = @as(u8, 1) << @as(u3, @intCast(index));
            if (self.remote_modifiers & bit == 0 and desired & bit != 0) batch.append(.{ .keysym = keysym(code, false).?, .down = true });
        }
        self.remote_modifiers = desired;
    }
};

fn modifierFlags(value: Modifiers) u4 {
    return @as(u4, @intFromBool(value.shift)) | (@as(u4, @intFromBool(value.ctrl)) << 1) | (@as(u4, @intFromBool(value.alt)) << 2) | (@as(u4, @intFromBool(value.super)) << 3);
}

fn expectKeyBatch(value: ?KeyBatch, expected: []const input.Key) !void {
    try std.testing.expect(value != null);
    const batch = value.?;
    try std.testing.expectEqual(expected.len, batch.slice().len);
    for (expected, batch.slice()) |wanted, actual| try std.testing.expectEqualDeep(wanted, actual);
}

test "BMC keyboard batch pairs flags-only Shift Right held before capture" {
    var keyboard: Keyboard = .{};
    try expectKeyBatch(keyboard.keyBatch(124, .{ .shift = true }, true), &.{ .{ .keysym = 0xffe1, .down = true }, .{ .keysym = 0xff53, .down = true } });
    try expectKeyBatch(keyboard.keyBatch(124, .{ .shift = true }, false), &.{ .{ .keysym = 0xff53, .down = false }, .{ .keysym = 0xffe1, .down = false } });
    try std.testing.expectEqual(@as(u8, 0), keyboard.remote_modifiers);
    try std.testing.expectEqual(@as(u32, 0), keyboard.pressed[124]);
}

test "BMC keyboard batch preserves explicit modifier sides without duplicate inferred presses" {
    var keyboard: Keyboard = .{};
    try expectKeyBatch(keyboard.keyBatch(56, .{ .shift = true }, true), &.{.{ .keysym = 0xffe1, .down = true }});
    try expectKeyBatch(keyboard.keyBatch(60, .{ .shift = true }, true), &.{.{ .keysym = 0xffe2, .down = true }});
    try expectKeyBatch(keyboard.keyBatch(56, .{ .shift = true }, false), &.{.{ .keysym = 0xffe1, .down = false }});
    try expectKeyBatch(keyboard.keyBatch(124, .{ .shift = true }, true), &.{.{ .keysym = 0xff53, .down = true }});
    try expectKeyBatch(keyboard.keyBatch(124, .{ .shift = true }, false), &.{.{ .keysym = 0xff53, .down = false }});
    try expectKeyBatch(keyboard.keyBatch(60, .{}, false), &.{.{ .keysym = 0xffe2, .down = false }});
    try std.testing.expectEqual(@as(u8, 0), keyboard.remote_modifiers);
}

test "BMC keyboard batch repeats and overlapping primary keys share inferred modifiers until final up" {
    var keyboard: Keyboard = .{};
    try expectKeyBatch(keyboard.keyBatch(124, .{ .shift = true }, true), &.{ .{ .keysym = 0xffe1, .down = true }, .{ .keysym = 0xff53, .down = true } });
    try expectKeyBatch(keyboard.keyBatch(124, .{ .shift = true }, true), &.{.{ .keysym = 0xff53, .down = true }});
    try expectKeyBatch(keyboard.keyBatch(123, .{ .shift = true }, true), &.{.{ .keysym = 0xff51, .down = true }});
    try expectKeyBatch(keyboard.keyBatch(124, .{ .shift = true }, false), &.{.{ .keysym = 0xff53, .down = false }});
    try expectKeyBatch(keyboard.keyBatch(123, .{ .shift = true }, false), &.{ .{ .keysym = 0xff51, .down = false }, .{ .keysym = 0xffe1, .down = false } });
    try std.testing.expectEqual(@as(u8, 0), keyboard.remote_modifiers);
}

test "BMC keyboard batch missing modifier up clears remote state while preserving the original symbol" {
    var keyboard: Keyboard = .{};
    try expectKeyBatch(keyboard.keyBatch(0, .{ .shift = true }, true), &.{ .{ .keysym = 0xffe1, .down = true }, .{ .keysym = 'A', .down = true } });
    try expectKeyBatch(keyboard.keyBatch(0, .{}, true), &.{ .{ .keysym = 0xffe1, .down = false }, .{ .keysym = 'A', .down = true } });
    try expectKeyBatch(keyboard.keyBatch(0, .{}, false), &.{.{ .keysym = 'A', .down = false }});
    try std.testing.expectEqual(@as(u8, 0), keyboard.remote_modifiers);
    try std.testing.expectEqual(@as(u32, 0), keyboard.pressed[0]);
}

test "BMC keyboard batch synchronizes Control Alt Super independently from Shift" {
    var keyboard: Keyboard = .{};
    const modifiers: Modifiers = .{ .shift = true, .ctrl = true, .alt = true, .super = true };
    try expectKeyBatch(keyboard.keyBatch(122, modifiers, true), &.{ .{ .keysym = 0xffe1, .down = true }, .{ .keysym = 0xffe3, .down = true }, .{ .keysym = 0xffe9, .down = true }, .{ .keysym = 0xffeb, .down = true }, .{ .keysym = 0xffbe, .down = true } });
    try expectKeyBatch(keyboard.keyBatch(122, modifiers, false), &.{ .{ .keysym = 0xffbe, .down = false }, .{ .keysym = 0xffe1, .down = false }, .{ .keysym = 0xffe3, .down = false }, .{ .keysym = 0xffe9, .down = false }, .{ .keysym = 0xffeb, .down = false } });
    try std.testing.expectEqual(@as(u8, 0), keyboard.remote_modifiers);
}

test "BMC keyboard batch hands an inferred modifier to a physical side and clear drops all bookkeeping" {
    var keyboard: Keyboard = .{};
    _ = keyboard.keyBatch(124, .{ .shift = true }, true).?;
    try expectKeyBatch(keyboard.keyBatch(60, .{ .shift = true }, true), &.{ .{ .keysym = 0xffe1, .down = false }, .{ .keysym = 0xffe2, .down = true } });
    try expectKeyBatch(keyboard.keyBatch(124, .{ .shift = true }, false), &.{.{ .keysym = 0xff53, .down = false }});
    try expectKeyBatch(keyboard.keyBatch(60, .{}, false), &.{.{ .keysym = 0xffe2, .down = false }});
    _ = keyboard.keyBatch(124, .{ .ctrl = true }, true).?;
    keyboard.clear();
    try std.testing.expectEqual(@as(u8, 0), keyboard.remote_modifiers);
    for (keyboard.pressed) |value| try std.testing.expectEqual(@as(u32, 0), value);
    for (keyboard.required_modifiers) |value| try std.testing.expectEqual(@as(u4, 0), value);
    try expectKeyBatch(keyboard.keyBatch(124, .{}, true), &.{.{ .keysym = 0xff53, .down = true }});
}

test "BMC keyboard batch remains bounded for every supported physical key and modifier snapshot" {
    for (0..128) |raw| {
        for (0..16) |bits| {
            var keyboard: Keyboard = .{};
            const modifiers: Modifiers = .{ .shift = bits & 1 != 0, .ctrl = bits & 2 != 0, .alt = bits & 4 != 0, .super = bits & 8 != 0 };
            if (keyboard.keyBatch(@intCast(raw), modifiers, true)) |down| {
                try std.testing.expect(down.len <= down.events.len);
                const up = keyboard.keyBatch(@intCast(raw), modifiers, false).?;
                try std.testing.expect(up.len <= up.events.len);
                try std.testing.expectEqual(@as(u8, 0), keyboard.remote_modifiers);
            } else try std.testing.expectEqual(@as(u8, 0), keyboard.remote_modifiers);
        }
    }
    var keyboard: Keyboard = .{};
    try std.testing.expect(keyboard.keyBatch(0xffff, .{ .shift = true }, true) == null);
    try std.testing.expectEqual(@as(u8, 0), keyboard.remote_modifiers);
}

pub const WheelAccumulator = struct {
    x: f32 = 0,
    y: f32 = 0,
    pub fn clear(self: *WheelAccumulator) void {
        self.* = .{};
    }
    pub fn add(self: *WheelAccumulator, dx: f32, dy: f32, trackpad: bool) struct { x: i8, y: i8 } {
        if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return .{ .x = 0, .y = 0 };
        if (!trackpad) return .{ .x = discrete(-dx), .y = discrete(-dy) };
        self.x -= dx;
        self.y -= dy;
        const sx: i8 = @intFromFloat(std.math.clamp(@trunc(self.x / 40), -16, 16));
        const sy: i8 = @intFromFloat(std.math.clamp(@trunc(self.y / 40), -16, 16));
        self.x -= @as(f32, @floatFromInt(sx)) * 40;
        self.y -= @as(f32, @floatFromInt(sy)) * 40;
        return .{ .x = sx, .y = sy };
    }
    fn discrete(delta: f32) i8 {
        return if (delta == 0) 0 else if (delta > 0) 1 else -1;
    }
};
