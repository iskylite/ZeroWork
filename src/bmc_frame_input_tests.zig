const std = @import("std");
const identity = @import("host/identity.zig");
const budgets = @import("host/frame_budget.zig");
const frames = @import("host/frame_texture_sink.zig");
const framebuffer = @import("plugins/bmc_ikvm/framebuffer.zig");
const remote = @import("plugins/bmc_ikvm/remote_input.zig");
const a = std.testing.allocator;
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(7) };

const Graphics = struct {
    creates: u32 = 0,
    updates: usize = 0,
    releases: usize = 0,
    fail_create: bool = false,
    fail_update: bool = false,
    fn create(context: *anyopaque, _: u32, _: u32) !u32 {
        const self: *Graphics = @ptrCast(@alignCast(context));
        if (self.fail_create) return error.TestCreateFailed;
        self.creates += 1;
        return self.creates;
    }
    fn update(context: *anyopaque, _: u32, _: []const u8) !void {
        const self: *Graphics = @ptrCast(@alignCast(context));
        if (self.fail_update) return error.TestUploadFailed;
        self.updates += 1;
    }
    fn release(context: *anyopaque, _: u32) void {
        const self: *Graphics = @ptrCast(@alignCast(context));
        self.releases += 1;
    }
    fn backend(self: *Graphics) frames.Backend {
        return .{ .context = self, .create = create, .update = update, .release = release };
    }
};

fn acquire(service: *framebuffer.Service) !framebuffer.FrameLease {
    return switch (service.acquireLatest(service.binding(), 0)) {
        .frame => |lease| lease,
        else => error.TestFrameUnavailable,
    };
}

test "BMC default Frame.copy keeps the exact 32 MiB boundary and literals cannot bypass submit" {
    const length = budgets.default_frame_bytes;
    const pixels = try a.alloc(u8, length);
    defer a.free(pixels);
    @memset(pixels, 0);
    var exact = try frames.Frame.copy(a, owner, 1, 4096, 2048, pixels);
    exact.deinit();
    try std.testing.expectError(error.InvalidFrame, frames.Frame.copy(a, owner, 1, 4096, 2160, &.{}));
    try std.testing.expectError(error.InvalidFrame, frames.Frame.copy(a, owner, 0, 1, 1, &.{ 0, 0, 0, 255 }));
    var graphics: Graphics = .{};
    var sink = frames.Sink.init(owner, graphics.backend());
    defer sink.close() catch unreachable;
    var literal: frames.Frame = .{ .allocator = a, .owner = owner, .revision = 1, .width = 1, .height = 1, .rgba = try a.dupe(u8, &.{ 0, 0, 0, 255 }) };
    defer literal.deinit();
    try std.testing.expectError(error.InvalidFrame, sink.submit(literal));
    var malformed = try frames.Frame.copy(a, owner, 1, 1, 1, &.{ 0, 0, 0, 255 });
    defer malformed.deinit();
    malformed.width = 2;
    try std.testing.expectError(error.InvalidFrame, sink.submit(malformed));
    try std.testing.expectEqual(@as(usize, 0), graphics.updates);
}

test "BMC 4096x2160 requires explicit owner reservation and returns CPU GPU budgets on upload failure and close" {
    const length = budgets.kvm_frame_bytes;
    const pixels = try a.alloc(u8, length);
    defer a.free(pixels);
    @memset(pixels, 255);
    var denied = budgets.Budget.init(length - 1);
    try std.testing.expectError(error.FrameBudgetExceeded, frames.Frame.copyWithBudget(a, &denied, owner, 1, 4096, 2160, pixels));
    try std.testing.expectEqual(@as(usize, 0), denied.usedBytes());
    var budget = budgets.Budget.init(length * 2);
    var graphics: Graphics = .{ .fail_update = true };
    var sink = frames.Sink.initWithBudget(owner, graphics.backend(), &budget, .kvm);
    try sink.submit(try frames.Frame.copyWithBudget(a, &budget, owner, 1, 4096, 2160, pixels));
    try std.testing.expectEqual(length, budget.usedBytes());
    try std.testing.expectError(error.TestUploadFailed, sink.drain());
    try std.testing.expectEqual(@as(usize, 0), budget.usedBytes());
    try std.testing.expect(sink.texture == null);
    graphics.fail_update = false;
    try sink.submit(try frames.Frame.copyWithBudget(a, &budget, owner, 2, 4096, 2160, pixels));
    try std.testing.expect(try sink.drain());
    try std.testing.expectEqual(length, budget.usedBytes());
    try std.testing.expectEqual(@as(u32, 4096), sink.width);
    try sink.close();
    try std.testing.expectEqual(@as(usize, 0), budget.usedBytes());
    try std.testing.expectEqual(length * 2, budget.peakBytes());
    try budget.deinit();
}

