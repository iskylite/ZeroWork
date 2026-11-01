const std = @import("std");
const T = std.testing;
const remote = @import("plugins/bmc_ikvm/remote_input.zig");
const video = @import("plugins/bmc_ikvm/video_pipeline.zig");
const frames = @import("plugins/bmc_ikvm/framebuffer.zig");
const budgets = @import("host/frame_budget.zig");
const identity = @import("host/identity.zig");
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(732) };

const Output = struct {
    data: [4096]u8 = undefined,
    length: usize = 0,
    chunk: usize = 4096,
    writes: usize = 0,
    aborts: usize = 0,
    service: ?*remote.Service = null,
    trigger_write: ?usize = null,
    action: enum { focus_barrier, revoke, disconnect, close } = .focus_barrier,

    fn write(raw: *anyopaque, input: []const u8) !usize {
        const self: *Output = @ptrCast(@alignCast(raw));
        const length = @min(input.len, self.chunk);
        if (length > self.data.len - self.length) return error.TestOutputFull;
        @memcpy(self.data[self.length..][0..length], input[0..length]);
        self.length += length;
        self.writes += 1;
        if (self.trigger_write == self.writes) {
            self.trigger_write = null;
            const service = self.service.?;
            switch (self.action) {
                .focus_barrier => {
                    service.setFocus(false);
                    _ = service.releaseAll(service.binding(), .lost_focus);
                },
                .revoke => try service.setControl(false, (try service.snapshot(service.binding())).control_generation + 1),
                .disconnect => try service.setConnected(false, (try service.snapshot(service.binding())).transport_generation),
                .close => service.close(),
            }
        }
        return length;
    }
    fn abort(raw: *anyopaque) void {
        const self: *Output = @ptrCast(@alignCast(raw));
        self.aborts += 1;
    }
    fn wire(self: *Output, generation: u64) remote.Wire {
        return .{ .context = self, .generation = generation, .write = write, .abort = abort };
    }
    fn videoWire(self: *Output) video.Wire {
        return .{ .context = self, .write = write, .abort = abort };
    }
    fn bytes(self: *const Output) []const u8 {
        return self.data[0..self.length];
    }
};

fn ready(service: *remote.Service, focused: bool) !void {
    try service.setConnected(true, 1);
    try service.setControl(true, 2);
    service.setFocus(focused);
}
fn chord(keys: []const u32) !remote.Chord {
    return remote.Chord.init(keys);
}
fn explicit(service: *remote.Service, sequence: u64, keys: []const u32) !void {
    const result = service.submitChord(service.binding(), service.explicitChordCommand(sequence, try chord(keys)));
    try T.expect(result == .accepted);
    try T.expectEqual(sequence, result.accepted);
}
fn ordinary(service: *remote.Service, sequence: u64, event: remote.Event) !void {
    try T.expect(service.submit(service.binding(), service.command(sequence, event)) == .accepted);
}
fn expectKey(bytes: []const u8, keysym: u32, down: bool) !void {
    try T.expectEqual(@as(usize, 8), bytes.len);
    try T.expectEqualSlices(u8, &.{ 4, @intFromBool(down), 0, 0 }, bytes[0..4]);
    try T.expectEqual(keysym, std.mem.readInt(u32, bytes[4..8], .big));
}
fn expectChord(bytes: []const u8, keys: []const u32) !void {
    try T.expectEqual(keys.len * 16, bytes.len);
    for (keys, 0..) |keysym, index| {
        try expectKey(bytes[index * 8 ..][0..8], keysym, true);
        try expectKey(bytes[(keys.len * 2 - index - 1) * 8 ..][0..8], keysym, false);
    }
}

