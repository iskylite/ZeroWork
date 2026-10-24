//! Renderer-facing texture API over real D3D12 staging copies. Render-thread
//! confined. Context owns the queue that future rendering must also use;
//! uploads/readbacks never race a separate render queue. Context address is stable.
const std = @import("std");
const gpu = @import("../gpu.zig");
const d12 = @import("resources.zig");
pub const Context = struct {
    allocator: std.mem.Allocator,
    device: d12.Device,
    /// Submit through `submitCommands`: a direct submission would run ahead of
    /// texture writes still waiting in `pending_uploads`.
    queue: d12.Queue,
    resources: usize = 0,
    timeout_ms: u32 = 5000,
    /// Persistently mapped upload pages that back setVertexBytes/setFragmentBytes.
    /// A page is sub-allocated by one recording encoder, retired with its command's
    /// fence serial on submit, and reused only after that serial completes (or at
    /// once if the command never executed). Creating a committed buffer for every
    /// inline-bytes call cost ~100 us of CPU each and dominated D3D12 encoding.
    upload_pages: std.ArrayListUnmanaged(UploadPage) = .empty,
    /// Texture writes recorded since the last submission on this queue. Each glyph/icon
    /// write used to submit and wait for its own copy (a full GPU round trip per region:
    /// a story with a few hundred new glyphs opened seconds late on a VM). Writes now
    /// share one copy command that every submission on this queue sends first; in-order
    /// queue execution keeps the copies ahead of the draws and readbacks submitted after
    /// them, and native commands retain the staging buffers until their fence.
    pending_uploads: ?d12.CommandEncoder = null,
    /// Finished upload command whose submission failed. Kept and resent first:
    /// the atlas already counts its glyphs as uploaded, and a buffer-to-texture
    /// copy is idempotent, so resending one that did execute is harmless.
    unsent_uploads: ?d12.CommandBuffer = null,

    pub fn init(allocator: std.mem.Allocator, device: *const d12.Device) !*Context {
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        var owned = device.retained();
        errdefer owned.destroy();
        self.* = .{ .allocator = allocator, .device = owned, .queue = try owned.createQueue() };
        return self;
    }
    /// Failure preserves the context and queue for retry.
    pub const upload_page_size: u64 = 64 * 1024;
    pub const UploadPage = struct {
        buffer: d12.Buffer,
        state: union(enum) { free, recording, submitted: u64 },
    };
    /// Index of a page now owned by a recording encoder.
    pub fn acquireUploadPage(self: *Context) !usize {
        for (self.upload_pages.items, 0..) |*page, index| switch (page.state) {
            .free => {
                page.state = .recording;
                return index;
            },
            .submitted => |serial| {
                self.queue.wait(serial, 0) catch continue;
                page.state = .recording;
                return index;
            },
            .recording => {},
        };
        var buffer = try self.device.createBuffer(self.allocator, .{ .size = upload_page_size, .usage = .{ .map_write = true, .uniform = true, .vertex = true, .storage = true } });
        errdefer buffer.destroy();
        try self.upload_pages.append(self.allocator, .{ .buffer = buffer, .state = .recording });
        return self.upload_pages.items.len - 1;
    }
    /// Returns pages from an encoder/command: retired behind `serial` when the
    /// GPU may read them, otherwise free immediately.
    pub fn releaseUploadPages(self: *Context, pages: []const usize, serial: ?u64) void {
        for (pages) |index| self.upload_pages.items[index].state = if (serial) |value| .{ .submitted = value } else .free;
    }
    pub fn deinit(self: *Context) !void {
        if (self.resources != 0) return error.ResourcesStillAlive;
        // No texture is alive, so nothing can observe these writes any more.
        self.discardUploads();
        try self.queue.deinit(self.timeout_ms);
        for (self.upload_pages.items) |*page| page.buffer.destroy();
        self.upload_pages.deinit(self.allocator);
        self.device.destroy();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
    /// The one submission path: recorded texture writes go first.
    pub fn submitCommands(self: *Context, commands: []const d12.CommandBuffer) !u64 {
        try self.flushUploads();
        return self.queue.submit(commands);
    }
    /// Sends the recorded texture writes. `submitCommands` calls this first.
    /// A failure loses nothing: an unfinished encoder stays pending and a
    /// command the queue never took is resent, so the next submission retries
    /// in order. A command the queue did take (a Signal failure after
    /// execution) is in flight and is never resent.
    pub fn flushUploads(self: *Context) !void {
        if (self.unsent_uploads != null) try self.sendUnsentUploads();
        if (self.pending_uploads) |*encoder| {
            const command = try encoder.finish();
            encoder.deinit();
            self.pending_uploads = null;
            self.unsent_uploads = command;
            try self.sendUnsentUploads();
        }
    }
    fn sendUnsentUploads(self: *Context) !void {
        const command = &self.unsent_uploads.?;
        const before = self.queue.last_serial;
        _ = self.queue.submit(&.{command.*}) catch |err| {
            if (self.queue.last_serial != before) {
                command.deinit();
                self.unsent_uploads = null;
            }
            return err;
        };
        command.deinit();
        self.unsent_uploads = null;
    }
    /// Drops writes that can no longer be observed (no texture is alive).
    fn discardUploads(self: *Context) void {
        if (self.unsent_uploads) |*command| command.deinit();
        if (self.pending_uploads) |*encoder| encoder.deinit();
        self.unsent_uploads = null;
        self.pending_uploads = null;
    }
    fn uploadEncoder(self: *Context) !*d12.CommandEncoder {
        if (self.pending_uploads == null) self.pending_uploads = try self.device.createCommandEncoder();
        return &self.pending_uploads.?;
    }
    fn submit(self: *Context, encoder: *d12.CommandEncoder) !void {
        var command = try encoder.finish();
        defer command.deinit();
        const serial = try self.submitCommands(&.{command});
        try self.queue.wait(serial, self.timeout_ms);
    }
    pub fn createBuffer(self: *Context, allocator: std.mem.Allocator, desc: gpu.BufferDescriptor) !d12.Buffer {
        var native = desc;
        // Renderer vertex slots also carry uniforms and shader instance data.
        if (desc.usage.vertex) {
            native.usage.uniform = true;
            native.usage.storage = true;
        }
        if (desc.mapped_at_creation and !desc.usage.map_read) native.usage.map_write = true;
        return self.device.createBuffer(allocator, native);
    }
    pub fn createTexture(self: *Context, allocator: std.mem.Allocator, desc: gpu.TextureDescriptor) !Texture {
        var native_desc = desc;
        if (desc.memory == .host_upload) {
            if (desc.dimension != .@"2d" or desc.size.depth != 1 or desc.sample_count != 1) return error.UnsupportedTextureMemory;
            // D3D12 textures remain device-local; the public host-upload policy
            // enables synchronous staging, not a CPU-mappable texture heap.
            native_desc.memory = .device_local;
            native_desc.usage.copy_dst = true;
        } else if (desc.memory != .device_local) return error.UnsupportedTextureMemory;
        const inner = try self.device.createTexture(allocator, native_desc);
        self.resources += 1;
        return .{ .inner = inner, .context = self, .format = desc.format, .size = desc.size, .mip_level_count = desc.mip_level_count, .dimension = desc.dimension, .memory = desc.memory };
    }
};
pub const Texture = struct {
    inner: d12.Texture,
    context: *Context,
    format: gpu.TextureFormat,
    size: gpu.Extent3D,
    mip_level_count: u32,
    dimension: gpu.TextureDimension,
    memory: gpu.TextureMemory,

    prepared_readback: ?d12.Buffer = null,
    prepared_layout: ?d12.TextureCopyLayout = null,

    /// Encode the CPU copy in the frame that produces the luminance texture.
    /// The caller must wait for that frame's completion before consuming bytes.
    pub fn prepareBgra8Readback(self: *Texture, encoder: anytype, width: u32, height: u32) !void {
        if (encoder.context != self.context) return error.InvalidTextureData;
        if (self.format != .bgra8_unorm and self.format != .bgra8_unorm_srgb) return error.UnsupportedTextureFormat;
        if (self.dimension != .@"2d" or self.size.depth != 1) return error.InvalidTextureRegion;
        const region = d12.TextureRegion{ .width = width, .height = height };
        const layout = try self.inner.copyLayout(region, 0);
        self.prepared_layout = null;
        if (self.prepared_readback) |*buffer| {
            if (buffer.size < layout.required_bytes) {
                buffer.destroy();
                self.prepared_readback = null;
            }
        }
        if (self.prepared_readback == null) self.prepared_readback = try self.context.device.createBuffer(self.context.allocator, .{ .size = layout.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
        try encoder.inner.copyTextureToBuffer(&self.inner, region, &self.prepared_readback.?, 0, layout.row_pitch);
        self.prepared_layout = layout;
    }

    /// CPU-only access after the producing command buffer has completed.
    pub fn readPreparedBgra8(self: *Texture, width: u32, height: u32, bytes: []u8, bytes_per_row: u32) !void {
        const layout = self.prepared_layout orelse return error.InvalidTextureData;
        if (width != layout.width or height != layout.height or bytes_per_row < layout.row_bytes or @as(u64, bytes_per_row) * height > bytes.len) return error.InvalidTextureData;
        const buffer = &(self.prepared_readback orelse return error.InvalidTextureData);
        const mapped = try buffer.getMappedRange(0, buffer.size);
        for (0..height) |row| @memcpy(bytes[row * bytes_per_row ..][0..@intCast(layout.row_bytes)], mapped[row * layout.row_pitch ..][0..@intCast(layout.row_bytes)]);
    }

    /// One queued, owned staging buffer. The copy is ordered on the renderer's
    /// queue before Present; the source drawable may be reused after submission.
    pub const RecordingReadback = struct {
        buffer: d12.Buffer,
        context: *Context,
        serial: u64,
        width: u32,
        height: u32,
        stride: u32,

        pub fn ready(self: *RecordingReadback, timeout_ms: u32) !bool {
            self.context.queue.wait(self.serial, timeout_ms) catch |err| switch (err) {
                error.GpuTimeout => return false,
                else => return err,
            };
            return true;
        }
        pub fn bytes(self: *RecordingReadback) ![]u8 {
            return self.buffer.getMappedRange(0, self.buffer.size);
        }
        pub fn deinit(self: *RecordingReadback) void {
            // Native submitted commands retain pending buffers until the fence.
            self.buffer.destroy();
        }
    };

    pub fn beginRecordingReadback(self: *const Texture) !RecordingReadback {
        if (self.format != .bgra8_unorm and self.format != .bgra8_unorm_srgb) return error.UnsupportedTextureFormat;
        const region = d12.TextureRegion{ .width = self.size.width, .height = self.size.height };
        const layout = try self.inner.copyLayout(region, 0);
        var buffer = try self.context.device.createBuffer(self.context.allocator, .{ .size = layout.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
        errdefer buffer.destroy();
        var encoder = try self.context.device.createCommandEncoder();
        defer encoder.deinit();
        var source = self.inner;
        try encoder.copyTextureToBuffer(&source, region, &buffer, 0, layout.row_pitch);
        var command = try encoder.finish();
        defer command.deinit();
        const serial = try self.context.submitCommands(&.{command});
        return .{ .buffer = buffer, .context = self.context, .serial = serial, .width = self.size.width, .height = self.size.height, .stride = layout.row_pitch };
    }

    pub fn writeRegion(self: *Texture, mip: u32, x: u32, y: u32, width: u32, height: u32, bytes: []const u8, bytes_per_row: u32) !void {
        if (self.memory != .host_upload) return error.TextureNotHostWritable;
        const region = d12.TextureRegion{ .mip = mip, .x = x, .y = y, .width = width, .height = height };
        const layout = try self.inner.copyLayout(region, 0);
        if (bytes_per_row < layout.row_bytes or @as(u64, bytes_per_row) * height > bytes.len) return error.InvalidTextureData;
        var buffer = try self.context.device.createBuffer(self.context.allocator, .{ .size = layout.required_bytes, .usage = .{ .map_write = true, .copy_src = true } });
        defer buffer.destroy();
        const mapped = try buffer.getMappedRange(0, buffer.size);
        @memset(mapped, 0);
        for (0..height) |row| @memcpy(mapped[row * layout.row_pitch ..][0..@intCast(layout.row_bytes)], bytes[row * bytes_per_row ..][0..@intCast(layout.row_bytes)]);
        // Recorded, not submitted: the next submission on this queue sends it first.
        const encoder = try self.context.uploadEncoder();
        try encoder.copyBufferToTexture(&buffer, 0, layout.row_pitch, &self.inner, region);
    }
    pub fn readBgra8(self: *const Texture, width: u32, height: u32, bytes: []u8, bytes_per_row: u32) !void {
        if (self.format != .bgra8_unorm and self.format != .bgra8_unorm_srgb) return error.UnsupportedTextureFormat;
        if (self.dimension != .@"2d" or self.size.depth != 1) return error.InvalidTextureRegion;
        const region = d12.TextureRegion{ .width = width, .height = height };
        const layout = try self.inner.copyLayout(region, 0);
        if (bytes_per_row < layout.row_bytes or @as(u64, bytes_per_row) * height > bytes.len) return error.InvalidTextureData;
        var buffer = try self.context.device.createBuffer(self.context.allocator, .{ .size = layout.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
        defer buffer.destroy();
        var encoder = try self.context.device.createCommandEncoder();
        defer encoder.deinit();
        var source = self.inner;
        try encoder.copyTextureToBuffer(&source, region, &buffer, 0, layout.row_pitch);
        try self.context.submit(&encoder);
        const mapped = try buffer.getMappedRange(0, buffer.size);
        for (0..height) |row| @memcpy(bytes[row * bytes_per_row ..][0..@intCast(layout.row_bytes)], mapped[row * layout.row_pitch ..][0..@intCast(layout.row_bytes)]);
    }
    pub fn binding(self: *const Texture) TextureBinding {
        return .{ .inner = self.inner, .context = self.context, .width = self.size.width, .height = self.size.height };
    }
    pub fn nativeHandleForRecording(self: *const Texture) ?*anyopaque {
        _ = self;
        return null; // Windows records through beginRecordingReadback, not a native texture handle.
    }
    pub fn destroy(self: *Texture) void {
        if (self.prepared_readback) |*buffer| buffer.destroy();
        self.inner.destroy();
        self.context.resources -= 1;
        self.* = undefined;
    }
    pub fn deinit(self: *Texture) void {
        self.destroy();
    }
};
/// Borrowed binding. Native recording retains the resource; the caller must
/// keep it alive until recording. Views explicitly own a native texture retain.
pub const TextureBinding = struct {
    inner: d12.Texture,
    context: *Context,
    width: u32,
    height: u32,
    pub fn eql(self: TextureBinding, other: TextureBinding) bool {
        return self.inner.raw == other.inner.raw;
    }
    pub fn createView(self: TextureBinding) TextureView {
        self.context.resources += 1;
        return .{ .inner = self.inner.retained(), .context = self.context };
    }
};
pub const TextureView = struct {
    inner: d12.Texture,
    context: *Context,
    pub fn destroy(self: *TextureView) void {
        self.inner.destroy();
        self.context.resources -= 1;
        self.* = undefined;
    }
};
