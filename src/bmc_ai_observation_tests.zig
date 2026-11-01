//! Remote CPU image -> immutable multimodal reference -> validated RFB input.
//! These tests use the real content lease and sender, without a BMC or window.
const std = @import("std");
const T = std.testing;
const a = T.allocator;
const ai = @import("plugins/bmc_ikvm/ai_control.zig");
const remote = @import("plugins/bmc_ikvm/remote_input.zig");
const framebuffer = @import("plugins/bmc_ikvm/framebuffer.zig");
const video = @import("plugins/bmc_ikvm/video_pipeline.zig");
const budgets = @import("host/frame_budget.zig");
const content = @import("host/content_context.zig");
const identity = @import("host/identity.zig");
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(73), .generation = 4 };

const Harness = struct {
    budget: budgets.Budget = budgets.Budget.init(64 * 1024 * 1024),
    framebuffer: framebuffer.Service = undefined,
    input: remote.Service = undefined,
    service: ai.Service = undefined,
    context: content.Context = undefined,
    grant: content.AutomationGrant = undefined,
    now: u64 = 10_000,
    wire_bytes: [4096]u8 = undefined,
    wire_length: usize = 0,
    refresh_requests: usize = 0,
    refresh_busy: bool = false,

    fn init(self: *Harness, width: u32, height: u32) !void {
        self.now = @intCast(@divTrunc(@import("platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
        self.framebuffer = framebuffer.Service.init(a, owner, &self.budget);
        self.input = remote.Service.init(owner);
        try self.input.setConnected(true, 1);
        try self.input.setControl(true, 1);
        self.service = ai.Service.init(owner, &self.framebuffer, &self.input);
        self.service.clock = .{ .context = self, .milliseconds = nowMs };
        self.service.refresh = .{ .context = self, .request = refresh };
        self.service.on_stop = .{ .context = self, .revoke_lease = revokeLease };
        self.context = .{ .owner = owner, .window_id = @fromBackingInt(1), .window = .{ .context = self, .request_fullscreen = fullscreen, .fullscreen_state = fullscreenState, .transfer = transfer }, .consumer = .{ .context = &self.input, .consume = consume } };
        try self.context.setAuthorization(true, 2);
        self.context.setFocus(true, false);
        self.grant = try self.context.acquireAutomation(2, null, null, std.math.maxInt(u64));
        try self.publish(width, height);
    }
    fn deinit(self: *Harness) void {
        self.context.close();
        self.service.close();
        self.input.close();
        self.framebuffer.deinit() catch unreachable;
        self.budget.deinit() catch unreachable;
    }
    fn publish(self: *Harness, width: u32, height: u32) !void {
        self.now = @max(self.now, @as(u64, @intCast(@divTrunc(@import("platform/realtime.zig").monotonicNs(), std.time.ns_per_ms))));
        const pixels = try a.alloc(u8, @as(usize, width) * height * 4);
        defer a.free(pixels);
        for (0..height) |y| for (0..width) |x| {
            const i = (y * width + x) * 4;
            pixels[i..][0..4].* = .{ @intCast(x % 256), @intCast(y % 256), 37, 255 };
        };
        _ = try self.framebuffer.publishComplete(width, height, pixels, @intCast(@import("platform/realtime.zig").monotonicNs()));
    }
    fn nowMs(raw: ?*anyopaque) u64 {
        const self: *Harness = @ptrCast(@alignCast(raw.?));
        return self.now;
    }
    fn fullscreen(_: *anyopaque, _: bool) !void {}
    fn fullscreenState(_: *anyopaque) bool {
        return false;
    }
    fn transfer(_: *anyopaque, _: identity.SessionHandle, _: identity.WindowId) !void {}
    fn consume(raw: *anyopaque, event: content.Input) !void {
        if (event != .release_all) return error.TypedInputRequired;
        const input: *remote.Service = @ptrCast(@alignCast(raw));
        _ = input.releaseAll(input.binding(), .released);
    }
    fn write(raw: *anyopaque, bytes: []const u8) !usize {
        const self: *Harness = @ptrCast(@alignCast(raw));
        if (self.wire_length + bytes.len > self.wire_bytes.len) return error.FixtureFull;
        @memcpy(self.wire_bytes[self.wire_length..][0..bytes.len], bytes);
        self.wire_length += bytes.len;
        return bytes.len;
    }
    fn abort(_: *anyopaque) void {}
    fn refresh(raw: *anyopaque) !void {
        const self: *Harness = @ptrCast(@alignCast(raw));
        if (self.refresh_busy) return error.ControlQueueFull;
        self.refresh_requests += 1;
    }
    fn revokeLease(raw: *anyopaque) void {
        const self: *Harness = @ptrCast(@alignCast(raw));
        self.context.takeHumanControl();
    }
    fn pump(self: *Harness) !void {
        const state = try self.input.snapshot(self.input.binding());
        _ = try self.input.pump(.{ .context = self, .generation = state.transport_generation, .write = write, .abort = abort });
    }
    fn pointer(self: *Harness, observation: ai.Observation, operation: u64, point: ai.Point) !ai.Receipt {
        return self.service.pointer(self.service.binding(), .{ .observation_id = observation.id, .operation_id = operation, .proof = self.grant.proof, .action = .{ .move = point } });
    }
};

test "BMC AI screenshot produces real immutable remote crop PNG and releases its FrameLease" {
    var h: Harness = .{};
    try h.init(8, 6);
    defer h.deinit();
    var observation = try h.service.screenshot(h.service.binding(), a, .{ .region = .{ .x = 2, .y = 2, .width = 4, .height = 4 }, .max_width = 2, .max_height = 2 });
    defer observation.deinit();
    const result = observation.image_ref.content().?;
    try T.expectEqual(@as(u32, 8), observation.original_width);
    try T.expectEqual(@as(u32, 6), observation.original_height);
    try T.expectEqual(@as(u32, 2), result.width);
    try T.expectEqual(@as(u32, 2), result.height);
    try T.expect(std.mem.startsWith(u8, result.bytes, "\x89PNG\r\n\x1a\n"));
    try T.expectEqualStrings("bmc_ikvm:remote-frame", result.path);
    try T.expectEqualSlices(u8, &.{ 2, 2, 37, 255, 4, 2, 37, 255, 2, 4, 37, 255, 4, 4, 37, 255 }, result.pixels);
    // An image result owns a copy, not a decoder slot. Resize and runtime close
    // can retire all frame memory while the provider retains the same image.
    _ = try h.framebuffer.configure(4, 4);
    try h.publish(4, 4);
    h.service.close();
    try T.expectEqualSlices(u8, &.{ 2, 2, 37, 255 }, observation.image_ref.content().?.pixels[0..4]);
}

test "BMC AI crop scale maps image pixels directly and rejects borders nonfinite and malformed regions" {
    const mapping = try ai.image.transform(4096, 2160, null, 1920, 1200);
    try T.expectEqual(@as(u32, 1920), mapping.output_width);
    try T.expectEqual(@as(u32, 1012), mapping.output_height);
    const point = try mapping.remote(.{ .x = 960, .y = 506 });
    try T.expectEqual(@as(u16, 2048), point.x);
    try T.expectEqual(@as(u16, 1080), point.y);
    const crop = try ai.image.transform(200, 100, .{ .x = 40, .y = 20, .width = 80, .height = 60 }, 40, 30);
    const cropped = try crop.remote(.{ .x = 10.9, .y = 12.9 });
    try T.expectEqual(@as(u16, 60), cropped.x);
    try T.expectEqual(@as(u16, 44), cropped.y);
    try T.expectError(error.CoordinateOutOfBounds, crop.remote(.{ .x = 40, .y = 0 }));
    try T.expectError(error.CoordinateOutOfBounds, crop.remote(.{ .x = -0.1, .y = 0 }));
    try T.expectError(error.CoordinateOutOfBounds, crop.remote(.{ .x = std.math.nan(f64), .y = 0 }));
    try T.expectError(error.CoordinateOutOfBounds, crop.remote(.{ .x = 0, .y = std.math.inf(f64) }));
    try T.expectError(error.InvalidRegion, ai.image.transform(200, 100, .{ .x = 190, .width = 11, .height = 1 }, 40, 30));
    try T.expectError(error.InvalidOutputSize, ai.image.transform(200, 100, null, 1921, 1200));
}

test "BMC AI ordinary frame updates preserve observation authority and mapped input reaches RFB exactly once" {
    var h: Harness = .{};
    try h.init(8, 6);
    defer h.deinit();
    var observation = try h.service.screenshot(h.service.binding(), a, .{ .region = .{ .x = 2, .y = 2, .width = 4, .height = 4 }, .max_width = 2, .max_height = 2 });
    defer observation.deinit();
    try h.publish(8, 6);
    const accepted = try h.pointer(observation, 1, .{ .x = 1, .y = 1 });
    try T.expectEqual(ai.automation.Status.accepted, accepted.status);
    try h.publish(8, 6);
    try T.expectError(error.OperationPending, h.service.screenshot(h.service.binding(), a, .{}));
    try h.pump();
    const sent = try h.service.operationStatus(h.service.binding(), 1);
    try T.expectEqual(ai.automation.Status.sent, sent.status);
    try T.expectEqual(@as(u16, 1), sent.sent_events);
    try T.expectEqualSlices(u8, &.{ 5, 0, 0, 4, 0, 4 }, h.wire_bytes[0..h.wire_length]);
    _ = try h.pointer(observation, 1, .{ .x = 1, .y = 1 });
    try h.pump();
    try T.expectEqual(@as(usize, 6), h.wire_length);
    try T.expectError(error.OperationConflict, h.pointer(observation, 1, .{ .x = 0, .y = 0 }));
    try T.expectError(error.FreshObservationRequired, h.pointer(observation, 2, .{ .x = 0, .y = 0 }));
    try T.expectError(error.PostActionFramePending, h.service.screenshot(h.service.binding(), a, .{}));
    try T.expectEqual(@as(usize, 1), h.refresh_requests);
    try T.expectError(error.PostActionFramePending, h.service.screenshot(h.service.binding(), a, .{}));
    try T.expectEqual(@as(usize, 1), h.refresh_requests);
    try h.publish(8, 6);
    var fresh = try h.service.screenshot(h.service.binding(), a, .{ .region = .{ .x = 2, .y = 2, .width = 4, .height = 4 }, .max_width = 2, .max_height = 2 });
    defer fresh.deinit();
    try T.expectError(error.CoordinateOutOfBounds, h.pointer(fresh, 2, .{ .x = 2, .y = 0 }));
    _ = try h.pointer(fresh, 2, .{ .x = 0, .y = 0 });
    try h.pump();
    try T.expectEqual(@as(usize, 12), h.wire_length);
}

test "BMC AI owner polling prepares the post action frame before the first approved screenshot" {
    var h: Harness = .{};
    try h.init(8, 6);
    defer h.deinit();
    var observation = try h.service.screenshot(h.service.binding(), a, .{});
    defer observation.deinit();
    _ = try h.pointer(observation, 1, .{ .x = 1, .y = 1 });
    try h.pump();
    try T.expect(try h.service.poll());
    try T.expectEqual(@as(usize, 1), h.refresh_requests);
    try T.expect(!(try h.service.poll()));
    try h.publish(8, 6);
    var fresh = try h.service.screenshot(h.service.binding(), a, .{});
    defer fresh.deinit();
    try T.expect(fresh.sequence > observation.sequence);
    try T.expectEqual(@as(usize, 1), h.refresh_requests);
    try T.expectEqual(@as(usize, 6), h.wire_length);
}

test "BMC AI post action refresh retries a busy worker slot without accepting an old frame" {
    var h: Harness = .{};
    try h.init(8, 6);
    defer h.deinit();
    var observation = try h.service.screenshot(h.service.binding(), a, .{});
    defer observation.deinit();
    _ = try h.pointer(observation, 1, .{ .x = 1, .y = 1 });
    try h.pump();
    h.refresh_busy = true;
    try T.expect(!(try h.service.poll()));
    try T.expectError(error.PostActionFramePending, h.service.screenshot(h.service.binding(), a, .{}));
    try T.expectEqual(@as(usize, 0), h.refresh_requests);
    h.refresh_busy = false;
    try T.expect(try h.service.poll());
    try T.expectError(error.PostActionFramePending, h.service.screenshot(h.service.binding(), a, .{}));
    try h.publish(8, 6);
    var fresh = try h.service.screenshot(h.service.binding(), a, .{});
    defer fresh.deinit();
    try T.expectEqual(@as(usize, 1), h.refresh_requests);
    try T.expectEqual(@as(usize, 6), h.wire_length);
}

test "BMC AI DesktopSize waits for complete geometry before observing or using a new lease" {
    var h: Harness = .{ .budget = budgets.Budget.init(128 * 1024 * 1024) };
    try h.init(1, 1);
    defer h.deinit();
    var pipeline = try video.Pipeline.init(a, owner, 1, &h.framebuffer, &h.input, &h.budget);
    defer pipeline.deinit();
    try pipeline.start(.{ .tls_trusted = true, .web_authenticated = true, .oem_authenticated = true });
    var hello: [52]u8 = undefined;
    hello[0..2].* = .{ 0x82, 50 };
    @memcpy(hello[2..14], "RFB 003.008\n");
    @memcpy(hello[14..28], &[_]u8{ 105, 1, 0, 99, 104, 0, 0, 0, 1, 1, 0, 0, 0, 0 });
    std.mem.writeInt(u16, hello[28..30], 1, .big);
    std.mem.writeInt(u16, hello[30..32], 1, .big);
    (video.rfb.raw.PixelFormat{}).write(hello[32..48]);
    std.mem.writeInt(u32, hello[48..52], 0, .big);
    _ = try pipeline.feed(&hello, @intCast(@import("platform/realtime.zig").monotonicNs()));
    const first = [_]u8{ 0x82, 20, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 11, 22, 33, 0 };
    _ = try pipeline.feed(&first, @intCast(@import("platform/realtime.zig").monotonicNs()));
    var old = try h.service.screenshot(h.service.binding(), a, .{});
    defer old.deinit();
    var resize: [18]u8 = .{ 0x82, 16, 0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0, 0 };
    std.mem.writeInt(i32, resize[14..18], -223, .big);
    _ = try pipeline.feed(&resize, @intCast(@import("platform/realtime.zig").monotonicNs()));
    try T.expect((try h.input.snapshot(h.input.binding())).geometry_pending);
    try T.expectError(error.FrameGeometryPending, h.service.screenshot(h.service.binding(), a, .{}));
    try T.expectError(error.FrameGeometryPending, h.pointer(old, 1, .{ .x = 0, .y = 0 }));
    const old_proof = h.grant.proof;
    h.context.takeHumanControl();
    h.grant = try h.context.acquireAutomation(2, null, null, std.math.maxInt(u64));
    try T.expect(!old_proof.valid());
    try T.expectError(error.FrameGeometryPending, h.pointer(old, 1, .{ .x = 0, .y = 0 }));
    try T.expectEqual(@as(usize, 0), h.wire_length);
    var complete: [34]u8 = @splat(0);
    complete[0..2].* = .{ 0x82, 32 };
    complete[5] = 1;
    std.mem.writeInt(u16, complete[10..12], 2, .big);
    std.mem.writeInt(u16, complete[12..14], 2, .big);
    @memset(complete[18..], 37);
    _ = try pipeline.feed(&complete, @intCast(@import("platform/realtime.zig").monotonicNs()));
    const current = try h.input.snapshot(h.input.binding());
    try T.expect(!current.geometry_pending);
    try T.expectError(error.ObservationInvalidated, h.pointer(old, 1, .{ .x = 0, .y = 0 }));
    var fresh = try h.service.screenshot(h.service.binding(), a, .{});
    defer fresh.deinit();
    try T.expectEqual(@as(u32, 2), fresh.original_width);
    try T.expectEqual(@as(u32, 2), fresh.original_height);
    try T.expectEqual(current.geometry_generation, fresh.frame_generation);
    try T.expect(fresh.frame_generation != old.frame_generation);
    _ = try h.pointer(fresh, 1, .{ .x = 1, .y = 1 });
    try h.pump();
    try T.expectEqual(@as(usize, 6), h.wire_length);
}

test "BMC AI observation expires and invalidates on resolution generation control reconnect and human takeover" {
    var h: Harness = .{};
    try h.init(8, 6);
    defer h.deinit();
    var expired = try h.service.screenshot(h.service.binding(), a, .{ .max_age_ms = 5 });
    defer expired.deinit();
    h.now += 5;
    try T.expectError(error.ObservationExpired, h.pointer(expired, 1, .{ .x = 0, .y = 0 }));
    var resized = try h.service.screenshot(h.service.binding(), a, .{});
    defer resized.deinit();
    try h.publish(4, 4);
    try T.expectError(error.ObservationInvalidated, h.pointer(resized, 2, .{ .x = 0, .y = 0 }));
    var generation = try h.service.screenshot(h.service.binding(), a, .{});
    defer generation.deinit();
    _ = try h.framebuffer.advanceGeneration();
    try h.publish(4, 4);
    try T.expectError(error.ObservationInvalidated, h.pointer(generation, 3, .{ .x = 0, .y = 0 }));
    var control = try h.service.screenshot(h.service.binding(), a, .{});
    defer control.deinit();
    try h.input.setControl(true, 2);
    try T.expectError(error.ObservationInvalidated, h.pointer(control, 4, .{ .x = 0, .y = 0 }));
    try T.expect(!h.grant.proof.valid());
    h.grant = try h.context.acquireAutomation(2, null, null, std.math.maxInt(u64));
    var reconnect = try h.service.screenshot(h.service.binding(), a, .{});
    defer reconnect.deinit();
    try h.input.setConnected(false, 1);
    try h.input.setConnected(true, 2);
    try h.input.setControl(true, 3);
    try T.expectError(error.ObservationInvalidated, h.pointer(reconnect, 5, .{ .x = 0, .y = 0 }));
    try T.expect(!h.grant.proof.valid());
    var resumed_without_grant = try h.service.screenshot(h.service.binding(), a, .{});
    defer resumed_without_grant.deinit();
    try T.expectError(error.StaleAutomationAuthority, h.pointer(resumed_without_grant, 6, .{ .x = 0, .y = 0 }));
    h.grant = try h.context.acquireAutomation(2, null, null, std.math.maxInt(u64));
    var takeover = try h.service.screenshot(h.service.binding(), a, .{});
    defer takeover.deinit();
    h.context.takeHumanControl();
    try T.expect(!h.grant.proof.valid());
    try T.expectError(error.ObservationInvalidated, h.pointer(takeover, 6, .{ .x = 0, .y = 0 }));
    try T.expectEqual(@as(usize, 0), h.wire_length);
}

test "BMC AI host stop and bounded observation history leave no reusable old image authority" {
    var h: Harness = .{};
    try h.init(1, 1);
    defer h.deinit();
    var first = try h.service.screenshot(h.service.binding(), a, .{});
    defer first.deinit();
    for (0..ai.Service.observation_capacity) |_| {
        var next = try h.service.screenshot(h.service.binding(), a, .{});
        next.deinit();
    }
    try T.expectError(error.ObservationNotFound, h.pointer(first, 1, .{ .x = 0, .y = 0 }));
    var recent = try h.service.screenshot(h.service.binding(), a, .{});
    defer recent.deinit();
    _ = try h.pointer(recent, 2, .{ .x = 0, .y = 0 });
    try h.service.stop(h.service.binding());
    try T.expect(!h.grant.proof.valid());
    try T.expectError(error.ObservationNotFound, h.pointer(recent, 3, .{ .x = 0, .y = 0 }));
    try T.expectEqual(ai.automation.Status.cancelled_unsent, (try h.service.operationStatus(h.service.binding(), 2)).status);
    try h.pump();
    try T.expectEqual(@as(usize, 0), h.wire_length);
    h.service.close();
    try T.expectError(error.OwnerClosed, h.service.screenshot(h.service.binding(), a, .{}));
}

test "BMC AI screenshot obeys the 1920 by 1200 bound with valid fully decoded PNG" {
    var h: Harness = .{};
    try h.init(1920, 1200);
    defer h.deinit();
    var observation = try h.service.screenshot(h.service.binding(), a, .{});
    defer observation.deinit();
    const result = observation.image_ref.content().?;
    try T.expectEqual(@as(u32, 1920), result.width);
    try T.expectEqual(@as(u32, 1200), result.height);
    try T.expectEqual(@as(usize, 1920 * 1200 * 4), result.pixels.len);
    try T.expect(result.bytes.len <= @import("ai/image_attachments.zig").max_bytes);
    try T.expectEqualSlices(u8, &.{ 0, 0, 37, 255 }, result.pixels[0..4]);
}
