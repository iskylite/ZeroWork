//! Shared Linux renderer contracts; instantiated with the native driver.
pub fn For(comptime Driver: type) type {
    return struct {
        //! Linux GPU renderer resources: ref-counted owners around the native Linux GPU
        //! resource layer (`device.zig`, `resources.zig`, `pipeline.zig`).
        //!
        //! Ownership contracts implemented here:
        //! * `Context` takes a native `vk.Device` by *move*, counts live resource
        //!   owners (`resources`) and deferred commands (`pending_commands`), and
        //!   refuses teardown while either counter is nonzero.
        //! * `Buffer` always carries a zeroed CPU shadow the same size as the native
        //!   buffer; `native()` uploads that shadow before handing out the real native
        //!   buffer for draw binding. No dummy buffers exist.
        //! * `Texture` identity is a monotonic id (render-thread confined). A
        //!   `TextureBinding` is a *borrowed* identity snapshot: obtaining one never
        //!   retains. It stays valid only while the owner is alive through a
        //!   `retained()` texture or a `TextureView`.
        //! * `Sampler` supports independent filters, address modes and finite LOD
        //!   clamps; unsupported comparison/anisotropy features are explicitly rejected.
        //! * `RecordingReadback` performs the native GPU read synchronously; the CPU
        //!   image only ever holds pixels the device actually produced.
        const std = @import("std");

        pub const gpu = @import("../gpu.zig");
        pub const vk = Driver;

        /// Errors this module adds on top of the native `vk.Error` set.
        pub const ResourceError = error{
            /// Buffer range request escaped the buffer (checked by subtraction).
            OutOfBounds,
            /// `writeRegion` on a texture that is not `host_upload`.
            TextureNotHostWritable,
            /// Texture descriptor outside the supported 2D single-mip subset.
            UnsupportedTextureDescriptor,
            /// Sampler descriptor outside the native sampler matrix.
            UnsupportedSamplerDescriptor,
            /// Texture region/stride request outside the texture or its bytes.
            InvalidTextureRegion,
        };

        /// Union of native errors and the module extensions above.
        pub const Error = vk.Error || ResourceError;

        /// Monotonic texture identity counter. Render-thread confined by contract, so
        /// no atomics: creation and binding snapshotting happen on the render thread.
        var next_texture_id: u64 = 0;

        fn allocateTextureId() u64 {
            next_texture_id += 1;
            return next_texture_id;
        }

        /// Stable owner of a moved-in native Linux GPU device plus its live resource and
        /// deferred-command counters. Allocated once by `init`; never moved afterwards.
        pub const Context = struct {
            allocator: std.mem.Allocator,
            device: vk.Device,
            /// Live resource owners (buffers, textures, samplers). Guard for teardown.
            resources: usize = 0,
            /// Deferred command recordings still holding snapshots. Guard for teardown.
            pending_commands: usize = 0,
            /// Inline draw bytes (fragment/vertex constants) are uploaded into one
            /// distinct zero-offset native buffer per binding, exactly sized: one
            /// combined buffer with ranges is not used (it broke SSBO ranges on
            /// vmwgfx). Those buffers are pooled by (size, usage) instead of being
            /// created and deleted per draw; a buffer is busy until its submission's
            /// completion boundary, then reusable.
            uploads: std.ArrayList(PooledUpload) = .empty,

            pub const PooledUpload = struct { buffer: vk.resources.Buffer, size: usize, usage: u32, busy: bool };
            const upload_pool_limit = 512;

            /// A free exact-size upload buffer, created when none is free. `pooled`
            /// is false when the pool is full: the caller destroys that buffer.
            pub fn acquireUpload(self: *Context, size: usize, usage: u32, diagnostic: *vk.Diagnostic) !struct { buffer: vk.resources.Buffer, pooled: bool } {
                for (self.uploads.items) |*entry| {
                    if (!entry.busy and entry.size == size and entry.usage == usage) {
                        entry.busy = true;
                        return .{ .buffer = entry.buffer, .pooled = true };
                    }
                }
                const buffer = try self.device.createBufferResource(size, usage, diagnostic);
                if (self.uploads.items.len >= upload_pool_limit) return .{ .buffer = buffer, .pooled = false };
                self.uploads.append(self.allocator, .{ .buffer = buffer, .size = size, .usage = usage, .busy = true }) catch {
                    return .{ .buffer = buffer, .pooled = false };
                };
                return .{ .buffer = buffer, .pooled = true };
            }

            /// Completion boundary of a submission: every upload it used is idle again.
            /// After a failed boundary the GPU may still read them, so they are released
            /// to the driver (which keeps storage alive for queued work) instead.
            pub fn retireUploads(self: *Context, completed: bool) void {
                if (completed) {
                    for (self.uploads.items) |*entry| entry.busy = false;
                    return;
                }
                var i: usize = 0;
                while (i < self.uploads.items.len) {
                    if (self.uploads.items[i].busy) {
                        self.uploads.items[i].buffer.destroy();
                        _ = self.uploads.swapRemove(i);
                    } else i += 1;
                }
            }

            fn destroyUploads(self: *Context) void {
                for (self.uploads.items) |*entry| entry.buffer.destroy();
                self.uploads.deinit(self.allocator);
                self.uploads = .empty;
            }

            /// Moves `native` into a heap-stable `Context`. `native.handle` is nulled
            /// only after the owner allocation succeeds, so a failed init leaves the
            /// caller in possession of the device. Rejects a null handle.
            pub fn init(allocator: std.mem.Allocator, native: *vk.Device) Error!*Context {
                if (native.handle == null) return error.InvalidDescriptor;
                const self = try allocator.create(Context);
                errdefer allocator.destroy(self);
                self.* = .{
                    .allocator = allocator,
                    .device = native.*,
                    .resources = 0,
                    .pending_commands = 0,
                };
                native.handle = null;
                return self;
            }

            /// Destroys the native device and frees the context. Fails with
            /// `ResourcesAlive` while resource owners or deferred commands remain; any
            /// native teardown failure propagates and preserves the `Context`.
            pub fn deinit(self: *Context) Error!u32 {
                if (self.resources != 0 or self.pending_commands != 0) return error.ResourcesAlive;
                self.destroyUploads();
                const validation_errors = try self.device.deinit();
                const allocator = self.allocator;
                allocator.destroy(self);
                return validation_errors;
            }

            /// Creates a buffer with a zeroed CPU shadow sized to `desc.size`. The
            /// native usage word uses the same bit layout as `gpu.BufferUsages`; a
            /// `vertex` buffer additionally gains `uniform | storage` because renderer
            /// vertex slots carry both roles.
            pub fn createBuffer(self: *Context, allocator: std.mem.Allocator, desc: gpu.BufferDescriptor) Error!Buffer {
                if (desc.size == 0) return error.InvalidDescriptor;
                const raw_usage: u32 = @bitCast(desc.usage);
                if (raw_usage == 0) return error.InvalidDescriptor;
                if (desc.usage._padding != 0) return error.InvalidDescriptor;

                var native_usage = raw_usage;
                if (desc.usage.vertex) {
                    const extra: u32 = @bitCast(gpu.BufferUsages{ .uniform = true, .storage = true });
                    native_usage |= extra;
                }

                const shadow_len = std.math.cast(usize, desc.size) orelse return error.OutOfMemory;

                const owner = try allocator.create(BufferOwner);
                errdefer allocator.destroy(owner);
                const bytes = try allocator.alloc(u8, shadow_len);
                errdefer allocator.free(bytes);
                @memset(bytes, 0);

                var diagnostic: vk.Diagnostic = .{};
                var inner = try vk.resources.Buffer.init(&self.device, desc.size, native_usage, &diagnostic);
                errdefer inner.destroy();

                owner.* = .{
                    .context = self,
                    .allocator = allocator,
                    .inner = inner,
                    .bytes = bytes,
                    .refs = 1,
                };
                self.resources += 1;
                return .{ .owner = owner, .size = desc.size };
            }

            /// Creates a texture in the supported subset: 2D, depth 1, one mip level,
            /// one sample, R8/RGBA8/BGRA8 unorm or RGBA16 float, nonzero extents within the device's
            /// `max_image_dimension_2d`, nonzero usage without padding bits, and view
            /// formats either empty or equal to the texture format. `host_upload`
            /// textures are cleared to zero immediately through the native
            /// `Texture.clear`; `device_local` contents stay undefined.
            pub fn createTexture(self: *Context, allocator: std.mem.Allocator, desc: gpu.TextureDescriptor) Error!Texture {
                const format = desc.format;
                const native_format: vk.resources.Format = switch (format) {
                    .r8_unorm => .r8_unorm,
                    .rgba8_unorm => .rgba8_unorm,
                    .bgra8_unorm => .bgra8_unorm,
                    .rgba16_float => .rgba16_float,
                    else => return error.UnsupportedTextureDescriptor,
                };
                if (desc.dimension != .@"2d") return error.UnsupportedTextureDescriptor;
                if (desc.size.depth != 1) return error.UnsupportedTextureDescriptor;
                if (desc.mip_level_count != 1) return error.UnsupportedTextureDescriptor;
                if (desc.sample_count != 1) return error.UnsupportedTextureDescriptor;
                if (desc.size.width == 0 or desc.size.height == 0) return error.UnsupportedTextureDescriptor;
                const max_dimension = self.device.maxTextureDimension2D();
                if (desc.size.width > max_dimension or desc.size.height > max_dimension) return error.UnsupportedTextureDescriptor;
                for (desc.view_formats) |view_format| {
                    if (view_format != format) return error.UnsupportedTextureDescriptor;
                }
                const raw_usage: u32 = @bitCast(desc.usage);
                if (raw_usage == 0) return error.UnsupportedTextureDescriptor;
                if (desc.usage._padding != 0) return error.UnsupportedTextureDescriptor;

                const owner = try allocator.create(TextureOwner);
                errdefer allocator.destroy(owner);

                var diagnostic: vk.Diagnostic = .{};
                var inner = try vk.resources.Texture.init(&self.device, desc.size.width, desc.size.height, native_format, &diagnostic);
                errdefer inner.destroy();
                if (desc.memory == .host_upload) {
                    // Planned native zero-clear; the native module owns the body.
                    try inner.clear([4]f32{ 0, 0, 0, 0 }, &diagnostic);
                }

                owner.* = .{
                    .context = self,
                    .allocator = allocator,
                    .inner = inner,
                    .refs = 1,
                    .id = allocateTextureId(),
                    .format = format,
                    .size = desc.size,
                    .memory = desc.memory,
                };
                self.resources += 1;
                return .{
                    .owner = owner,
                    .format = format,
                    .size = desc.size,
                    .mip_level_count = desc.mip_level_count,
                    .dimension = desc.dimension,
                    .memory = desc.memory,
                };
            }

            /// Linux GPU filter/address/LOD combinations; compare and anisotropy require
            /// features that this 2D renderer does not advertise.
            pub fn createSampler(self: *Context, allocator: std.mem.Allocator, desc: gpu.SamplerDescriptor) Error!Sampler {
                if (desc.compare != null or desc.max_anisotropy != 1) return error.UnsupportedSamplerDescriptor;
                if (!std.math.isFinite(desc.lod_min_clamp) or !std.math.isFinite(desc.lod_max_clamp) or desc.lod_min_clamp < 0 or desc.lod_max_clamp < desc.lod_min_clamp) return error.UnsupportedSamplerDescriptor;

                const owner = try allocator.create(SamplerOwner);
                errdefer allocator.destroy(owner);

                var diagnostic: vk.Diagnostic = .{};
                var inner = try vk.pipeline.Sampler.initDescriptor(&self.device, .{
                    .mag_filter = @backingInt(desc.mag_filter),
                    .min_filter = @backingInt(desc.min_filter),
                    .mipmap_filter = @backingInt(desc.mipmap_filter),
                    .address_u = @backingInt(desc.address_mode_u),
                    .address_v = @backingInt(desc.address_mode_v),
                    .address_w = @backingInt(desc.address_mode_w),
                    .lod_min = desc.lod_min_clamp,
                    .lod_max = desc.lod_max_clamp,
                }, &diagnostic);
                errdefer inner.destroy();

                owner.* = .{
                    .context = self,
                    .allocator = allocator,
                    .inner = inner,
                    .refs = 1,
                };
                self.resources += 1;
                return .{ .owner = owner };
            }
        };

        // ============================================================================
        // Buffers
        // ============================================================================

        /// Shared buffer owner: native buffer plus zeroed CPU shadow plus refcount.
        pub const BufferOwner = struct {
            context: *Context,
            allocator: std.mem.Allocator,
            inner: vk.resources.Buffer,
            bytes: []u8,
            refs: usize,
        };

        /// Handle to a buffer. Copying the handle does not retain the owner; use
        /// `retained()` for a second owning reference.
        pub const Buffer = struct {
            owner: ?*BufferOwner,
            size: u64,

            /// CPU shadow range. Bounds are checked by subtraction from the total, so
            /// overflowing `offset + size` can never pass validation.
            pub fn getMappedRange(self: *Buffer, offset: u64, size: u64) Error![]u8 {
                const owner = self.owner orelse return error.InvalidDescriptor;
                const total: u64 = owner.bytes.len;
                if (offset > total) return error.OutOfBounds;
                const available = total - offset;
                if (size > available) return error.OutOfBounds;
                const start: usize = @intCast(offset);
                const end = start + @as(usize, @intCast(size));
                return owner.bytes[start..end];
            }

            /// Uploads the CPU shadow into the native buffer, then returns the real
            /// native buffer pointer for draw binding.
            pub fn native(self: *const Buffer) Error!*vk.resources.Buffer {
                const owner = self.owner orelse return error.InvalidDescriptor;
                var diagnostic: vk.Diagnostic = .{};
                try owner.inner.write(0, owner.bytes, &diagnostic);
                return &owner.inner;
            }

            /// Second owning reference; the last release frees native + shadow + owner.
            pub fn retained(self: *const Buffer) Buffer {
                if (self.owner) |owner| owner.refs += 1;
                return .{ .owner = self.owner, .size = self.size };
            }

            /// Releases one reference. Idempotent.
            pub fn destroy(self: *Buffer) void {
                releaseBuffer(self);
            }

            /// Alias of `destroy`. Idempotent.
            pub fn deinit(self: *Buffer) void {
                releaseBuffer(self);
            }
        };

        fn releaseBuffer(value: *Buffer) void {
            const owner = value.owner orelse return;
            value.owner = null;
            owner.refs -= 1;
            if (owner.refs == 0) releaseBufferOwner(owner);
        }

        fn releaseBufferOwner(owner: *BufferOwner) void {
            owner.inner.destroy();
            const allocator = owner.allocator;
            const context = owner.context;
            allocator.free(owner.bytes);
            allocator.destroy(owner);
            context.resources -= 1;
        }

        // ============================================================================
        // Textures
        // ============================================================================

        /// Shared texture owner: native texture, identity, metadata and refcount.
        pub const TextureOwner = struct {
            context: *Context,
            allocator: std.mem.Allocator,
            inner: vk.resources.Texture,
            refs: usize,
            id: u64,
            format: gpu.TextureFormat,
            size: gpu.Extent3D,
            memory: gpu.TextureMemory,
        };

        /// Handle to a texture. Copying the handle does not retain the owner.
        pub const Texture = struct {
            owner: ?*TextureOwner,
            format: gpu.TextureFormat,
            size: gpu.Extent3D,
            mip_level_count: u32,
            dimension: gpu.TextureDimension,
            memory: gpu.TextureMemory,

            /// Metadata-only texture with no native resource. `.binding()` reports
            /// id 0; never stands in for a real GPU resource.
            pub fn fakeForTesting(width: u32, height: u32, format: gpu.TextureFormat) Texture {
                return .{
                    .owner = null,
                    .format = format,
                    .size = .{ .width = width, .height = height, .depth = 1 },
                    .mip_level_count = 1,
                    .dimension = .@"2d",
                    .memory = .device_local,
                };
            }

            /// Writes into a `host_upload` texture through the native staging path.
            /// Only mip 0 exists; a zero extent is a no-op.
            pub fn writeRegion(self: *Texture, mip: u32, x: u32, y: u32, width: u32, height: u32, bytes: []const u8, stride: u32) Error!void {
                if (self.memory != .host_upload) return error.TextureNotHostWritable;
                if (mip != 0) return error.InvalidTextureRegion;
                if (width == 0 or height == 0) return;
                const owner = self.owner orelse return error.InvalidDescriptor;

                // Subtraction-based bounds: no offset+extent overflow can pass.
                if (width > owner.size.width or x > owner.size.width - width) return error.InvalidTextureRegion;
                if (height > owner.size.height or y > owner.size.height - height) return error.InvalidTextureRegion;
                const pixel = bytesPerPixel(owner.format);
                if (pixel == 0) return error.InvalidTextureRegion;
                const row_bytes: usize = @as(usize, width) * @as(usize, pixel);
                const tail = std.math.mul(usize, @as(usize, stride), @as(usize, height - 1)) catch return error.InvalidTextureRegion;
                const needed = std.math.add(usize, row_bytes, tail) catch return error.InvalidTextureRegion;
                if (bytes.len < needed) return error.InvalidTextureRegion;

                var diagnostic: vk.Diagnostic = .{};
                try owner.inner.writeRegion(x, y, width, height, bytes, stride, &diagnostic);
            }

            /// Reads a BGRA8 region starting at (0, 0). Only BGRA8 textures are
            /// readable through this path.
            pub fn readBgra8(self: *const Texture, width: u32, height: u32, bytes: []u8, stride: u32) Error!void {
                const owner = self.owner orelse return error.InvalidDescriptor;
                if (owner.format != .bgra8_unorm) return error.UnsupportedTextureDescriptor;
                if (width == 0 or height == 0) return;
                if (width > owner.size.width or height > owner.size.height) return error.InvalidTextureRegion;
                const row_bytes: usize = @as(usize, width) * 4;
                const tail = std.math.mul(usize, @as(usize, stride), @as(usize, height - 1)) catch return error.InvalidTextureRegion;
                const needed = std.math.add(usize, row_bytes, tail) catch return error.InvalidTextureRegion;
                if (bytes.len < needed) return error.InvalidTextureRegion;

                var diagnostic: vk.Diagnostic = .{};
                try owner.inner.readRegion(0, 0, width, height, bytes, stride, &diagnostic);
            }

            /// Validates owner and native handle, then returns the real native texture.
            pub fn native(self: *const Texture) Error!*vk.resources.Texture {
                const owner = self.owner orelse return error.InvalidDescriptor;
                if (owner.inner.handle == null) return error.InvalidDescriptor;
                return &owner.inner;
            }

            /// Borrowed identity snapshot (owner pointer + monotonic id + extents).
            /// Never retains: the caller must keep a `retained()` texture or a
            /// `TextureView` alive for as long as the binding is used.
            pub fn binding(self: *const Texture) TextureBinding {
                return .{
                    .owner = self.owner,
                    .id = if (self.owner) |owner| owner.id else 0,
                    .width = self.size.width,
                    .height = self.size.height,
                };
            }

            /// Native opaque handle for command recording, or null when absent.
            pub fn nativeHandleForRecording(self: *const Texture) ?*anyopaque {
                const owner = self.owner orelse return null;
                const handle = owner.inner.handle orelse return null;
                return @ptrCast(handle);
            }

            /// Second owning reference; the last release destroys the native texture.
            pub fn retained(self: *const Texture) Texture {
                if (self.owner) |owner| owner.refs += 1;
                return .{
                    .owner = self.owner,
                    .format = self.format,
                    .size = self.size,
                    .mip_level_count = self.mip_level_count,
                    .dimension = self.dimension,
                    .memory = self.memory,
                };
            }

            /// Synchronous full-image BGRA readback into a buffer this struct owns.
            /// The CPU image is filled by the native GPU read only; no fabricated
            /// pixels are ever produced.
            pub fn beginRecordingReadback(self: *const Texture) Error!RecordingReadback {
                const owner = self.owner orelse return error.InvalidDescriptor;
                if (owner.inner.handle == null) return error.InvalidDescriptor;
                if (owner.format != .bgra8_unorm) return error.UnsupportedTextureDescriptor;
                const width = owner.size.width;
                const height = owner.size.height;
                const stride = std.math.mul(u32, width, 4) catch return error.OutOfBounds;
                const total = std.math.mul(usize, @as(usize, stride), @as(usize, height)) catch return error.OutOfBounds;
                const data = try owner.allocator.alloc(u8, total);
                errdefer owner.allocator.free(data);
                @memset(data, 0);
                var diagnostic: vk.Diagnostic = .{};
                try owner.inner.readRegion(0, 0, width, height, data, stride, &diagnostic);
                return .{
                    .allocator = owner.allocator,
                    .data = data,
                    .width = width,
                    .height = height,
                    .stride = stride,
                };
            }

            /// Releases one reference. Idempotent.
            pub fn destroy(self: *Texture) void {
                releaseTexture(self);
            }

            /// Alias of `destroy`. Idempotent.
            pub fn deinit(self: *Texture) void {
                releaseTexture(self);
            }
        };

        fn releaseTexture(value: *Texture) void {
            const owner = value.owner orelse return;
            value.owner = null;
            releaseTextureOwner(owner);
        }

        /// Shared release helper for texture owners (textures and views alike).
        fn releaseTextureOwner(owner: *TextureOwner) void {
            owner.refs -= 1;
            if (owner.refs != 0) return;
            owner.inner.destroy();
            const allocator = owner.allocator;
            const context = owner.context;
            allocator.destroy(owner);
            context.resources -= 1;
        }

        fn bytesPerPixel(format: gpu.TextureFormat) u32 {
            return switch (format) {
                .r8_unorm => 1,
                .rgba8_unorm, .bgra8_unorm => 4,
                .rgba16_float => 8,
                else => 0,
            };
        }

        // ============================================================================
        // Texture bindings and views
        // ============================================================================

        /// Borrowed texture identity for deferred command recording. Compared by
        /// exact id; ids are monotonic, so a destroyed texture's id is never reused.
        pub const TextureBinding = struct {
            owner: ?*TextureOwner = null,
            id: u64 = 0,
            width: u32 = 0,
            height: u32 = 0,

            /// Synthetic binding for tests: ownerless, identified purely by token.
            pub fn testBinding(token: u64, width: u32, height: u32) TextureBinding {
                return .{ .owner = null, .id = token, .width = width, .height = height };
            }

            /// Exact-id identity comparison.
            pub fn eql(self: TextureBinding, other: TextureBinding) bool {
                return self.id == other.id;
            }

            /// Retaining view: increments the owner refcount so the binding stays
            /// valid for the view's lifetime.
            pub fn createView(self: TextureBinding) TextureView {
                if (self.owner) |owner| owner.refs += 1;
                return .{ .value = self };
            }

            /// Reconstructs an owning texture handle by retaining the owner.
            pub fn retainedTexture(self: TextureBinding) Error!Texture {
                const owner = self.owner orelse return error.InvalidDescriptor;
                owner.refs += 1;
                return .{
                    .owner = owner,
                    .format = owner.format,
                    .size = owner.size,
                    .mip_level_count = 1,
                    .dimension = .@"2d",
                    .memory = owner.memory,
                };
            }
        };

        /// Owning view over a texture binding; releasing it releases the owner hold.
        pub const TextureView = struct {
            value: TextureBinding,

            /// Returns the held binding without retaining it again.
            pub fn binding(self: *const TextureView) TextureBinding {
                return self.value;
            }

            /// Releases the owner hold and nulls the held owner. Idempotent.
            pub fn destroy(self: *TextureView) void {
                releaseBinding(&self.value);
            }

            /// Alias of `destroy`. Idempotent.
            pub fn deinit(self: *TextureView) void {
                releaseBinding(&self.value);
            }
        };

        fn releaseBinding(value: *TextureBinding) void {
            const owner = value.owner orelse return;
            value.owner = null;
            releaseTextureOwner(owner);
        }

        // ============================================================================
        // Samplers
        // ============================================================================

        /// Shared sampler owner: native sampler plus refcount.
        pub const SamplerOwner = struct {
            context: *Context,
            allocator: std.mem.Allocator,
            inner: vk.pipeline.Sampler,
            refs: usize,
        };

        /// Handle to a sampler. Copying the handle does not retain the owner.
        pub const Sampler = struct {
            owner: ?*SamplerOwner,

            /// Validates owner and native handle, then returns the real native sampler.
            pub fn native(self: *const Sampler) Error!*vk.pipeline.Sampler {
                const owner = self.owner orelse return error.InvalidDescriptor;
                if (owner.inner.handle == null) return error.InvalidDescriptor;
                return &owner.inner;
            }

            /// Second owning reference; the last release frees the native sampler.
            pub fn retained(self: *const Sampler) Sampler {
                if (self.owner) |owner| owner.refs += 1;
                return .{ .owner = self.owner };
            }

            /// Releases one reference. Idempotent.
            pub fn destroy(self: *Sampler) void {
                releaseSampler(self);
            }

            /// Alias of `destroy`. Idempotent.
            pub fn deinit(self: *Sampler) void {
                releaseSampler(self);
            }
        };

        fn releaseSampler(value: *Sampler) void {
            const owner = value.owner orelse return;
            value.owner = null;
            owner.refs -= 1;
            if (owner.refs != 0) return;
            owner.inner.destroy();
            const allocator = owner.allocator;
            const context = owner.context;
            allocator.destroy(owner);
            context.resources -= 1;
        }

        // ============================================================================
        // Readback
        // ============================================================================

        /// Owned CPU image produced by a synchronous native GPU read. The read
        /// completed before this value existed, so `ready` never waits on a clock.
        pub const RecordingReadback = struct {
            allocator: std.mem.Allocator,
            data: []u8,
            width: u32,
            height: u32,
            stride: u32,

            /// True once the native read succeeded; the read is synchronous, so a
            /// successfully constructed readback is immediately ready.
            pub fn ready(self: *const RecordingReadback, timeout_ms: u32) Error!bool {
                _ = timeout_ms;
                return self.data.len != 0;
            }

            /// The readback CPU image.
            pub fn bytes(self: *const RecordingReadback) Error![]u8 {
                if (self.data.len == 0) return error.InvalidDescriptor;
                return self.data;
            }

            /// Frees the CPU image. Idempotent.
            pub fn deinit(self: *RecordingReadback) void {
                if (self.data.len == 0) return;
                self.allocator.free(self.data);
                self.data = self.data[0..0];
            }
        };
    };
}
