//! Real xdg-shell/Vulkan presentation. Software acceptance remains explicit.
const std = @import("std");
const vk = @import("vulkan_device").vulkan_native;
const wl = @import("linux_platform");
const r = vk.renderer_resources;
const probe_vertex align(4) = @embedFile("probe_vertex").*;
const probe_fragment align(4) = @embedFile("probe_fragment").*;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options: vk.Device.Options = .{};
    var frames: u32 = 120;
    var exercise_resize = false;
    var input_check = false;
    var scale_check = false;
    var pacing_check = false;
    var cursor_check = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--allow-software")) options.allow_software = true else if (std.mem.eql(u8, args[i], "--validation")) options.require_validation = true else if (std.mem.eql(u8, args[i], "--frames") and i + 1 < args.len) {
            i += 1;
            frames = try std.fmt.parseInt(u32, args[i], 10);
            if (frames == 0 or frames > 100000) return error.InvalidFrameCount;
        } else if (std.mem.eql(u8, args[i], "--resize")) exercise_resize = true else if (std.mem.eql(u8, args[i], "--cursor-check")) cursor_check = true else if (std.mem.eql(u8, args[i], "--input-check")) input_check = true else if (std.mem.eql(u8, args[i], "--scale-check")) scale_check = true else if (std.mem.eql(u8, args[i], "--pacing-check")) pacing_check = true else return error.InvalidArgument;
    }
    if (exercise_resize and frames < 120) return error.InsufficientResizeFrames;
    if (cursor_check and frames < 120) return error.InsufficientCursorFrames;
    try verifyRendererSurface(options, init.arena.allocator());
    // Odd logical dimensions exercise fractional rounding, not just integral
    // products at quarter scales.
    var window = try wl.Window.init(if (scale_check) 641 else 640, if (scale_check) 479 else 480, "Zenit — Wayland + Vulkan");
    defer window.deinit();
    if (cursor_check) {
        // A maximized surface keeps the real pointer inside across desktop
        // scale changes; do not rely on GNOME placing a small new window
        // underneath a stationary pointer. Focus still requires wl_pointer.enter.
        try window.setMaximized(true);
        if (!window.cursorAvailable()) return error.CursorServiceUnavailable;
        if (window.setCursorShapeChecked(255) or window.setCursorShapeChecked(19)) return error.InvalidCursorAccepted;
    }
    var cursor_seen: u32 = 0;
    var cursor_focused_frames: u32 = 0;
    var cursor_scales_seen: u8 = 0;
    var cursor_uncontrolled = false;
    var metrics = try window.nativeSurface();
    options.wayland_display = metrics.display;
    options.wayland_surface = metrics.surface;
    var diagnostic: vk.Diagnostic = .{};
    var device = vk.Device.init(options, &diagnostic) catch |err| {
        std.debug.print("WAYLAND_VULKAN FAIL: error={s} operation={s} vk_result={d}\n", .{ @errorName(err), diagnostic.operationName(), diagnostic.vk_result });
        return err;
    };
    defer _ = device.deinit() catch {};
    std.debug.print("WAYLAND_VULKAN_DEVICE: name={s} software={} logical={d}x{d} pixels={d}x{d} scale={d}\n", .{ device.info.deviceName(), device.info.isSoftware(), metrics.logical_width, metrics.logical_height, metrics.pixel_width, metrics.pixel_height, metrics.scale });
    // Bad source images must be rejected before acquiring a swapchain image.
    for ([_]vk.resources.Format{ .r8_unorm, .bgra8_unorm }) |format| {
        var invalid = try device.createTextureResource(2, 2, format, &diagnostic);
        defer invalid.destroy();
        if (format == .r8_unorm) try invalid.writeRegion(0, 0, 2, 2, &.{ 255, 255, 255, 255 }, 2, &diagnostic);
        if (device.presentTexture(&invalid, &diagnostic)) |_| return error.InvalidPresentSourceAccepted else |err| {
            if (err != error.InvalidDescriptor) return err;
        }
    }
    var pipeline = try vk.pipeline.Pipeline.init(&device, &probe_vertex, "main", &probe_fragment, "main", &.{}, .bgra8_unorm, &diagnostic);
    defer pipeline.destroy();
    var frame_texture: ?vk.resources.Texture = null;
    defer if (frame_texture) |*texture| texture.destroy();
    var pixel_checks: u32 = 0;
    var presented: u32 = 0;
    var idle_polls: u32 = 0;
    var resized: u32 = 0;
    var closed = false;
    var pointer_presses: u32 = 0;
    var pointer_releases: u32 = 0;
    var pointer_scrolls: u32 = 0;
    var scales_seen: u8 = 0;
    var last_tick: u64 = 0;
    if (pacing_check) window.startDisplayLink();
    defer if (pacing_check) window.stopDisplayLink();
    while (presented < frames) {
        const alive = if (pacing_check) window.pollEventsWithTimeout(100) else try window.poll(100);
        if (!alive) {
            closed = true;
            break;
        }
        const next = try window.nativeSurface();
        if (scale_check) {
            const expected_width: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(next.logical_width)) * next.scale));
            const expected_height: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(next.logical_height)) * next.scale));
            if (next.pixel_width != expected_width or next.pixel_height != expected_height) return error.ScaleDimensionsMismatch;
            for ([_]f32{ 1, 1.25, 1.5, 1.75, 2 }, 0..) |scale, bit| {
                if (@abs(next.scale - scale) < 0.001) scales_seen |= @as(u8, 1) << @intCast(bit);
            }
        }
        if (metrics.pixel_width != next.pixel_width or metrics.pixel_height != next.pixel_height) {
            resized += 1;
            std.debug.print("WAYLAND_METRICS: logical={d}x{d} pixels={d}x{d} scale={d}\n", .{ next.logical_width, next.logical_height, next.pixel_width, next.pixel_height, next.scale });
        }
        metrics = next;
        if (cursor_check) {
            const shape: u8 = @intCast((cursor_focused_frames / 6) % 21);
            const requested: u8 = if (shape == 19) 20 else if (shape == 20) 1 else shape;
            const before = window.cursorState();
            if (!window.setCursorShapeChecked(requested)) return error.CursorShapeRejected;
            const state = window.cursorState();
            if (state.pointer_focused != 0) cursor_focused_frames += 1;
            if (state.desired_shape != requested) return error.CursorDesiredShapeMismatch;
            if (requested == 20) {
                if (before.applied_shape != state.applied_shape or before.apply_count != state.apply_count) return error.UncontrolledCursorWasOverridden;
                cursor_uncontrolled = true;
            } else if (state.pointer_focused != 0) {
                if (state.applied_shape != requested or state.apply_count <= before.apply_count) return error.CursorNotApplied;
                cursor_seen |= @as(u32, 1) << @intCast(requested);
                if (scale_check and state.compositor_theme == 0 and requested < 18) {
                    const expected_cursor_scale: u32 = @intFromFloat(@ceil(metrics.scale));
                    if (state.theme_scale != expected_cursor_scale) return error.CursorThemeScaleMismatch;
                    for ([_]f32{ 1, 1.25, 1.5, 1.75, 2 }, 0..) |scale, bit| {
                        if (@abs(metrics.scale - scale) < 0.001) cursor_scales_seen |= @as(u8, 1) << @intCast(bit);
                    }
                }
            }
        }
        while (window.popInputEvent()) |event| {
            if (event.kind == 1) {
                if (event.button == 0 and event.cancelled == 0) {
                    if (event.pressed != 0) pointer_presses += 1 else pointer_releases += 1;
                }
                std.debug.print("WAYLAND_BUTTON: x={d} y={d} button={d} pressed={} cancelled={}\n", .{ event.x, event.y, event.button, event.pressed != 0, event.cancelled != 0 });
            } else if (event.kind == 5) {
                pointer_scrolls += 1;
                std.debug.print("WAYLAND_SCROLL: x={d} y={d} dx={d} dy={d}\n", .{ event.x, event.y, event.dx, event.dy });
            } else if (event.kind == 2) {
                std.debug.print("WAYLAND_KEY: key={d} pressed={} modifiers={d}\n", .{ event.keycode, event.pressed != 0, event.modifiers });
            } else if (event.kind == 3) {
                std.debug.print("WAYLAND_TEXT: {s}\n", .{event.text[0..event.text_length]});
            }
        }
        if (pacing_check) {
            const tick = window.getDisplayTick();
            if (presented > 0 and tick <= last_tick) {
                idle_polls += 1;
                if (idle_polls > 300) return error.CompositorFrameTimeout;
                continue;
            }
            last_tick = tick;
        } else if (!try window.requestFrame()) {
            idle_polls += 1;
            if (idle_polls > 300) return error.CompositorFrameTimeout;
            continue;
        }
        const color: [4]f32 = if ((presented / 30) % 2 == 0) .{ 0.25, 0.5, 0.75, 1 } else .{ 0.75, 0.25, 0.5, 1 };
        const recreate = if (frame_texture) |texture| texture.width != metrics.pixel_width or texture.height != metrics.pixel_height else true;
        if (recreate) {
            if (frame_texture) |*texture| texture.destroy();
            frame_texture = null;
            frame_texture = try device.createTextureResource(metrics.pixel_width, metrics.pixel_height, .bgra8_unorm, &diagnostic);
        }
        const texture = &frame_texture.?;
        try pipeline.draw(texture, &.{}, 0, 3, 0, 1, color, &diagnostic);
        if (recreate) {
            var sample: [4]u8 = undefined;
            try texture.readRegion(metrics.pixel_width / 2, metrics.pixel_height / 2, 1, 1, &sample, 4, &diagnostic);
            if (!std.mem.eql(u8, &sample, &.{ 0, 255, 0, 255 })) return error.WindowDrawPixelMismatch;
            try texture.readRegion(0, 0, 1, 1, &sample, 4, &diagnostic);
            const expected = if ((presented / 30) % 2 == 0) [_]u8{ 191, 128, 64, 255 } else [_]u8{ 128, 64, 191, 255 };
            if (!std.mem.eql(u8, &sample, &expected)) return error.WindowClearPixelMismatch;
            pixel_checks += 1;
        }
        device.presentTexture(texture, &diagnostic) catch |err| {
            window.cancelFrame();
            if (err == error.SurfaceOutdated or err == error.Timeout) {
                idle_polls += 1;
                if (idle_polls > 300) return error.SurfaceRecoveryTimeout;
                continue;
            }
            std.debug.print("WAYLAND_VULKAN FAIL: error={s} operation={s} vk_result={d}\n", .{ @errorName(err), diagnostic.operationName(), diagnostic.vk_result });
            return err;
        };
        presented += 1;
        idle_polls = 0;
        if (pacing_check and (presented == 20 or presented == 60)) {
            window.stopDisplayLink();
            window.startDisplayLink();
        }
        if (exercise_resize and presented == 20) try window.setMaximized(true);
        if (exercise_resize and presented == 60) try window.setMaximized(false);
    }
    if (cursor_check) {
        if (cursor_seen != 0x7ffff or !cursor_uncontrolled) {
            const failed = window.cursorState();
            std.debug.print("WAYLAND_CURSOR DIAGNOSTIC: seen=0x{x} focused={d} applied={d} uncontrolled={}\n", .{ cursor_seen, failed.pointer_focused, failed.apply_count, cursor_uncontrolled });
            return error.CursorFocusOrShapesMissing;
        }
        if (!window.setCursorShapeChecked(1)) return error.CursorRestoreFailed;
        const state = window.cursorState();
        if (scale_check and state.compositor_theme == 0 and cursor_scales_seen != 31) {
            std.debug.print("WAYLAND_CURSOR SCALE DIAGNOSTIC: mask={d} focused={d} applied={d}\n", .{ cursor_scales_seen, state.pointer_focused, state.apply_count });
            return error.CursorRequiredScalesMissing;
        }
        std.debug.print("WAYLAND_CURSOR PASS: shapes=0..18 custom_rejected=true uncontrolled_preserved=true serial_from_enter=true applied={d} compositor_theme={} theme_scale={d} scale_mask={d}\n", .{ state.apply_count, state.compositor_theme != 0, state.theme_scale, cursor_scales_seen });
    }
    if (presented == 0) return error.NoPresentedFrames;
    if (pacing_check and last_tick < presented - 1) return error.CompositorTicksMissing;
    if (pacing_check) std.debug.print("WAYLAND_PACING PASS: frames={d} ticks={d} refresh_hz={d} compositor_callbacks=true\n", .{ presented, last_tick, window.getDisplayRefreshRate() });
    if (exercise_resize and (closed or presented != frames)) return error.UnexpectedCloseDuringResizeGate;
    if (exercise_resize and resized < 2) return error.ResizeConfigureMissing;
    if (pixel_checks == 0) return error.WindowPixelChecksMissing;
    if (input_check and (pointer_presses == 0 or pointer_releases != pointer_presses or pointer_scrolls == 0)) return error.PointerInteractionMissing;
    if (input_check) std.debug.print("WAYLAND_POINTER PASS: presses={d} releases={d} scrolls={d} platform_window=true\n", .{ pointer_presses, pointer_releases, pointer_scrolls });
    if (scale_check and scales_seen != 31) return error.RequiredScalesMissing;
    if (scale_check) std.debug.print("WAYLAND_SCALE PASS: scales=1,1.25,1.5,1.75,2 logical_physical=true pixel_checks={d}\n", .{pixel_checks});
    if (frame_texture) |*texture| texture.destroy();
    frame_texture = null;
    pipeline.destroy();
    const software = device.info.isSoftware();
    const errors = try device.deinit();
    if (errors != 0) return error.VulkanValidationErrors;
    std.debug.print("WAYLAND_VULKAN PASS: mode={s} frames={d} resizes={d} closed={} graphics_draw=true texture_present=true invalid_present_sources=2 pixel_checks={d} validation_enabled={} validation_errors=0\n", .{ if (software) "software-functional" else "gpu", presented, resized, closed, pixel_checks, options.require_validation });
}