test "BMC explicit input accepts unfocused controlled chord through optional interface without capturing ordinary input" {
    var service = remote.Service.init(owner);
    try ready(&service, false);
    const binding = service.binding();
    const iface = try binding.borrow(remote.Interface, remote.key, owner);
    const before = try service.snapshot(binding);
    try T.expect(service.submit(binding, service.command(1, .{ .key = .{ .keysym = 'a', .down = true } })) == .not_focused);
    const command = service.explicitChordCommand(1, try chord(&.{ 0xffe3, 0xffe9, 0xffff }));
    try T.expect(iface.submit_chord.?(binding.context, binding, command) == .accepted);
    const queued = try service.snapshot(binding);
    try T.expect(!queued.focused);
    try T.expectEqual(before.capture_paused, queued.capture_paused);
    try T.expectEqual(before.input_epoch, queued.input_epoch);
    var output: Output = .{ .chunk = 2 };
    try T.expectEqual(@as(usize, 6), try service.pump(output.wire(1)));
    try expectChord(output.bytes(), &.{ 0xffe3, 0xffe9, 0xffff });
    try T.expectEqual(@as(usize, 0), service.pressed_count);
    service.setFocus(true);
    try ordinary(&service, 2, .{ .key = .{ .keysym = 'a', .down = true } });
    _ = service.releaseAll(binding, .released);
    try T.expectEqual(@as(usize, 0), try service.pump(output.wire(1)));
}

test "BMC explicit input rejects wrong owner binding generations stale epochs and malformed chords" {
    var service = remote.Service.init(owner);
    try ready(&service, false);
    const command = service.explicitChordCommand(1, try chord(&.{0xffbe}));
    var invalid = command;
    invalid.session_handle = .{ .session_id = @fromBackingInt(999) };
    try T.expect(service.submitChord(service.binding(), invalid) == .stale_binding);
    invalid = command;
    invalid.binding_generation += 1;
    try T.expect(service.submitChord(service.binding(), invalid) == .stale_binding);
    var stale_binding = service.binding();
    stale_binding.generation += 1;
    try T.expect(service.submitChord(stale_binding, command) == .stale_binding);
    stale_binding = service.binding();
    stale_binding.authorized = false;
    try T.expect(service.submitChord(stale_binding, command) == .stale_binding);
    var another = remote.Service.init(owner);
    try T.expect(service.submitChord(another.binding(), command) == .stale_binding);
    for (0..3) |field| {
        invalid = command;
        switch (field) {
            0 => invalid.input_epoch += 1,
            1 => invalid.control_generation += 1,
            else => invalid.transport_generation += 1,
        }
        try T.expect(service.submitChord(service.binding(), invalid) == .stale_epoch);
    }
    invalid = command;
    invalid.input_sequence = 0;
    try T.expect(service.submitChord(service.binding(), invalid) == .invalid_command);
    for ([_]remote.Chord{ .{ .count = 0 }, .{ .count = 9 }, .{ .count = 1 }, .{ .count = 2, .keys = .{ 1, 1, 0, 0, 0, 0, 0, 0 } } }) |value| {
        invalid = command;
        invalid.chord = value;
        try T.expect(service.submitChord(service.binding(), invalid) == .invalid_command);
    }
    try T.expect(service.submitChord(service.binding(), command) == .accepted);
    try T.expect(service.submitChord(service.binding(), command) == .invalid_command);
}

test "BMC explicit input focus release preserves queued menu intent and releases ordinary downs first" {
    var service = remote.Service.init(owner);
    try ready(&service, true);
    var output: Output = .{};
    try ordinary(&service, 1, .{ .key = .{ .keysym = 'a', .down = true } });
    try ordinary(&service, 2, .{ .pointer = .{ .x = 12, .y = 34, .buttons = 1 } });
    try T.expectEqual(@as(usize, 2), try service.pump(output.wire(1)));
    const before = try service.snapshot(service.binding());
    try ordinary(&service, 3, .{ .key = .{ .keysym = 'b', .down = true } });
    service.setFocus(false);
    _ = service.releaseAll(service.binding(), .released);
    try explicit(&service, 4, &.{ 0xffe3, 0xffe9, 0xffff });
    try explicit(&service, 5, &.{0xffbe});
    service.setFocus(true);
    service.setFocus(false);
    _ = service.releaseAll(service.binding(), .lost_focus);
    const queued = try service.snapshot(service.binding());
    try T.expect(queued.input_epoch > before.input_epoch);
    try T.expectEqual(before.explicit_input_epoch, queued.explicit_input_epoch);
    try T.expectEqual(@as(usize, 2), queued.queued);
    const start = output.length;
    try T.expectEqual(@as(usize, 10), try service.pump(output.wire(1)));
    try expectKey(output.bytes()[start..][0..8], 'a', false);
    try T.expectEqualSlices(u8, &.{ 5, 0, 0, 12, 0, 34 }, output.bytes()[start + 8 ..][0..6]);
    try expectChord(output.bytes()[start + 14 ..][0..48], &.{ 0xffe3, 0xffe9, 0xffff });
    try expectChord(output.bytes()[start + 62 ..], &.{0xffbe});
    try T.expectEqual(@as(usize, 0), service.pressed_count);
    try T.expectEqual(@as(u8, 0), service.pressed_buttons);
    try T.expectEqual(@as(usize, 0), try service.pump(output.wire(1)));
}

