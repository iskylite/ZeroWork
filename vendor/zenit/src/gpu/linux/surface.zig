//! Shared Linux surface/frame ownership.
pub fn For(comptime b: type, comptime r: type) type {
    return struct {
        //! Wayland presentation through an owned render target. Native Linux GPU copies
        //! that target to the acquired swapchain image and fences presentation lifetime.
        const std = @import("std");
        const gpu = @import("../gpu.zig");

        pub const NativeSurface = extern struct {
            display: *anyopaque,
            surface: *anyopaque,
            logical_width: u32,
            logical_height: u32,
            pixel_width: u32,
            pixel_height: u32,
            scale: f32,
        };
        pub const SurfaceUsage = enum { color_target_only, color_target_and_read };
        pub const PresentMode = enum { fifo, immediate, mailbox };
        pub const AlphaMode = enum { fully_opaque, premultiplied, postmultiplied };
        pub const SurfaceConfiguration = struct {
            format: gpu.TextureFormat,
            width: u32,
            height: u32,
            usage: SurfaceUsage = .color_target_only,
            present_mode: PresentMode = .fifo,
            alpha_mode: AlphaMode = .fully_opaque,
            maximum_frame_latency: u32 = 2,
        };
        const Owner = struct {
            context: *r.Context,
            config: SurfaceConfiguration,
            acquired: u32 = 0,
        };
        pub const Surface = struct {
            native: NativeSurface,
            owner: ?*Owner = null,
            /// Handle points to the Linux platform's NativeSurface descriptor, not a
            /// wl_surface itself. Copy metrics so no caller stack pointer is retained.
            pub fn init(handle: *anyopaque) Surface {
                return .{ .native = @as(*const NativeSurface, @ptrCast(@alignCast(handle))).* };
            }
            pub fn configure(self: *Surface, allocator: std.mem.Allocator, device: *b.Device, config: SurfaceConfiguration) !void {
                _ = allocator;
                const context = try device.liveContext();
                if (context.device.wayland_display != self.native.display or context.device.wayland_surface != self.native.surface) return error.InvalidSurfaceDevice;
                if (config.format != .bgra8_unorm) return error.UnsupportedSurfaceFormat;
                if (config.present_mode != .fifo) return error.UnsupportedPresentMode;
                if (config.alpha_mode != .fully_opaque) return error.UnsupportedSurfaceAlpha;
                if (config.width == 0 or config.height == 0 or config.width > context.device.maxTextureDimension2D() or config.height > context.device.maxTextureDimension2D() or config.maximum_frame_latency == 0 or config.maximum_frame_latency > 64) return error.InvalidSurface;
                if (self.owner) |owner| {
                    if (owner.context != context) return error.InvalidSurfaceDevice;
                    if (owner.acquired != 0) return error.SurfaceBusy;
                    owner.config = config;
                } else {
                    const owner = try context.allocator.create(Owner);
                    owner.* = .{ .context = context, .config = config };
                    context.resources += 1;
                    self.owner = owner;
                }
            }
            pub fn acquireTexture(self: *Surface, allocator: std.mem.Allocator) !SurfaceTexture {
                const owner = self.owner orelse return error.SurfaceNotConfigured;
                // One outstanding acquisition prevents ambiguous prepare/present order.
                if (owner.acquired != 0) return error.SurfaceBusy;
                const texture = try owner.context.createTexture(allocator, .{
                    .size = .{ .width = owner.config.width, .height = owner.config.height },
                    .format = owner.config.format,
                    .usage = .{ .render_attachment = true, .copy_src = true, .texture_binding = true },
                });
                owner.acquired += 1;
                return .{ .texture = texture, .owner = owner };
            }
            pub fn deinitChecked(self: *Surface) !void {
                const owner = self.owner orelse return;
                if (owner.acquired != 0) return error.SurfaceBusy;
                owner.context.resources -= 1;
                owner.context.allocator.destroy(owner);
                self.owner = null;
            }
            pub fn deinit(self: *Surface) void {
                self.deinitChecked() catch @panic("Linux GPU surface still acquired");
            }
        };
        pub const SurfaceTexture = struct {
            texture: r.Texture,
            owner: ?*Owner,
            command: ?b.CommandBuffer = null,
            presented: bool = false,
            pub fn preparePresentChecked(self: *SurfaceTexture, command: *const b.CommandBuffer) !void {
                const owner = self.owner orelse return error.InvalidSurface;
                if (self.command != null or self.presented) return error.SurfaceAlreadyPrepared;
                if (self.texture.owner == null or self.texture.owner.?.context != owner.context) return error.InvalidSurfaceDevice;
                try command.presentTexture(&self.texture);
                self.command = command.retained();
            }
            pub fn preparePresent(self: *SurfaceTexture, command: *const b.CommandBuffer) void {
                self.preparePresentChecked(command) catch @panic("invalid Linux GPU present preparation");
            }
            pub fn presentAfterSubmitChecked(self: *SurfaceTexture, command: *const b.CommandBuffer) !void {
                if (self.owner == null) return error.InvalidSurface;
                if (self.presented) return error.SurfaceAlreadyPresented;
                const prepared = self.command orelse return error.SurfaceNotPrepared;
                if (prepared.state != command.state) return error.InvalidPresentCommand;
                try command.completionChecked();
                self.presented = true;
            }
            pub fn presentAfterSubmit(self: *SurfaceTexture, command: *const b.CommandBuffer) void {
                self.presentAfterSubmitChecked(command) catch |err| switch (err) {
                    error.SurfaceOutdated, error.Timeout => {},
                    else => @panic(@errorName(err)),
                };
            }
            pub fn deinit(self: *SurfaceTexture) void {
                const owner = self.owner orelse return;
                if (self.command) |*command| command.deinit();
                self.command = null;
                self.texture.destroy();
                owner.acquired -= 1;
                self.owner = null;
            }
        };
    };
}
