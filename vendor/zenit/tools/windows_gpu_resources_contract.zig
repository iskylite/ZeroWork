extern fn zenit_d12_test_atomic_probe_device_loss() c_int;
const std = @import("std");
const d12 = @import("gpu").Backend.native;
extern fn zenit_d12_test_fail_next_signal(*anyopaque) void;
extern fn zenit_d12_test_debug_enable() void;
extern fn zenit_d12_test_debug_check(*anyopaque) void;
extern fn zenit_d12_test_width(*anyopaque) u64;
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |actual| {
        if (actual != expected) return actual;
    }
}
fn run(force_software: bool) !void {
    var device = try d12.Device.init(force_software);
    var released = false;
    defer if (!released) device.destroy();
    if (force_software and !device.isSoftware()) return error.ForcedWarpSelectedHardware;
    std.debug.print("D3D12 requested={s} actual={s}\n", .{
        if (force_software) "WARP" else "default",
        if (device.isSoftware()) "software/WARP" else "hardware",
    });
    // Buffers retain their owner independently of the user's Device reference.
    var upload = try device.createBuffer(std.heap.page_allocator, .{ .size = 4099, .usage = .{ .map_write = true, .copy_src = true, .uniform = true } });
    defer upload.destroy();
    var storage_upload = try device.createBuffer(std.heap.page_allocator, .{ .size = 4099, .usage = .{ .map_write = true, .storage = true, .vertex = true, .index = true, .copy_src = true }, .mapped_at_creation = true });
    defer storage_upload.destroy();
    if (zenit_d12_test_width(upload.raw) != 4352 or zenit_d12_test_width(storage_upload.raw) != 4099) return error.IncorrectNativeAllocationSize;
    var local = try device.createBuffer(std.heap.page_allocator, .{ .size = 4099, .usage = .{ .copy_dst = true, .copy_src = true, .storage = true } });
    defer local.destroy();
    var readback = try device.createBuffer(std.heap.page_allocator, .{ .size = 4099, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    try expectError(error.InvalidBufferDescriptor, device.createBuffer(std.heap.page_allocator, .{ .size = 0, .usage = .{ .vertex = true } }));
    try expectError(error.InvalidBufferDescriptor, device.createBuffer(std.heap.page_allocator, .{ .size = 8, .usage = .{ .map_read = true, .map_write = true } }));
    try expectError(error.InvalidBufferDescriptor, device.createBuffer(std.heap.page_allocator, .{ .size = 8, .usage = .{ .map_read = true, .vertex = true } }));
    try expectError(error.UnsupportedMappedAtCreation, device.createBuffer(std.heap.page_allocator, .{ .size = 8, .usage = .{ .vertex = true }, .mapped_at_creation = true }));
    try expectError(error.InvalidBufferDescriptor, device.createBuffer(std.heap.page_allocator, .{ .size = 8, .usage = .{} }));
    try expectError(error.InvalidBufferDescriptor, device.createBuffer(std.heap.page_allocator, .{ .size = std.math.maxInt(u64), .usage = .{ .uniform = true } }));
    try expectError(error.InvalidBufferDescriptor, device.createBuffer(std.heap.page_allocator, .{ .size = 8, .usage = .{ .map_write = true, .copy_dst = true } }));
    try expectError(error.InvalidBufferDescriptor, device.createBuffer(std.heap.page_allocator, .{ .size = 8, .usage = @bitCast(@as(u32, 1 << 31)) }));
    try expectError(error.BufferNotMappable, local.getMappedRange(0, 8));
    try expectError(error.BufferNotMapped, upload.getMappedRange(4098, 2));
    try expectError(error.BufferNotMapped, upload.getMappedRange(std.math.maxInt(u64), 2));
    try expectError(error.BufferNotMapped, upload.getMappedRange(0, 0));
    // Physical uniform allocation rounds up, but the logical API must not expose padding.
    try expectError(error.BufferNotMapped, upload.getMappedRange(4099, 1));
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("queue teardown failed");
    var encoders: [8]d12.CommandEncoder = undefined;
    // Prove the serials belong to the production Queue, with separately recorded
    // command lists created before the public Device is destroyed.
    var created_encoders: usize = 0;
    defer for (encoders[0..created_encoders]) |*encoder| encoder.deinit();
    for (&encoders) |*encoder| {
        encoder.* = try device.createCommandEncoder();
        created_encoders += 1;
    }
    var encoder_index: usize = 0;
    const native_owner = device.raw;
    device.destroy();
    released = true;
    for ([_]*d12.Buffer{ &upload, &storage_upload }) |source| {
        const bytes = try source.getMappedRange(0, 4099);
        for (0..4) |pass| {
            for (bytes, 0..) |*value, i| value.* = @truncate(i * 31 + pass * 79);
            source.unmap();
            const again = try source.getMappedRange(0, 4099);
            if (again.ptr != bytes.ptr) return error.MappingMoved;
            const encoder = &encoders[encoder_index];
            encoder_index += 1;
            try encoder.copyBufferToBuffer(source, 0, &local, 0, bytes.len);
            try encoder.copyBufferToBuffer(&local, 0, &readback, 0, bytes.len);
            var command = try encoder.finish();
            defer command.deinit();
            try expectError(error.EncoderAlreadyFinished, encoder.finish());
            const serial = try queue.submit(&.{command});
            if (serial != encoder_index) return error.NonMonotonicSubmission;
            try expectError(error.InvalidSubmission, queue.submit(&.{command}));
            try queue.wait(serial, 5000);
            const output = try readback.getMappedRange(0, 4099);
            for (output, 0..) |value, i| {
                const expected: u8 = @truncate(i * 31 + pass * 79);
                if (value != expected) return error.ReadbackMismatch;
            }
        }
    }
    zenit_d12_test_debug_check(native_owner);
    std.debug.print("PASS: 8 upload -> device-local -> readback submissions, 32792 verified bytes; production Queue/CommandEncoder, mapping, native alignment, bounds and lifetime contracts\n", .{});
}
fn ownershipAndTimeout() !void {
    var device = try d12.Device.init(true);
    var device_live = true;
    defer if (device_live) device.destroy();
    var foreign = try d12.Device.init(true);
    defer foreign.destroy();
    var other = try foreign.createBuffer(std.heap.page_allocator, .{ .size = 128, .usage = .{ .copy_dst = true } });
    defer other.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("queue teardown failed");
    var source = try device.createBuffer(std.heap.page_allocator, .{ .size = 128, .usage = .{ .map_write = true, .copy_src = true } });
    var source_live = true;
    defer if (source_live) source.destroy();
    var local = try device.createBuffer(std.heap.page_allocator, .{ .size = 128, .usage = .{ .copy_src = true, .copy_dst = true } });
    var local_live = true;
    defer if (local_live) local.destroy();
    var readback = try device.createBuffer(std.heap.page_allocator, .{ .size = 128, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    const bytes = try source.getMappedRange(0, 128);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i * 17 + 9);
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    try expectError(error.InvalidBufferCopy, encoder.copyBufferToBuffer(&source, 0, &other, 0, 8));
    try expectError(error.InvalidBufferCopy, encoder.copyBufferToBuffer(&source, 0, &source, 0, 8));
    try expectError(error.InvalidBufferCopy, encoder.copyBufferToBuffer(&local, 0, &source, 0, 8));
    try expectError(error.InvalidBufferCopy, encoder.copyBufferToBuffer(&source, 127, &local, 0, 2));
    try expectError(error.InvalidBufferCopy, encoder.copyBufferToBuffer(&source, 0, &local, 127, 2));
    try expectError(error.InvalidBufferCopy, encoder.copyBufferToBuffer(&source, std.math.maxInt(u64), &local, 0, 1));
    try expectError(error.InvalidBufferCopy, encoder.copyBufferToBuffer(&source, 0, &local, 0, 0));
    // First initialize every byte, then overwrite an offset range with a second
    // copy. The default heap becomes a source immediately afterward.
    try encoder.copyBufferToBuffer(&source, 0, &local, 0, 128);
    try encoder.copyBufferToBuffer(&source, 3, &local, 19, 37);
    var read_encoder = try device.createCommandEncoder();
    defer read_encoder.deinit();
    try read_encoder.copyBufferToBuffer(&local, 0, &readback, 0, 128);
    var foreign_encoder = try foreign.createCommandEncoder();
    defer foreign_encoder.deinit();
    var foreign_command = try foreign_encoder.finish();
    defer foreign_command.deinit();
    try expectError(error.InvalidSubmission, queue.submit(&.{foreign_command}));
    source.destroy();
    source_live = false;
    local.destroy();
    local_live = false;
    var command = try encoder.finish();
    const first_serial = try queue.submit(&.{command});
    command.deinit();
    if (try queue.submit(&.{}) != first_serial) return error.EmptySubmitChangedSerial;
    // First list completes before the gate; second list stays pending. This
    // exercises prefix reclamation while a later submission still owns local.
    const gate = zenit_d12_test_gate_create(device.raw, queue.raw);
    var gate_signaled = false;
    defer {
        // Release the GPU gate even if a test assertion fails.
        if (!gate_signaled) zenit_d12_test_gate_signal(gate);
        queue.waitIdle(5000) catch @panic("gate teardown failed");
        zenit_d12_test_gate_release(gate);
    }
    var read_command = try read_encoder.finish();
    zenit_d12_test_fail_next_signal(queue.raw);
    try expectError(error.NativeGpuFailure, queue.submit(&.{read_command}));
    const serial = queue.last_serial;
    read_command.deinit();
    if (first_serial != 1 or serial != 2) return error.NonMonotonicSubmission;
    const native_owner = device.raw;
    device.destroy();
    device_live = false;
    try queue.wait(first_serial, 5000);
    try queue.collect();
    try expectError(error.GpuTimeout, queue.wait(serial, 0));
    try expectError(error.GpuTimeout, queue.wait(serial, 2));
    try expectError(error.GpuTimeout, queue.deinit(0));
    try expectError(error.InvalidWait, queue.wait(serial + 1, 0));
    try expectError(error.InvalidWait, queue.wait(serial, std.math.maxInt(u32)));
    try queue.collect();
    zenit_d12_test_gate_signal(gate);
    gate_signaled = true;
    try queue.wait(serial, 5000);
    const output = try readback.getMappedRange(0, 128);
    for (output, 0..) |byte, i| {
        const original = if (i >= 19 and i < 56) i - 19 + 3 else i;
        const expected: u8 = @truncate(original * 17 + 9);
        if (byte != expected) return error.OffsetCopyMismatch;
    }
    try queue.collect();
    zenit_d12_test_debug_check(native_owner);
    std.debug.print("PASS: GPU-blocked timeout/deinit retry, injected Signal failure recovery and prefix reclamation; recorded/submitted resource retention; cross-device, usage and offset validation; 128 bytes verified\n", .{});
}
pub fn main(init: std.process.Init) !void {
    const requested_scope = @import("contract_options").scope;
    // resources = other without the app contract; resources_core and
    // resources_shared split it into two runs that together cover it exactly.
    const Scope = @TypeOf(requested_scope);
    const scope: Scope = switch (requested_scope) {
        .resources, .resources_core, .resources_shared => .other,
        else => requested_scope,
    };
    const core = requested_scope != .resources_shared;
    const shared = requested_scope != .resources_core;
    std.debug.print("NATIVE_GPU_SCOPE={s}\n", .{@tagName(requested_scope)});
    zenit_d12_test_debug_enable();
    if (scope == .atomic_probe_failure) {
        switch (zenit_d12_test_atomic_probe_device_loss()) {
            0 => std.debug.print("PASS: isolated removed-device atomic self-test fails explicitly and caches failure\n", .{}),
            4 => std.debug.print("SKIP: hardware-only atomic self-test device-loss injection on software adapter\n", .{}),
            else => return error.IncorrectAtomicProbeDeviceLossHandling,
        }
        return;
    }
    if (scope == .buffer_arrays) return @import("windows_gpu_buffer_array_contract.zig").run();
    if (scope == .bindings) return @import("windows_gpu_pipeline_contract.zig").run(init.io);
    if (scope == .app) return @import("windows_gpu_app_renderer_contract.zig").run(init.io);
    if (scope != .sdf and core) try run(false);
    if (scope != .sdf and core) try run(true);
    if (scope != .sdf and core) try ownershipAndTimeout();
    if (scope != .sdf and core) try @import("windows_gpu_texture_contract.zig").run();
    if (scope != .sdf and core) try @import("windows_gpu_renderer_resources_contract.zig").run();
    if (scope != .sdf and core) try @import("windows_gpu_renderer_commands_contract.zig").run(init.io);
    if (scope != .sdf and core) try @import("windows_gpu_renderer_render_contract.zig").run();
    if (scope != .sdf and core) try @import("windows_gpu_renderer_uniform_contract.zig").run();
    if (scope != .sdf and core) try @import("windows_gpu_renderer_sampling_contract.zig").run();
    if (scope != .sdf and core) try @import("windows_gpu_renderer_pipeline_contract.zig").run();
    if (scope != .sdf and core) try @import("windows_gpu_renderer_blur_contract.zig").run();
    if (scope != .sdf and core) try @import("windows_gpu_renderer_composite_contract.zig").run();
    if (scope != .sdf and core) try @import("windows_gpu_renderer_path_contract.zig").run();
    if (scope != .sdf and core) try @import("windows_gpu_renderer_image_contract.zig").run();
    if (scope != .sdf and core) try @import("windows_gpu_renderer_glyph_contract.zig").run();
    if (scope != .other) try @import("windows_gpu_renderer_sdf_contract.zig").run();
    if (scope != .other) try @import("windows_gpu_renderer_sdf_contract.zig").profile();
    if (scope != .sdf and core) try @import("windows_gpu_renderer_glass_contract.zig").run();
    if (scope != .sdf and shared) try @import("windows_gpu_renderer_device_contract.zig").run();
    if (scope != .sdf and shared) try @import("windows_gpu_frame_sync_contract.zig").run(init.io);
    if (scope != .sdf and shared) try @import("windows_gpu_surface_contract.zig").run();
    if (scope != .sdf and shared) try @import("windows_gpu_png_contract.zig").run(init.io);
    if (scope != .other) try @import("windows_gpu_shared_renderer_contract.zig").run(init.io);
    if (scope != .sdf and shared) try @import("windows_gpu_srgb_surface_contract.zig").run();
    if (scope != .sdf and shared) try @import("windows_gpu_shared_glyph_path_contract.zig").run(init.io);
    if (scope != .sdf and shared) try @import("windows_gpu_display_contract.zig").run(init.io);
    if (scope != .sdf and shared) try @import("windows_gpu_ui_glass_contract.zig").run(init.io);
    if (scope != .sdf and requested_scope != .resources and requested_scope != .resources_core and requested_scope != .resources_shared) try @import("windows_gpu_app_renderer_contract.zig").run(init.io);
    if (scope != .sdf and shared) try @import("windows_gpu_renderer_instance_contract.zig").run();
    if (scope != .sdf and shared) try @import("windows_gpu_views_contract.zig").run();
    if (scope != .sdf and shared) try @import("windows_gpu_binding_contract.zig").run();
    if (scope != .sdf and shared) try @import("windows_gpu_storage_contract.zig").run();
    if (scope != .sdf and shared) try @import("windows_gpu_shader_contract.zig").run();
    if (scope != .sdf and shared) try @import("windows_gpu_render_pipeline_contract.zig").run();
    if (scope != .sdf and shared) try @import("windows_gpu_render_contract.zig").run();
    if (scope != .sdf and shared) try @import("windows_gpu_pipeline_contract.zig").run(init.io);
}
