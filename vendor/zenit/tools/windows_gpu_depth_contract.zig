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
    \\float4 far(uint id:SV_VertexID):SV_Position{return position(id,0.75);}
    \\float4 near(uint id:SV_VertexID):SV_Position{return position(id,0.25);}
    \\float4 mid(uint id:SV_VertexID):SV_Position{return position(id,0.5);}
    \\float4 tiny(uint id:SV_VertexID):SV_Position{return position(id,0.125);}
    \\float4 red():SV_Target{return float4(1,0,0,1);}
    \\float4 green():SV_Target{return float4(0,1,0,1);}
    \\float4 blue():SV_Target{return float4(0,0,1,1);}
    \\float4 yellow():SV_Target{return float4(1,1,0,1);}
    \\float4 magenta():SV_Target{return float4(1,0,1,1);}
    \\float depth():SV_Depth{return 0.125;}
;
fn make(device: *d12.Device, module: *d12.ShaderModule, layout: *d12.PipelineLayout, vs: []const u8, ps: []const u8, state: gpu.DepthStencilState, depth_only: bool) !d12.RenderPipeline {
    var v = try module.getFunction(vs);
    defer v.deinit();
    var p = try module.getFunction(ps);
    defer p.deinit();
    return device.createRenderPipeline(.{ .layout = layout, .vertex_function = &v, .fragment_function = &p, .depth_stencil = state, .targets = if (depth_only) &.{} else &.{.{ .format = .rgba8_unorm }} });
}
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("depth queue teardown failed");
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = code, .entry_points = &.{
        .{ .name = "far", .stage = .vertex },       .{ .name = "near", .stage = .vertex },    .{ .name = "mid", .stage = .vertex },    .{ .name = "tiny", .stage = .vertex },
        .{ .name = "red", .stage = .fragment },     .{ .name = "green", .stage = .fragment }, .{ .name = "blue", .stage = .fragment }, .{ .name = "yellow", .stage = .fragment },
        .{ .name = "magenta", .stage = .fragment }, .{ .name = "depth", .stage = .fragment },
    } } } });
    defer module.deinit();
    var foreign = try d12.Device.init(true);
    defer foreign.destroy();
    var foreign_depth = try foreign.createTexture(a, .{ .size = .{ .width = 4, .height = 3 }, .format = .depth32_float, .usage = .{ .render_attachment = true } });
    defer foreign_depth.destroy();
    for ([_]gpu.TextureFormat{ .depth16_unorm, .depth24_plus, .depth32_float, .depth24_plus_stencil8, .depth32_float_stencil8 }) |format| {
        var encoder = try device.createCommandEncoder();
        defer encoder.deinit();
        var color = try device.createTexture(a, .{ .size = .{ .width = 4, .height = 3 }, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
        defer color.destroy();
        const region = try color.fullRegion(0, 0);
        const fp = try color.copyLayout(region, 0);
        var readback = try device.createBuffer(a, .{ .size = fp.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
        defer readback.destroy();
        {
            var depth = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 6, .depth = 2 }, .mip_level_count = 2, .format = format, .usage = .{ .render_attachment = true } });
            defer depth.destroy();
            try expectError(error.InvalidTextureDescriptor, device.createTexture(a, .{ .size = .{ .width = 4, .height = 3 }, .format = format, .usage = .{ .render_attachment = true, .storage_binding = true } }));
            try expectError(error.InvalidTextureRegion, depth.copyLayout(try depth.fullRegion(1, 1), 0));
            var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{} });
            defer layout.deinit();
            var state = gpu.DepthStencilState{ .format = format, .depth_write_enabled = true, .depth_compare = .less };
            var wrong_state = state;
            wrong_state.depth_bias_clamp = std.math.nan(f32);
            try expectError(error.InvalidRenderPipeline, make(&device, &module, &layout, "far", "red", wrong_state, false));
            wrong_state = state;
            wrong_state.format = if (format == .depth16_unorm) .depth32_float else .depth16_unorm;
            var wrong_format = try make(&device, &module, &layout, "far", "red", wrong_state, false);
            defer wrong_format.deinit();
            var far = try make(&device, &module, &layout, "far", "red", state, false);
            defer far.deinit();
            var near = try make(&device, &module, &layout, "near", "green", state, false);
            defer near.deinit();
            var mid = try make(&device, &module, &layout, "mid", "blue", state, false);
            defer mid.deinit();
            state.depth_write_enabled = false;
            var tiny = try make(&device, &module, &layout, "tiny", "yellow", state, false);
            defer tiny.deinit();
            state.depth_compare = .equal;
            var equal = try make(&device, &module, &layout, "mid", "magenta", state, false);
            defer equal.deinit();
            var final = try make(&device, &module, &layout, "tiny", "magenta", state, false);
            defer final.deinit();
            state.depth_write_enabled = true;
            state.depth_compare = .always;
            var depth_only = try make(&device, &module, &layout, "far", "depth", state, true);
            defer depth_only.deinit();
            const attachments = [_]d12.ColorAttachment{.{ .texture = &color, .load_op = .clear }};
            var attachment = d12.DepthStencilAttachment{ .texture = &depth, .mip = 1, .layer = 1, .depth_load_op = .clear, .depth_clear_value = 1 };
            try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &attachments, .depth_stencil_attachment = .{ .texture = &depth } }));
            try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &attachments, .depth_stencil_attachment = .{ .texture = &foreign_depth } }));
            try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &attachments, .depth_stencil_attachment = .{ .texture = &color } }));
            var invalid = attachment;
            invalid.depth_clear_value = std.math.nan(f32);
            try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &attachments, .depth_stencil_attachment = invalid }));
            invalid = attachment;
            invalid.depth_read_only = true;
            try expectError(error.InvalidRenderPass, encoder.beginRenderPass(.{ .color_attachments = &attachments, .depth_stencil_attachment = invalid }));
            var first = try encoder.beginRenderPass(.{ .color_attachments = &attachments, .depth_stencil_attachment = attachment });
            defer first.deinit();
            try expectError(error.InvalidDraw, first.draw(.{ .pipeline = &wrong_format, .vertex_count = 3 }));
            try first.draw(.{ .pipeline = &far, .vertex_count = 3 });
            try first.draw(.{ .pipeline = &near, .vertex_count = 3, .scissor = .{ .x = 1, .y = 1, .width = 2, .height = 1 } });
            try first.draw(.{ .pipeline = &mid, .vertex_count = 3 });
            try first.end();
            attachment.depth_load_op = .load;
            attachment.depth_read_only = true;
            var second = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &color }}, .depth_stencil_attachment = attachment });
            defer second.deinit();
            try expectError(error.InvalidDraw, second.draw(.{ .pipeline = &far, .vertex_count = 3 }));
            try second.draw(.{ .pipeline = &tiny, .vertex_count = 3, .scissor = .{ .width = 1, .height = 2 } });
            try second.draw(.{ .pipeline = &equal, .vertex_count = 3, .scissor = .{ .x = 3, .width = 1, .height = 3 } });
            try second.end();
            attachment.depth_load_op = .clear;
            attachment.depth_clear_value = 0.2;
            attachment.depth_read_only = false;
            var only = try encoder.beginRenderPass(.{ .depth_stencil_attachment = attachment });
            defer only.deinit();
            try only.draw(.{ .pipeline = &depth_only, .vertex_count = 3 });
            try only.end();
            attachment.depth_load_op = .load;
            attachment.depth_read_only = true;
            var last = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &color }}, .depth_stencil_attachment = attachment });
            defer last.deinit();
            try last.draw(.{ .pipeline = &final, .vertex_count = 3, .scissor = .{ .y = 2, .width = 1, .height = 1 } });
            try last.end();
        }
        try encoder.copyTextureToBuffer(&color, region, &readback, 0, fp.row_pitch);
        var command = try encoder.finish();
        const gate = zenit_d12_test_gate_create(device.raw, queue.raw);
        var signaled = false;
        defer {
            if (!signaled) zenit_d12_test_gate_signal(gate);
            queue.waitIdle(5000) catch @panic("depth gate teardown failed");
            zenit_d12_test_gate_release(gate);
        }
        _ = try queue.submit(&.{command});
        command.deinit();
        try expectError(error.GpuTimeout, queue.waitIdle(0));
        zenit_d12_test_gate_signal(gate);
        signaled = true;
        try queue.waitIdle(5000);
        const pixels = try readback.getMappedRange(0, readback.size);
        var frame: [4 * 3 * 4]u8 = undefined;
        for (0..3) |y| for (0..4) |x| {
            const expected: [4]u8 = if (x == 3 or (x == 0 and y == 2)) .{ 255, 0, 255, 255 } else if (x == 0 and y < 2) .{ 255, 255, 0, 255 } else if (y == 1 and x >= 1 and x < 3) .{ 0, 255, 0, 255 } else .{ 0, 0, 255, 255 };
            const pixel = pixels[y * fp.row_pitch + x * 4 ..][0..4];
            @memcpy(frame[(y * 4 + x) * 4 ..][0..4], pixel);
            if (!std.mem.eql(u8, pixel, &expected)) return error.IncorrectDepthPixel;
        };
        if (format == .depth32_float) std.debug.print("DEPTH_RGBA8_HEX={s}\n", .{std.fmt.bytesToHex(frame, .lower)});
        std.debug.print("PASS: production depth {s}, mip1/layer1, less/equal occlusion, load/read-only, depth-only SV_Depth, 12 colors and blocked-GPU retention\n", .{@tagName(format)});
    }
    try stencil(&device, &queue, &module);
}