test "BMC allocation failure releases reservation and a budgeted sink rejects unreserved or stale frames" {
    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var budget = budgets.Budget.init(128);
    try std.testing.expectError(error.OutOfMemory, frames.Frame.copyWithBudget(fixed.allocator(), &budget, owner, 1, 1, 1, &.{ 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(usize, 0), budget.usedBytes());
    var graphics: Graphics = .{};
    var sink = frames.Sink.initWithBudget(owner, graphics.backend(), &budget, .kvm);
    defer sink.close() catch unreachable;
    var plain = try frames.Frame.copy(a, owner, 1, 1, 1, &.{ 0, 0, 0, 0 });
    defer plain.deinit();
    try std.testing.expectError(error.InvalidFrameReservation, sink.submit(plain));
    var stale = try frames.Frame.copyWithBudget(a, &budget, try owner.nextGeneration(), 1, 1, 1, &.{ 0, 0, 0, 0 });
    try std.testing.expectError(error.StaleFrame, sink.submit(stale));
    stale.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.usedBytes());
    try sink.submit(try frames.Frame.copyForGeneration(a, &budget, owner, 1, 1, 1, 1, &.{ 0, 0, 0, 0 }));
    try sink.submit(try frames.Frame.copyForGeneration(a, &budget, owner, 2, 2, 1, 1, &.{ 0, 0, 0, 0 }));
    var full = try frames.Frame.copyForGeneration(a, &budget, owner, 3, 2, 1, 1, &.{ 0, 0, 0, 0 });
    try std.testing.expectError(error.FrameQueueFull, sink.submit(full));
    full.deinit();
    try std.testing.expectEqual(@as(usize, 8), budget.usedBytes());
    try std.testing.expect(try sink.drain());
    try std.testing.expectEqual(@as(usize, 1), graphics.updates);
    try std.testing.expectEqual(@as(u64, 2), sink.frame_generation);
    var old = try frames.Frame.copyForGeneration(a, &budget, owner, 99, 1, 1, 1, &.{ 0, 0, 0, 0 });
    try std.testing.expectError(error.StaleFrame, sink.submit(old));
    old.deinit();
    try sink.close();
    try std.testing.expectEqual(@as(usize, 0), budget.usedBytes());
}

test "BMC resize upload create failures keep the old GPU geometry and queued close returns every reservation" {
    var budget = budgets.Budget.init(128);
    var graphics: Graphics = .{};
    var sink = frames.Sink.initWithBudget(owner, graphics.backend(), &budget, .kvm);
    defer sink.close() catch unreachable;
    try sink.submit(try frames.Frame.copyForGeneration(a, &budget, owner, 1, 1, 1, 1, &.{ 1, 2, 3, 4 }));
    _ = try sink.drain();
    const old_texture = sink.texture;
    graphics.fail_update = true;
    try sink.submit(try frames.Frame.copyForGeneration(a, &budget, owner, 2, 2, 2, 1, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }));
    try std.testing.expectError(error.TestUploadFailed, sink.drain());
    try std.testing.expectEqual(old_texture, sink.texture);
    try std.testing.expectEqual(@as(u32, 1), sink.width);
    try std.testing.expectEqual(@as(u64, 1), sink.revision);
    try std.testing.expectEqual(@as(u64, 1), sink.frame_generation);
    try std.testing.expectEqual(@as(usize, 4), budget.usedBytes());
    graphics.fail_update = false;
    try sink.submit(try frames.Frame.copyForGeneration(a, &budget, owner, 3, 2, 2, 1, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }));
    _ = try sink.drain();
    try std.testing.expectEqual(@as(usize, 8), budget.usedBytes());
    graphics.fail_create = true;
    try sink.submit(try frames.Frame.copyForGeneration(a, &budget, owner, 4, 3, 3, 1, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }));
    try std.testing.expectError(error.TestCreateFailed, sink.drain());
    try std.testing.expectEqual(@as(u32, 2), sink.width);
    try std.testing.expectEqual(@as(u64, 3), sink.revision);
    try std.testing.expectEqual(@as(usize, 8), budget.usedBytes());
    try sink.submit(try frames.Frame.copyForGeneration(a, &budget, owner, 5, 3, 1, 1, &.{ 1, 2, 3, 4 }));
    try sink.close();
    try std.testing.expectEqual(@as(usize, 0), budget.usedBytes());
    var closed = try frames.Frame.copyWithBudget(a, &budget, owner, 6, 1, 1, &.{ 1, 2, 3, 4 });
    try std.testing.expectError(error.FrameSinkClosed, sink.submit(closed));
    closed.deinit();
    try std.testing.expectEqual(@as(usize, 0), budget.usedBytes());
}

