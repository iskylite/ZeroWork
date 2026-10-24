const std = @import("std");
const d12 = @import("gpu").Backend.native;
const r = d12.renderer_resources;
const c = d12.renderer_commands;
const a = std.heap.page_allocator;
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;
extern fn zenit_d12_test_fail_next_signal(*anyopaque) void;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |err| if (err != expected) return err;
}
pub fn run(io: std.Io) !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const context = try r.Context.init(a, &device);
    defer context.deinit() catch @panic("renderer command context cleanup");
    var queue = c.Queue.init(context);
    defer queue.deinit();
    var source = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .copy_src = true } });
    var source_live = true;
    defer if (source_live) source.destroy();
    var destination = try context.createTexture(a, .{ .size = source.size, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .copy_src = true } });
    defer destination.destroy();
    var src: [128]u8 = undefined;
    var dst: [128]u8 = undefined;
    for (0..32) |i| {
        @memcpy(src[i * 4 ..][0..4], &[_]u8{ @intCast(i * 3), 20, 200, 255 });
        @memcpy(dst[i * 4 ..][0..4], &[_]u8{ 255, 0, 0, 255 });
    }
    try source.writeRegion(0, 0, 0, 8, 4, &src, 32);
    try destination.writeRegion(0, 0, 0, 8, 4, &dst, 32);
    var encoder = try c.CommandEncoder.init(&queue);
    defer encoder.deinit();
    var pass = try encoder.beginBlitPass();
    try expectError(error.InvalidEncoderState, encoder.beginBlitPass());
    try expectError(error.InvalidEncoderState, encoder.finish());
    try expectError(error.InvalidTextureCopy, pass.copyTextureRegion(source.binding(), std.math.maxInt(u32), 0, 1, 1, destination.binding(), 0, 0));
    try expectError(error.InvalidTextureCopy, pass.copyTextureRegion(source.binding(), 0, 0, 0, 1, destination.binding(), 0, 0));
    try pass.copyTextureRegion(source.binding(), 1, 0, 3, 2, destination.binding(), 2, 1);
    pass.end();
    if (pass.isActive()) return error.EndedBlitStillActive;
    var second = try encoder.beginBlitPass();
    if (pass.isActive()) return error.StaleBlitReactivated;
    try expectError(error.InvalidEncoderState, pass.copyTextureRegion(source.binding(), 0, 0, 1, 1, destination.binding(), 0, 0));
    try second.copyTextureRegion(source.binding(), 7, 3, 1, 1, destination.binding(), 7, 3);
    second.end();
    // Native recording, rather than borrowed binding copies, owns the source.
    source.destroy();
    source_live = false;
    var command = try encoder.finish();
    var command_live = true;
    defer if (command_live) command.deinit();
    try expectError(error.EncoderAlreadyFinished, encoder.finish());
    try expectError(error.EncoderAlreadyFinished, encoder.beginBlitPass());
    encoder.deinit(); // No double decrement; ownership moved to command.
    var retained = command.retained();
    defer retained.deinit();
    if (retained.isCompleted() or retained.gpuElapsedMicros() != null) return error.UnsubmittedCommandCompleted;
    try expectError(error.CommandNotSubmitted, retained.waitChecked(0));
    const gate = zenit_d12_test_gate_create(device.raw, context.queue.raw);
    var signaled = false;
    defer {
        if (!signaled) zenit_d12_test_gate_signal(gate);
        context.queue.waitIdle(5000) catch @panic("blit gate cleanup");
        zenit_d12_test_gate_release(gate);
    }
    // Send the setup writes first, so the injected failure hits the blit command.
    try context.flushUploads();
    zenit_d12_test_fail_next_signal(context.queue.raw);
    try expectError(error.NativeGpuFailure, command.submitChecked());
    try expectError(error.CommandAlreadySubmitted, retained.submitChecked());
    if (retained.isCompleted()) return error.BlockedCommandCompleted;
    const poll_start = try @import("zenit_time").Instant.now(io);
    for (0..100) |_| if (retained.gpuElapsedMicros() != null) return error.BlockedTimestampAvailable;
    const poll_us = (try @import("zenit_time").Instant.now(io)).since(poll_start) / std.time.ns_per_us;
    if (poll_us > 100_000) return error.TimestampPollBlocked;
    try expectError(error.GpuTimeout, retained.waitChecked(0));
    const errors = c.CommandBuffer.error_count.load(.monotonic);
    command.submit();
    if (c.CommandBuffer.error_count.load(.monotonic) != errors + 1) return error.MissingSubmissionErrorCounter;
    c.CommandBuffer.error_count.store(errors, .monotonic);
    command.deinit();
    command_live = false;
    try expectError(error.ResourcesStillAlive, context.deinit());
    // Queue residence and CPU sleep must not enter the execution interval.
    try io.sleep(.fromMilliseconds(200), .awake);
    zenit_d12_test_gate_signal(gate);
    signaled = true;
    retained.waitUntilCompleted();
    if (!retained.isCompleted()) return error.IncorrectCommandCompletion;
    const gpu_us = retained.gpuElapsedMicros() orelse return error.MissingCompletedTimestamp;
    if (gpu_us >= 150_000) return error.TimestampIncludedQueueWait;
    if (retained.gpuElapsedMicros() != gpu_us) return error.UnstableCompletedTimestamp;
    std.debug.print("PASS: native GPU timestamps unavailable before submit/while gated, 100 nonblocking polls={d}us, stable completed interval={d}us after Signal failure and original-owner release\n", .{ poll_us, gpu_us });
    var output: [128]u8 = undefined;
    try destination.readBgra8(8, 4, &output, 32);
    var pixels: [128]u8 = undefined;
    for (0..4) |y| for (0..8) |x| {
        const from: ?usize = if (x >= 2 and x < 5 and y >= 1 and y < 3) (y - 1) * 8 + x - 1 else if (x == 7 and y == 3) 31 else null;
        const expected = if (from) |i| src[i * 4 ..][0..4] else dst[(y * 8 + x) * 4 ..][0..4];
        const pixel = output[(y * 8 + x) * 4 ..][0..4];
        if (!std.mem.eql(u8, pixel, expected)) return error.IncorrectRendererBlit;
        @memcpy(pixels[(y * 8 + x) * 4 ..][0..4], &[_]u8{ pixel[2], pixel[1], pixel[0], pixel[3] });
    };
    var abandoned = try c.CommandEncoder.init(&queue);
    var abandoned_pass = try abandoned.beginBlitPass();
    abandoned.deinit();
    if (abandoned_pass.isActive()) return error.AbandonedBlitStillActive;
    try expectError(error.InvalidEncoderState, abandoned_pass.copyTextureRegion(destination.binding(), 0, 0, 1, 1, destination.binding(), 0, 0));
    try checkNativeTimestampLifetime(&device);
    std.debug.print("RENDERER_BLIT_RGBA8_HEX={s}\nPASS: renderer BlitPass 32 pixels, two pass generations, stale/abandoned rejection, pre-finish source destruction, retained shared submission, blocked completion, Signal failure recovery and duplicate-submit accounting\n", .{std.fmt.bytesToHex(pixels, .lower)});
}

