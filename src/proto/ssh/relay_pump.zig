const std = @import("std");
const Relay = @import("relay.zig").Relay;
const Direction = @import("relay.zig").Direction;
const Reader = @import("../../vt/worker_io.zig").ChannelReader;
const Writer = @import("../../vt/channel_pump.zig").ChannelWriter;

pub const Pump = struct {
    relay: Relay = .{},
    left: Reader,
    right: Reader,
    left_writer: Writer,
    right_writer: Writer,
    scratch_left: []u8,
    scratch_right: []u8,

    pub fn init(left: Reader, right: Reader, left_writer: Writer, right_writer: Writer, scratch_left: []u8, scratch_right: []u8) !Pump {
        if (scratch_left.len == 0 or scratch_right.len == 0) return error.EmptyBuffer;
        var pump: Pump = .{ .left = left, .right = right, .left_writer = left_writer, .right_writer = right_writer, .scratch_left = scratch_left, .scratch_right = scratch_right };
        try pump.relay.start();
        return pump;
    }

    pub fn step(self: *Pump) !StepResult {
        var result: StepResult = .{};
        switch (try self.left.read(self.scratch_left)) {
            .would_block => {},
            .eof => {
                try self.relay.eof(.left_to_right);
                result.left_eof = true;
            },
            .bytes => |count| {
                if (count == 0 or count > self.scratch_left.len) return error.InvalidReadCount;
                const written = try writeAll(self.right_writer, self.scratch_left[0..count]);
                try self.relay.forwarded(.left_to_right, written);
                result.left_to_right = written;
            },
        }
        switch (try self.right.read(self.scratch_right)) {
            .would_block => {},
            .eof => {
                try self.relay.eof(.right_to_left);
                result.right_eof = true;
            },
            .bytes => |count| {
                if (count == 0 or count > self.scratch_right.len) return error.InvalidReadCount;
                const written = try writeAll(self.left_writer, self.scratch_right[0..count]);
                try self.relay.forwarded(.right_to_left, written);
                result.right_to_left = written;
            },
        }
        return result;
    }

    fn writeAll(writer: Writer, bytes: []const u8) !usize {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = try writer.write(bytes[offset..]);
            if (count == 0 or count > bytes.len - offset) return error.InvalidWriteCount;
            offset += count;
        }
        return offset;
    }
};

pub const StepResult = struct { left_to_right: usize = 0, right_to_left: usize = 0, left_eof: bool = false, right_eof: bool = false };

const Memory = struct {
    input: []const u8,
    blocked: bool = false,
    position: usize = 0,
    output: [64]u8 = undefined,
    output_len: usize = 0,

    fn read(ctx: *anyopaque, buffer: []u8) !@import("../../vt/worker_io.zig").Read {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        if (self.blocked) return .would_block;
        if (self.position == self.input.len) return .eof;
        const count = @min(buffer.len, self.input.len - self.position);
        @memcpy(buffer[0..count], self.input[self.position .. self.position + count]);
        self.position += count;
        return .{ .bytes = count };
    }

    fn write(ctx: *anyopaque, bytes: []const u8) !usize {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        @memcpy(self.output[self.output_len .. self.output_len + bytes.len], bytes);
        self.output_len += bytes.len;
        return bytes.len;
    }
};

test "relay pump forwards both directions and closes on EOF" {
    var left: Memory = .{ .input = "client" };
    var right: Memory = .{ .input = "server" };
    var left_scratch: [16]u8 = undefined;
    var right_scratch: [16]u8 = undefined;
    var pump = try Pump.init(
        .{ .ctx = &left, .read_fn = Memory.read },
        .{ .ctx = &right, .read_fn = Memory.read },
        .{ .ctx = &left, .write_fn = Memory.write },
        .{ .ctx = &right, .write_fn = Memory.write },
        &left_scratch,
        &right_scratch,
    );
    const first = try pump.step();
    try std.testing.expectEqual(@as(usize, 6), first.left_to_right);
    try std.testing.expectEqual(@as(usize, 6), first.right_to_left);
    try std.testing.expectEqualStrings("client", right.output[0..right.output_len]);
    try std.testing.expectEqualStrings("server", left.output[0..left.output_len]);
    const second = try pump.step();
    try std.testing.expect(second.left_eof and second.right_eof);
    try std.testing.expectEqual(@import("relay.zig").State.closed, pump.relay.state);
}

test "relay pump keeps a would-block channel open" {
    var left: Memory = .{ .input = "", .blocked = true };
    var right: Memory = .{ .input = "", .blocked = true };
    var left_scratch: [4]u8 = undefined;
    var right_scratch: [4]u8 = undefined;
    var pump = try Pump.init(
        .{ .ctx = &left, .read_fn = Memory.read },
        .{ .ctx = &right, .read_fn = Memory.read },
        .{ .ctx = &left, .write_fn = Memory.write },
        .{ .ctx = &right, .write_fn = Memory.write },
        &left_scratch,
        &right_scratch,
    );
    const result = try pump.step();
    try std.testing.expect(!result.left_eof and !result.right_eof);
    try std.testing.expectEqual(@import("relay.zig").State.running, pump.relay.state);
}