test "BMC explicit input and ordinary commands preserve their shared sequence order" {
    var service = remote.Service.init(owner);
    try ready(&service, true);
    try ordinary(&service, 1, .{ .key = .{ .keysym = 'a', .down = true } });
    try explicit(&service, 2, &.{0xffbe});
    try ordinary(&service, 3, .{ .key = .{ .keysym = 'a', .down = false } });
    var output: Output = .{};
    try T.expectEqual(@as(usize, 4), try service.pump(output.wire(1)));
    try expectKey(output.bytes()[0..8], 'a', true);
    try expectChord(output.bytes()[8..24], &.{0xffbe});
    try expectKey(output.bytes()[24..32], 'a', false);
    try T.expectEqual(@as(usize, 0), service.pressed_count);
}

test "BMC explicit input bounded queue rejects newest without clearing accepted actions or consuming sequence" {
    var service = remote.Service.init(owner);
    try ready(&service, false);
    for (0..remote.Service.explicit_capacity) |index| try explicit(&service, index + 1, &.{0xffbe});
    const extra = service.explicitChordCommand(remote.Service.explicit_capacity + 1, try chord(&.{0xffbf}));
    const before = try service.snapshot(service.binding());
    try T.expect(service.submitChord(service.binding(), extra) == .queue_full);
    const after = try service.snapshot(service.binding());
    try T.expectEqual(before, after);
    _ = service.releaseAll(service.binding(), .lost_focus);
    var output: Output = .{};
    try T.expectEqual(remote.Service.explicit_capacity * 2, try service.pump(output.wire(1)));
    for (0..remote.Service.explicit_capacity) |index| try expectChord(output.bytes()[index * 16 ..][0..16], &.{0xffbe});
    try T.expect(service.submitChord(service.binding(), extra) == .accepted);
    try T.expectEqual(@as(usize, 2), try service.pump(output.wire(1)));
    try T.expectEqual(@as(usize, 0), service.pressed_count);
}

test "BMC explicit input survives ordinary queue overflow without resuming capture" {
    var service = remote.Service.init(owner);
    try ready(&service, true);
    for (0..remote.Service.capacity) |index| try ordinary(&service, index + 1, .{ .key = .{ .keysym = 'a', .down = true } });
    try explicit(&service, remote.Service.capacity + 1, &.{0xffc9});
    try T.expect(service.submit(service.binding(), service.command(remote.Service.capacity + 2, .{ .key = .{ .keysym = 'b', .down = true } })) == .queue_full);
    try T.expect((try service.snapshot(service.binding())).capture_paused);
    service.setFocus(false);
    try explicit(&service, remote.Service.capacity + 3, &.{0xffbe});
    var output: Output = .{};
    try T.expectEqual(@as(usize, 4), try service.pump(output.wire(1)));
    try expectChord(output.bytes()[0..16], &.{0xffc9});
    try expectChord(output.bytes()[16..32], &.{0xffbe});
    const after = try service.snapshot(service.binding());
    try T.expect(after.capture_paused and !after.focused);
    try T.expectEqual(@as(usize, 0), service.pressed_count);
}

test "BMC explicit input focus barrier during partial raw packet preserves complete paired chord" {
    var service = remote.Service.init(owner);
    try ready(&service, true);
    try explicit(&service, 1, &.{ 0xffe3, 0xffe9, 0xffff });
    try ordinary(&service, 2, .{ .key = .{ .keysym = 'a', .down = true } });
    var output: Output = .{ .chunk = 2, .service = &service, .trigger_write = 1 };
    try T.expectEqual(@as(usize, 6), try service.pump(output.wire(1)));
    try expectChord(output.bytes(), &.{ 0xffe3, 0xffe9, 0xffff });
    try T.expectEqual(@as(usize, 0), output.aborts);
    try T.expectEqual(@as(usize, 0), service.pressed_count);
    try T.expect(!(try service.snapshot(service.binding())).focused);
}