fn stencil(device: *d12.Device, queue: *d12.Queue, module: *d12.ShaderModule) !void {
    const Branch = enum { pass, fail, depth_fail };
    const Case = struct { branch: Branch = .pass, op: gpu.StencilOperation, initial: u32, reference: u32 = 0x55, expected: u32, write_mask: u32 = 255, read_mask: u32 = 255 };
    const cases = [_]Case{
        .{ .op = .keep, .initial = 0x3c, .expected = 0x3c },
        .{ .op = .zero, .initial = 0x3c, .expected = 0 },
        .{ .op = .replace, .initial = 0x3c, .expected = 0x55 },
        .{ .op = .invert, .initial = 0x3c, .expected = 0xc3 },
        .{ .op = .increment_clamp, .initial = 255, .expected = 255 },
        .{ .op = .decrement_clamp, .initial = 0, .expected = 0 },
        .{ .op = .increment_wrap, .initial = 255, .expected = 0 },
        .{ .op = .decrement_wrap, .initial = 0, .expected = 255 },
        .{ .op = .replace, .initial = 0xa0, .expected = 0xa5, .write_mask = 15, .read_mask = 15 },
        .{ .branch = .fail, .op = .replace, .initial = 0x3c, .expected = 0x55 },
        .{ .branch = .depth_fail, .op = .replace, .initial = 0x3c, .expected = 0x55 },
    };
    for ([_]gpu.TextureFormat{ .depth24_plus_stencil8, .depth32_float_stencil8 }) |format| {
        for (cases) |case| {
            var encoder = try device.createCommandEncoder();
            defer encoder.deinit();
            var color = try device.createTexture(a, .{ .size = .{ .width = 4, .height = 2 }, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
            defer color.destroy();
            const region = try color.fullRegion(0, 0);
            const fp = try color.copyLayout(region, 0);
            var readback = try device.createBuffer(a, .{ .size = fp.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
            defer readback.destroy();
            {
                var depth = try device.createTexture(a, .{ .size = .{ .width = 8, .height = 4, .depth = 2 }, .mip_level_count = 2, .format = format, .usage = .{ .render_attachment = true } });
                defer depth.destroy();
                var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{} });
                defer layout.deinit();
                var state = gpu.DepthStencilState{ .format = format, .depth_write_enabled = false, .depth_compare = .always, .stencil_write_mask = case.write_mask, .stencil_front = .{ .pass_op = case.op }, .stencil_back = .{ .pass_op = case.op } };
                switch (case.branch) {
                    .pass => {},
                    .fail => state.stencil_front = .{ .compare = .never, .fail_op = case.op },
                    .depth_fail => {
                        state.depth_compare = .never;
                        state.stencil_front = .{ .depth_fail_op = case.op };
                    },
                }
                state.stencil_back = state.stencil_front;
                var writer = try make(device, module, &layout, "far", "depth", state, true);
                defer writer.deinit();
                state.depth_compare = .always;
                state.stencil_front = .{ .compare = .equal };
                state.stencil_back = state.stencil_front;
                state.stencil_read_mask = case.read_mask;
                state.stencil_write_mask = 0;
                var reader = try make(device, module, &layout, "far", "green", state, false);
                defer reader.deinit();
                var attachment = d12.DepthStencilAttachment{ .texture = &depth, .mip = 1, .layer = 1, .depth_load_op = .clear, .depth_clear_value = 1, .stencil_load_op = .clear, .stencil_clear_value = case.initial };
                var first = try encoder.beginRenderPass(.{ .depth_stencil_attachment = attachment });
                defer first.deinit();
                try expectError(error.InvalidDraw, first.draw(.{ .pipeline = &writer, .vertex_count = 3, .stencil_reference = 256 }));
                try first.draw(.{ .pipeline = &writer, .vertex_count = 3, .stencil_reference = case.reference, .scissor = .{ .width = 2, .height = 2 } });
                try first.end();
                attachment.depth_load_op = .load;
                attachment.stencil_load_op = .load;
                attachment.depth_read_only = true;
                attachment.stencil_read_only = true;
                var second = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &color, .load_op = .clear, .clear_value = .{ 0, 0, 1, 1 } }}, .depth_stencil_attachment = attachment });
                defer second.deinit();
                // Depth-only writer mismatches the color target count, so use a
                // color-compatible writer to isolate readonly stencil admission.
                state.stencil_front = .{ .pass_op = .replace };
                state.stencil_back = state.stencil_front;
                state.stencil_write_mask = 255;
                var forbidden = try make(device, module, &layout, "far", "red", state, false);
                defer forbidden.deinit();
                try expectError(error.InvalidDraw, second.draw(.{ .pipeline = &forbidden, .vertex_count = 3 }));
                try second.draw(.{ .pipeline = &reader, .vertex_count = 3, .stencil_reference = case.expected });
                try second.end();
                try encoder.copyTextureToBuffer(&color, region, &readback, 0, fp.row_pitch);
                // Undefined discard contents are not asserted; both plane paths
                // are executed only after color evidence has been copied.
                attachment.depth_read_only = false;
                attachment.stencil_read_only = false;
                attachment.depth_load_op = .dont_care;
                attachment.stencil_load_op = .dont_care;
                attachment.depth_store_op = .discard;
                attachment.stencil_store_op = .discard;
                var discard = try encoder.beginRenderPass(.{ .depth_stencil_attachment = attachment });
                defer discard.deinit();
                try discard.end();
            }
            var command = try encoder.finish();
            defer command.deinit();
            _ = try queue.submit(&.{command});
            try queue.waitIdle(5000);
            const pixels = try readback.getMappedRange(0, readback.size);
            for (0..2) |y| for (0..4) |x| {
                const green = x < 2 or (case.initial & case.read_mask) == (case.expected & case.read_mask);
                const expected: [4]u8 = if (green) .{ 0, 255, 0, 255 } else .{ 0, 0, 255, 255 };
                if (!std.mem.eql(u8, pixels[y * fp.row_pitch + x * 4 ..][0..4], &expected)) return error.IncorrectStencilPixel;
            };
            std.debug.print("PASS: production stencil {s} {s} branch={s} mask={x}, selected mip/layer, clear/load/read-only/discard, eight pixel mask checks\n", .{ @tagName(format), @tagName(case.op), @tagName(case.branch), case.write_mask });
        }
    }
}
