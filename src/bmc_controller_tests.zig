const std = @import("std");
const T = std.testing;
const a = T.allocator;
const console = @import("plugins/bmc_ikvm/controller.zig");
const video = @import("plugins/bmc_ikvm/video_pipeline.zig");
const management = @import("plugins/bmc_ikvm/management_adapter.zig");
const frame = @import("plugins/bmc_ikvm/framebuffer.zig");
const input = @import("plugins/bmc_ikvm/remote_input.zig");
const budgets = @import("host/frame_budget.zig");
const svc = @import("plugins/bmc_ikvm/services.zig");
const profile = @import("plugins/bmc_ikvm/protocol/profile.zig");
const ledger = @import("plugins/bmc_ikvm/management_journal.zig");
const actions = @import("host/resource_actions.zig");
const owner: svc.identity.SessionHandle = .{ .session_id = @fromBackingInt(715) };
const key: svc.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 11 };

test {
    T.refAllDecls(console);
    T.refAllDecls(video);
    T.refAllDecls(management);
}

const Wire = struct {
    bytes: std.ArrayList(u8) = .empty,
    max_write: usize = 65536,
    aborted: bool = false,
    fn write(raw: *anyopaque, bytes: []const u8) !usize {
        const self: *Wire = @ptrCast(@alignCast(raw));
        if (self.aborted) return error.Closed;
        const n = @min(self.max_write, bytes.len);
        try self.bytes.appendSlice(a, bytes[0..n]);
        return n;
    }
    fn abort(raw: *anyopaque) void {
        const self: *Wire = @ptrCast(@alignCast(raw));
        self.aborted = true;
    }
    fn wire(self: *Wire) video.Wire {
        return .{ .context = self, .write = write, .abort = abort };
    }
    fn deinit(self: *Wire) void {
        self.bytes.deinit(a);
    }
};
fn append16(bytes: *std.ArrayList(u8), value: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, value, .big);
    try bytes.appendSlice(a, &b);
}
fn append32(bytes: *std.ArrayList(u8), value: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, value, .big);
    try bytes.appendSlice(a, &b);
}
fn handshake(width: u16, height: u16) !std.ArrayList(u8) {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    try bytes.appendSlice(a, "RFB 003.008\n");
    try bytes.appendSlice(a, &.{ 105, 1, 0, 99, 104, 0, 0, 0, 1, 1, 0, 0, 0, 0 });
    try append16(&bytes, width);
    try append16(&bytes, height);
    var format: [16]u8 = undefined;
    (video.rfb.raw.PixelFormat{}).write(&format);
    try bytes.appendSlice(a, &format);
    try append32(&bytes, 0);
    return bytes;
}
fn rectangle(bytes: *std.ArrayList(u8), width: u16, height: u16, encoding: i32) !void {
    try append16(bytes, 0);
    try append16(bytes, 0);
    try append16(bytes, width);
    try append16(bytes, height);
    try append32(bytes, @bitCast(encoding));
}
fn rawUpdate(width: u16, height: u16, colour: [4]u8) !std.ArrayList(u8) {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    try bytes.appendSlice(a, &.{ 0, 0, 0, 1 });
    try rectangle(&bytes, width, height, 0);
    for (0..@as(usize, width) * height) |_| try bytes.appendSlice(a, &colour);
    return bytes;
}
fn feedBinary(pipeline: *video.Pipeline, payload: []const u8, split: usize) !void {
    // Real unmasked server frames; payload is split across WS message boundaries
    // independently of every RFB message, then transport is split again.
    var offset: usize = 0;
    while (offset < payload.len) {
        const n = @min(split, payload.len - offset, 125);
        var packet: [127]u8 = undefined;
        packet[0] = 0x82;
        packet[1] = @intCast(n);
        @memcpy(packet[2..][0..n], payload[offset..][0..n]);
        for (packet[0 .. n + 2]) |byte| try T.expectEqual(@as(usize, 1), try pipeline.feed(&.{byte}, 200));
        offset += n;
    }
}
const Unmasked = struct { opcode: u8, payload: []u8 };
fn nextClient(bytes: []const u8, offset: *usize) !Unmasked {
    if (offset.* + 6 > bytes.len) return error.TruncatedClientFrame;
    const start = offset.*;
    if (bytes[start + 1] & 128 == 0) return error.UnmaskedClientFrame;
    const n: usize = bytes[start + 1] & 127;
    if (n >= 126 or start + n + 6 > bytes.len) return error.InvalidClientFrame;
    const payload = try a.alloc(u8, n);
    for (payload, 0..) |*v, i| v.* = bytes[start + 6 + i] ^ bytes[start + 2 + i % 4];
    offset.* += n + 6;
    return .{ .opcode = bytes[start] & 15, .payload = payload };
}

test "BMC console real WS fragments publish first frame, resize and OEM grant/revoke" {
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var framebuffer = frame.Service.init(a, owner, &budget);
    defer framebuffer.deinit() catch unreachable;
    var remote_input = input.Service.init(owner);
    var pipeline = try video.Pipeline.init(a, owner, 1, &framebuffer, &remote_input, &budget);
    defer pipeline.deinit();
    try pipeline.start(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
    var hello = try handshake(2, 1);
    defer hello.deinit(a);
    try feedBinary(&pipeline, hello.items, 3);
    try T.expect((try remote_input.snapshot(remote_input.binding())).controlled);
    var image = try rawUpdate(2, 1, .{ 3, 2, 1, 0 });
    defer image.deinit(a);
    try feedBinary(&pipeline, image.items, 5);
    remote_input.setFocus(true);
    var lease = framebuffer.acquireLatest(framebuffer.binding(), 0).frame;
    try T.expectEqual(@as(u64, 1), lease.snapshot.frame_generation);
    try T.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 1, 2, 3, 255 }, lease.snapshot.pixels);
    lease.release();
    const before = try remote_input.snapshot(remote_input.binding());
    const command = remote_input.command(1, .{ .key = .{ .keysym = 'a', .down = true } });
    try T.expect(remote_input.submit(remote_input.binding(), command) == .accepted);
    var wire: Wire = .{};
    defer wire.deinit();
    try pipeline.pump(wire.wire());
    try feedBinary(&pipeline, &.{ 106, 0, 0, 99 }, 1);
    const revoked = try remote_input.snapshot(remote_input.binding());
    try T.expect(!revoked.controlled and revoked.input_epoch > before.input_epoch);
    try T.expect(remote_input.submit(remote_input.binding(), command) == .read_only);
    try pipeline.pump(wire.wire());
    var output_offset: usize = 0;
    var downs: usize = 0;
    var ups: usize = 0;
    while (output_offset < wire.bytes.items.len) {
        const output = try nextClient(wire.bytes.items, &output_offset);
        defer a.free(output.payload);
        if (output.payload.len == 8 and output.payload[0] == 4) {
            if (output.payload[1] == 1) downs += 1 else ups += 1;
        }
    }
    try T.expectEqual(@as(usize, 1), downs);
    try T.expectEqual(@as(usize, 1), ups);
    var resized: std.ArrayList(u8) = .empty;
    defer resized.deinit(a);
    try resized.appendSlice(a, &.{ 0, 0, 0, 1 });
    try rectangle(&resized, 1, 1, -223);
    try feedBinary(&pipeline, resized.items, 2);
    var old = framebuffer.acquireLatest(framebuffer.binding(), 0).frame;
    try T.expectEqual(@as(u32, 2), old.snapshot.width);
    old.release();
    var smaller = try rawUpdate(1, 1, .{ 6, 5, 4, 0 });
    defer smaller.deinit(a);
    try feedBinary(&pipeline, smaller.items, 1);
    var latest = framebuffer.acquireLatest(framebuffer.binding(), 0).frame;
    try T.expectEqual(@as(u32, 1), latest.snapshot.width);
    try T.expectEqual(@as(u64, 2), latest.snapshot.frame_generation);
    latest.release();
}

