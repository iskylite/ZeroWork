//! Shared Linux renderer contracts; instantiated with the native driver.
pub fn For(comptime Driver: type) type {
    return struct {
        //! Deferred renderer commands. Buffer contents are copied at draw recording,
        //! including unaligned logical offsets; Linux GPU sees aligned, owned snapshots.
        //! Images, samplers and pipelines are retained through synchronous submission.
        const std = @import("std");
        const gpu = @import("../gpu.zig");
        const vk = Driver;
        const r = @import("renderer_resources.zig").For(Driver);
        const p = @import("renderer_pipeline.zig").For(Driver);
        pub const Queue = struct {
            context: *r.Context,
            pub fn init(context: *r.Context) Queue {
                return .{ .context = context };
            }
            pub fn deinit(self: *Queue) void {
                self.* = undefined;
            }
        };
        const BufferSource = union(enum) {
            buffer: struct { value: r.Buffer, offset: u64 },
            bytes: []u8,
            fn release(self: *BufferSource, a: std.mem.Allocator) void {
                switch (self.*) {
                    .buffer => |*b| b.value.destroy(),
                    .bytes => |b| a.free(b),
                }
            }
            fn data(self: *const BufferSource, minimum: u32, uniform: bool) ![]const u8 {
                const bytes: []const u8 = switch (self.*) {
                    .buffer => |b| blk: {
                        const owner = b.value.owner orelse return error.InvalidDescriptor;
                        if (b.offset > owner.bytes.len) return error.InvalidBufferOffset;
                        break :blk owner.bytes[@intCast(b.offset)..];
                    },
                    .bytes => |b| b,
                };
                if (bytes.len == 0 or bytes.len < minimum) return error.BufferBindingTooSmall;
                return if (uniform) bytes[0..minimum] else bytes;
            }
        };
        const PassState = struct {
            target: ?r.Texture = null,
            pipeline: ?p.RenderPipeline = null,
            vertex: [64]?BufferSource = @splat(null),
            fragment: [64]?BufferSource = @splat(null),
            textures: [64]?r.Texture = @splat(null),
            samplers: [64]?r.Sampler = @splat(null),
            region: vk.pipeline.DrawRegion = undefined,
            fn release(self: *PassState, a: std.mem.Allocator) void {
                if (self.target) |*v| v.destroy();
                if (self.pipeline) |*v| v.deinit();
                for (&self.vertex, &self.fragment) |*v, *f| {
                    if (v.*) |*b| b.release(a);
                    if (f.*) |*b| b.release(a);
                }
                for (&self.textures) |*v| if (v.*) |*t| t.destroy();
                for (&self.samplers) |*v| if (v.*) |*s| s.destroy();
                self.* = .{};
            }
        };
        const Snapshot = struct {
            binding: p.Binding,
            native_buffer: ?*vk.resources.Buffer = null,
            shared_buffer: bool = false,
            value: union(enum) { buffer: []u8, texture: r.Texture, sampler: r.Sampler },
            fn release(self: *Snapshot, a: std.mem.Allocator) void {
                switch (self.value) {
                    .buffer => |b| if (!self.shared_buffer) a.free(b),
                    .texture => |*t| t.destroy(),
                    .sampler => |*s| s.destroy(),
                }
            }
        };
        const Draw = struct {
            pipeline: p.RenderPipeline,
            target: r.Texture,
            bindings: []Snapshot,
            region: vk.pipeline.DrawRegion,
            first_vertex: u32,
            vertices: u32,
            first_instance: u32,
            instances: u32,
            fn release(self: *Draw, a: std.mem.Allocator) void {
                for (self.bindings) |*b| b.release(a);
                self.pipeline.deinit();
                self.target.destroy();
            }
            fn execute(self: *Draw, context: *r.Context) !void {
                // Upload buffers come from the context pool (busy until the
                // submission's completion boundary); only overflow is transient.
                var buffers: [64]?vk.resources.Buffer = @splat(null);
                var transient: [64]bool = @splat(false);
                defer for (&buffers, transient) |*b, t| if (t) if (b.*) |*v| v.destroy();
                var bindings: [64]vk.pipeline.DrawBinding = undefined;
                var diag: vk.Diagnostic = .{};
                for (self.bindings, 0..) |*snapshot, i| {
                    const meta = snapshot.binding;
                    bindings[i] = switch (snapshot.value) {
                        .buffer => |bytes| blk: {
                            if (snapshot.native_buffer) |shared| break :blk try .buffer(meta.group, meta.binding, meta.kind == 2, shared, 0, bytes.len);
                            const upload = try context.acquireUpload(bytes.len, if (meta.kind == 2) 128 else 64, &diag);
                            buffers[i] = upload.buffer;
                            transient[i] = !upload.pooled;
                            try buffers[i].?.write(0, bytes, &diag);
                            break :blk try .buffer(meta.group, meta.binding, meta.kind == 2, &buffers[i].?, 0, bytes.len);
                        },
                        .texture => |*t| try .texture(meta.group, meta.binding, try t.native()),
                        .sampler => |*s| try .sampler(meta.group, meta.binding, try s.native()),
                    };
                }
                const owner = self.pipeline.owner orelse return error.InvalidDescriptor;
                owner.inner.drawRegion(try self.target.native(), bindings[0..self.bindings.len], self.first_vertex, self.vertices, self.first_instance, self.instances, null, self.region, &diag) catch |err| {
                    std.log.err("Linux GPU draw failed: {s} operation={s} result={d}", .{ @errorName(err), diag.operationName(), diag.resultCode() });
                    return err;
                };
            }
        };
        const Command = union(enum) {
            clear: struct { target: r.Texture, rgba: [4]f32 },
            draw: Draw,
            copy: struct { source: r.Texture, destination: r.Texture, sx: u32, sy: u32, dx: u32, dy: u32, width: u32, height: u32 },
            present: r.Texture,
            fn release(self: *Command, a: std.mem.Allocator) void {
                switch (self.*) {
                    .clear => |*v| v.target.destroy(),
                    .draw => |*v| v.release(a),
                    .copy => |*v| {
                        v.source.destroy();
                        v.destination.destroy();
                    },
                    .present => |*v| v.destroy(),
                }
            }
            fn execute(self: *Command, context: *r.Context) !void {
                var diag: vk.Diagnostic = .{};
                switch (self.*) {
                    .clear => |*v| try (try v.target.native()).clear(v.rgba, &diag),
                    .draw => |*v| try v.execute(context),
                    .copy => |*v| try (try v.source.native()).copyTo(v.sx, v.sy, try v.destination.native(), v.dx, v.dy, v.width, v.height, &diag),
                    .present => |*v| try context.device.presentTexture(try v.native(), &diag),
                }
            }
        };
        const CachedSnapshot = struct {
            source: r.Buffer,
            kind: u32,
            bytes: []u8,
            native_buffer: ?vk.resources.Buffer = null,
        };
        const State = struct {
            context: *r.Context,
            refs: usize = 1,
            commands: std.ArrayList(Command) = .empty,
            snapshots: std.ArrayList(CachedSnapshot) = .empty,
            snapshot_arena: std.heap.ArenaAllocator,
            active: enum { none, render, blit } = .none,
            generation: u64 = 0,
            pass: PassState = .{},
            failure: ?anyerror = null,
            gpu_elapsed_ns: ?u64 = null,
            status: enum { recording, recorded, complete, failed } = .recording,
            fn snapshotBuffer(self: *State, source: *const BufferSource, bytes: []const u8, kind: u32) ![]u8 {
                // Held mappings can change without a new map call. Match actual
                // draw ranges and their contents, never a write-generation tag.
                const original = source.buffer;
                for (self.snapshots.items) |*cached| {
                    if (cached.kind == kind and vk.snapshotBytesEqual(cached.bytes, bytes))
                        return cached.bytes;
                }
                const a = self.context.allocator;
                // These immutable CPU copies have command-buffer lifetime.
                // A per-recording arena avoids many Debug allocator allocations
                // while retaining exact bounds and draw-time snapshot semantics.
                const copy = try self.snapshot_arena.allocator().dupe(u8, bytes);
                const retained = original.value.retained();
                errdefer {
                    var held = retained;
                    held.destroy();
                }
                try self.snapshots.append(a, .{ .source = retained, .kind = kind, .bytes = copy });
                return copy;
            }
            fn release(self: *State) void {
                self.refs -= 1;
                if (self.refs != 0) return;
                const a = self.context.allocator;
                self.pass.release(a);
                for (self.commands.items) |*c| c.release(a);
                self.commands.deinit(a);
                for (self.snapshots.items) |*cached| {
                    cached.source.destroy();
                }
                self.snapshots.deinit(a);
                self.snapshot_arena.deinit();
                self.context.pending_commands -= 1;
                a.destroy(self);
            }
        };
        pub const CommandEncoder = struct {
            state: ?*State,
            pub fn init(queue: *Queue) !CommandEncoder {
                const state = try queue.context.allocator.create(State);
                state.* = .{ .context = queue.context, .snapshot_arena = std.heap.ArenaAllocator.init(queue.context.allocator) };
                queue.context.pending_commands += 1;
                return .{ .state = state };
            }
            pub fn beginRenderPass(self: *CommandEncoder, desc: gpu.RenderPassDescriptor) !RenderPass {
                const state = self.state orelse return error.InvalidEncoder;
                if (state.active != .none) return error.PassAlreadyOpen;
                if (desc.color_attachments.len != 1 or desc.depth_stencil_attachment != null) return error.UnsupportedRenderPass;
                const attachment = desc.color_attachments[0];
                if (attachment.resolve_target != null) return error.UnsupportedRenderPass;
                var target = try attachment.view.binding().retainedTexture();
                errdefer target.destroy();
                if (target.owner.?.context != state.context) return error.ForeignDeviceResource;
                if (attachment.load_op != .load) {
                    const c = attachment.clear_value;
                    var clear: Command = .{ .clear = .{ .target = target.retained(), .rgba = if (attachment.load_op == .clear) .{ @floatCast(c.r), @floatCast(c.g), @floatCast(c.b), @floatCast(c.a) } else .{ 0, 0, 0, 0 } } };
                    errdefer clear.release(state.context.allocator);
                    try state.commands.append(state.context.allocator, clear);
                }
                state.pass = .{ .target = target, .region = .{ .viewport = .{ 0, 0, @floatFromInt(target.size.width), @floatFromInt(target.size.height), 0, 1 }, .scissor = .{ 0, 0, target.size.width, target.size.height } } };
                state.active = .render;
                state.generation += 1;
                return .{ .encoder = self, .generation = state.generation };
            }
            pub fn beginBlitPass(self: *CommandEncoder) !BlitPass {
                const state = self.state orelse return error.InvalidEncoder;
                if (state.active != .none) return error.PassAlreadyOpen;
                state.active = .blit;
                state.generation += 1;
                return .{ .encoder = self, .generation = state.generation };
            }
            pub fn finish(self: *CommandEncoder) !CommandBuffer {
                const state = self.state orelse return error.InvalidEncoder;
                if (state.active != .none) return error.PassStillOpen;
                if (state.failure) |err| return err;
                state.status = .recorded;
                self.state = null;
                return .{ .state = state };
            }
            pub fn deinit(self: *CommandEncoder) void {
                if (self.state) |state| state.release();
                self.state = null;
            }
        };
        pub const RenderPass = struct {
            pub var frame_draw_call_count: u32 = 0;
            encoder: *CommandEncoder,
            generation: u64,
            pub fn isActive(self: *const RenderPass) bool {
                const s = self.encoder.state orelse return false;
                return s.active == .render and s.generation == self.generation;
            }
            fn state(self: *const RenderPass) *State {
                if (!self.isActive()) @panic("inactive Linux GPU render pass");
                return self.encoder.state.?;
            }
            pub fn setPipeline(self: *RenderPass, pipeline: *const p.RenderPipeline) void {
                const s = self.state();
                if (s.pass.pipeline) |*v| v.deinit();
                s.pass.pipeline = pipeline.retained();
            }
            pub fn setViewport(self: *RenderPass, x: f32, y: f32, w: f32, h: f32, min: f32, max: f32) void {
                self.state().pass.region.viewport = .{ x, y, w, h, min, max };
            }
            pub fn setScissorRect(self: *RenderPass, x: u32, y: u32, w: u32, h: u32) void {
                self.state().pass.region.scissor = .{ x, y, w, h };
            }
            fn setBuffer(self: *RenderPass, vertex: bool, slot: u32, buffer: *const r.Buffer, offset: u64) void {
                const s = self.state();
                if (slot >= 64) {
                    s.failure = error.UnsupportedBindingSlot;
                    return;
                }
                const owner = buffer.owner orelse {
                    s.failure = error.InvalidDescriptor;
                    return;
                };
                if (owner.context != s.context or offset > buffer.size) {
                    s.failure = error.InvalidBufferOffset;
                    return;
                }
                const at = if (vertex) &s.pass.vertex[slot] else &s.pass.fragment[slot];
                if (at.*) |*old| old.release(s.context.allocator);
                at.* = .{ .buffer = .{ .value = buffer.retained(), .offset = offset } };
            }
            pub fn setVertexBuffer(self: *RenderPass, slot: u32, buffer: *const r.Buffer, offset: u64) void {
                self.setBuffer(true, slot, buffer, offset);
            }
            pub fn setFragmentBuffer(self: *RenderPass, slot: u32, buffer: *const r.Buffer, offset: u64) void {
                self.setBuffer(false, slot, buffer, offset);
            }
            fn setBytes(self: *RenderPass, vertex: bool, slot: u32, data: []const u8) void {
                const s = self.state();
                if (slot >= 64) {
                    s.failure = error.UnsupportedBindingSlot;
                    return;
                }
                const bytes = s.context.allocator.dupe(u8, data) catch |err| {
                    s.failure = err;
                    return;
                };
                const at = if (vertex) &s.pass.vertex[slot] else &s.pass.fragment[slot];
                if (at.*) |*old| old.release(s.context.allocator);
                at.* = .{ .bytes = bytes };
            }
            pub fn setVertexBytes(self: *RenderPass, slot: u32, data: []const u8) void {
                self.setBytes(true, slot, data);
            }
            pub fn setFragmentBytes(self: *RenderPass, slot: u32, data: []const u8) void {
                self.setBytes(false, slot, data);
            }
            pub fn setFragmentTexture(self: *RenderPass, slot: u32, texture: *const r.Texture) void {
                self.setFragmentTextureBinding(slot, texture.binding());
            }
            pub fn setFragmentTextureBinding(self: *RenderPass, slot: u32, binding: r.TextureBinding) void {
                const s = self.state();
                if (slot >= 64) {
                    s.failure = error.UnsupportedBindingSlot;
                    return;
                }
                var value = binding.retainedTexture() catch |err| {
                    s.failure = err;
                    return;
                };
                if (value.owner.?.context != s.context) {
                    value.destroy();
                    s.failure = error.ForeignDeviceResource;
                    return;
                }
                if (s.pass.textures[slot]) |*old| old.destroy();
                s.pass.textures[slot] = value;
            }
            pub fn setFragmentSampler(self: *RenderPass, slot: u32, sampler: ?*const r.Sampler) void {
                const s = self.state();
                if (slot >= 64) {
                    s.failure = error.UnsupportedBindingSlot;
                    return;
                }
                if (sampler) |v| {
                    const owner = v.owner orelse {
                        s.failure = error.InvalidDescriptor;
                        return;
                    };
                    if (owner.context != s.context) {
                        s.failure = error.ForeignDeviceResource;
                        return;
                    }
                }
                if (s.pass.samplers[slot]) |*old| old.destroy();
                s.pass.samplers[slot] = if (sampler) |v| v.retained() else null;
            }
            fn recordDraw(self: *RenderPass, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) !void {
                const s = self.state();
                if (vertices == 0 or instances == 0) return;
                const pipeline = s.pass.pipeline orelse return error.MissingPipeline;
                const owner = pipeline.owner orelse return error.InvalidDescriptor;
                const target = s.pass.target orelse return error.MissingRenderTarget;
                if (owner.context != s.context or owner.format != target.format) return error.InvalidRenderTarget;
                const a = s.context.allocator;
                const owned_bindings = try s.snapshot_arena.allocator().alloc(Snapshot, owner.bindings.len);
                var initialized: usize = 0;
                errdefer for (owned_bindings[0..initialized]) |*b| b.release(a);
                for (owner.bindings) |meta| {
                    if (meta.binding >= 64) return error.UnsupportedBindingSlot;
                    const slot = meta.binding;
                    var snapshot: Snapshot = .{ .binding = meta, .value = undefined };
                    switch (meta.kind) {
                        0, 2 => {
                            if (meta.group != 0) return error.UnsupportedBindingGroup;
                            const vs = if (meta.stages & 1 != 0) s.pass.vertex[slot] else null;
                            const fs = if (meta.stages & 2 != 0) s.pass.fragment[slot] else null;
                            const source = vs orelse fs orelse return error.MissingBufferBinding;
                            const full_bytes = try source.data(meta.min_size, meta.kind == 0);
                            var bytes = full_bytes;
                            // Only these production entries index binding 1 by
                            // instance ID. Keep its prefix for first_instance,
                            // but do not copy/upload the unused 8192-item tail
                            // on every draw. Indirect gradients/shadows and
                            // arbitrary storage buffers retain their full range.
                            if (comptime @hasDecl(vk, "snapshotBytesEqual")) {
                                if (owner.instance_indexed and meta.kind == 2 and meta.group == 0 and meta.binding == 1 and meta.stride > 0) {
                                    const instance_end = try std.math.add(usize, first_instance, instances);
                                    const needed = try std.math.mul(usize, instance_end, meta.stride);
                                    if (needed > bytes.len) return error.BufferBindingTooSmall;
                                    bytes = bytes[0..needed];
                                }
                            }
                            if (vs != null and fs != null) {
                                const other = try fs.?.data(meta.min_size, meta.kind == 0);
                                if (other.len < bytes.len or (bytes.ptr != other.ptr and !std.mem.eql(u8, bytes, other[0..bytes.len]))) return error.ConflictingStageBuffers;
                            }
                            snapshot.value = .{ .buffer = blk: {
                                if (comptime @hasDecl(vk, "snapshotBytesEqual")) {
                                    if (source == .buffer) {
                                        snapshot.shared_buffer = true;
                                        break :blk try s.snapshotBuffer(&source, bytes, meta.kind);
                                    }
                                }
                                break :blk try a.dupe(u8, bytes);
                            } };
                        },
                        1 => {
                            if (meta.group != 1 or meta.stages & 1 != 0) return error.UnsupportedBindingGroup;
                            snapshot.value = .{ .texture = (s.pass.textures[slot] orelse return error.MissingTextureBinding).retained() };
                        },
                        4 => {
                            if (meta.group != 2 or meta.stages & 1 != 0) return error.UnsupportedBindingGroup;
                            snapshot.value = .{ .sampler = (s.pass.samplers[slot] orelse return error.MissingSamplerBinding).retained() };
                        },
                        else => return error.UnsupportedBindingKind,
                    }
                    owned_bindings[initialized] = snapshot;
                    initialized += 1;
                }
                var command: Command = .{ .draw = .{ .pipeline = pipeline.retained(), .target = target.retained(), .bindings = owned_bindings, .region = s.pass.region, .first_vertex = first_vertex, .vertices = vertices, .first_instance = first_instance, .instances = instances } };
                // Resource ownership moves to command. Array storage belongs to
                // the recording arena and is retired after all commands.
                initialized = 0;
                errdefer command.release(a);
                try s.commands.append(a, command);
                frame_draw_call_count += 1;
            }
            pub fn draw(self: *RenderPass, vertices: u32, instances: u32, first_vertex: u32, first_instance: u32) void {
                self.recordDraw(vertices, instances, first_vertex, first_instance) catch |err| {
                    self.state().failure = err;
                };
            }
            pub fn end(self: *RenderPass) void {
                const s = self.state();
                s.pass.release(s.context.allocator);
                s.active = .none;
            }
        };
        pub const BlitPass = struct {
            encoder: *CommandEncoder,
            generation: u64,
            pub fn isActive(self: *const BlitPass) bool {
                const s = self.encoder.state orelse return false;
                return s.active == .blit and s.generation == self.generation;
            }
            pub fn copyTextureRegion(self: *BlitPass, source: r.TextureBinding, sx: u32, sy: u32, width: u32, height: u32, destination: r.TextureBinding, dx: u32, dy: u32) !void {
                if (!self.isActive()) return error.InactiveBlitPass;
                const s = self.encoder.state.?;
                if (width == 0 or height == 0 or sx > source.width or width > source.width - sx or sy > source.height or height > source.height - sy or dx > destination.width or width > destination.width - dx or dy > destination.height or height > destination.height - dy) return error.InvalidTextureRegion;
                var src = try source.retainedTexture();
                errdefer src.destroy();
                var dst = try destination.retainedTexture();
                errdefer dst.destroy();
                if (src.owner.?.context != s.context or dst.owner.?.context != s.context) return error.ForeignDeviceResource;
                if (src.format != dst.format) return error.InvalidTextureRegion;
                if (source.eql(destination) and sx < dx + width and dx < sx + width and sy < dy + height and dy < sy + height) return error.InvalidTextureRegion;
                try s.commands.append(s.context.allocator, .{ .copy = .{ .source = src, .destination = dst, .sx = sx, .sy = sy, .dx = dx, .dy = dy, .width = width, .height = height } });
            }
            pub fn end(self: *BlitPass) void {
                if (!self.isActive()) @panic("inactive Linux GPU blit pass");
                self.encoder.state.?.active = .none;
            }
        };
        pub const CommandBuffer = struct {
            state: ?*State,
            pub fn submitChecked(self: *CommandBuffer) !void {
                self.submitRecorded() catch |err| {
                    if (self.state) |s| {
                        if (s.status == .failed) s.failure = err;
                    }
                    return err;
                };
            }
            fn submitRecorded(self: *CommandBuffer) !void {
                const s = self.state orelse return error.InvalidCommandBuffer;
                if (s.status != .recorded) return error.CommandAlreadySubmitted;
                errdefer s.status = .failed;
                // Upload each unique immutable snapshot once. Keep each native
                // binding at offset zero: the native Fedora pixel contract
                // rejects the single-buffer path with changing SSBO ranges.
                // Content deduplication still shares unchanged tables/uniforms.
                defer for (s.snapshots.items) |*cached| {
                    if (cached.native_buffer) |*buffer| buffer.destroy();
                    cached.native_buffer = null;
                };
                if (comptime @hasDecl(vk, "snapshotBytesEqual")) {
                    var diag: vk.Diagnostic = .{};
                    for (s.snapshots.items) |*cached| {
                        cached.native_buffer = try s.context.device.createBufferResource(cached.bytes.len, if (cached.kind == 2) 128 else 64, &diag);
                        try cached.native_buffer.?.write(0, cached.bytes, &diag);
                    }
                    for (s.commands.items) |*command| if (command.* == .draw) {
                        for (command.draw.bindings) |*binding| if (binding.value == .buffer and binding.shared_buffer) {
                            for (s.snapshots.items) |*cached| if (cached.bytes.ptr == binding.value.buffer.ptr) {
                                binding.native_buffer = &cached.native_buffer.?;
                                break;
                            };
                        };
                    };
                }
                if (comptime @hasDecl(vk.Device, "beginSubmissionTiming")) {
                    s.context.device.beginSubmissionTiming() catch |err| {
                        s.failure = err;
                        s.status = .failed;
                        return err;
                    };
                }
                var failure: ?anyerror = null;
                var timing_finished = false;
                for (s.commands.items) |*command| {
                    // The GPU render interval excludes swap/compositor pacing.
                    // Presentation is appended after the encoded render work.
                    if (comptime @hasDecl(vk.Device, "endSubmissionTiming")) {
                        if (command.* == .present and !timing_finished) {
                            timing_finished = true;
                            s.context.device.endSubmissionTiming() catch |err| {
                                failure = err;
                                break;
                            };
                        }
                    }
                    command.execute(s.context) catch |err| {
                        failure = err;
                        break;
                    };
                }
                if (comptime @hasDecl(vk.Device, "endSubmissionTiming")) if (!timing_finished) {
                    s.context.device.endSubmissionTiming() catch |err| {
                        if (failure == null) failure = err;
                    };
                };
                // A driver completion boundary covers every queued command, including
                // successful work before a later failure. GL retains queued storage
                // internally when a temporary buffer name is deleted.
                var completed = true;
                s.context.device.completeSubmission() catch |err| {
                    completed = false;
                    if (failure == null) failure = err;
                };
                s.context.retireUploads(completed);
                if (comptime @hasDecl(vk.Device, "finishSubmissionTiming")) {
                    s.gpu_elapsed_ns = s.context.device.finishSubmissionTiming() catch |err| blk: {
                        if (failure == null) failure = err;
                        break :blk null;
                    };
                }
                if (failure) |err| {
                    s.failure = err;
                    s.status = .failed;
                    return err;
                }
                s.status = .complete;
            }
            pub fn submit(self: *CommandBuffer) void {
                self.submitChecked() catch |err| switch (err) {
                    error.SurfaceOutdated, error.Timeout => std.log.warn("Linux GPU presentation deferred: {s}", .{@errorName(err)}),
                    else => @panic(@errorName(err)),
                };
            }
            pub fn retained(self: *const CommandBuffer) CommandBuffer {
                if (self.state) |s| s.refs += 1;
                return self.*;
            }
            pub fn waitUntilCompleted(self: *const CommandBuffer) void {
                _ = self;
            } // submission is synchronous
            pub fn isCompleted(self: *const CommandBuffer) bool {
                const s = self.state orelse return false;
                return s.status == .complete or s.status == .failed;
            }
            pub fn completionChecked(self: *const CommandBuffer) !void {
                const s = self.state orelse return error.InvalidCommandBuffer;
                if (s.status == .failed) return s.failure.?;
                if (s.status != .complete) return error.CommandNotSubmitted;
            }
            pub fn gpuElapsedMicros(self: *const CommandBuffer) ?u64 {
                const s = self.state orelse return null;
                if (s.status != .complete) return null;
                const nanoseconds = s.gpu_elapsed_ns orelse return null;
                return nanoseconds / std.time.ns_per_us;
            }
            pub fn presentTexture(self: *const CommandBuffer, texture: *const r.Texture) !void {
                const s = self.state orelse return error.InvalidCommandBuffer;
                if (s.status != .recorded) return error.CommandAlreadySubmitted;
                errdefer s.status = .failed;
                var owned = texture.retained();
                errdefer owned.destroy();
                if (owned.owner == null or owned.owner.?.context != s.context) return error.ForeignDeviceResource;
                try s.commands.append(s.context.allocator, .{ .present = owned });
            }
            pub fn presentDrawable(self: *CommandBuffer, drawable: *anyopaque) void {
                _ = self;
                _ = drawable;
                @panic("Linux GPU requires an owned surface texture for presentation");
            }
            pub fn deinit(self: *CommandBuffer) void {
                if (self.state) |s| s.release();
                self.state = null;
            }
        };
    };
}
