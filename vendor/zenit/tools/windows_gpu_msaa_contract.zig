const std = @import("std");
const gpu = @import("gpu");
const d12 = @import("gpu").Backend.native;
const a = std.heap.page_allocator;
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |actual| if (actual != expected) return actual;
}
const code =
    \\float4 position(uint id,float z){return float4(id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3),z,1);}
    \\float4 vertex(uint id:SV_VertexID):SV_Position{return position(id,0.5);}
    \\float4 near(uint id:SV_VertexID):SV_Position{return position(id,0.25);}
    \\float4 far(uint id:SV_VertexID):SV_Position{return position(id,0.75);}
    \\float4 red():SV_Target{return float4(1,0,0,1);}
    \\float4 green():SV_Target{return float4(0,1,0,1);}
    \\float4 zero():SV_Target{return float4(1,1,1,0);}
    \\float4 sample(uint i:SV_SampleIndex):SV_Target{return i<threshold?float4(1,0,0,1):float4(0,1,0,1);}
;
fn make(device: *d12.Device, layout: *d12.PipelineLayout, module: *d12.ShaderModule, format: gpu.TextureFormat, count: u32, vs: []const u8, ps: []const u8, mask: u64, coverage: bool) !d12.RenderPipeline {
    var v = try module.getFunction(vs);
    defer v.deinit();
    var p = try module.getFunction(ps);
    defer p.deinit();
    return device.createRenderPipeline(.{ .layout = layout, .vertex_function = &v, .fragment_function = &p, .targets = &.{.{ .format = format }}, .depth_stencil = .{ .format = .depth32_float, .depth_write_enabled = true, .depth_compare = .less }, .multisample = .{ .count = count, .mask = mask, .alpha_to_coverage_enabled = coverage } });
}
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("MSAA queue teardown failed");
    var checked: u32 = 0;
    for ([_]gpu.TextureFormat{ .rgba8_unorm, .bgra8_unorm }) |format| {
        for ([_]u32{ 2, 4, 8, 16, 32 }) |count| {
            const color_supported = try device.supportsSampleCount(format, count);
            const depth_supported = try device.supportsSampleCount(.depth32_float, count);
            if (!color_supported or !depth_supported) {
                if (!color_supported) try expectError(error.InvalidTextureDescriptor, device.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = format, .sample_count = count, .usage = .{ .render_attachment = true } }));
                if (!depth_supported) try expectError(error.InvalidTextureDescriptor, device.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = .depth32_float, .sample_count = count, .usage = .{ .render_attachment = true } }));
                std.debug.print("UNSUPPORTED (not passed): MSAA {s} count={d}\n", .{ @tagName(format), count });
                continue;
            }
            var encoder = try device.createCommandEncoder();
            defer encoder.deinit();
            var readback = try device.createBuffer(a, .{ .size = 2048, .usage = .{ .map_read = true, .copy_dst = true } });
            defer readback.destroy();
            {
                var ms = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 4, .depth = 2 }, .format = format, .sample_count = count, .usage = .{ .render_attachment = true, .copy_src = true } });
                defer ms.destroy();
                var depth = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 4, .depth = 2 }, .format = .depth32_float, .sample_count = count, .usage = .{ .render_attachment = true } });
                defer depth.destroy();
                var target = try device.createTexture(a, .{ .size = .{ .width = 16, .height = 8, .depth = 2 }, .mip_level_count = 2, .format = format, .usage = .{ .render_attachment = true, .copy_src = true } });
                defer target.destroy();
                try expectError(error.InvalidTextureRegion, ms.copyLayout(try ms.fullRegion(0, 1), 0));
                try expectError(error.InvalidTextureDescriptor, device.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .mip_level_count = 2, .format = format, .sample_count = count, .usage = .{ .render_attachment = true } }));
                try expectError(error.InvalidTextureDescriptor, device.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = format, .sample_count = count, .usage = .{ .texture_binding = true } }));
                var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{} });
                defer layout.deinit();
                const source = try std.fmt.allocPrint(a, "static const uint threshold={d};\n{s}", .{ count / 2, code });
                defer a.free(source);
                var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = source, .entry_points = &.{
                    .{ .name = "vertex", .stage = .vertex },   .{ .name = "near", .stage = .vertex },    .{ .name = "far", .stage = .vertex },
                    .{ .name = "red", .stage = .fragment },    .{ .name = "green", .stage = .fragment }, .{ .name = "zero", .stage = .fragment },
                    .{ .name = "sample", .stage = .fragment },
                } } } });
                defer module.deinit();
                const shift: u6 = @intCast(count / 2);
                var masked = try make(&device, &layout, &module, format, count, "vertex", "red", (@as(u64, 1) << shift) - 1, false);
                defer masked.deinit();
                var per_sample = try make(&device, &layout, &module, format, count, "near", "sample", 0xffffffff, false);
                defer per_sample.deinit();
                var zero = try make(&device, &layout, &module, format, count, "near", "zero", 0xffffffff, true);
                defer zero.deinit();
                var full = try make(&device, &layout, &module, format, count, "near", "green", 0xffffffff, true);
                defer full.deinit();
                var far = try make(&device, &layout, &module, format, count, "far", "green", 0xffffffff, false);
                defer far.deinit();
                var mismatch = try make(&device, &layout, &module, format, 1, "vertex", "red", 0xffffffff, false);
                defer mismatch.deinit();
                var sentinel = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &target, .mip = 1, .layer = 0, .load_op = .clear, .clear_value = .{ 1, 1, 0, 1 } }} });
                defer sentinel.deinit();
                try sentinel.end();
                const colors = [_]d12.ColorAttachment{.{ .texture = &ms, .layer = 1, .load_op = .clear, .store_op = .discard, .clear_value = .{ 0, 0, 1, 1 }, .resolve_target = .{ .texture = &target, .mip = 1, .layer = 1 } }};
                const ds = d12.DepthStencilAttachment{ .texture = &depth, .layer = 1, .depth_load_op = .clear, .depth_clear_value = 1 };
                var wrong = colors;
                wrong[0].resolve_target.?.mip = 0;
                try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &wrong, .depth_stencil_attachment = ds }));
                wrong = colors;
                wrong[0].resolve_target.?.texture = &ms;
                try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &wrong, .depth_stencil_attachment = ds }));
                wrong = colors;
                wrong[0].texture = &target;
                wrong[0].mip = 1;
                try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &wrong }));
                var foreign = try d12.Device.init(true);
                defer foreign.destroy();
                var foreign_target = try foreign.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = format, .usage = .{ .render_attachment = true } });
                defer foreign_target.destroy();
                wrong = colors;
                wrong[0].resolve_target = .{ .texture = &foreign_target };
                try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &wrong, .depth_stencil_attachment = ds }));
                var wrong_format = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = if (format == .rgba8_unorm) .bgra8_unorm else .rgba8_unorm, .usage = .{ .render_attachment = true } });
                defer wrong_format.destroy();
                wrong[0].resolve_target = .{ .texture = &wrong_format };
                try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &wrong, .depth_stencil_attachment = ds }));
                var wrong_usage = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = format, .usage = .{ .copy_src = true } });
                defer wrong_usage.destroy();
                wrong[0].resolve_target = .{ .texture = &wrong_usage };
                try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &wrong, .depth_stencil_attachment = ds }));
                var other_ms = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = format, .sample_count = count, .usage = .{ .render_attachment = true } });
                defer other_ms.destroy();
                try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &.{ colors[0], .{ .texture = &other_ms, .resolve_target = colors[0].resolve_target } } }));
                var single_depth = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .format = .depth32_float, .usage = .{ .render_attachment = true } });
                defer single_depth.destroy();
                try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &colors, .depth_stencil_attachment = .{ .texture = &single_depth } }));
                var pass = try encoder.beginRenderPass(.{ .color_attachments = &colors, .depth_stencil_attachment = ds });
                defer pass.deinit();
                try expectError(error.InvalidDraw, pass.draw(.{ .pipeline = &mismatch, .vertex_count = 3 }));
                try pass.draw(.{ .pipeline = &masked, .vertex_count = 3 });
                try pass.draw(.{ .pipeline = &per_sample, .vertex_count = 3, .scissor = .{ .x = 4, .width = 2, .height = 4 } });
                try pass.draw(.{ .pipeline = &zero, .vertex_count = 3, .scissor = .{ .y = 2, .width = 2, .height = 2 } });
                try pass.draw(.{ .pipeline = &full, .vertex_count = 3, .scissor = .{ .x = 2, .y = 2, .width = 2, .height = 2 } });
                try pass.draw(.{ .pipeline = &far, .vertex_count = 3, .scissor = .{ .x = 6, .width = 2, .height = 4 } });
                try pass.end();
                try encoder.copyTextureToBuffer(&target, try target.fullRegion(1, 1), &readback, 0, 256);
                try encoder.copyTextureToBuffer(&target, try target.fullRegion(1, 0), &readback, 1024, 256);
            }
            var command = try encoder.finish();
            const gate = zenit_d12_test_gate_create(device.raw, queue.raw);
            var signaled = false;
            defer {
                if (!signaled) zenit_d12_test_gate_signal(gate);
                queue.waitIdle(5000) catch @panic("MSAA gate teardown failed");
                zenit_d12_test_gate_release(gate);
            }
            _ = try queue.submit(&.{command});
            command.deinit();
            try expectError(error.GpuTimeout, queue.waitIdle(0));
            try expectError(error.GpuTimeout, queue.deinit(0));
            zenit_d12_test_gate_signal(gate);
            signaled = true;
            try queue.waitIdle(5000);
            const bytes = try readback.getMappedRange(0, readback.size);
            var frame: [8 * 4 * 4]u8 = undefined;
            for (0..4) |y| for (0..8) |x| {
                const p = bytes[y * 256 + x * 4 ..][0..4];
                const c: [4]u8 = if (format == .bgra8_unorm) .{ p[2], p[1], p[0], p[3] } else p.*;
                @memcpy(frame[(y * 8 + x) * 4 ..][0..4], &c);
                const fully_covered = x >= 2 and x < 4 and y >= 2;
                const rg = x >= 4;
                const expected: [4]u8 = if (fully_covered) .{ 0, 255, 0, 255 } else if (rg) .{ 128, 128, 0, 255 } else .{ 128, 0, 128, 255 };
                for (c, expected) |actual, e| if (@abs(@as(i16, actual) - @as(i16, e)) > 1) return error.IncorrectMsaaResolve;
                const sentinel = bytes[1024 + y * 256 + x * 4 ..][0..4];
                const expected_sentinel: [4]u8 = if (format == .bgra8_unorm) .{ 0, 255, 255, 255 } else .{ 255, 255, 0, 255 };
                if (!std.mem.eql(u8, sentinel, &expected_sentinel)) return error.MsaaTouchedWrongLayer;
            };
            if (format == .rgba8_unorm and count == 4) std.debug.print("MSAA_RGBA8_HEX={s}\n", .{std.fmt.bytesToHex(frame, .lower)});
            std.debug.print("PASS: production MSAA {s} count={d}, mask/SV_SampleIndex/alpha-coverage/per-sample depth, array layer1 to mip1/layer1 resolve before discard, 64 pixels and blocked-GPU owner retention\n", .{ @tagName(format), count });
            checked += 1;
        }
    }
    if (checked == 0) return error.NoVerifiedMsaaSupport;
}