test "BMC console WS ping is a masked pong and never reaches RFB" {
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var framebuffer = frame.Service.init(a, owner, &budget);
    defer framebuffer.deinit() catch unreachable;
    var remote_input = input.Service.init(owner);
    var pipeline = try video.Pipeline.init(a, owner, 1, &framebuffer, &remote_input, &budget);
    defer pipeline.deinit();
    try pipeline.start(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
    _ = try pipeline.feed(&.{ 0x89, 3, 0, 255, 1 }, 0);
    try T.expectEqual(video.rfb.Phase.version, pipeline.decoder.phase);
    try T.expectEqual(@as(usize, 0), pipeline.decoder.bufferedBytes());
    var wire: Wire = .{ .max_write = 1 };
    defer wire.deinit();
    while (pipeline.count != 0) try pipeline.pump(wire.wire());
    var offset: usize = 0;
    const preamble = try nextClient(wire.bytes.items, &offset);
    defer a.free(preamble.payload);
    try T.expectEqualStrings("KVM ", preamble.payload);
    const pong = try nextClient(wire.bytes.items, &offset);
    defer a.free(pong.payload);
    try T.expectEqual(@as(u8, 10), pong.opcode);
    try T.expectEqualSlices(u8, &.{ 0, 255, 1 }, pong.payload);
}

test "BMC console control requests expire on the worker without granting or replying automatically" {
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var framebuffer = frame.Service.init(a, owner, &budget);
    defer framebuffer.deinit() catch unreachable;
    var remote_input = input.Service.init(owner);
    var pipeline = try video.Pipeline.init(a, owner, 1, &framebuffer, &remote_input, &budget);
    defer pipeline.deinit();
    try pipeline.start(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
    var hello = try handshake(1, 1);
    defer hello.deinit(a);
    try feedBinary(&pipeline, hello.items, 7);
    try feedBinary(&pipeline, &.{ 106, 0, 0, 99 }, 4);
    var wire: Wire = .{};
    defer wire.deinit();
    try pipeline.pump(wire.wire());
    wire.bytes.clearRetainingCapacity();

    try pipeline.requestControl();
    try pipeline.pump(wire.wire());
    var offset: usize = 0;
    const requested = try nextClient(wire.bytes.items, &offset);
    defer a.free(requested.payload);
    try T.expectEqualSlices(u8, &.{109}, requested.payload);
    try T.expectEqual(wire.bytes.items.len, offset);
    try T.expect(!(try remote_input.snapshot(remote_input.binding())).controlled);
    wire.bytes.clearRetainingCapacity();

    const first_ns = std.time.ns_per_s;
    _ = try pipeline.feed(&.{ 0x82, 4, 107, 0, 9, 10 }, first_ns);
    try T.expectEqualSlices(u8, &.{ 107, 0, 9, 10 }, &pipeline.control_request.?);
    try pipeline.pump(wire.wire());
    try T.expectEqual(@as(usize, 0), wire.bytes.items.len);
    pipeline.expireControlRequest(first_ns + 29 * std.time.ns_per_s);
    try T.expect(pipeline.control_request != null);

    // A later request has its own complete context and deadline. Expiring the
    // earlier one cannot retire or answer this new server notification.
    const second_ns = first_ns + 20 * std.time.ns_per_s;
    _ = try pipeline.feed(&.{ 0x82, 4, 107, 0, 11, 12 }, second_ns);
    pipeline.expireControlRequest(first_ns + 30 * std.time.ns_per_s);
    try T.expectEqualSlices(u8, &.{ 107, 0, 11, 12 }, &pipeline.control_request.?);
    try T.expectError(error.StaleControlRequest, pipeline.replyControl(.{ 107, 0, 9, 10 }, .full_control));
    pipeline.expireControlRequest(second_ns + 30 * std.time.ns_per_s);
    try T.expect(pipeline.control_request == null);
    try T.expectError(error.NoControlRequest, pipeline.replyControl(.{ 107, 0, 11, 12 }, .full_control));
    try pipeline.pump(wire.wire());
    try T.expectEqual(@as(usize, 0), wire.bytes.items.len);
    try T.expect(!(try remote_input.snapshot(remote_input.binding())).controlled);

    _ = try pipeline.feed(&.{ 0x82, 4, 107, 0, 13, 14 }, second_ns + 31 * std.time.ns_per_s);
    try pipeline.replyControl(.{ 107, 0, 13, 14 }, .video_only);
    try pipeline.pump(wire.wire());
    offset = 0;
    const replied = try nextClient(wire.bytes.items, &offset);
    defer a.free(replied.payload);
    try T.expectEqualSlices(u8, &.{ 108, 0, 13, 14 }, replied.payload);
    try T.expectEqual(wire.bytes.items.len, offset);
    try T.expect(pipeline.control_request == null);
    try T.expect(!(try remote_input.snapshot(remote_input.binding())).controlled);
    _ = try pipeline.feed(&.{ 0x82, 4, 107, 0, 15, 16 }, second_ns + 32 * std.time.ns_per_s);
    pipeline.stop();
    try T.expect(pipeline.control_request == null and pipeline.decoder.pending_control_request == null);
}

test "BMC console DesktopSize rejects recapture until a complete geometry is published" {
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var framebuffer = frame.Service.init(a, owner, &budget);
    defer framebuffer.deinit() catch unreachable;
    var remote_input = input.Service.init(owner);
    var pipeline = try video.Pipeline.init(a, owner, 1, &framebuffer, &remote_input, &budget);
    defer pipeline.deinit();
    try pipeline.start(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
    var hello = try handshake(1, 1);
    defer hello.deinit(a);
    try feedBinary(&pipeline, hello.items, 7);
    var image = try rawUpdate(1, 1, .{ 3, 2, 1, 0 });
    defer image.deinit(a);
    try feedBinary(&pipeline, image.items, 3);
    var wire: Wire = .{};
    defer wire.deinit();
    try pipeline.pump(wire.wire());
    wire.bytes.clearRetainingCapacity();
    remote_input.setFocus(true);
    const initial = try remote_input.snapshot(remote_input.binding());
    try T.expect(initial.focused and !initial.geometry_pending);
    try T.expectEqual(@as(u64, 1), initial.geometry_generation);

    var resize: std.ArrayList(u8) = .empty;
    defer resize.deinit(a);
    try resize.appendSlice(a, &.{ 0, 0, 0, 1 });
    try rectangle(&resize, 2, 1, -223);
    try feedBinary(&pipeline, resize.items, 2);
    // Drain the required full-frame protocol request, then measure only input.
    try pipeline.pump(wire.wire());
    wire.bytes.clearRetainingCapacity();
    remote_input.setFocus(true); // A second click still points at the old image.
    const pending = try remote_input.snapshot(remote_input.binding());
    try T.expect(pending.controlled and pending.geometry_pending and !pending.focused and pending.capture_paused);
    try T.expectEqual(initial.geometry_generation, pending.geometry_generation);
    try T.expect(remote_input.submit(remote_input.binding(), remote_input.command(1, .{ .pointer = .{ .x = 0, .y = 0, .buttons = 1 } })) == .not_focused);
    try T.expectError(error.InputUnavailable, remote_input.resumeCapture());
    try pipeline.pump(wire.wire());
    try T.expectEqual(@as(usize, 0), wire.bytes.items.len);

    // A complete decoded frame still cannot release the gate if publication
    // is blocked by a renderer lease on the previous geometry.
    var old = framebuffer.acquireLatest(framebuffer.binding(), 0).frame;
    var larger = try rawUpdate(2, 1, .{ 6, 5, 4, 0 });
    defer larger.deinit(a);
    try feedBinary(&pipeline, larger.items, 3);
    try T.expect((try remote_input.snapshot(remote_input.binding())).geometry_pending);
    try T.expectEqual(@as(u32, 1), old.snapshot.width);
    old.release();
    try feedBinary(&pipeline, larger.items, 3);
    const published = try remote_input.snapshot(remote_input.binding());
    try T.expect(!published.geometry_pending and !published.focused and published.controlled);
    try T.expectEqual(@as(u64, 2), published.geometry_generation);
    var latest = framebuffer.acquireLatest(framebuffer.binding(), 0).frame;
    try T.expectEqual(published.geometry_generation, latest.snapshot.frame_generation);
    latest.release();
    try pipeline.pump(wire.wire());
    wire.bytes.clearRetainingCapacity();
    remote_input.setFocus(true);
    var stale_geometry = remote_input.command(2, .{ .pointer = .{ .x = 0, .y = 0, .buttons = 0 } });
    stale_geometry.geometry_generation = initial.geometry_generation;
    try T.expect(remote_input.submit(remote_input.binding(), stale_geometry) == .stale_epoch);
    try T.expect(remote_input.submit(remote_input.binding(), remote_input.command(2, .{ .pointer = .{ .x = 1, .y = 0, .buttons = 0 } })) == .accepted);
    try pipeline.pump(wire.wire());
    var offset: usize = 0;
    const pointer = try nextClient(wire.bytes.items, &offset);
    defer a.free(pointer.payload);
    try T.expectEqualSlices(u8, &.{ 5, 0, 0, 1, 0, 0 }, pointer.payload);
    try T.expectEqual(wire.bytes.items.len, offset);

    // Even a same-size DesktopSize has a new displayed generation; matching
    // dimensions cannot accidentally authorize the previous uploaded texture.
    try feedBinary(&pipeline, resize.items, 2);
    try feedBinary(&pipeline, larger.items, 3);
    try T.expectEqual(@as(u64, 3), (try remote_input.snapshot(remote_input.binding())).geometry_generation);
}

test "BMC console revocation after physical WS short write aborts before old key suffix" {
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var framebuffer = frame.Service.init(a, owner, &budget);
    defer framebuffer.deinit() catch unreachable;
    var remote_input = input.Service.init(owner);
    var pipeline = try video.Pipeline.init(a, owner, 1, &framebuffer, &remote_input, &budget);
    defer pipeline.deinit();
    try pipeline.start(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
    var hello = try handshake(1, 1);
    defer hello.deinit(a);
    try feedBinary(&pipeline, hello.items, 7);
    var image = try rawUpdate(1, 1, .{ 3, 2, 1, 0 });
    defer image.deinit(a);
    try feedBinary(&pipeline, image.items, 3);
    remote_input.setFocus(true);
    var wire: Wire = .{};
    defer wire.deinit();
    try pipeline.pump(wire.wire());
    wire.bytes.clearRetainingCapacity();
    wire.max_write = 1;
    try T.expect(remote_input.submit(remote_input.binding(), remote_input.command(1, .{ .key = .{ .keysym = 'x', .down = true } })) == .accepted);
    try pipeline.pump(wire.wire());
    try T.expectEqual(@as(usize, 1), wire.bytes.items.len);
    try feedBinary(&pipeline, &.{ 106, 0, 0, 99 }, 2);
    try T.expectError(error.InputWriteInterrupted, pipeline.pump(wire.wire()));
    try T.expect(wire.aborted);
    try T.expectEqual(@as(usize, 1), wire.bytes.items.len);
    try T.expect(!(try remote_input.snapshot(remote_input.binding())).connected);
}

fn identityFixture() profile.Identity {
    return .{ .trusted_channel = true, .manufacturer = "Sugon", .product = "SuperPod", .processor_vendor = "Hygon", .bmc_chip = "AST2600-A3", .firmware = "1.80", .oem_namespace = "Public", .kvm_login_resource = profile.kvm_login_path, .oem_rfb = true };
}
const WorkerFixture = struct {
    began: std.atomic.Value(bool) = .init(false),
    begin_release: std.atomic.Value(bool) = .init(false),
    cleanups: std.atomic.Value(usize) = .init(0),
    read_hold: std.atomic.Value(bool) = .init(false),
    read_blocked: std.atomic.Value(bool) = .init(false),
    sent_key_ups: std.atomic.Value(usize) = .init(0),
    sent_button_releases: std.atomic.Value(usize) = .init(0),
    waits_with_inbound: std.atomic.Value(usize) = .init(0),
    delayed_ms_with_inbound: std.atomic.Value(u64) = .init(0),
    cancel_io: ?*const std.atomic.Value(bool) = null,
    creator: std.Thread.Id,
    inbound: []const u8 = &.{},
    read_offset: usize = 0,
    fn begin(raw: *anyopaque, _: *const console.model.Payload, plan: *const console.route.Plan, operation: svc.OperationKey, _: *const std.atomic.Value(bool)) !video.rfb.Authenticated {
        const self: *WorkerFixture = @ptrCast(@alignCast(raw));
        try T.expect(std.Thread.getCurrentId() != self.creator);
        try T.expect(plan.owner.eql(owner));
        try T.expect(operation.eql(key));
        self.began.store(true, .release);
        while (!self.begin_release.load(.acquire)) std.atomic.spinLoopHint();
        return .{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true };
    }
    fn read(raw: *anyopaque, bytes: []u8) !usize {
        const self: *WorkerFixture = @ptrCast(@alignCast(raw));
        if (self.read_hold.load(.acquire)) {
            self.read_blocked.store(true, .release);
            while (self.read_hold.load(.acquire)) std.atomic.spinLoopHint();
        }
        if (self.read_offset == self.inbound.len) return error.WouldBlock;
        const n = @min(bytes.len, self.inbound.len - self.read_offset);
        @memcpy(bytes[0..n], self.inbound[self.read_offset..][0..n]);
        self.read_offset += n;
        return n;
    }
    fn write(raw: *anyopaque, bytes: []const u8) !usize {
        const self: *WorkerFixture = @ptrCast(@alignCast(raw));
        if (self.cancel_io) |cancel| if (cancel.load(.acquire)) return error.Cancelled;
        // This fixture accepts complete masked client frames without short
        // writes. Count actual releases, never submissions or local clears.
        if (bytes.len == 14 and bytes[1] & 127 == 8 and bytes[6] ^ bytes[2] == 4 and bytes[7] ^ bytes[3] == 0) _ = self.sent_key_ups.fetchAdd(1, .acq_rel);
        if (bytes.len == 12 and bytes[1] & 127 == 6 and bytes[6] ^ bytes[2] == 5 and bytes[7] ^ bytes[3] == 0) _ = self.sent_button_releases.fetchAdd(1, .acq_rel);
        return bytes.len;
    }
    fn abort(_: *anyopaque) void {}
    fn cleanup(raw: *anyopaque) console.Cleanup {
        const self: *WorkerFixture = @ptrCast(@alignCast(raw));
        _ = self.cleanups.fetchAdd(1, .acq_rel);
        return .released;
    }
    fn wait(raw: *anyopaque, milliseconds: u32) void {
        const self: *WorkerFixture = @ptrCast(@alignCast(raw));
        if (self.read_offset < self.inbound.len) {
            _ = self.waits_with_inbound.fetchAdd(1, .acq_rel);
            _ = self.delayed_ms_with_inbound.fetchAdd(milliseconds, .acq_rel);
        }
        std.atomic.spinLoopHint();
    }
    fn now(_: *anyopaque) u64 {
        return 1;
    }
    fn driver(self: *WorkerFixture) console.Driver {
        return .{ .context = self, .begin = begin, .read = read, .write = write, .abort = abort, .cleanup = cleanup, .wait = wait, .now_ns = now };
    }
};

fn appendServerBinary(bytes: *std.ArrayList(u8), payload: []const u8) !void {
    if (payload.len < 126) {
        try bytes.appendSlice(a, &.{ 0x82, @intCast(payload.len) });
    } else if (payload.len <= 65535) {
        try bytes.appendSlice(a, &.{ 0x82, 126 });
        try append16(bytes, @intCast(payload.len));
    } else {
        try bytes.appendSlice(a, &.{ 0x82, 127 });
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(payload.len), .big);
        try bytes.appendSlice(a, &length);
    }
    try bytes.appendSlice(a, payload);
}

test "BMC controller drains multi-record video without a sleep per 16KiB" {
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    const controller = try console.Controller.create(a, owner, key, .{ .endpoint = .{ .host = "bmc.invalid" }, .username = "operator" }, null, &budget, &journal, null);
    var hello = try handshake(256, 256);
    defer hello.deinit(a);
    var image = try rawUpdate(256, 256, .{ 3, 2, 1, 0 });
    defer image.deinit(a);
    var packet: std.ArrayList(u8) = .empty;
    defer packet.deinit(a);
    try appendServerBinary(&packet, hello.items);
    try appendServerBinary(&packet, image.items);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fixture", &digest, .{});
    const selected = try profile.syntheticForTest(identityFixture(), .{ .firmware = "1.80", .identity_fixture_sha256 = @splat(1), .public_key_pem = "fixture", .public_key_sha256 = digest, .public_key_source = "fixture", .web_login_schema_verified = true, .kvm_login_schema_verified = true, .ws_subprotocol_echo_verified = true, .oem_handshake_verified = true, .web_logout = .own_session_location, .kvm_logout = .own_session_location });
    var fixture: WorkerFixture = .{ .creator = std.Thread.getCurrentId(), .inbound = packet.items };
    defer {
        controller.cancel();
        while (!controller.poll().worker_exited) std.atomic.spinLoopHint();
        controller.deinit() catch unreachable;
    }
    fixture.begin_release.store(true, .release);
    try controller.startSynthetic(selected, fixture.driver());
    while (controller.poll().published_frames == 0 and !controller.poll().worker_exited) std.atomic.spinLoopHint();
    try T.expectEqual(@as(u64, 1), controller.poll().published_frames);
    // The complete update spans 17 transport reads. A ready record must not be
    // penalized by the idle backoff between those reads (formerly 160ms).
    try T.expectEqual(@as(u64, 0), fixture.delayed_ms_with_inbound.load(.acquire));
    try T.expectEqual(@as(usize, 0), fixture.waits_with_inbound.load(.acquire));
    const measured = controller.poll().performance;
    try T.expectEqual(@as(u64, packet.items.len), measured.read_bytes);
    try T.expect(measured.read_calls >= 17);
    try T.expect(measured.active_yields >= 1);
}

const ShortWriteSchedulingFixture = struct {
    worker: WorkerFixture,
    controller: *console.Controller,
    input_submitted: bool = false,
    pending_input_delay_ms: std.atomic.Value(u64) = .init(0),
    idle_waits: std.atomic.Value(usize) = .init(0),
    fn cast(raw: *anyopaque) *ShortWriteSchedulingFixture {
        return @ptrCast(@alignCast(raw));
    }
    fn begin(raw: *anyopaque, payload: *const console.model.Payload, plan: *const console.route.Plan, operation: svc.OperationKey, cancel: *const std.atomic.Value(bool)) !video.rfb.Authenticated {
        return WorkerFixture.begin(&cast(raw).worker, payload, plan, operation, cancel);
    }
    fn read(raw: *anyopaque, bytes: []u8) !usize {
        const self = cast(raw);
        if (self.worker.read_offset == self.worker.inbound.len and !self.input_submitted) {
            self.controller.remote_input.setFocus(true);
            const binding = self.controller.inputBinding();
            try T.expect(self.controller.remote_input.submit(binding, self.controller.remote_input.command(1, .{ .key = .{ .keysym = 'a', .down = true } })) == .accepted);
            self.input_submitted = true;
        }
        return WorkerFixture.read(&self.worker, bytes);
    }
    fn write(_: *anyopaque, bytes: []const u8) !usize {
        // A valid TLS short write must be retried promptly even when the
        // remote desktop is static and no video bytes are arriving.
        return @min(@as(usize, 1), bytes.len);
    }
    fn abort(raw: *anyopaque) void {
        WorkerFixture.abort(&cast(raw).worker);
    }
    fn cleanup(raw: *anyopaque) console.Cleanup {
        return WorkerFixture.cleanup(&cast(raw).worker);
    }
    fn wait(raw: *anyopaque, milliseconds: u32) void {
        const self = cast(raw);
        if (self.input_submitted and self.controller.poll().input.last_sent_input_sequence == 0) {
            _ = self.pending_input_delay_ms.fetchAdd(milliseconds, .acq_rel);
        } else if (self.input_submitted) {
            _ = self.idle_waits.fetchAdd(1, .acq_rel);
        }
        WorkerFixture.wait(&self.worker, milliseconds);
    }
    fn driver(self: *ShortWriteSchedulingFixture) console.Driver {
        return .{ .context = self, .begin = begin, .read = read, .write = write, .abort = abort, .cleanup = cleanup, .wait = wait, .now_ns = WorkerFixture.now };
    }
};

test "BMC controller drains positive input short writes then backs off when idle" {
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    const controller = try console.Controller.create(a, owner, key, .{ .endpoint = .{ .host = "bmc.invalid" }, .username = "operator" }, null, &budget, &journal, null);
    var bytes = try handshake(1, 1);
    defer bytes.deinit(a);
    var image = try rawUpdate(1, 1, .{ 3, 2, 1, 0 });
    defer image.deinit(a);
    try bytes.appendSlice(a, image.items);
    var packet: std.ArrayList(u8) = .empty;
    defer packet.deinit(a);
    try appendServerBinary(&packet, bytes.items);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fixture", &digest, .{});
    const selected = try profile.syntheticForTest(identityFixture(), .{ .firmware = "1.80", .identity_fixture_sha256 = @splat(1), .public_key_pem = "fixture", .public_key_sha256 = digest, .public_key_source = "fixture", .web_login_schema_verified = true, .kvm_login_schema_verified = true, .ws_subprotocol_echo_verified = true, .oem_handshake_verified = true, .web_logout = .own_session_location, .kvm_logout = .own_session_location });
    var fixture: ShortWriteSchedulingFixture = .{ .worker = .{ .creator = std.Thread.getCurrentId(), .inbound = packet.items }, .controller = controller };
    defer {
        controller.cancel();
        while (!controller.poll().worker_exited) std.atomic.spinLoopHint();
        controller.deinit() catch unreachable;
    }
    fixture.worker.begin_release.store(true, .release);
    try controller.startSynthetic(selected, fixture.driver());
    while (fixture.idle_waits.load(.acquire) == 0 and !controller.poll().worker_exited) std.atomic.spinLoopHint();
    const state = controller.poll();
    try T.expect(state.failure == null);
    try T.expectEqual(@as(u64, 1), state.input.last_sent_input_sequence);
    try T.expectEqual(@as(u64, 0), fixture.pending_input_delay_ms.load(.acquire));
    try T.expect(state.performance.written_bytes > 14);
    try T.expect(state.performance.idle_waits > 0);
    try T.expectEqual(state.performance.idle_waits * 2, state.performance.idle_wait_ms);
}

test "BMC controller freezes config and unsupported production identity acquires no network" {
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    var host = "bmc.invalid".*;
    const controller = try console.Controller.create(a, owner, key, .{ .endpoint = .{ .host = &host }, .username = "operator" }, null, &budget, &journal, null);
    defer controller.deinit() catch unreachable;
    host[0] = 'X';
    try T.expectEqualStrings("bmc.invalid", controller.config.value.endpoint.host);
    try T.expectEqualStrings("bmc.invalid", controller.plan.destination.host);
    var fixture: WorkerFixture = .{ .creator = std.Thread.getCurrentId() };
    var unsupported_identity = identityFixture();
    unsupported_identity.firmware = "1.81";
    try T.expectError(error.UnsupportedProfile, controller.start(unsupported_identity, fixture.driver()));
    try T.expect(!fixture.began.load(.acquire));
    try T.expectEqual(error.UnsupportedProfile, controller.poll().failure.?);
    const binding = controller.framebufferBinding();
    _ = try binding.borrow(frame.Interface, frame.key, owner);
    _ = try controller.inputBinding().borrow(input.Interface, input.key, owner);
    _ = try controller.powerBinding().borrow(svc.PowerService, svc.power_key, owner);
    _ = try controller.bootBinding().borrow(svc.BootService, svc.boot_key, owner);
}
test "BMC controller cancelled late authentication completion only releases worker resources" {
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    const controller = try console.Controller.create(a, owner, key, .{ .endpoint = .{ .host = "bmc.invalid" }, .username = "operator" }, null, &budget, &journal, null);
    defer controller.deinit() catch unreachable;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fixture", &digest, .{});
    const selected = try profile.syntheticForTest(identityFixture(), .{ .firmware = "1.80", .identity_fixture_sha256 = @splat(1), .public_key_pem = "fixture", .public_key_sha256 = digest, .public_key_source = "fixture", .web_login_schema_verified = true, .kvm_login_schema_verified = true, .ws_subprotocol_echo_verified = true, .oem_handshake_verified = true, .web_logout = .own_session_location, .kvm_logout = .own_session_location });
    var fixture: WorkerFixture = .{ .creator = std.Thread.getCurrentId() };
    try controller.startSynthetic(selected, fixture.driver());
    while (!fixture.began.load(.acquire)) std.atomic.spinLoopHint();
    controller.cancel();
    fixture.begin_release.store(true, .release);
    while (!controller.poll().worker_exited) std.atomic.spinLoopHint();
    const state = controller.poll();
    try T.expectEqual(console.Cleanup.released, state.cleanup);
    try T.expectEqual(@as(u64, 0), state.published_frames);
    try T.expectEqual(@as(usize, 1), fixture.cleanups.load(.acquire));
    try T.expectEqual(@as(usize, 0), budget.usedBytes());
}

test "BMC controller refuses early control and refresh until RFB negotiation completes" {
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    const controller = try console.Controller.create(a, owner, key, .{ .endpoint = .{ .host = "bmc.invalid" }, .username = "operator" }, null, &budget, &journal, null);
    var fixture: WorkerFixture = .{ .creator = std.Thread.getCurrentId() };
    defer {
        controller.cancel();
        while (!controller.poll().worker_exited) std.atomic.spinLoopHint();
        controller.deinit() catch unreachable;
    }
    fixture.begin_release.store(true, .release);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fixture", &digest, .{});
    const selected = try profile.syntheticForTest(identityFixture(), .{ .firmware = "1.80", .identity_fixture_sha256 = @splat(1), .public_key_pem = "fixture", .public_key_sha256 = digest, .public_key_source = "fixture", .web_login_schema_verified = true, .kvm_login_schema_verified = true, .ws_subprotocol_echo_verified = true, .oem_handshake_verified = true, .web_logout = .own_session_location, .kvm_logout = .own_session_location });
    try controller.startSynthetic(selected, fixture.driver());
    while (controller.poll().route != .connected) std.atomic.spinLoopHint();
    try T.expectEqual(console.VideoState.negotiating, controller.poll().video);
    try T.expect(!controller.poll().rfb_ready);
    try T.expectError(error.VideoUnavailable, controller.requestControl());
    try T.expectError(error.VideoUnavailable, controller.requestFullRefresh());
    try T.expectError(error.VideoUnavailable, controller.replyControl(.{ 107, 0, 0, 1 }, .video_only));
    try T.expect(!controller.poll().worker_exited);
    try T.expect(controller.poll().failure == null);
}

test "BMC controller cancellation immediately closes input while preserving held release or remote uncertainty" {
    for ([_]bool{ false, true }) |reject_cancelled_writes| {
        var budget = budgets.Budget.init(128 * 1024 * 1024);
        defer budget.deinit() catch unreachable;
        var backend: ledger.MemoryBackend = .{ .allocator = a };
        defer backend.deinit();
        var journal = try ledger.Journal.init(a, backend.backend());
        defer journal.deinit();
        const controller = try console.Controller.create(a, owner, key, .{ .endpoint = .{ .host = "bmc.invalid" }, .username = "operator" }, null, &budget, &journal, null);
        var bytes = try handshake(1, 1);
        defer bytes.deinit(a);
        var image = try rawUpdate(1, 1, .{ 3, 2, 1, 0 });
        defer image.deinit(a);
        try bytes.appendSlice(a, image.items);
        try bytes.appendSlice(a, &.{ 107, 0, 9, 10 });
        var packet: std.ArrayList(u8) = .empty;
        defer packet.deinit(a);
        try packet.appendSlice(a, &.{ 0x82, @intCast(bytes.items.len) });
        try packet.appendSlice(a, bytes.items);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("fixture", &digest, .{});
        const selected = try profile.syntheticForTest(identityFixture(), .{ .firmware = "1.80", .identity_fixture_sha256 = @splat(1), .public_key_pem = "fixture", .public_key_sha256 = digest, .public_key_source = "fixture", .web_login_schema_verified = true, .kvm_login_schema_verified = true, .ws_subprotocol_echo_verified = true, .oem_handshake_verified = true, .web_logout = .own_session_location, .kvm_logout = .own_session_location });
        var fixture: WorkerFixture = .{ .creator = std.Thread.getCurrentId(), .inbound = packet.items, .cancel_io = if (reject_cancelled_writes) &controller.cancel_requested else null };
        defer {
            fixture.read_hold.store(false, .release);
            controller.cancel();
            while (!controller.poll().worker_exited) std.atomic.spinLoopHint();
            controller.deinit() catch unreachable;
        }
        fixture.begin_release.store(true, .release);
        try controller.startSynthetic(selected, fixture.driver());
        while (controller.poll().published_frames == 0) std.atomic.spinLoopHint();
        controller.remote_input.setFocus(true);
        const binding = controller.inputBinding();
        try T.expect(controller.remote_input.submit(binding, controller.remote_input.command(1, .{ .key = .{ .keysym = 'a', .down = true } })) == .accepted);
        try T.expect(controller.remote_input.submit(binding, controller.remote_input.command(2, .{ .pointer = .{ .x = 0, .y = 0, .buttons = 1 } })) == .accepted);
        while (controller.poll().input.last_sent_input_sequence != 2) std.atomic.spinLoopHint();
        fixture.read_hold.store(true, .release);
        while (!fixture.read_blocked.load(.acquire)) std.atomic.spinLoopHint();
        try T.expect(controller.poll().rfb_ready and controller.poll().control_request != null);

        controller.cancel();
        const cancelled = controller.poll();
        try T.expect(!cancelled.input.controlled and !cancelled.input.focused and cancelled.input.capture_paused);
        try T.expect(!cancelled.rfb_ready and cancelled.control_request == null);
        try T.expectEqual(video.rfb.ControlState.read_only, cancelled.control);
        try T.expect(controller.remote_input.submit(binding, controller.remote_input.command(3, .{ .key = .{ .keysym = 'b', .down = true } })) == .read_only);
        // The worker has not resumed. Closing cannot discard actual held
        // state or claim its release before the wire accepts those ups.
        try T.expectEqual(@as(usize, 1), controller.remote_input.pressed_count);
        try T.expectEqual(@as(u8, 1), controller.remote_input.pressed_buttons);
        try T.expect(controller.remote_input.release_pending);
        fixture.read_hold.store(false, .release);
        while (!controller.poll().worker_exited) std.atomic.spinLoopHint();
        const closed = controller.poll();
        try T.expect(closed.failure == null);
        try T.expectEqual(console.Cleanup.released, closed.cleanup);
        try T.expectEqual(reject_cancelled_writes, closed.input.remote_unconfirmed);
        try T.expectEqual(@as(usize, if (reject_cancelled_writes) 0 else 1), fixture.sent_key_ups.load(.acquire));
        try T.expectEqual(@as(usize, if (reject_cancelled_writes) 0 else 1), fixture.sent_button_releases.load(.acquire));
        try T.expectEqual(@as(usize, 0), controller.remote_input.pressed_count);
        try T.expectEqual(@as(u8, 0), controller.remote_input.pressed_buttons);
    }
}

fn execution(id: u64) svc.Execution {
    return .{ .call = .{ .owner = owner, .binding_generation = 1 }, .operation = .{ .owner = .{ .session = owner }, .operation_id = id }, .nonce = @splat(@intCast(id)), .system_uri = "/redfish/v1/Systems/A", .capability_revision = 2, .grant_revision = 3 };
}
fn managementSnapshots() struct { power: svc.PowerSnapshot, boot: svc.BootSnapshot } {
    const evidence: svc.Evidence = .{ .source_uri = "/redfish/v1/Systems/A", .collected_ms = 100, .validity = .valid };
    const capability: svc.Capability = .{ .revision = 2, .grant_revision = 3, .binding_generation = 1, .system_mapping_verified = true, .write_granted = true, .secondary_auth = .disabled, .secondary_auth_evidence = evidence };
    return .{
        .power = .{ .system_uri = "/redfish/v1/Systems/A", .system_identity = "fixture-node-A", .capability = capability, .state = .{ .value = .on, .evidence = evidence }, .reset_types = .{ .value = &.{ "ForceOff", "ForceRestart" }, .evidence = evidence }, .reset_target = "/redfish/v1/Systems/A/Actions/ComputerSystem.Reset" },
        .boot = .{ .system_uri = "/redfish/v1/Systems/A", .system_identity = "fixture-node-A", .write_uri = "/redfish/v1/Systems/A", .capability = capability, .state = .{ .enabled = "Disabled", .target = "None", .mode = "UEFI" }, .enabled_evidence = evidence, .target_evidence = evidence, .mode_evidence = evidence, .allowed_enabled = .{ .value = &.{ "Disabled", "Once" }, .evidence = evidence }, .allowed_targets = .{ .value = &.{ "None", "Pxe" }, .evidence = evidence }, .allowed_modes = .{ .value = &.{"UEFI"}, .evidence = evidence }, .etag = "\"one\"" },
    };
}
test "BMC management typed services use host arbiter and unknown writes never replay" {
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    var arbiter = actions.Arbiter.init(a);
    defer arbiter.deinit();
    var adapter: management.Adapter = undefined;
    try adapter.initForTest(a, owner, .{ .host = "bmc.invalid" }, &journal, arbiter.facade(owner));
    defer adapter.deinit();
    const snapshots = managementSnapshots();
    try adapter.setSnapshots(snapshots.power, snapshots.boot, true);
    const binding = adapter.powerBinding();
    const api = try binding.borrow(svc.PowerService, svc.power_key, owner);
    const request: svc.PowerExecutionRequest = .{ .execution = execution(21), .action = .force_off };
    try T.expect(api.request(binding.context, request) == .accepted);
    try T.expect(api.request(binding.context, request) == .accepted);
    var conflicting = request;
    conflicting.action = .force_restart;
    try T.expectEqual(svc.Reason.conflict, api.request(binding.context, conflicting).rejected);
    try T.expectEqual(@as(usize, 0), backend.writes); // Typed request never persists on caller.
    const outbound = (try adapter.next(100)).?;
    try T.expectEqual(management.power.Method.post, outbound.method);
    try T.expectEqual(@as(usize, 1), arbiter.count());
    try T.expect(journal.entries[0].dispatch_started);
    try adapter.complete(.{ .sequence = outbound.sequence, .transport_error = true }, 101);
    var outcome = try api.result(binding.context, request.execution.call, request.execution.operation, a);
    defer outcome.deinit();
    try T.expectEqual(svc.Phase.outcome_unknown, outcome.value.phase);
    try T.expectEqual(@as(usize, 0), arbiter.count());
    try T.expect(api.request(binding.context, request) == .accepted);
    conflicting = request;
    conflicting.execution.nonce[0] = 99;
    try T.expectEqual(svc.Reason.conflict, api.request(binding.context, conflicting).rejected);
    try T.expect((try adapter.next(102)) == null);
    try T.expectEqual(@as(usize, 1), journal.entries.len);
    var denied_power = snapshots.power;
    var denied_boot = snapshots.boot;
    denied_power.capability.write_granted = false;
    denied_boot.capability.write_granted = false;
    try adapter.setSnapshots(denied_power, denied_boot, true);
    try T.expectEqual(svc.Reason.permission_denied, api.request(binding.context, .{ .execution = execution(22), .action = .force_off }).rejected);
    const boot_binding = adapter.bootBinding();
    const boot_api = try boot_binding.borrow(svc.BootService, svc.boot_key, owner);
    try T.expectEqual(svc.Reason.permission_denied, boot_api.apply(boot_binding.context, .{ .execution = execution(23), .baseline = snapshots.boot.state, .enabled = "Once", .target = "Pxe" }).rejected);
}

test "BMC management completion republishes verified power and boot typed snapshots" {
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    var arbiter = actions.Arbiter.init(a);
    defer arbiter.deinit();
    var adapter: management.Adapter = undefined;
    try adapter.initForTest(a, owner, .{ .host = "bmc.invalid" }, &journal, arbiter.facade(owner));
    defer adapter.deinit();
    const snapshots = managementSnapshots();
    try adapter.setSnapshots(snapshots.power, snapshots.boot, true);
    const binding = adapter.powerBinding();
    const api = try binding.borrow(svc.PowerService, svc.power_key, owner);
    const request: svc.PowerExecutionRequest = .{ .execution = execution(31), .action = .force_off };
    try T.expect(api.request(binding.context, request) == .accepted);
    const outbound = (try adapter.next(100)).?;
    try adapter.complete(.{ .sequence = outbound.sequence, .status = 204 }, 101);
    const verification = (try adapter.next(1101)).?;
    try T.expectEqual(management.power.Method.get, verification.method);
    try adapter.complete(.{ .sequence = verification.sequence, .status = 200, .body = "{\"Id\":\"A\",\"UUID\":\"fixture-node-A\",\"PowerState\":\"Off\",\"Boot\":{\"BootSourceOverrideEnabled\":\"Once\",\"BootSourceOverrideTarget\":\"Pxe\",\"BootSourceOverrideMode\":\"UEFI\"}}" }, 1102);
    var power_snapshot = try api.snapshot(binding.context, request.execution.call, a);
    defer power_snapshot.deinit();
    try T.expectEqual(svc.PowerState.off, power_snapshot.value.state.value.?);
    const boot_binding = adapter.bootBinding();
    const boot_api = try boot_binding.borrow(svc.BootService, svc.boot_key, owner);
    var boot_snapshot = try boot_api.snapshot(boot_binding.context, request.execution.call, a);
    defer boot_snapshot.deinit();
    try T.expectEqualStrings("Once", boot_snapshot.value.state.enabled.?);
    try T.expectEqualStrings("Pxe", boot_snapshot.value.state.target.?);
}

test "BMC management cancellation drains the exact HTTP transaction before new dispatch" {
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    var arbiter = actions.Arbiter.init(a);
    defer arbiter.deinit();
    var adapter: management.Adapter = undefined;
    try adapter.initForTest(a, owner, .{ .host = "bmc.invalid" }, &journal, arbiter.facade(owner));
    defer adapter.deinit();
    const snapshots = managementSnapshots();
    try adapter.setSnapshots(snapshots.power, snapshots.boot, true);
    const binding = adapter.powerBinding();
    const api = try binding.borrow(svc.PowerService, svc.power_key, owner);
    const first: svc.PowerExecutionRequest = .{ .execution = execution(41), .action = .force_off };
    const second: svc.PowerExecutionRequest = .{ .execution = execution(42), .action = .force_restart };
    try T.expect(api.request(binding.context, first) == .accepted);
    const outbound = (try adapter.next(100)).?;
    try T.expectEqual(svc.CancelResult.observation_stopped_remote_may_continue, api.cancel(binding.context, first.execution.call, first.execution.operation));
    try T.expect((try adapter.next(101)) == null);
    try T.expect(api.request(binding.context, second) == .accepted);
    try T.expect((try adapter.next(102)) == null);
    try T.expectEqual(@as(usize, 1), journal.entries.len);
    try T.expectError(error.StaleCompletion, adapter.complete(.{ .sequence = outbound.sequence + 1, .status = 204 }, 103));
    try T.expect((try adapter.next(104)) == null);
    try adapter.complete(.{ .sequence = outbound.sequence, .status = 204 }, 105);
    var result = try api.result(binding.context, first.execution.call, first.execution.operation, a);
    defer result.deinit();
    try T.expectEqual(svc.Phase.outcome_unknown, result.value.phase);
    try T.expectEqual(svc.Reason.cancelled, result.value.reason.?);
    const next = (try adapter.next(106)).?;
    try T.expect(next.operation.eql(second.execution.operation));
    try T.expectEqual(management.power.Method.post, next.method);
    try T.expectEqual(@as(usize, 2), journal.entries.len);
    try T.expectError(error.StaleCompletion, adapter.complete(.{ .sequence = outbound.sequence, .status = 204 }, 107));
    try T.expect((try adapter.next(108)) == null);
    try adapter.complete(.{ .sequence = next.sequence, .transport_error = true }, 109);
}

test "BMC management timeout retains the HTTP slot until its late completion" {
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    var arbiter = actions.Arbiter.init(a);
    defer arbiter.deinit();
    var adapter: management.Adapter = undefined;
    try adapter.initForTest(a, owner, .{ .host = "bmc.invalid" }, &journal, arbiter.facade(owner));
    defer adapter.deinit();
    const snapshots = managementSnapshots();
    try adapter.setSnapshots(snapshots.power, snapshots.boot, true);
    const binding = adapter.powerBinding();
    const api = try binding.borrow(svc.PowerService, svc.power_key, owner);
    const request: svc.PowerExecutionRequest = .{ .execution = execution(43), .action = .force_off };
    try T.expect(api.request(binding.context, request) == .accepted);
    const outbound = (try adapter.next(100)).?;
    try T.expect((try adapter.next(60_101)) == null);
    var result = try api.result(binding.context, request.execution.call, request.execution.operation, a);
    defer result.deinit();
    try T.expectEqual(svc.Phase.outcome_unknown, result.value.phase);
    try T.expectEqual(svc.Reason.timeout, result.value.reason.?);
    try T.expectError(error.StaleCompletion, adapter.complete(.{ .sequence = outbound.sequence + 1, .status = 204 }, 60_102));
    try adapter.complete(.{ .sequence = outbound.sequence, .transport_error = true }, 60_103);
    var final_result = try api.result(binding.context, request.execution.call, request.execution.operation, a);
    defer final_result.deinit();
    try T.expectEqual(svc.Reason.timeout, final_result.value.reason.?);
}

test "BMC video reconnect advances same-size frame generation and denies old transport input" {
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var framebuffer = frame.Service.init(a, owner, &budget);
    defer framebuffer.deinit() catch unreachable;
    var remote_input = input.Service.init(owner);
    var hello = try handshake(1, 1);
    defer hello.deinit(a);
    var image = try rawUpdate(1, 1, .{ 3, 2, 1, 0 });
    defer image.deinit(a);
    {
        var first = try video.Pipeline.init(a, owner, 1, &framebuffer, &remote_input, &budget);
        defer first.deinit();
        try first.start(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
        try feedBinary(&first, hello.items, 3);
        try feedBinary(&first, image.items, 3);
    }
    const old_command = remote_input.command(1, .{ .key = .{ .keysym = 'a', .down = true } });
    var second = try video.Pipeline.init(a, owner, 2, &framebuffer, &remote_input, &budget);
    defer second.deinit();
    try second.start(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
    try feedBinary(&second, hello.items, 3);
    try feedBinary(&second, image.items, 3);
    remote_input.setFocus(true);
    var lease = framebuffer.acquireLatest(framebuffer.binding(), 0).frame;
    defer lease.release();
    try T.expectEqual(@as(u64, 2), lease.snapshot.frame_generation);
    try T.expect(remote_input.submit(remote_input.binding(), old_command) == .stale_epoch);
    var wire: Wire = .{};
    defer wire.deinit();
    try T.expectError(error.StaleTransport, remote_input.pump(.{ .context = &wire, .generation = 1, .write = Wire.write, .abort = Wire.abort }));
    try T.expectEqual(@as(usize, 0), wire.bytes.items.len);
}

test "BMC controller local cleanup waits for retained complete frame lease" {
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    const controller = try console.Controller.create(a, owner, key, .{ .endpoint = .{ .host = "bmc.invalid" }, .username = "operator" }, null, &budget, &journal, null);
    defer controller.deinit() catch unreachable;
    var bytes = try handshake(1, 1);
    defer bytes.deinit(a);
    var image = try rawUpdate(1, 1, .{ 3, 2, 1, 0 });
    defer image.deinit(a);
    try bytes.appendSlice(a, image.items);
    var packet: std.ArrayList(u8) = .empty;
    defer packet.deinit(a);
    try packet.appendSlice(a, &.{ 0x82, @intCast(bytes.items.len) });
    try packet.appendSlice(a, bytes.items);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fixture", &digest, .{});
    const selected = try profile.syntheticForTest(identityFixture(), .{ .firmware = "1.80", .identity_fixture_sha256 = @splat(1), .public_key_pem = "fixture", .public_key_sha256 = digest, .public_key_source = "fixture", .web_login_schema_verified = true, .kvm_login_schema_verified = true, .ws_subprotocol_echo_verified = true, .oem_handshake_verified = true, .web_logout = .own_session_location, .kvm_logout = .own_session_location });
    var fixture: WorkerFixture = .{ .creator = std.Thread.getCurrentId(), .inbound = packet.items };
    fixture.begin_release.store(true, .release);
    try controller.startSynthetic(selected, fixture.driver());
    while (controller.poll().published_frames == 0) std.atomic.spinLoopHint();
    var lease = controller.framebuffer.acquireLatest(controller.framebufferBinding(), 0).frame;
    controller.cancel();
    while (fixture.cleanups.load(.acquire) == 0) std.atomic.spinLoopHint();
    try T.expect(!controller.poll().worker_exited);
    try T.expectEqual(console.Cleanup.awaiting, controller.poll().cleanup);
    lease.release();
    while (!controller.poll().worker_exited) std.atomic.spinLoopHint();
    try T.expectEqual(console.Cleanup.released, controller.poll().cleanup);
    try T.expectEqual(@as(usize, 0), budget.usedBytes());
}

const DelayedManagementFixture = struct {
    worker: WorkerFixture,
    manager: *management.Adapter,
    in_flight: ?u64 = null,
    dispatches: std.atomic.Value(usize) = .init(0),
    completions: std.atomic.Value(usize) = .init(0),
    allow_completion: std.atomic.Value(bool) = .init(false),
    fn cast(raw: *anyopaque) *DelayedManagementFixture {
        return @ptrCast(@alignCast(raw));
    }
    fn begin(raw: *anyopaque, payload: *const console.model.Payload, plan: *const console.route.Plan, operation: svc.OperationKey, cancel: *const std.atomic.Value(bool)) !video.rfb.Authenticated {
        const self = cast(raw);
        const authenticated = try WorkerFixture.begin(&self.worker, payload, plan, operation, cancel);
        const snapshots = managementSnapshots();
        try self.manager.setSnapshots(snapshots.power, snapshots.boot, true);
        return authenticated;
    }
    fn read(raw: *anyopaque, bytes: []u8) !usize {
        return WorkerFixture.read(&cast(raw).worker, bytes);
    }
    fn write(raw: *anyopaque, bytes: []const u8) !usize {
        return WorkerFixture.write(&cast(raw).worker, bytes);
    }
    fn abort(raw: *anyopaque) void {
        WorkerFixture.abort(&cast(raw).worker);
    }
    fn cleanup(raw: *anyopaque) console.Cleanup {
        return WorkerFixture.cleanup(&cast(raw).worker);
    }
    fn wait(raw: *anyopaque, milliseconds: u32) void {
        WorkerFixture.wait(&cast(raw).worker, milliseconds);
    }
    fn now(_: *anyopaque) u64 {
        return 100 * std.time.ns_per_ms;
    }
    fn io(raw: *anyopaque, outbound: ?management.power.Outbound) !?management.power.Completion {
        const self = cast(raw);
        if (outbound) |work| {
            if (self.in_flight != null) return error.ManagementBusy;
            if (work.method != .post) return error.UnexpectedManagementRead;
            self.in_flight = work.sequence;
            _ = self.dispatches.fetchAdd(1, .acq_rel);
        }
        if (self.in_flight) |sequence| if (self.allow_completion.swap(false, .acq_rel)) {
            self.in_flight = null;
            _ = self.completions.fetchAdd(1, .acq_rel);
            return .{ .sequence = sequence, .status = 204 };
        };
        return null;
    }
    fn driver(self: *DelayedManagementFixture) console.Driver {
        return .{ .context = self, .begin = begin, .read = read, .write = write, .abort = abort, .cleanup = cleanup, .wait = wait, .now_ns = now, .management_io = io };
    }
    fn awaitDispatches(self: *DelayedManagementFixture, controller: *console.Controller, expected: usize) !void {
        for (0..100_000_000) |_| {
            if (self.dispatches.load(.acquire) == expected) return;
            if (controller.poll().worker_exited) return error.VideoStopped;
            std.atomic.spinLoopHint();
        }
        return error.FixtureTimedOut;
    }
};

test "BMC controller keeps video streaming while cancelled management HTTP drains" {
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    var arbiter = actions.Arbiter.init(a);
    defer arbiter.deinit();
    const controller = try console.Controller.createForTest(a, owner, key, .{ .endpoint = .{ .host = "bmc.invalid" }, .username = "operator" }, null, &budget, &journal, arbiter.facade(owner));
    var bytes = try handshake(1, 1);
    defer bytes.deinit(a);
    var image = try rawUpdate(1, 1, .{ 3, 2, 1, 0 });
    defer image.deinit(a);
    try bytes.appendSlice(a, image.items);
    var packet: std.ArrayList(u8) = .empty;
    defer packet.deinit(a);
    try packet.appendSlice(a, &.{ 0x82, @intCast(bytes.items.len) });
    try packet.appendSlice(a, bytes.items);
    var fixture: DelayedManagementFixture = .{ .worker = .{ .creator = std.Thread.getCurrentId(), .inbound = packet.items }, .manager = &controller.manager };
    defer {
        controller.cancel();
        while (!controller.poll().worker_exited) std.atomic.spinLoopHint();
        controller.deinit() catch unreachable;
    }
    fixture.worker.begin_release.store(true, .release);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("fixture", &digest, .{});
    const selected = try profile.syntheticForTest(identityFixture(), .{ .firmware = "1.80", .identity_fixture_sha256 = @splat(1), .public_key_pem = "fixture", .public_key_sha256 = digest, .public_key_source = "fixture", .web_login_schema_verified = true, .kvm_login_schema_verified = true, .ws_subprotocol_echo_verified = true, .oem_handshake_verified = true, .web_logout = .own_session_location, .kvm_logout = .own_session_location });
    try controller.startSynthetic(selected, fixture.driver());
    while (controller.poll().published_frames == 0) std.atomic.spinLoopHint();
    const binding = controller.powerBinding();
    const api = try binding.borrow(svc.PowerService, svc.power_key, owner);
    const first: svc.PowerExecutionRequest = .{ .execution = execution(51), .action = .force_off };
    const second: svc.PowerExecutionRequest = .{ .execution = execution(52), .action = .force_restart };
    try T.expect(api.request(binding.context, first) == .accepted);
    try fixture.awaitDispatches(controller, 1);
    try T.expectEqual(svc.CancelResult.observation_stopped_remote_may_continue, api.cancel(binding.context, first.execution.call, first.execution.operation));
    try T.expect(api.request(binding.context, second) == .accepted);
    for (0..100_000_000) |_| {
        var result = try api.result(binding.context, first.execution.call, first.execution.operation, a);
        defer result.deinit();
        if (result.value.phase == .outcome_unknown) break;
        if (controller.poll().worker_exited) return error.VideoStopped;
        std.atomic.spinLoopHint();
    } else return error.FixtureTimedOut;
    try T.expectEqual(@as(usize, 1), fixture.dispatches.load(.acquire));
    try T.expectEqual(console.VideoState.streaming, controller.poll().video);
    fixture.allow_completion.store(true, .release);
    try fixture.awaitDispatches(controller, 2);
    try T.expectEqual(@as(usize, 1), fixture.completions.load(.acquire));
    const state = controller.poll();
    try T.expect(state.failure == null);
    try T.expect(!state.worker_exited);
    try T.expectEqual(console.VideoState.streaming, state.video);
    var result = try api.result(binding.context, first.execution.call, first.execution.operation, a);
    defer result.deinit();
    try T.expectEqual(svc.Phase.outcome_unknown, result.value.phase);
    try T.expectEqual(svc.Reason.cancelled, result.value.reason.?);
}