test "BMC drain revalidates queued metadata and SPSC rejects a second producer" {
    var budget = budgets.Budget.init(128);
    var graphics: Graphics = .{};
    var sink = frames.Sink.initWithBudget(owner, graphics.backend(), &budget, .kvm);
    defer sink.close() catch unreachable;
    try sink.submit(try frames.Frame.copyWithBudget(a, &budget, owner, 1, 1, 1, &.{ 1, 2, 3, 4 }));
    sink.entries[0].rgba = sink.entries[0].rgba[0..3];
    try std.testing.expectError(error.InvalidFrame, sink.drain());
    try std.testing.expectEqual(@as(usize, 0), budget.usedBytes());
    var other = try frames.Frame.copyWithBudget(a, &budget, owner, 2, 1, 1, &.{ 1, 2, 3, 4 });
    defer other.deinit();
    const Worker = struct {
        fn run(target: *frames.Sink, frame: frames.Frame) void {
            std.testing.expectError(error.MultipleFrameProducers, target.submit(frame)) catch @panic("accepted second producer");
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &sink, other });
    thread.join();
}

test "BMC delta base remains continuous when the display queue fills; resize keeps sink revisions monotonic" {
    var budget = budgets.Budget.init(1024);
    var service = framebuffer.Service.init(a, owner, &budget);
    defer service.close() catch unreachable;
    var graphics: Graphics = .{};
    var sink = frames.Sink.initWithBudget(owner, graphics.backend(), &budget, .kvm);
    defer sink.close() catch unreachable;
    _ = try service.publishComplete(2, 1, &.{ 255, 0, 0, 255, 0, 0, 255, 255 }, 1);
    try std.testing.expect(try service.publishToSink(&sink));
    try service.beginUpdate();
    try service.applyRectangle(0, 0, 1, 1, &.{ 0, 255, 0, 255 }, 4);
    _ = try service.finishUpdate(2);
    try std.testing.expect(try service.publishToSink(&sink));
    try service.beginUpdate();
    try service.applyRectangle(1, 0, 1, 1, &.{ 255, 255, 255, 255 }, 4);
    _ = try service.finishUpdate(3);
    const before = budget.usedBytes();
    try std.testing.expect(!try service.publishToSink(&sink));
    try std.testing.expectEqual(before, budget.usedBytes());
    var lease = try acquire(&service);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255, 255, 255, 255, 255 }, lease.snapshot.pixels);
    lease.release();
    try std.testing.expect(try sink.drain());
    try std.testing.expect(try service.publishToSink(&sink));
    try std.testing.expect(try sink.drain());
    try std.testing.expectEqual(@as(u64, 3), sink.revision);
    _ = try sink.discardPending();
    const generation = try service.configure(1, 1);
    try std.testing.expectEqual(@as(u64, 2), generation);
    try std.testing.expectError(error.FullFrameRequired, service.beginUpdate());
    _ = try service.publishComplete(1, 1, &.{ 1, 2, 3, 255 }, 4);
    try std.testing.expect(try service.publishToSink(&sink));
    try std.testing.expect(try sink.drain());
    try std.testing.expectEqual(@as(u64, 4), sink.revision);
    try std.testing.expectEqual(@as(u64, 2), sink.frame_generation);
    try std.testing.expectEqual(@as(u32, 1), sink.width);
    try sink.close();
    try service.close();
    try std.testing.expectEqual(@as(usize, 0), budget.usedBytes());
}