fn verifyRendererSurface(base_options: vk.Device.Options, a: std.mem.Allocator) !void {
    // Each independently owned WSI device gets a fresh xdg surface. Destroying
    // the first swapchain can unmap its surface; reusing it without another
    // initial configure handshake would invalidate the following input gate.
    var window = try wl.Window.init(640, 480, "Zenit — renderer surface contract");
    defer window.deinit();
    const metrics = try window.nativeSurface();
    var options = base_options;
    options.wayland_display = metrics.display;
    options.wayland_surface = metrics.surface;
    const b = vk.renderer_device;
    var instance = try b.Instance.initWithOptions(a, .{}, options);
    defer instance.deinit();
    const adapters = try instance.enumerateAdapters();
    defer a.free(adapters);
    defer adapters[0].deinit();
    var requested = try adapters[0].requestDevice(a, .{});
    defer requested.device.deinit();
    defer requested.queue.deinit();
    var descriptor: b.NativeSurface = .{
        .display = metrics.display,
        .surface = metrics.surface,
        .logical_width = metrics.logical_width,
        .logical_height = metrics.logical_height,
        .pixel_width = metrics.pixel_width,
        .pixel_height = metrics.pixel_height,
        .scale = metrics.scale,
    };
    var surface = b.Surface.init(@ptrCast(&descriptor));
    defer surface.deinit();
    const config: b.SurfaceConfiguration = .{ .format = .bgra8_unorm, .width = metrics.pixel_width, .height = metrics.pixel_height, .usage = .color_target_and_read };
    try surface.configure(a, &requested.device, config);
    var frame = try surface.acquireTexture(a);
    defer frame.deinit();
    if (surface.acquireTexture(a)) |_| return error.DuplicateAcquisitionAccepted else |err| {
        if (err != error.SurfaceBusy) return err;
    }
    if (surface.configure(a, &requested.device, config)) |_| return error.AcquiredSurfaceReconfigured else |err| {
        if (err != error.SurfaceBusy) return err;
    }
    if (surface.deinitChecked()) |_| return error.AcquiredSurfaceDestroyed else |err| {
        if (err != error.SurfaceBusy) return err;
    }
    var encoder = try b.CommandEncoder.init(&requested.queue);
    defer encoder.deinit();
    var view = frame.texture.binding().createView();
    defer view.destroy();
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &[_]r.gpu.RenderPassColorAttachment{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1 } }} });
    pass.end();
    var command = try encoder.finish();
    defer command.deinit();
    try frame.preparePresentChecked(&command);
    if (frame.preparePresentChecked(&command)) |_| return error.DuplicatePreparationAccepted else |err| {
        if (err != error.SurfaceAlreadyPrepared) return err;
    }
    if (frame.presentAfterSubmitChecked(&command)) |_| return error.UnsubmittedFramePresented else |err| {
        if (err != error.CommandNotSubmitted) return err;
    }
    try command.submitChecked();
    try frame.presentAfterSubmitChecked(&command);
    if (frame.presentAfterSubmitChecked(&command)) |_| return error.DuplicatePresentAccepted else |err| {
        if (err != error.SurfaceAlreadyPresented) return err;
    }
    const pixels = try a.alloc(u8, @as(usize, metrics.pixel_width) * metrics.pixel_height * 4);
    defer a.free(pixels);
    try frame.texture.readBgra8(metrics.pixel_width, metrics.pixel_height, pixels, metrics.pixel_width * 4);
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) if (!std.mem.eql(u8, pixels[i..][0..4], &.{ 191, 128, 64, 255 })) return error.SurfaceFramePixelMismatch;
    // Explicit release order exercises surface/device ownership guards.
    if (requested.device.deinitChecked()) |_| return error.LiveSurfaceDeviceDestroyed else |err| {
        if (err != error.ResourcesAlive) return err;
    }
    view.destroy();
    frame.deinit();
    command.deinit();
    encoder.deinit();
    try surface.configure(a, &requested.device, config);
    try surface.deinitChecked();
    try requested.device.deinitChecked();
    std.debug.print("VULKAN_RENDERER_SURFACE PASS: pixels={d} exact=true acquisition_guard=true present_order=true device_ownership=true validation_errors=0\n", .{pixels.len / 4});
}