test "BMC explicit input hard barriers discard queued actions and deny disconnected revoked or closed state" {
    for (0..4) |barrier| {
        var service = remote.Service.init(owner);
        try ready(&service, false);
        const old = service.explicitChordCommand(1, try chord(&.{0xffbe}));
        try T.expect(service.submitChord(service.binding(), old) == .accepted);
        switch (barrier) {
            0 => try service.setControl(false, 3),
            1 => try service.setConnected(false, 1),
            2 => try service.setConnected(true, 2),
            else => service.close(),
        }
        try T.expect(service.submitChord(service.binding(), old) == .read_only);
        var output: Output = .{};
        try T.expectEqual(@as(usize, 0), try service.pump(output.wire(if (barrier == 2) 2 else 1)));
        try T.expectEqual(@as(usize, 0), output.length);
        try T.expectEqual(@as(usize, 0), (try service.snapshot(service.binding())).queued);
        if (barrier == 0) {
            try service.setControl(true, 4);
            try T.expect(service.submitChord(service.binding(), old) == .stale_epoch);
        }
    }
}

test "BMC explicit input revoke or close between raw suffix writes aborts without old suffix or reconnect replay" {
    for ([_]bool{ false, true }) |close| {
        var service = remote.Service.init(owner);
        try ready(&service, false);
        const old = service.explicitChordCommand(1, try chord(&.{ 0xffe3, 0xffe9, 0xffff }));
        try T.expect(service.submitChord(service.binding(), old) == .accepted);
        var output: Output = .{ .chunk = 2, .service = &service, .trigger_write = 2, .action = if (close) .close else .revoke };
        try T.expectError(error.InputWriteInterrupted, service.pump(output.wire(1)));
        try T.expectEqual(@as(usize, 4), output.length);
        try T.expectEqual(@as(usize, 1), output.aborts);
        try T.expect((try service.snapshot(service.binding())).remote_unconfirmed);
        if (!close) {
            try service.setConnected(true, 2);
            try service.setControl(true, 4);
            try T.expect(service.submitChord(service.binding(), old) == .stale_epoch);
            try T.expectEqual(@as(usize, 0), try service.pump(output.wire(2)));
            try T.expectEqual(@as(usize, 4), output.length);
        }
    }
}

test "BMC explicit input revoke after complete in-flight down releases only actual sent keys" {
    var service = remote.Service.init(owner);
    try ready(&service, false);
    try explicit(&service, 1, &.{ 0xffe3, 0xffe9, 0xffff });
    var output: Output = .{ .service = &service, .trigger_write = 1, .action = .revoke };
    try T.expectEqual(@as(usize, 2), try service.pump(output.wire(1)));
    try expectChord(output.bytes(), &.{0xffe3});
    try T.expectEqual(@as(usize, 0), service.pressed_count);
    try T.expectEqual(@as(usize, 0), output.aborts);
}