test "BMC leases protect old pixels, rectangle reuse waits, and rejected resize preserves latest" {
    var budget = budgets.Budget.init(64);
    var service = framebuffer.Service.init(a, owner, &budget);
    defer service.close() catch unreachable;
    _ = try service.publishComplete(1, 1, &.{ 1, 2, 3, 4 }, 1);
    var old = try acquire(&service);
    try std.testing.expectError(error.FrameBorrowed, service.publishComplete(1, 1, &.{ 5, 6, 7, 8 }, 2));
    try std.testing.expectError(error.FrameBorrowed, service.configure(2, 1));
    try service.beginUpdate();
    try service.applyRectangle(0, 0, 1, 1, &.{ 5, 6, 7, 8 }, 4);
    _ = try service.finishUpdate(2);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, old.snapshot.pixels);
    try std.testing.expectError(error.FrameBorrowed, service.beginUpdate());
    old.release();
    old.release();
    try service.beginUpdate();
    try std.testing.expectError(error.InvalidRectangle, service.applyRectangle(1, 0, 1, 1, &.{ 0, 0, 0, 0 }, 4));
    service.abortUpdate();
    var latest = try acquire(&service);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8 }, latest.snapshot.pixels);
    try std.testing.expectError(error.FrameBorrowed, service.close());
    latest.release();
    try service.close();
    try std.testing.expectEqual(@as(usize, 0), budget.usedBytes());
    var small_budget = budgets.Budget.init(16);
    var small = framebuffer.Service.init(a, owner, &small_budget);
    defer small.close() catch unreachable;
    _ = try small.publishComplete(1, 1, &.{ 9, 9, 9, 9 }, 1);
    try std.testing.expectError(error.FrameBudgetExceeded, small.configure(2, 2));
    var kept = try acquire(&small);
    defer kept.release();
    try std.testing.expectEqual(@as(u32, 1), kept.snapshot.width);
    try std.testing.expectEqual(@as(u64, 1), kept.snapshot.frame_generation);
    kept.release();
    _ = try small.configure(2, 1);
    try std.testing.expectError(error.FrameBudgetExceeded, small.configure(4, 1));
    var after_pending_failure = try acquire(&small);
    try std.testing.expectEqual(@as(u32, 1), after_pending_failure.snapshot.width);
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9 }, after_pending_failure.snapshot.pixels);
    after_pending_failure.release();
    _ = try small.publishComplete(1, 1, &.{ 8, 8, 8, 8 }, 2);
    var stale = small.binding();
    stale.owner = try owner.nextGeneration();
    try std.testing.expect(small.acquireLatest(stale, 0) == .stale_binding);
}

