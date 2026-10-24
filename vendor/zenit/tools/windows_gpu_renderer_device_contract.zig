const std = @import("std");
const d12 = @import("gpu").Backend.native;
const gpu = @import("gpu");
const b = d12.renderer_device;
const a = std.heap.page_allocator;
const fixture = @import("windows_gpu_device_fixture.zig");
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |err| if (err != expected) return err;
}
pub fn run() !void {
    try expectError(error.BackendDisabled, b.Instance.init(a, .{ .backends = .{ .metal = true } }));
    var instance = try b.Instance.init(a, .{});
    var instance_live = true;
    defer if (instance_live) instance.deinit();
    const adapters = try instance.enumerateAdapters();
    defer a.free(adapters);
    if (adapters.len != 1) return error.IncorrectDefaultAdapterCount;
    var adapters_live = true;
    defer if (adapters_live) for (adapters) |*adapter| adapter.deinit();
    try expectError(error.UnsupportedFeatures, adapters[0].requestDevice(a, .{ .required_features = .{ .timestamp_query = true } }));
    var limits = gpu.Limits{};
    limits.max_bind_groups = 5;
    try expectError(error.UnsupportedLimits, adapters[0].requestDevice(a, .{ .required_limits = limits }));
    var dq = try adapters[0].requestDevice(a, .{});
    var device_live = true;
    defer if (device_live) dq.device.deinit();
    var queue_live = true;
    defer if (queue_live) dq.queue.deinit();
    if (dq.queue.context != dq.device.context or dq.device.isSoftware() != adapters[0].isSoftware() or dq.device.limits.max_bind_groups != 4 or @as(u64, @bitCast(dq.device.features)) != @as(u64, @bitCast(adapters[0].getFeatures()))) return error.IncorrectRendererDeviceInfo;
    var second = try adapters[0].requestDevice(a, .{});
    defer second.device.deinit();
    defer second.queue.deinit();
    if (second.device.context == dq.device.context or second.queue.context == dq.queue.context) return error.SharedDeviceContext;
    for (adapters) |*adapter| adapter.deinit();
    adapters_live = false;
    instance.deinit();
    instance_live = false;
    // Device retains the native device independently of Adapter/Instance.
    if (!try dq.device.supportsSampleCount(.bgra8_unorm, 1)) return error.MissingSingleSampleSupport;
    var buffer = try dq.device.createBuffer(a, .{ .size = 32, .usage = .{ .vertex = true }, .mapped_at_creation = true });
    defer buffer.destroy();
    if (!buffer.usage.storage or !buffer.usage.uniform or !buffer.usage.map_write) return error.IncorrectFacadeBufferPolicy;
    @memset(try buffer.getMappedRange(0, 32), 0x73);
    var sampler = try dq.device.createSampler(a, .{});
    defer sampler.destroy();
    var target = try dq.device.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    var target_live = true;
    defer if (target_live) target.destroy();
    var view = target.binding().createView();
    var view_live = true;
    defer if (view_live) view.destroy();
    var foreign = try second.device.createTexture(a, .{ .size = .{ .width = fixture.width, .height = fixture.height }, .format = .rgba8_unorm, .memory = .host_upload, .usage = .{ .texture_binding = true } });
    defer foreign.destroy();
    try foreign.writeRegion(0, 0, 0, fixture.width, fixture.height, fixture.bytes(), fixture.bytes_per_row);
    try expectError(error.ResourcesStillAlive, dq.device.deinitChecked());
    var module = try b.ShaderModule.initFromSource(&dq.device, @import("render").shader_sources.damage_clear);
    defer module.deinit();
    var vertex = try module.getFunction("damage_clear_vertex_main");
    defer vertex.deinit();
    var fragment = try module.getFunction("damage_clear_fragment_main");
    defer fragment.deinit();
    var pipeline = try b.createRenderPipeline(&dq.device, .{ .vertex_function = &vertex, .fragment_function = &fragment, .color_attachment_formats = &.{.bgra8_unorm} });
    defer pipeline.deinit();
    {
        var encoder = try b.CommandEncoder.init(&dq.queue);
        defer encoder.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .RED }} });
        try expectError(error.InvalidTextureBinding, pass.setFragmentTextureBindingChecked(0, foreign.binding()));
        pass.setPipeline(&pipeline);
        pass.setScissorRect(2, 1, 3, 2);
        try pass.drawChecked(3, 1, 0, 0);
        pass.end();
        var command = try encoder.finish();
        defer command.deinit();
        try command.submitChecked();
        try command.waitChecked(5000);
    }
    var pixels: [128]u8 = undefined;
    try target.readBgra8(8, 4, &pixels, 32);
    for (0..4) |y| for (0..8) |x| {
        const expected: [4]u8 = if (x >= 2 and x < 5 and y >= 1 and y < 3) .{ 0, 0, 0, 0 } else .{ 0, 0, 255, 255 };
        if (!std.mem.eql(u8, pixels[(y * 8 + x) * 4 ..][0..4], &expected)) return error.IncorrectFacadePixel;
    };
    // Teardown must preserve the stable context if its submitted work is blocked.
    const gate = zenit_d12_test_gate_create(dq.device.context.device.raw, dq.device.context.queue.raw);
    var signaled = false;
    defer {
        if (!signaled) zenit_d12_test_gate_signal(gate);
        zenit_d12_test_gate_release(gate);
    }
    {
        var encoder = try b.CommandEncoder.init(&dq.queue);
        defer encoder.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .load, .store_op = .store }} });
        pass.setPipeline(&pipeline);
        try pass.drawChecked(3, 1, 0, 0);
        pass.end();
        var command = try encoder.finish();
        defer command.deinit();
        try command.submitChecked();
        try expectError(error.GpuTimeout, command.waitChecked(0));
    }
    view.destroy();
    view_live = false;
    target.destroy();
    target_live = false;
    dq.queue.deinit();
    queue_live = false;
    dq.device.context.timeout_ms = 0;
    try expectError(error.GpuTimeout, dq.device.deinitChecked());
    zenit_d12_test_gate_signal(gate);
    signaled = true;
    dq.device.context.timeout_ms = 5000;
    try dq.device.deinitChecked();
    device_live = false;
    // Native buffers, samplers and shader/pipeline owners do not borrow Context.
    for (try buffer.getMappedRange(0, 32)) |byte| if (byte != 0x73) return error.BufferLostAfterFacadeDeinit;
    for (0..32) |i| std.mem.swap(u8, &pixels[i * 4], &pixels[i * 4 + 2]);
    std.debug.print("RENDERER_DEVICE_RGBA8_HEX={s}\nPASS: renderer Instance/Adapter/Device facade, 32 exact pixels, default adapter/feature-limit guards, adapter release independence, separate ordered contexts, cross-context texture rejection, resource-live guard and GPU-blocked deinit retry, buffer survival after context destruction\n", .{std.fmt.bytesToHex(pixels, .lower)});
}