fn startPipeline(pipeline: *video.Pipeline) !void {
    try pipeline.start(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
    var packet: [52]u8 = undefined;
    packet[0] = 0x82;
    packet[1] = 50;
    const hello = packet[2..];
    @memcpy(hello[0..12], "RFB 003.008\n");
    @memcpy(hello[12..26], &[_]u8{ 105, 1, 0, 99, 104, 0, 0, 0, 1, 1, 0, 0, 0, 0 });
    std.mem.writeInt(u16, hello[26..28], 1, .big);
    std.mem.writeInt(u16, hello[28..30], 1, .big);
    (video.rfb.raw.PixelFormat{}).write(hello[30..46]);
    std.mem.writeInt(u32, hello[46..50], 0, .big);
    _ = try pipeline.feed(&packet, 1);
    // Capture requires a published complete base, beyond ServerInit geometry.
    _ = try pipeline.feed(&.{ 0x82, 20, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 }, 1);
}

fn drainPipeline(pipeline: *video.Pipeline, output: *Output) !void {
    for (0..128) |_| {
        try pipeline.pump(output.videoWire());
        if (pipeline.count == 0 and pipeline.input_output == null and pipeline.remote_input.tx == null and pipeline.remote_input.active == null and (try pipeline.remote_input.snapshot(pipeline.remote_input.binding())).queued == 0) return;
    }
    return error.TestPipelineDidNotDrain;
}

fn unmaskKeyFrames(bytes: []const u8, result: []u8) !usize {
    var offset: usize = 0;
    var length: usize = 0;
    while (offset != bytes.len) {
        if (bytes.len - offset < 6 or bytes[offset] != 0x82 or bytes[offset + 1] != 0x88 or result.len - length < 8 or bytes.len - offset < 14) return error.InvalidTestInputFrame;
        for (0..8) |index| result[length + index] = bytes[offset + 6 + index] ^ bytes[offset + 2 + index % 4];
        offset += 14;
        length += 8;
    }
    return length;
}

test "BMC explicit input read-only video configuration denies real major control grant" {
    for ([_]bool{ false, true }) |read_only| {
        var budget = budgets.Budget.init(128 * 1024 * 1024);
        defer budget.deinit() catch unreachable;
        var framebuffer = frames.Service.init(T.allocator, owner, &budget);
        defer framebuffer.deinit() catch unreachable;
        var service = remote.Service.init(owner);
        var pipeline = try video.Pipeline.init(T.allocator, owner, 1, &framebuffer, &service, &budget);
        defer pipeline.deinit();
        pipeline.read_only_requested = read_only;
        try startPipeline(&pipeline);
        const state = try service.snapshot(service.binding());
        try T.expectEqual(!read_only, state.controlled);
        try T.expect(!state.focused);
        const result = service.submitChord(service.binding(), service.explicitChordCommand(1, try chord(&.{0xffbe})));
        try T.expect(if (read_only) result == .read_only else result == .accepted);
        var output: Output = .{};
        try T.expectEqual(@as(usize, if (read_only) 0 else 2), try service.pump(output.wire(1)));
    }
}

test "BMC explicit input short WebSocket writes survive focus barriers with intact ordered paired frames" {
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var framebuffer = frames.Service.init(T.allocator, owner, &budget);
    defer framebuffer.deinit() catch unreachable;
    var service = remote.Service.init(owner);
    var pipeline = try video.Pipeline.init(T.allocator, owner, 1, &framebuffer, &service, &budget);
    defer pipeline.deinit();
    try startPipeline(&pipeline);
    var output: Output = .{};
    try drainPipeline(&pipeline, &output);
    const start = output.length;
    service.setFocus(true);
    try explicit(&service, 1, &.{ 0xffe3, 0xffe9, 0xffff });
    output.chunk = 3;
    output.service = &service;
    output.trigger_write = output.writes + 1;
    try drainPipeline(&pipeline, &output);
    var raw: [48]u8 = undefined;
    try T.expectEqual(raw.len, try unmaskKeyFrames(output.bytes()[start..], &raw));
    try expectChord(&raw, &.{ 0xffe3, 0xffe9, 0xffff });
    try T.expectEqual(@as(usize, 0), output.aborts);
    try T.expectEqual(@as(usize, 0), service.pressed_count);
    try T.expect(!(try service.snapshot(service.binding())).focused);
}

test "BMC explicit input short WebSocket prefix aborts on revoke disconnect or close without mixing frames" {
    for (0..3) |barrier| {
        var budget = budgets.Budget.init(128 * 1024 * 1024);
        defer budget.deinit() catch unreachable;
        var framebuffer = frames.Service.init(T.allocator, owner, &budget);
        defer framebuffer.deinit() catch unreachable;
        var service = remote.Service.init(owner);
        var pipeline = try video.Pipeline.init(T.allocator, owner, 1, &framebuffer, &service, &budget);
        defer pipeline.deinit();
        try startPipeline(&pipeline);
        var output: Output = .{};
        try drainPipeline(&pipeline, &output);
        const start = output.length;
        try explicit(&service, 1, &.{ 0xffe3, 0xffe9, 0xffff });
        output.chunk = 3;
        output.service = &service;
        output.trigger_write = output.writes + 1;
        output.action = switch (barrier) {
            0 => .revoke,
            1 => .disconnect,
            else => .close,
        };
        try pipeline.pump(output.videoWire());
        try T.expectEqual(start + 3, output.length);
        try T.expectError(error.InputWriteInterrupted, pipeline.pump(output.videoWire()));
        try T.expectEqual(start + 3, output.length);
        try T.expectEqual(@as(usize, 1), output.aborts);
        try T.expect(pipeline.closed);
        try T.expect(!(try service.snapshot(service.binding())).connected);
    }
}