test "BMC worker publishes complete frames while main borrows immutable leases" {
    var budget = budgets.Budget.init(128);
    var service = framebuffer.Service.init(a, owner, &budget);
    defer service.close() catch unreachable;
    _ = try service.publishComplete(2, 1, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, 1);
    const Worker = struct {
        fn run(target: *framebuffer.Service, done: *std.atomic.Value(bool)) void {
            for (1..2001) |value| {
                const byte: u8 = @truncate(value);
                const pixels: [8]u8 = @splat(byte);
                _ = target.publishComplete(2, 1, &pixels, value) catch |err| {
                    if (err == error.FrameBorrowed) continue;
                    @panic("unexpected publish failure");
                };
            }
            done.store(true, .release);
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &service, &done });
    var samples: usize = 0;
    while (!done.load(.acquire)) {
        var lease = try acquire(&service);
        for (lease.snapshot.pixels) |value| try std.testing.expectEqual(lease.snapshot.pixels[0], value);
        lease.release();
        samples += 1;
    }
    thread.join();
    try std.testing.expect(samples != 0);
}

const Output = struct {
    data: [16384]u8 = undefined,
    length: usize = 0,
    chunk: usize = 16384,
    blocked: bool = false,
    block_at: ?usize = null,
    aborts: usize = 0,
    release_service: ?*remote.Service = null,
    release_once: bool = false,
    fn write(context: *anyopaque, input: []const u8) !usize {
        const self: *Output = @ptrCast(@alignCast(context));
        if (self.blocked) return error.WouldBlock;
        if (self.block_at) |limit| if (self.length >= limit) return error.WouldBlock;
        const length = @min(input.len, self.chunk);
        if (self.length + length > self.data.len) return error.TestOutputFull;
        @memcpy(self.data[self.length..][0..length], input[0..length]);
        self.length += length;
        if (self.release_once) {
            self.release_once = false;
            const service = self.release_service.?;
            _ = service.releaseAll(service.binding(), .lost_focus);
        }
        return length;
    }
    fn abort(context: *anyopaque) void {
        const self: *Output = @ptrCast(@alignCast(context));
        self.aborts += 1;
    }
    fn wire(self: *Output, generation: u64) remote.Wire {
        return .{ .context = self, .generation = generation, .write = write, .abort = abort };
    }
    fn bytes(self: *const Output) []const u8 {
        return self.data[0..self.length];
    }
};
fn ready(service: *remote.Service) !void {
    try service.setConnected(true, 1);
    try service.setControl(true, 2);
    service.setFocus(true);
}
fn accepted(service: *remote.Service, sequence: u64, event: remote.Event) !void {
    const result = service.submit(service.binding(), service.command(sequence, event));
    try std.testing.expect(result == .accepted);
    try std.testing.expectEqual(sequence, result.accepted);
}

test "BMC pointer moves coalesce but button transitions preserve RFB order and masks" {
    var service = remote.Service.init(owner);
    try ready(&service);
    try accepted(&service, 1, .{ .pointer = .{ .x = 1, .y = 2, .buttons = 0 } });
    try accepted(&service, 2, .{ .pointer = .{ .x = 3, .y = 4, .buttons = 0 } });
    try accepted(&service, 3, .{ .pointer = .{ .x = 5, .y = 6, .buttons = 1 } });
    try accepted(&service, 4, .{ .pointer = .{ .x = 7, .y = 8, .buttons = 1 } });
    try accepted(&service, 5, .{ .pointer = .{ .x = 9, .y = 10, .buttons = 1 } });
    try accepted(&service, 6, .{ .pointer = .{ .x = 11, .y = 12, .buttons = 0 } });
    var output: Output = .{ .chunk = 2 };
    try std.testing.expectEqual(@as(usize, 4), try service.pump(output.wire(1)));
    try std.testing.expectEqualSlices(u8, &.{ 5, 0, 0, 3, 0, 4, 5, 1, 0, 5, 0, 6, 5, 1, 0, 9, 0, 10, 5, 0, 0, 11, 0, 12 }, output.bytes());
}

