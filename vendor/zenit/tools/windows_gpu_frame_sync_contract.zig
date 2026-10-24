const std = @import("std");
const d12 = @import("gpu").Backend.native;
const b = d12.renderer_device;
const a = std.heap.page_allocator;
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;
extern fn zenit_d12_test_fail_next_signal(*anyopaque) void;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |err| if (err != expected) return err;
}
fn command(queue: *b.Queue) !b.CommandBuffer {
    var encoder = try b.CommandEncoder.init(queue);
    defer encoder.deinit();
    return encoder.finish();
}
pub fn run(io: std.Io) !void {
    var instance = try b.Instance.init(a, .{});
    defer instance.deinit();
    const adapters = try instance.enumerateAdapters();
    defer a.free(adapters);
    defer for (adapters) |*adapter| adapter.deinit();
    var dq = try adapters[0].requestDevice(a, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();
    var sync = b.FrameSync.init(3);
    defer sync.deinit();
    try expectError(error.UnbalancedFrameSync, sync.signalChecked());
    try sync.waitForNextFrameChecked(0);
    try expectError(error.UnbalancedFrameSync, sync.drainChecked(3, 0));
    try sync.signalChecked();
    try expectError(error.UnbalancedFrameSync, sync.drainChecked(2, 0));
    // Ring cancellation preserves ownership and order across middle/head/tail.
    var abandoned: [3]b.CommandBuffer = undefined;
    for (&abandoned) |*slot| {
        slot.* = try command(&dq.queue);
        try sync.waitForNextFrameChecked(0);
        try sync.signalOnCompletionChecked(slot);
    }
    try expectError(error.CommandNotSubmitted, sync.waitForNextFrameChecked(0));
    try sync.cancelUnsubmittedChecked(&abandoned[1]);
    try expectError(error.CommandNotRegistered, sync.cancelUnsubmittedChecked(&abandoned[1]));
    try sync.cancelUnsubmittedChecked(&abandoned[0]);
    try sync.cancelUnsubmittedChecked(&abandoned[2]);
    for (&abandoned) |*slot| slot.deinit();
    if (sync.pending != 0 or dq.device.context.resources != 0) return error.CancelledFrameOwnerLeak;
    const gate = zenit_d12_test_gate_create(dq.device.context.device.raw, dq.device.context.queue.raw);
    var signaled = false;
    defer {
        if (!signaled) zenit_d12_test_gate_signal(gate);
        sync.drainChecked(3, 5000) catch @panic("frame gate cleanup");
        zenit_d12_test_gate_release(gate);
    }
    var first = try command(&dq.queue);
    var first_live = true;
    defer if (first_live) first.deinit();
    try sync.waitForNextFrameChecked(0);
    try sync.signalOnCompletionChecked(&first); // Registered before submit.
    try sync.waitForNextFrameChecked(0);
    try expectError(error.CommandAlreadyRegistered, sync.signalOnCompletionChecked(&first));
    try sync.signalChecked();
    // Execute succeeds but fence Signal fails: this frame still owns GPU work.
    zenit_d12_test_fail_next_signal(dq.device.context.queue.raw);
    try expectError(error.NativeGpuFailure, first.submitChecked());
    try expectError(error.CommandAlreadySubmitted, sync.cancelUnsubmittedChecked(&first));
    first.deinit();
    first_live = false;
    for (0..2) |_| {
        var next = try command(&dq.queue);
        defer next.deinit();
        try sync.waitForNextFrameChecked(0);
        try sync.signalOnCompletionChecked(&next);
        try next.submitChecked();
    }
    if (sync.pending != 3 or sync.acquired != 0 or dq.device.context.resources != 3) return error.IncorrectBlockedFrameOwnership;
    try sync.collectChecked();
    try expectError(error.GpuTimeout, sync.waitForNextFrameChecked(0));
    try expectError(error.GpuTimeout, sync.drainChecked(3, 0));
    try expectError(error.UnbalancedFrameSync, sync.deinitChecked());
    try expectError(error.ResourcesStillAlive, dq.device.deinitChecked());
    if (sync.pending != 3 or sync.acquired != 0) return error.FrameSlotReturnedBeforeGpuCompletion;
    zenit_d12_test_gate_signal(gate);
    signaled = true;
    try sync.drainChecked(3, 5000);
    if (sync.pending != 0 or dq.device.context.resources != 0) return error.CompletedFrameOwnerLeak;
    // Exercise ring wrapping and full reclaim through the shared renderer's void API.
    for (0..17) |_| {
        try sync.waitForNextFrame();
        var next = try command(&dq.queue);
        defer next.deinit();
        sync.signalOnCompletion(&next);
        try next.submitChecked();
    }
    sync.drain(3);
    for (0..3) |_| try sync.waitForNextFrame();
    try expectError(error.UnbalancedFrameSync, sync.waitForNextFrameChecked(0));
    for (0..3) |_| sync.signal();
    if (sync.pending != 0 or sync.acquired != 0 or dq.device.context.resources != 0) return error.UnbalancedFinalFrameState;
    var low_latency = b.FrameSync.initWithLimit(3, 1);
    defer low_latency.deinit();
    const slow_gate = zenit_d12_test_gate_create(dq.device.context.device.raw, dq.device.context.queue.raw);
    defer {
        zenit_d12_test_gate_signal(slow_gate);
        low_latency.drain(3);
        zenit_d12_test_gate_release(slow_gate);
    }
    var slow = try command(&dq.queue);
    defer slow.deinit();
    try low_latency.waitForNextFrame();
    low_latency.signalOnCompletion(&slow);
    try slow.submitChecked();
    try expectError(error.GpuTimeout, low_latency.waitForNextFrameChecked(0));
    if (low_latency.pending != 1 or low_latency.acquired != 0) return error.SoftwareFrameAdmissionExceeded;
    zenit_d12_test_gate_signal(slow_gate);
    low_latency.drain(3);
    for (0..7) |_| {
        try low_latency.waitForNextFrame();
        try expectError(error.UnbalancedFrameSync, low_latency.waitForNextFrameChecked(0));
        var next = try command(&dq.queue);
        defer next.deinit();
        low_latency.signalOnCompletion(&next);
        try next.submitChecked();
    }
    low_latency.drain(3);
    // A GPU frame longer than one wait slice (software adapters take seconds)
    // must be waited out, not treated as fatal: release the gate from another
    // thread after 6 s (beyond the former 5 s fatal limit) while the render thread blocks in waitForNextFrame.
    {
        const long_gate = zenit_d12_test_gate_create(dq.device.context.device.raw, dq.device.context.queue.raw);
        defer zenit_d12_test_gate_release(long_gate);
        var long = try command(&dq.queue);
        defer long.deinit();
        try low_latency.waitForNextFrame();
        low_latency.signalOnCompletion(&long);
        try long.submitChecked();
        const releaser = try std.Thread.spawn(.{}, struct {
            fn run(thread_io: std.Io, g: *anyopaque) void {
                thread_io.sleep(.fromMilliseconds(6000), .awake) catch {};
                zenit_d12_test_gate_signal(g);
            }
        }.run, .{ io, long_gate });
        const start = try @import("zenit_time").Instant.now(io);
        try low_latency.waitForNextFrame();
        const waited_ms = (try @import("zenit_time").Instant.now(io)).since(start) / std.time.ns_per_ms;
        releaser.join();
        if (waited_ms < 5900) return error.LongFrameWaitReturnedEarly;
        low_latency.signal();
        low_latency.drain(3);
        std.debug.print("PASS: {d} ms GPU frame waited out across 1 s slices without a fatal timeout\n", .{waited_ms});
    }
    std.debug.print("PASS: single in-flight admission over three resource slots, blocked-GPU ownership and wraparound\n", .{});
    std.debug.print("PASS: D3D12 FrameSync, three GPU-blocked in-flight slots, registration before submit, duplicate/cancel guards, post-execute Signal failure retention, retained command/context ownership, timeout/drain retry, 17 wraparound frames and balanced void APIs\n", .{});
}