fn checkNativeTimestampLifetime(device: *d12.Device) !void {
    var queue = try device.createQueue();
    var queue_live = true;
    defer if (queue_live) queue.deinit(5000) catch @panic("timestamp queue cleanup");
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    try encoder.enableTimestamps();
    try expectError(error.InvalidEncoderState, encoder.enableTimestamps());
    var command = try encoder.finish();
    defer command.deinit();
    try expectError(error.EncoderAlreadyFinished, encoder.enableTimestamps());
    if (command.gpuElapsedMicros() != null) return error.UnsubmittedNativeTimestamp;
    const serial = try queue.submit(&.{command});
    try queue.wait(serial, 5000);
    const elapsed = command.gpuElapsedMicros() orelse return error.MissingNativeTimestamp;
    try queue.deinit(5000);
    queue_live = false;
    if (command.gpuElapsedMicros() != elapsed) return error.TimestampLostWithQueue;
    // Native callers may leave timing disabled; that is unknown, never 0 us.
    var untimed_encoder = try device.createCommandEncoder();
    defer untimed_encoder.deinit();
    var untimed = try untimed_encoder.finish();
    defer untimed.deinit();
    var untimed_queue = try device.createQueue();
    defer untimed_queue.deinit(5000) catch @panic("untimed queue cleanup");
    try untimed_queue.wait(try untimed_queue.submit(&.{untimed}), 5000);
    if (untimed.gpuElapsedMicros() != null) return error.UntimedCommandReportedTimestamp;
    std.debug.print("PASS: timestamp result survives queue destruction, duplicate/finished enable rejected, completed untimed command reports unknown\n", .{});
}