test "BMC mailbox 256 overflow pauses capture and priority release drops all old downs" {
    var service = remote.Service.init(owner);
    try ready(&service);
    var output: Output = .{};
    try accepted(&service, 1, .{ .key = .{ .keysym = 65, .down = true } });
    try accepted(&service, 2, .{ .pointer = .{ .x = 10, .y = 20, .buttons = 1 } });
    _ = try service.pump(output.wire(1));
    for (0..remote.Service.capacity) |index| try accepted(&service, index + 3, .{ .key = .{ .keysym = 66, .down = index % 2 == 0 } });
    const extra = service.command(259, .{ .key = .{ .keysym = 67, .down = true } });
    try std.testing.expect(service.submit(service.binding(), extra) == .queue_full);
    const state = try service.snapshot(service.binding());
    try std.testing.expect(state.capture_paused);
    try std.testing.expectEqual(@as(usize, 0), state.queued);
    const before = output.length;
    try std.testing.expectEqual(@as(usize, 2), try service.pump(output.wire(1)));
    try std.testing.expectEqualSlices(u8, &.{ 4, 0, 0, 0, 0, 0, 0, 65, 5, 0, 0, 10, 0, 20 }, output.bytes()[before..]);
    try std.testing.expectEqual(@as(usize, 0), try service.pump(output.wire(1)));
    try service.resumeCapture();
    try std.testing.expect(service.submit(service.binding(), extra) == .stale_epoch);
}

test "BMC partial input revoked between writes aborts transport and never replays old down on reconnect" {
    var service = remote.Service.init(owner);
    try ready(&service);
    try accepted(&service, 1, .{ .key = .{ .keysym = 65, .down = true } });
    try accepted(&service, 2, .{ .key = .{ .keysym = 66, .down = true } });
    var output: Output = .{ .chunk = 2, .release_service = &service, .release_once = true };
    try std.testing.expectError(error.InputWriteInterrupted, service.pump(output.wire(1)));
    try std.testing.expectEqual(@as(usize, 2), output.length);
    try std.testing.expectEqual(@as(usize, 1), output.aborts);
    try std.testing.expect((try service.snapshot(service.binding())).remote_unconfirmed);
    try service.setConnected(true, 2);
    try std.testing.expectEqual(@as(usize, 0), try service.pump(output.wire(2)));
    try std.testing.expect(service.submit(service.binding(), service.command(3, .{ .key = .{ .keysym = 67, .down = true } })) == .read_only);
    try service.setControl(true, 3);
    service.setFocus(true);
    try accepted(&service, 3, .{ .key = .{ .keysym = 67, .down = true } });
    const before = output.length;
    _ = try service.pump(output.wire(2));
    try std.testing.expectEqualSlices(u8, &.{ 4, 1, 0, 0, 0, 0, 0, 67 }, output.bytes()[before..]);
}

test "BMC release after a complete in-flight down emits its up and rejects old queued epoch" {
    var service = remote.Service.init(owner);
    try ready(&service);
    try accepted(&service, 1, .{ .key = .{ .keysym = 65, .down = true } });
    const old = service.command(2, .{ .key = .{ .keysym = 66, .down = true } });
    try std.testing.expect(service.submit(service.binding(), old) == .accepted);
    var output: Output = .{ .release_service = &service, .release_once = true };
    try std.testing.expectEqual(@as(usize, 2), try service.pump(output.wire(1)));
    try std.testing.expectEqualSlices(u8, &.{ 4, 1, 0, 0, 0, 0, 0, 65, 4, 0, 0, 0, 0, 0, 0, 65 }, output.bytes());
    try std.testing.expect(service.submit(service.binding(), old) == .stale_epoch);
    var stale_binding = service.binding();
    stale_binding.owner = try owner.nextGeneration();
    try std.testing.expect(service.releaseAll(stale_binding, .released) == .stale_binding);
}

test "BMC chords reverse release order and wheel pulses restore held buttons" {
    var service = remote.Service.init(owner);
    try ready(&service);
    const chord = try remote.Chord.init(&.{ 0xffe3, 0xffe9, 0xffff });
    try accepted(&service, 1, .{ .chord = chord });
    var output: Output = .{};
    try std.testing.expectEqual(@as(usize, 6), try service.pump(output.wire(1)));
    const expected_keys = [_]u32{ 0xffe3, 0xffe9, 0xffff, 0xffff, 0xffe9, 0xffe3 };
    for (expected_keys, 0..) |keysym, index| {
        const packet = output.bytes()[index * 8 ..][0..8];
        try std.testing.expectEqual(@as(u8, 4), packet[0]);
        try std.testing.expectEqual(@as(u8, @intFromBool(index < 3)), packet[1]);
        try std.testing.expectEqual(keysym, std.mem.readInt(u32, packet[4..8], .big));
    }
    try accepted(&service, 2, .{ .pointer = .{ .x = 100, .y = 200, .buttons = 1 } });
    try accepted(&service, 3, .{ .wheel = .{ .x = 100, .y = 200, .steps_y = 1, .steps_x = -1 } });
    const before = output.length;
    try std.testing.expectEqual(@as(usize, 5), try service.pump(output.wire(1)));
    for ([_]u8{ 1, 9, 1, 33, 1 }, 0..) |mask, index| {
        const packet = output.bytes()[before + index * 6 ..][0..6];
        try std.testing.expectEqualSlices(u8, &.{ 5, mask, 0, 100, 0, 200 }, packet);
    }
    _ = service.releaseAll(service.binding(), .released);
    const release_before = output.length;
    _ = try service.pump(output.wire(1));
    try std.testing.expectEqualSlices(u8, &.{ 5, 0, 0, 100, 0, 200 }, output.bytes()[release_before..]);
}

test "BMC blocked chord release uses actual sent keys in reverse order and never sends its pending Delete" {
    var service = remote.Service.init(owner);
    try ready(&service);
    try accepted(&service, 1, .{ .chord = try remote.Chord.init(&.{ 0xffe3, 0xffe9, 0xffff }) });
    var output: Output = .{ .block_at = 16 };
    try std.testing.expectEqual(@as(usize, 2), try service.pump(output.wire(1)));
    _ = service.releaseAll(service.binding(), .lost_focus);
    output.block_at = null;
    try std.testing.expectEqual(@as(usize, 2), try service.pump(output.wire(1)));
    try std.testing.expectEqual(@as(usize, 0), output.aborts);
    const expected_keys = [_]u32{ 0xffe3, 0xffe9, 0xffe9, 0xffe3 };
    try std.testing.expectEqual(@as(usize, 32), output.length);
    for (expected_keys, 0..) |keysym, index| {
        const packet = output.bytes()[index * 8 ..][0..8];
        try std.testing.expectEqual(@as(u8, @intFromBool(index < 2)), packet[1]);
        try std.testing.expectEqual(keysym, std.mem.readInt(u32, packet[4..8], .big));
    }
}

test "BMC main revoke races worker partial write without holding mailbox lock or sending old suffix" {
    var service = remote.Service.init(owner);
    try ready(&service);
    try accepted(&service, 1, .{ .key = .{ .keysym = 65, .down = true } });
    const Race = struct {
        entered: std.atomic.Value(bool) = .init(false),
        revoked: std.atomic.Value(bool) = .init(false),
        aborted: bool = false,
        sent: usize = 0,
        fn write(context: *anyopaque, _: []const u8) !usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.sent += 2;
            self.entered.store(true, .release);
            while (!self.revoked.load(.acquire)) std.atomic.spinLoopHint();
            return 2;
        }
        fn abort(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.aborted = true;
        }
        fn run(target: *remote.Service, race: *@This()) void {
            std.testing.expectError(error.InputWriteInterrupted, target.pump(.{ .context = race, .generation = 1, .write = write, .abort = abort })) catch @panic("race replayed input");
        }
    };
    var race: Race = .{};
    const thread = try std.Thread.spawn(.{}, Race.run, .{ &service, &race });
    while (!race.entered.load(.acquire)) std.atomic.spinLoopHint();
    try service.setControl(false, 3);
    race.revoked.store(true, .release);
    thread.join();
    try std.testing.expect(race.aborted);
    try std.testing.expectEqual(@as(usize, 2), race.sent);
    try std.testing.expect(service.submit(service.binding(), service.command(2, .{ .key = .{ .keysym = 66, .down = true } })) == .read_only);
}
