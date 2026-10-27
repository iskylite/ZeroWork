/// AppRenderer: top-level render coordinator
///
/// Encapsulates full UI -> screen pipeline:
///   1. cx.layout() - compute layout
///   2. cx.render(), paint pass - fill cx.display_list
///   3. encoder.encodeDisplay(cx) - encode to sdf/text/image renderer
///   4. flush(render_pass) - submit GPU
///   5. surface.present() - present frame
///
/// Usage:
/// ```
/// const app_renderer = try allocator.create(AppRenderer);
/// defer allocator.destroy(app_renderer);
/// try app_renderer.init(allocator, io, &device, &queue, &surface, .{});
/// defer app_renderer.deinit();
///
/// // Font setup
/// app_renderer.setFonts(&font_selector);
///
/// // Render loop
/// while (window.pollEvents()) {
///     try app_renderer.frame(cx, viewport_w, viewport_h, scale);
/// }
/// ```
const std = @import("std");
const gpu = @import("gpu");
const render = @import("render");
const render_pacing = @import("render_pacing.zig");
const caret_plan = @import("caret_patch_plan.zig");
extern fn macos_caret_patch_count(*anyopaque) c_uint;
extern fn macos_caret_drawable_info(*anyopaque, *anyopaque, *[4]u64) void;
extern fn metal_glass_clock_trace_line([*]const u8, usize) void;
extern fn macos_caret_patch_target(*anyopaque, c_uint, *[4]u32) ?*anyopaque;
const frame_testing_enabled = @import("builtin").is_test or @import("build_options").test_mode;
extern fn macos_caret_patch_command_succeeded(*anyopaque) c_int;
extern fn macos_caret_patch_composite(*anyopaque, [*]u8, u32, u32, f32) c_int;
extern fn macos_caret_patch_encode(*anyopaque, *anyopaque, *anyopaque, [*]const [4]f32, usize, f32) c_int;
extern fn macos_caret_patch_show(*anyopaque, c_int) void;
extern fn macos_caret_patch_clear(*anyopaque) void;
const engine_diagnostics_enabled = frame_testing_enabled or (@hasDecl(@import("build_options"), "engine_diagnostics") and @import("build_options").engine_diagnostics);
extern fn metal_command_buffer_track_engines(*anyopaque) void;
extern fn metal_command_buffer_engine_counts(*anyopaque, *[3]u32) void;
extern fn macos_fullscreen_header_encode(*anyopaque, *anyopaque, *anyopaque, u64) void;
extern fn macos_fullscreen_header_needs_content_revision(*anyopaque) c_int;

// Only evaluated during the bounded windowed prewarm, after Cx.render has run
// before_render hooks. Child paint versions catch header changes without
// invalidating the snapshot for body-only frames. No GPU readback for equality.
fn nativeHeaderContentRevision(header: anytype) u64 {
    var hash = std.hash.Wyhash.init(0);
    hashNativeHeaderSubtree(&hash, header);
    return hash.final();
}
fn hashNativeHeaderSubtree(hash: *std.hash.Wyhash, node: anytype) void {
    const caches = &node.meta.per_frame.caches;
    const stamp = [_]u64{ node.element_id_raw, caches.versions.content, caches.versions.composite, caches.text_hash.content_hash, caches.text_hash.spans_hash };
    hash.update(std.mem.asBytes(&stamp));
    const rect = node.rectFromWorldOrFallback();
    const geometry = [_]f32{ rect.x, rect.y, rect.w, rect.h };
    hash.update(std.mem.asBytes(&geometry));
    for (node.children.items) |child| hashNativeHeaderSubtree(hash, child);
}
const SdfRenderer = render.SdfRenderer;
const ImageRenderer = render.ImageRenderer;
const IconRenderer = render.IconRenderer;
const TextRenderer = render.TextRenderer;
const RenderCommandEncoder = render.RenderCommandEncoder;
const FontSelector = render.FontSelector;
const TextFontProps = render.TextFontProps;

// Metal-only, opt-in evidence. Null-backend builds prune every call, and
// disabled tracing does not sample clocks or register completion handlers.
extern fn metal_glass_clock_trace_enabled() bool;
extern fn metal_glass_clock_trace_host_time() f64;
extern fn metal_glass_clock_trace_frame(buffer: *anyopaque, drawable: *anyopaque, frame: u64, sample_host_time: f64, sample_frame_time_ms: f64, sample_frame_dt_ms: f64) void;

/// Stable FontSelector -> TextRenderer bridge.
///
/// AppRenderer owns TextRenderer for its whole lifetime, while frame encoders
/// are stack temporaries. Keeping this binding here makes `setFonts` the one
/// framework-level place that establishes the measure == draw contract.
fn measureWidthAsDrawn(ctx: *anyopaque, text: []const u8, font: *render.Font, props: TextFontProps) ?f32 {
    const text_renderer: *TextRenderer = @ptrCast(@alignCast(ctx));
    var fixed_advance: f32 = 0;
    if (props.use_monospace and props.monospace_char_width > 0) {
        var all_ascii = true;
        for (text) |byte| {
            if (byte >= 0x80) {
                all_ascii = false;
                break;
            }
        }
        if (all_ascii) fixed_advance = props.monospace_char_width;
    }
    return text_renderer.measureTextWidthAsDrawn(
        text,
        font,
        props.font_size,
        props.use_italic,
        fixed_advance,
    ) catch null;
}

/// Keep CPU in-flight slots aligned with the renderers' triple-buffered
/// instance storage. Dropping this below 3 made frame pacing depend too much
/// on CAMetalLayer drawable availability and pushed jitter into acquireTexture.
const FRAME_BUFFER_COUNT = render_pacing.frames_in_flight;
/// Frame performance stats, auto-collected each frame, exposed to DevTools via getLastFrameStats().
pub const FrameStats = struct {
    /// Layout compute time (microseconds).
    layout_us: u64 = 0,
    /// Render command generation time (microseconds).
    render_gen_us: u64 = 0,
    /// GPU encode + submit time (microseconds).
    gpu_encode_us: u64 = 0,
    /// Time waiting for previous frame GPU completion / next frame quota (microseconds).
    wait_for_frame_us: u64 = 0,
    /// Time acquiring drawable / surface texture (microseconds).
    acquire_texture_us: u64 = 0,
    /// Pure CPU pipeline time (layout + render + encode + flush, excludes wait/acquire).
    cpu_frame_us: u64 = 0,
    /// **True GPU execution time** (microseconds), from backend command-buffer timestamp interval.
    /// Differs from gpu_encode_us (CPU-side encode + submit wall-clock, includes wait/acquire).
    /// GPU timestamps are valid only **after** the command buffer completes; this frame's buffer
    /// was just submitted, so this reports the **previous frame's** GPU time. 0 = no completed
    /// frame yet.
    gpu_execute_us: u64 = 0,
    /// Encode time (encodeDisplay, microseconds).
    encode_us: u64 = 0,
    /// Flush + end render pass time (microseconds).
    flush_us: u64 = 0,
    /// Glass (backdrop blur / Liquid Glass) nodes processed and their CPU time.
    glass_count: u32 = 0,
    glass_us: u64 = 0,
    /// Offscreen textures created this frame (steady state: 0).
    texture_creates: u32 = 0,
    /// Backend render/blit passes recorded and the native begin/end CPU time
    /// (D3D12 only; 0 elsewhere).
    render_passes: u32 = 0,
    blit_passes: u32 = 0,
    compute_passes: u32 = 0,
    pass_native_us: u64 = 0,
    /// Path pipeline GPU draws actually issued this frame (post-batch).
    path_draw_calls: u32 = 0,
    /// GPU retained composite: whole-layer cache hit / redraw / damage-rect partial redraw this
    /// frame.
    retained_hits: u32 = 0,
    retained_misses: u32 = 0,
    retained_partial_repaints: u32 = 0,
    /// Icon pipeline GPU draws this frame.
    icon_draw_calls: u32 = 0,
    /// Image pipeline GPU draws (after batching consecutive same-texture).
    image_draw_calls: u32 = 0,
    /// Image pipeline instance count this frame.
    image_instances: u32 = 0,
    /// Image pipeline texture binding switches this frame, real bottleneck metric for dense image
    /// canvas.
    texture_binds: u32 = 0,
    /// SDF pipeline GPU draws this frame.
    sdf_draw_calls: u32 = 0,
    /// Text pipeline GPU draws this frame.
    text_draw_calls: u32 = 0,
    /// Total GPU draw calls issued this frame (sdf + text + path + icon + image sum).
    draw_calls: u32 = 0,
    /// SDF instance count.
    sdf_instances: u32 = 0,
    /// Text glyph instance count.
    text_instances: u32 = 0,
    /// Total render commands.
    command_count: u32 = 0,
    /// Total frame time (microseconds).
    total_frame_us: u64 = 0,
};

/// Cross-frame timing sample ring (P95 gate use). Implementation and test in timing_ring.zig,
/// independent of Metal/ObjC bridge so `zig build test` truly covers it.
pub const TimingRing = @import("timing_ring.zig").TimingRing;

/// Frame clear color. Window clear in **sRGB-encoded values** (0..1, same units as Color
/// bytes/255).
/// Render target is non-_sRGB format (docs/SRGB_BLENDING_PLAN.md), clear value written as-is.
/// Before 2026-10 interpreted as linear; old default 0.08/0.08/0.10 (linear) ≈ encoded
/// 0.313/0.313/0.349.
pub const ClearColor = struct {
    r: f32 = 0.313,
    g: f32 = 0.313,
    b: f32 = 0.349,
    a: f32 = 1.0,
};

/// AppRenderer config.
pub const Config = struct {
    visual_quality: render.visual_quality.Quality = .auto,
    clear_color: ClearColor = .{},
    /// Optional eager glyph upload; draw encoding still resolves missing glyphs.
    prewarm_text: bool = true,
};

pub const RecordingFrameFn = *const fn (texture: *const gpu.Backend.Texture) bool;
pub const RecordingFrameContextFn = *const fn (?*anyopaque, *const gpu.Backend.Texture) bool;

/// AppRenderer - encapsulate complete render pipeline.
/// Called before each drawable acquisition. Returning true fails that
/// acquisition with `error.SurfaceTimeout`, exactly like a compositor timeout,
/// so applications can test their recovery path deterministically.
pub const AcquireFaultHook = struct {
    ctx: ?*anyopaque = null,
    should_fail: *const fn (ctx: ?*anyopaque) bool,
};

pub const AppRenderer = struct {
    allocator: std.mem.Allocator,

    // GPU infrastructure (borrowed, not owned).
    device: *gpu.Backend.Device,
    queue: *gpu.Backend.Queue,
    surface: *gpu.Backend.Surface,

    // Renderers (owned).
    sdf_renderer: SdfRenderer,
    image_renderer: ImageRenderer,
    icon_renderer: IconRenderer,
    text_renderer: TextRenderer,

    // Fonts (borrowed, not owned).
    fonts: ?*FontSelector = null,

    // Config.
    config: Config,
    io: std.Io,
    visual_quality: render.visual_quality.Quality = .full,

    // Frame stats.
    frame_count: u64 = 0,
    fail_after_encode_for_testing: if (frame_testing_enabled) bool else void = if (frame_testing_enabled) false else {},
    acquire_fault_hook: ?AcquireFaultHook = null,
    /// Opt-in desktop audit identity stamp, never enabled for normal rendering.
    desktop_capture_stamp: bool = false,
    /// Cumulative retained count (monotonic cross-frame; /stats use, per-frame overwritten by later
    /// settle/idle frames; e2e assertions need cumulative).
    total_retained_hits: u64 = 0,
    total_retained_misses: u64 = 0,
    total_retained_partial_repaints: u64 = 0,
    /// Backdrop luminance adaptation: last frame glass backdrop avg luminance (linear 0~1).
    backdrop_luminance: ?f32 = null,
    /// Last frame performance stats.
    last_frame_stats: FrameStats = .{},
    /// Cross-frame timing sample ring (P95 gate use). `last_frame_stats` single-frame snapshot;
    /// single-frame timing very noisy. e2e needs "P95 over last N frames" robust aggregate.
    timing_ring: TimingRing = .{},
    /// Only resolved command-buffer timestamp intervals; no missing-sample zeros.
    gpu_timing_ring: TimingRing = .{},
    gpu_timing_disjoint_samples: u64 = 0,
    gpu_timing_failed_samples: u64 = 0,
    /// Last **render** frame start time (idle skip doesn't update), DevTools FPS frame-interval
    /// baseline.
    /// Use renderer's own wall-clock not cx.frame_dt_seconds: latter 1s capped and idle wake first
    /// frame
    /// nominal, not render interval.
    prev_frame_start: ?@import("zenit_time").Instant = null,

    // GPU frame sync, prevent CPU overwrite triple buffer GPU is reading. Platform abstraction:
    // Metal uses dispatch_semaphore, future Vulkan uses VkFence.
    frame_sync: gpu.Backend.FrameSync,

    // Offscreen texture pool + frame counter must live in AppRenderer (persistent cross-frame).
    // encoder per-frame local: pool embedded there would deinit whole pool each frame, cross-frame
    // texture reuse never happens; frame_index resets 0 each frame, pool's REUSE_LAG_FRAMES
    // in-flight
    // protection fails.
    offscreen_pool: render.OffscreenTexturePool = .{},
    /// Persistent path/blur/glass GPU resources (PSO, buffer, sampler, tessellator). Same reason as
    /// offscreen_pool must be in AppRenderer: embedded in per-frame encoder re-compiles MSL runtime
    /// each
    /// frame, continuous path/blur animation jitters (audit P1).
    persistent_gpu: render.PersistentGpuCache = .{},
    /// Test-only submission control; production frame code never reads it.
    developer_empty_frames: bool = false,
    frame_counter: u64 = 0,
    pool_viewport: [3]f32 = .{ 0, 0, 0 },
    pool_maintenance_retry: render.OffscreenMaintenanceRetry = .{},
    /// Public encoders can submit outside our FrameSync. Once one escapes,
    /// keep the pool's conservative frame quarantine for this renderer.
    has_external_encoder: bool = false,
    /// Icon pipeline draw count module-level cumulative; store last frame total for per-frame
    /// delta.
    prev_icon_draw_calls_total: u64 = 0,
    prev_image_draw_calls_total: u64 = 0,
    prev_sdf_draw_calls_total: u64 = 0,
    prev_text_draw_calls_total: u64 = 0,
    prev_image_instances_total: u64 = 0,
    prev_texture_binds_total: u64 = 0,

    /// Last frame submitted command buffer (used only **next frame** to read its GPU timestamps;
    /// GPUStartTime/GPUEndTime valid only after buffer complete). Wrapper holds extra ref, released
    /// after
    /// next frame reads; upper layer doesn't observe native handle.
    prev_frame_cmd_buffer: ?gpu.Backend.CommandBuffer = null,
    /// Scalar opt-in diagnostics; they never own drawables or command buffers.
    caret_diag_exit_host_time: f64 = 0,
    caret_diag_exit_seq: u64 = 0,
    caret_diag_handoff: bool = false,
    /// Submitted frames whose GPU timestamps are not resolved yet, oldest
    /// first. With frames in flight the previous frame is usually still on the
    /// GPU right after this one is submitted; harvesting only it (as before)
    /// read a timestamp only while the GPU was idle (a handful at startup).
    gpu_timing_pending: [4]?gpu.Backend.CommandBuffer = @splat(null),
    /// An idle poll may harvest before frame() publishes its statistics.
    idle_gpu_execute_us: u64 = 0,
    /// In-flight batch per-glass luminance readback: command buffer that wrote staging (extra
    /// retain).
    /// Until the batch read is done, the encode side stops writing staging
    /// (persistent_gpu.luminance_locked); poll waits only for this frame to complete. Waiting on
    /// "last frame" is wrong: with CVDisplayLink continuous output the last frame is always still
    /// on the GPU at new-frame start, so readout would stall for the entire animation.
    lum_batch_cmd_buffer: ?gpu.Backend.CommandBuffer = null,

    // -- e2e: retained copy of last **truly presented** frame --
    // /screenshot used to "drive new render then readback"; the new frame carries pending
    // layout/dirty, so the screenshot is newer than what is on screen and can hide on-screen
    // artifacts (e.g. layer ghosts). Instead, blit the drawable to a retained texture before each
    // present; screenshot reads it and does not drive a frame. Harness mode only (blit ~0.1ms
    // GPU/frame, not in CPU budget).
    retain_present_copy: bool = false,
    retained_enabled: bool = true,
    frame_damage: render.FrameDamage = .{},
    frame_partial_count: u64 = 0,
    frame_reuse_count: u64 = 0,
    background_damage: render.FrameDamage = .{},
    background_tex: ?gpu.Backend.Texture = null,
    background_valid: bool = false,
    background_reuse_count: u64 = 0,
    background_partial_count: u64 = 0,
    retained_tex: ?gpu.Backend.Texture = null,
    retained_w: u32 = 0,
    retained_h: u32 = 0,
    retained_valid: bool = false,
    /// Host-only entry preparation: copy hidden background from its presented
    /// frame, then render visible caret commands only into the small targets.
    last_frame_presented: bool = false,
    caret_patch_capture: bool = false,
    caret_background_capture: bool = false,
    /// Latches after bounded failed replacement; only renderer init resets it.
    caret_flip_disabled: bool = false,
    caret_test_fringe: if (frame_testing_enabled) bool else void = if (frame_testing_enabled) false else {},
    caret_hidden_items: ?[]caret_plan.Item = null,
    caret_patch_ready: bool = false,

    // E2E screenshot request, set by test harness screenshot callback (test-mode). Actual pixel
    // read
    // happens inside frame() before present (drawable valid + GPU done). One request per frame;
    // cleared
    // after read. Capacity 512 matches RPC payload limit.
    pending_screenshot_path: ?[512]u8 = null,
    pending_screenshot_len: usize = 0,
    last_screenshot_ok: bool = false,

    // Window-content recording. Context callbacks receive a submitted drawable
    // and order their copy on the renderer queue; legacy callbacks wait below.
    recording_active: bool = false,
    recording_frame_fn: ?RecordingFrameFn = null,
    recording_context_fn: ?RecordingFrameContextFn = null,
    recording_context: ?*anyopaque = null,

    /// Initialize AppRenderer.
    ///
    /// Create sdf/image/text renderer, encapsulate pipeline.
    pub fn init(
        self: *AppRenderer,
        allocator: std.mem.Allocator,
        io: std.Io,
        device: *gpu.Backend.Device,
        queue: *gpu.Backend.Queue,
        surface: *gpu.Backend.Surface,
        config: Config,
    ) !void {
        // allocator.create/undefined storage does not apply struct field defaults.
        // Initialize the entire owner so new optional resources cannot inherit
        // poisoned bytes (including caret snapshots on the first preparation).
        self.* = .{
            .allocator = allocator,
            .io = io,
            .device = device,
            .queue = queue,
            .surface = surface,
            .config = config,
            .sdf_renderer = undefined,
            .image_renderer = undefined,
            .icon_renderer = undefined,
            .text_renderer = undefined,
            .frame_sync = undefined,
            .developer_empty_frames = if (comptime frame_testing_enabled and gpu.backend_kind == .metal) @import("zenit_environment").has("ZENIT_DEV_EMPTY_FRAME") else false,
        };

        self.sdf_renderer = try SdfRenderer.init(allocator, device);
        errdefer self.sdf_renderer.deinit();

        try self.image_renderer.init(allocator, device);
        errdefer self.image_renderer.deinit();

        try self.icon_renderer.init(allocator, device);
        errdefer self.icon_renderer.deinit();

        self.text_renderer = try TextRenderer.init(allocator, device);
        errdefer self.text_renderer.deinit();

        var requested = config.visual_quality;
        if (comptime gpu.is_direct3d) {
            if (@import("zenit_environment").getOwned(allocator, "ZENIT_VISUAL_QUALITY") catch null) |value| {
                defer allocator.free(value);
                requested = try render.visual_quality.parse(value);
            }
        }
        if (comptime gpu.is_direct3d) {
            const args: std.process.Args = .{ .vector = std.os.windows.peb().ProcessParameters.CommandLine.slice() };
            var argv = try args.iterateAllocator(allocator);
            defer argv.deinit();
            const prefix = "--zenit-visual-quality=";
            while (argv.next()) |arg| {
                if (std.mem.startsWith(u8, arg, prefix)) requested = try render.visual_quality.parse(arg[prefix.len..]);
            }
        }
        const quality = render.visual_quality.resolve(requested, if (comptime gpu.is_direct3d) device.isSoftware() else false);
        if (comptime gpu.is_direct3d) std.log.info("[visual-quality] requested={s} effective={s}", .{ @tagName(requested), @tagName(quality) });
        self.visual_quality = quality;
        // WARP admits one GPU frame while retaining triple-buffered storage.
        self.frame_sync = if (comptime gpu.is_direct3d)
            gpu.Backend.FrameSync.initWithLimit(FRAME_BUFFER_COUNT, if (device.isSoftware()) 1 else FRAME_BUFFER_COUNT)
        else if (comptime gpu.backend_kind == .null_backend)
            gpu.Backend.FrameSync.init(FRAME_BUFFER_COUNT, io)
        else
            gpu.Backend.FrameSync.init(FRAME_BUFFER_COUNT);
    }

    /// Get correctly-bound RenderCommandEncoder (auto-carries fonts + persistent offscreen pool).
    pub fn getEncoder(self: *AppRenderer) RenderCommandEncoder {
        self.has_external_encoder = true;
        return self.createEncoder();
    }

    /// Manual submissions are not tracked by frameWithPresentation. The caller
    /// may retire wallclock-expired textures between encoders after proving all
    /// submissions using this pool have finished. Elapsed time is not a fence.
    pub fn maintainExternalOffscreenPool(self: *AppRenderer, gpu_completed: bool) void {
        const now: u64 = @intCast(@max(0, @import("zenit_time").monotonicTimestamp(self.io)));
        self.offscreen_pool.maintain(now, gpu_completed);
    }

    fn createEncoder(self: *AppRenderer) RenderCommandEncoder {
        var enc = RenderCommandEncoder.initWithImageAndIcon(&self.sdf_renderer, &self.text_renderer, &self.image_renderer, &self.icon_renderer, &self.offscreen_pool, &self.persistent_gpu);
        // Once manual submissions escape FrameSync, automatic frames must
        // retain the same conservative aging too. Otherwise mixed use loses
        // both wallclock maintenance and the manual encoder's frame sweeps.
        enc.external_pool_aging = self.has_external_encoder;
        // Reset frame-internal cursors (uniform ring write offset etc), keep pipeline/buffers.
        self.persistent_gpu.beginFrame();
        // Frame counter carried by AppRenderer (encoder per-frame new, self-increment zeroes each
        // frame).
        self.frame_counter += 1;
        self.offscreen_pool.setClock(@intCast(@max(0, @import("zenit_time").monotonicTimestamp(self.io))));
        enc.io = self.io;
        enc.frame_index = self.frame_counter;
        enc.retained_enabled = self.retained_enabled;
        enc.main_destination_opaque = self.config.clear_color.a == 1;
        enc.visual_quality = self.visual_quality;
        if (self.fonts) |f| enc.setFonts(f);
        return enc;
    }

    /// Set font selector, bind measurement to TextRenderer with stable lifetime. Any font drawn via
    /// AppRenderer thus defaults measure == draw; host no longer needs separate callback easily
    /// missed or
    /// mis-bound to per-frame encoder.
    pub fn setFonts(self: *AppRenderer, fonts: *FontSelector) void {
        if (self.fonts != fonts) self.frame_damage.invalidate();
        if (self.fonts) |previous| {
            if (previous.drawn_width_ctx == @as(*anyopaque, @ptrCast(&self.text_renderer))) {
                previous.setDrawnWidthSource(null, null);
            }
        }
        self.fonts = fonts;
        fonts.setDrawnWidthSource(&measureWidthAsDrawn, @ptrCast(&self.text_renderer));
    }

    /// Changing decoration never releases in-flight GPU resources.
    pub fn setVisualQuality(self: *AppRenderer, requested: render.visual_quality.Quality) void {
        // Blur pipeline failure auto-downgrades to basic (D3D12 only; WARP etc); Metal keeps
        // semantics: glass just non-blurred.
        const quality = if ((comptime gpu.is_direct3d) and self.persistent_gpu.blur_pipeline_failed) .basic else render.visual_quality.resolve(requested, if (comptime gpu.is_direct3d) self.device.isSoftware() else false);
        if (self.visual_quality == quality) return;
        self.visual_quality = quality;
        self.frame_damage.invalidate();
        self.background_damage.invalidate();
        self.background_valid = false;
        self.retained_valid = false;
        self.offscreen_pool.invalidateRetainedContents();
    }

    pub fn setRecordingFrameCallback(self: *AppRenderer, callback: RecordingFrameFn) void {
        self.recording_frame_fn = callback;
    }

    pub fn setRecordingActive(self: *AppRenderer, active: bool) void {
        self.recording_active = active;
    }

    pub fn setRecordingContextCallback(self: *AppRenderer, context: ?*anyopaque, callback: RecordingFrameContextFn) void {
        self.recording_context = context;
        self.recording_context_fn = callback;
    }

    /// E2E: request next frame capture drawable pixels to PNG before present. Actual read inside
    /// frame() (see captureSurfaceToPng). Returns true if request registered. Caveat: drawable must
    /// be
    /// framebufferOnly=false (test-mode surface uses .color_target_and_read), else getBytes reads
    /// nothing.
    /// Texture memory usage snapshot (image canvas LRU budget eviction).
    pub fn textureMemoryStats(self: *const AppRenderer) render.TextureMemoryStats {
        return self.image_renderer.getTextureMemoryStats();
    }

    pub fn requestCapture(self: *AppRenderer, path: []const u8) bool {
        if (path.len == 0 or path.len >= 512) return false;
        var buf: [512]u8 = undefined;
        @memcpy(buf[0..path.len], path);
        self.pending_screenshot_path = buf;
        self.pending_screenshot_len = path.len;
        self.last_screenshot_ok = false;
        return true;
    }

    /// Read BGRA8 from surface -> convert RGBA8 -> write PNG. Called before present. cmd_buffer
    /// must
    /// have waitUntilCompleted, ensuring render landed in texture.
    fn captureSurfaceToPng(self: *AppRenderer, texture: *const gpu.Backend.Texture, width: u32, height: u32) bool {
        if (width == 0 or height == 0) return false;
        const px = @as(usize, width) * @as(usize, height);
        const bytes_per_row: u32 = width * 4;

        const bgra = self.allocator.alloc(u8, px * 4) catch return false;
        defer self.allocator.free(bgra);
        const rgba = self.allocator.alloc(u8, px * 4) catch return false;
        defer self.allocator.free(rgba);

        texture.readBgra8(width, height, bgra, bytes_per_row) catch return false;

        // BGRA -> RGBA byte swap.
        var i: usize = 0;
        while (i < px * 4) : (i += 4) {
            rgba[i] = bgra[i + 2]; // R <- B position.
            rgba[i + 1] = bgra[i + 1]; // G
            rgba[i + 2] = bgra[i]; // B <- R position.
            rgba[i + 3] = bgra[i + 3]; // A
        }

        const path_slice = self.pending_screenshot_path.?[0..self.pending_screenshot_len];
        var path_z: [512:0]u8 = undefined;
        @memcpy(path_z[0..path_slice.len], path_slice);
        path_z[path_slice.len] = 0;

        return gpu.Backend.writePngRgba(&path_z, rgba, width, height, bytes_per_row);
    }

    /// Read any BGRA8 texture -> RGBA8 -> write PNG (same pipeline as captureSurfaceToPng, but path
    /// explicit, not dependent on pending_screenshot_* state).
    fn textureToPng(self: *AppRenderer, texture: *const gpu.Backend.Texture, width: u32, height: u32, path: []const u8) bool {
        return self.textureToPngComposited(texture, width, height, path, null);
    }

    pub fn captureCaretCompositeToPng(self: *AppRenderer, path: []const u8, scale: f32) bool {
        const texture = &(self.retained_tex orelse return false);
        if (self.prev_frame_cmd_buffer) |*command| command.waitUntilCompleted();
        return self.textureToPngComposited(texture, self.retained_w, self.retained_h, path, scale);
    }

    fn textureToPngComposited(self: *AppRenderer, texture: *const gpu.Backend.Texture, width: u32, height: u32, path: []const u8, caret_scale: ?f32) bool {
        if (width == 0 or height == 0 or path.len == 0 or path.len >= 512) return false;
        const px = @as(usize, width) * @as(usize, height);
        const bytes_per_row: u32 = width * 4;
        const bgra = self.allocator.alloc(u8, px * 4) catch return false;
        defer self.allocator.free(bgra);
        const rgba = self.allocator.alloc(u8, px * 4) catch return false;
        defer self.allocator.free(rgba);
        texture.readBgra8(width, height, bgra, bytes_per_row) catch return false;
        if (comptime gpu.backend_kind == .metal) {
            if (caret_scale) |scale| {
                if (macos_caret_patch_composite(@ptrCast(self.surface.layer), bgra.ptr, width, height, scale) == 0) return false;
            }
        }
        var i: usize = 0;
        while (i < px * 4) : (i += 4) {
            rgba[i] = bgra[i + 2];
            rgba[i + 1] = bgra[i + 1];
            rgba[i + 2] = bgra[i];
            rgba[i + 3] = bgra[i + 3];
        }
        var path_z: [512:0]u8 = undefined;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        return gpu.Backend.writePngRgba(&path_z, rgba, width, height, bytes_per_row);
    }

    /// E2E screenshot **preferred path**: read retained copy of last true-presented frame. Return
    /// false =
    /// no retained frame yet (startup/disabled), caller falls back to old path.
    pub fn captureRetainedToPng(self: *AppRenderer, path: []const u8) bool {
        if (!self.retained_valid) return false;
        const tex = &(self.retained_tex orelse return false);
        // Blit encoded in last frame command stream; must confirm GPU done before read, else reads
        // half-written
        // (steady-state already done, here just edge-case insurance).
        if (self.prev_frame_cmd_buffer) |*prev| prev.waitUntilCompleted();
        return self.textureToPng(tex, self.retained_w, self.retained_h, path);
    }

    /// Ensure retained texture matches current surface size (rebuild on resize).
    fn ensureBackgroundTexture(self: *AppRenderer, width: u32, height: u32) !void {
        if (self.background_tex) |*tex| {
            if (tex.size.width == width and tex.size.height == height) return;
            tex.destroy();
            self.background_tex = null;
        }
        self.background_valid = false;
        self.background_tex = try self.device.createTexture(self.allocator, .{
            .label = "static-frame-prefix",
            .size = .{ .width = width, .height = height, .depth = 1 },
            .format = gpu.color_format,
            .usage = .{ .copy_src = true, .copy_dst = true, .render_attachment = gpu.backend_kind == .metal },
        });
    }

    fn ensureRetainedTexture(self: *AppRenderer, width: u32, height: u32) bool {
        if (self.retained_tex != null and self.retained_w == width and self.retained_h == height) return true;
        if (self.retained_tex) |*t| t.destroy();
        self.retained_tex = null;
        self.retained_valid = false;
        const tex = self.device.createTexture(self.allocator, .{
            .label = "e2e-retained-present",
            .size = .{ .width = width, .height = height, .depth = 1 },
            .format = gpu.color_format,
            .usage = .{ .copy_src = true, .copy_dst = true, .render_attachment = gpu.backend_kind == .metal },
            // WARN: must be host_upload (CPU-readable shared storage). Default device_local is
            // GPU-private
            // compressed layout on Apple Silicon, getBytes directly SIGSEGV (crashes at AGX
            // processCompressedRegion2D).
            .memory = .host_upload,
        }) catch return false;
        self.retained_tex = tex;
        self.retained_w = width;
        self.retained_h = height;
        return true;
    }

    /// Initialize AppRenderer internal FontSelector lazy derived font cache. FontSelector borrowed
    /// ref,
    /// caller owns lifetime.
    pub fn initFontDerivedCache(self: *AppRenderer, allocator: std.mem.Allocator) void {
        if (self.fonts) |fs| {
            fs.initDerivedCache(allocator);
        }
    }

    /// Deinitialize AppRenderer internal FontSelector lazy derived font cache. FontSelector
    /// borrowed ref,
    /// caller should call once only at global teardown.
    pub fn deinitFontDerivedCache(self: *AppRenderer) void {
        if (self.fonts) |fs| {
            fs.deinitDerivedCache();
        }
    }

    fn frameResourceKey(self: *const AppRenderer) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.config.clear_color));
        const Font = @typeInfo(@TypeOf(@as(render.FontSelector, undefined).small)).pointer.child;
        if (self.fonts) |fonts| {
            inline for (@import("zenit_reflection").fields(FontSelector)) |field| {
                if (field.type == *Font or field.type == ?*Font) {
                    h.update(std.mem.asBytes(&@field(fonts, field.name)));
                } else if (@typeInfo(field.type) == .array) {
                    if (@typeInfo(field.type).array.child == ?*Font)
                        h.update(std.mem.asBytes(&@field(fonts, field.name)));
                }
            }
        }
        if (self.text_renderer.fallback_stack) |stack| {
            for (stack.families[0..stack.family_count]) |family| {
                h.update(std.mem.asBytes(&family.priority));
                h.update(std.mem.sliceAsBytes(family.fonts[0..family.count]));
            }
        }
        h.update(std.mem.asBytes(&self.text_renderer.font_ranges_context));
        h.update(std.mem.asBytes(&self.text_renderer.font_ranges_provider));
        return h.final();
    }

    pub fn clearCaretPreparation(self: *AppRenderer) void {
        if (self.caret_hidden_items) |items| self.allocator.free(items);
        self.caret_hidden_items = null;
        self.caret_background_capture = false;
    }

    pub fn caretItems(self: *AppRenderer, commands: anytype) ![]caret_plan.Item {
        const items = try self.allocator.alloc(caret_plan.Item, commands.len);
        for (commands, items) |it, *item| {
            var hash = std.hash.Wyhash.init(0);
            render.PaintFingerprint.hashCaretPaintItemInto(&hash, it);
            const digest = hash.final();
            if (frame_testing_enabled and (self.caret_background_capture or self.caret_patch_capture) and it.glass_ptr != null and @import("zenit_environment").has("ZENIT_CARET_FLIP_DEBUG")) {
                std.log.info("[caret-material] hidden={} payload=0x{x} content=0x{x}", .{ self.caret_background_capture, @intFromPtr(it.glass_ptr), digest });
            }
            if (frame_testing_enabled and (self.caret_background_capture or self.caret_patch_capture) and it.icon_rep_ptr != null and @import("zenit_environment").has("ZENIT_CARET_FLIP_DEBUG")) {
                std.log.info("[caret-icon] hidden={} payload=0x{x} content=0x{x}", .{ self.caret_background_capture, @intFromPtr(it.icon_rep_ptr), digest });
            }
            const control = it.kind == .control;
            const composite = control and (it.control_kind == .begin_opacity_layer or it.control_kind == .begin_blur_layer or it.control_kind == .begin_rounded_clip);
            item.* = .{
                .label = if (control) @tagName(it.control_kind) else @tagName(it.kind),
                .digest = digest,
                .bounds = if (composite) render.PaintFingerprint.nestedCompositeBounds(it) orelse render.PaintFingerprint.damageItemBounds(it) else if (control) .{ 0, 0, 0, 0 } else if (it.kind == .path) render.PaintFingerprint.pathItemBounds(it) else render.PaintFingerprint.damageItemBounds(it),
                .drawable = if (control) switch (it.control_kind) {
                    .push_clip, .pop_clip, .end_opacity_layer, .end_blur_layer, .end_rounded_clip => false,
                    else => true,
                } else it.kind != .none,
                // Damage bounds do not cover transformed primitives or icon
                // representations whose paths may escape geom. No trusted local
                // envelope means later painting must conservatively reject.
                .unbounded = (composite and render.PaintFingerprint.nestedCompositeBounds(it) == null) or
                    (!control and (it.use_draw_transform or it.icon_rep_ptr != null)) or
                    (control and !composite and it.control_kind != .push_clip and it.control_kind != .pop_clip and
                        it.control_kind != .end_opacity_layer and it.control_kind != .end_blur_layer and it.control_kind != .end_rounded_clip),
                .clip = control and (it.control_kind == .push_clip or it.control_kind == .pop_clip),
                .clip_delta = if (!control) 0 else switch (it.control_kind) {
                    .push_clip => 1,
                    .pop_clip => -1,
                    else => 0,
                },
                .effect_delta = if (!control) 0 else switch (it.control_kind) {
                    .begin_opacity_layer, .begin_blur_layer, .begin_rounded_clip => 1,
                    .end_opacity_layer, .end_blur_layer, .end_rounded_clip => -1,
                    else => 0,
                },
                // Draw the application's original GPU command, with its clip
                // stack. Effects/custom drawings use ordinary blinking until
                // a region-local replay contract exists for them.
                .local_caret = it.kind == .rect and it.stroke_width == 0 and it.noise_intensity == 0 and it.shadow_blur == 0 and it.rotate == 0 and !it.use_draw_transform,
            };
            item.paint_bounds = item.bounds;
            if (item.local_caret) item.bounds = .{ it.geom.x, it.geom.y, it.geom.w, it.geom.h };
        }
        return items;
    }

    fn renderCaretTargets(self: *AppRenderer, cx: anytype, scale: f32) !void {
        if (comptime gpu.backend_kind != .metal) return error.CaretPatchUnavailable;
        const commands = cx.lowerForEncoderPaintTable();
        const visible = try self.caretItems(commands);
        defer self.allocator.free(visible);
        const count = macos_caret_patch_count(@ptrCast(self.surface.layer));
        if (count == 0 or count > 64) return error.CaretPatchUnavailable;
        var patches: [64][4]f32 = undefined;
        for (0..count) |index| {
            var rect: [4]u32 = undefined;
            _ = macos_caret_patch_target(@ptrCast(self.surface.layer), @intCast(index), &rect) orelse return error.CaretPatchUnavailable;
            // Read the actual native crop, avoiding a second implementation of
            // outset, quad alignment and clipping at fractional backing scales.
            for (rect, &patches[index]) |v, *out| out.* = @as(f32, @floatFromInt(v)) / scale;
        }
        const selected = try caret_plan.select(self.allocator, self.caret_hidden_items orelse return error.CaretPatchUnavailable, visible, cx.caret_rects[0..cx.caret_rect_count], patches[0..count]);
        defer self.allocator.free(selected);
        for (0..count) |index| {
            var rect: [4]u32 = undefined;
            const raw = macos_caret_patch_target(@ptrCast(self.surface.layer), @intCast(index), &rect) orelse return error.CaretPatchUnavailable;
            const target: gpu.Backend.Texture = .{ .raw = @ptrCast(@alignCast(raw)), .format = gpu.color_format, .size = .{ .width = rect[2], .height = rect[3] }, .mip_level_count = 1, .dimension = .@"2d", .memory = .host_upload };
            try self.frame_sync.waitForNextFrame();
            var slot_owned = true;
            errdefer if (slot_owned) self.frame_sync.signal();
            var enc = self.createEncoder();
            defer enc.deinit();
            enc.beginFrame(self.pool_viewport[0], self.pool_viewport[1], scale);
            var command_encoder = try gpu.Backend.CommandEncoder.init(self.queue);
            errdefer command_encoder.deinit();
            var view = target.binding().createView();
            defer view.destroy();
            var pass = try command_encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .load, .store_op = .store }} });
            pass.root_crop = rect;
            pass.setViewport(0, 0, @floatFromInt(self.surface.extent.width), @floatFromInt(self.surface.extent.height), 0, 1);
            pass.setScissorRect(0, 0, self.surface.extent.width, self.surface.extent.height);
            enc.gpu_command_encoder = &command_encoder;
            enc.main_render_target = target.binding();
            enc.render_pass = &pass;
            // One command at a time keeps the original clip/order contract;
            // no full-window render target or drawable is acquired here.
            for (commands, selected, 0..) |_, keep, i| if (keep) try enc.encodeCommands(commands[i .. i + 1]);
            const current_pass = enc.render_pass orelse return error.MissingActiveRenderPass;
            try enc.flush(current_pass);
            current_pass.end();
            var command = try command_encoder.finish();
            defer command.deinit();
            self.frame_sync.signalOnCompletion(&command);
            slot_owned = false;
            command.submit();
            command.waitUntilCompleted();
            if (self.prev_frame_cmd_buffer) |*previous| previous.deinit();
            self.prev_frame_cmd_buffer = command.retained();
            if (macos_caret_patch_command_succeeded(@ptrCast(command.raw)) == 0) return error.CaretPreparationGpuFailed;
            self.frame_count += 1;
        }
        self.caret_patch_ready = true;
        if (self.pending_screenshot_path) |path| {
            macos_caret_patch_show(@ptrCast(self.surface.layer), 1);
            defer macos_caret_patch_show(@ptrCast(self.surface.layer), 0);
            self.last_screenshot_ok = self.captureCaretCompositeToPng(path[0..self.pending_screenshot_len], scale);
            self.pending_screenshot_path = null;
            self.pending_screenshot_len = 0;
        }
    }

    /// Render one frame using UI Cx context.
    ///
    /// Full pipeline:
    ///   1. cx.layout()
    ///   2. cx.render(), paint pass fills cx.display_list
    ///   3. encode -> rect/text renderer
    ///   4. create GPU encoder + render pass
    ///   5. flush + present.
    pub fn frame(self: *AppRenderer, cx: anytype, viewport_width: f32, viewport_height: f32, scale: f32) !void {
        return self.frameWithPresentation(cx, viewport_width, viewport_height, scale, null);
    }

    pub fn frameWithPresentation(self: *AppRenderer, cx: anytype, viewport_width: f32, viewport_height: f32, scale: f32, presentation_sample: anytype) !void {
        self.last_frame_presented = false;
        if (comptime gpu.is_direct3d) {
            if (try self.text_renderer.updateWindowTextParameters(self.surface.hwnd)) {
                self.frame_damage.invalidate();
                self.background_damage.invalidate();
                self.background_valid = false;
                self.retained_valid = false;
                self.offscreen_pool.invalidateRetainedContents();
                cx.needs_redraw = true;
                if (cx.root) |root| root.markRenderDirty();
            }
        }

        if (comptime @hasField(@TypeOf(cx.*), "frame_presentation_sample")) cx.frame_presentation_sample = presentation_sample;
        defer {
            if (comptime @hasField(@TypeOf(cx.*), "frame_presentation_sample")) cx.frame_presentation_sample = null;
        }
        const viewport = [3]f32{ viewport_width, viewport_height, scale };
        if (self.pool_viewport[0] != 0 and !std.mem.eql(f32, &viewport, &self.pool_viewport)) self.offscreen_pool.noteResize();
        self.pool_viewport = viewport;
        _ = self.pollBackdropLuminance(cx);
        // Permanent optional-pipeline failure downgrades this renderer once. Essential GPU errors
        // still
        // propagate; basic is not device recovery. Only D3D12 upgrades blur pipeline failure to
        // overall basic
        // quality (includes disabling animations).
        if ((comptime gpu.is_direct3d) and self.visual_quality != .basic and self.persistent_gpu.blur_pipeline_failed) {
            self.visual_quality = .basic;
            self.frame_damage.invalidate();
            self.background_damage.invalidate();
            self.background_valid = false;
            self.retained_valid = false;
            self.offscreen_pool.invalidateRetainedContents();
            if (self.lum_batch_cmd_buffer == null) {
                for (&self.persistent_gpu.luminance_slots) |*slot| slot.cur_pending = false;
            }
            cx.needs_redraw = true;
            if (cx.root) |root| root.markRenderDirty();
            std.log.warn("[visual-quality] basic: backdrop pipeline unavailable", .{});
        }
        if (@hasField(@TypeOf(cx.*), "renderer_reduced_motion")) {
            cx.renderer_reduced_motion = self.visual_quality == .basic;
        }
        // Basic quality draws glass as an opaque material and never reads the
        // backdrop luminance back; new glass must not wait for a reading.
        if (@hasField(@TypeOf(cx.*), "backdrop_luminance_readback")) {
            cx.backdrop_luminance_readback = self.visual_quality != .basic;
        }
        const frame_start = @import("zenit_time").Instant.now(cx.io) catch null;
        var measured_frame = false;
        // Registered before frame resources: their deferred teardown must be
        // included in CPU/total timing, especially COM releases on Direct3D.
        defer if (measured_frame) {
            const complete = @import("zenit_time").Instant.now(cx.io) catch null;
            const elapsed = timerDelta(frame_start, complete);
            self.last_frame_stats.total_frame_us = elapsed;
            self.last_frame_stats.cpu_frame_us = elapsed -| self.last_frame_stats.wait_for_frame_us -| self.last_frame_stats.acquire_texture_us;
            self.timing_ring.push(.{
                .gpu_execute_us = self.last_frame_stats.gpu_execute_us,
                .cpu_frame_us = self.last_frame_stats.cpu_frame_us,
                .total_frame_us = elapsed,
            });
            cx.frame_perf.pushFrameTotalUs(elapsed);
            if (@import("zenit_environment").has("ZENIT_FRAME_PROFILE")) {
                std.debug.print("FRAME_PROFILE frame={d} cpu={d} layout={d} gen={d} gpu={d} before={d} initial={d} tick={d} post={d} index={d} node={d} encode={d}\n", .{ cx.frame_count, self.last_frame_stats.cpu_frame_us, self.last_frame_stats.layout_us, self.last_frame_stats.render_gen_us, self.last_frame_stats.gpu_encode_us, cx.perf.before_render_us, cx.perf.br_initial_layout_us, cx.perf.br_tick_us, cx.perf.br_post_layout_us, cx.perf.br_index_us, cx.perf.render_node_us, self.last_frame_stats.encode_us });
            }
        };
        errdefer {
            self.frame_damage.invalidate();
            self.background_damage.invalidate();
            self.background_valid = false;
            self.retained_valid = false;
            // Layer encoding can mark textures primed before this frame is
            // submitted. Abandoning its command buffer also abandons those
            // pixels and damage baselines; the retry must repaint every layer.
            self.offscreen_pool.invalidateRetainedContents();
        }
        const frame_error_start = if (comptime gpu.is_direct3d) gpu.Backend.CommandBuffer.error_count.load(.monotonic) else 0;
        var wait_start: ?@import("zenit_time").Instant = null;
        var wait_end: ?@import("zenit_time").Instant = null;

        // D3D12 (especially WARP) can wait hundreds of milliseconds for a
        // frame slot. Sample animation time after that wait, so submitted UI
        // state does not describe the instant before the GPU stall.
        const early_frame_wait = gpu.is_direct3d;
        var acquired_slot = false;
        errdefer if (acquired_slot) self.frame_sync.signal();
        if (early_frame_wait) {
            wait_start = @import("zenit_time").Instant.now(cx.io) catch null;
            try self.frame_sync.waitForNextFrame();
            wait_end = @import("zenit_time").Instant.now(cx.io) catch null;
            acquired_slot = true;
            if (comptime gpu.is_direct3d) {
                // No submitted frame remains after the checked fence wait.
                // This is common with WARP's single-frame admission limit.
                // Release only the pool's time quarantine, never its owners or
                // content fingerprints; the next encoder resets frame leases.
                if (!self.has_external_encoder and self.frame_sync.pending == 0)
                    self.offscreen_pool.notifyGpuIdle();
            }
        }

        // 0. Advance frame clock (must be before layout/render; before_render hooks, overlay
        // enter-exit, spinner etc. read frame_time_ms). advanceFrameClock skips the advance for
        // idle
        // frames (whole tree clean + no overlay animation + no needs_redraw), keeping the
        // zero-dirty
        // fast path; any live signal (e.g. spinner markRenderDirty) advances the clock and drives
        // continuous animation. Without this, frame_time_ms stays frozen and animations are static.
        cx.advanceFrameClock();
        const clock_trace_enabled = if (comptime gpu.backend_kind == .metal) metal_glass_clock_trace_enabled() else false;
        const clock_sample_host_time = if (clock_trace_enabled) metal_glass_clock_trace_host_time() else 0;
        const clock_sample_frame_time_ms = cx.frame_time_ms;
        const clock_sample_frame_dt_ms: f64 = cx.frame_dt_ms;

        // 1. Layout.
        const layout_start = @import("zenit_time").Instant.now(cx.io) catch null;
        cx.world.layout_output.layout_oom = false;
        cx.layout();
        if (cx.world.layout_output.layout_oom) {
            if (cx.root) |root| root.markSizingDirty();
            return error.OutOfMemory;
        }
        const layout_end = @import("zenit_time").Instant.now(cx.io) catch null;

        // 2. Generate render commands. cx.render() runs paint pass fills cx.display_list; encoder
        //    via
        // enc.encodeDisplay(cx) calls cx.lowerForEncoder() itself for lowered DisplayItem slice.
        // Caller doesn't
        // hold IR.
        const render_start = @import("zenit_time").Instant.now(cx.io) catch null;
        _ = cx.render();
        if (comptime frame_testing_enabled) {
            if (self.caret_test_fringe and cx.caret_rect_count > 0) {
                const r = cx.caret_rects[0];
                // A later selection/highlight covers just the AA fringe,
                // strictly outside the tight caret geometry (one backing px).
                try cx.lowering.main_paint.append(cx.allocator, .{
                    .kind = .rect,
                    .geom = .{ .x = r[0] - 1 / scale, .y = r[1], .w = 1 / scale, .h = r[3] },
                    .color = .{ .r = 179, .g = 51, .b = 204, .a = 255 },
                });
            }
        }
        if (cx.world.layout_output.layout_oom) {
            if (cx.root) |root| root.markSizingDirty();
            return error.OutOfMemory;
        }
        const render_end = @import("zenit_time").Instant.now(cx.io) catch null;
        self.scanPaintTable(cx);
        if (self.caret_patch_capture) return self.renderCaretTargets(cx, scale);
        if (self.caret_background_capture) {
            if (self.caret_hidden_items) |items| self.allocator.free(items);
            self.caret_hidden_items = null;
            self.caret_hidden_items = try self.caretItems(cx.lowerForEncoderPaintTable());
        }

        // Admission must precede ring rotation, atlas collection and GPU writes.
        // CPU layout/paint can still overlap the preceding GPU frame.
        if (!early_frame_wait) {
            wait_start = @import("zenit_time").Instant.now(cx.io) catch null;
            try self.frame_sync.waitForNextFrame();
            wait_end = @import("zenit_time").Instant.now(cx.io) catch null;
            acquired_slot = true;
        }
        const checkpoint = .{
            .frame = self.frame_counter,
            .sdf = self.sdf_renderer.current_buffer,
            .text = self.text_renderer.current_buffer,
            .image = self.image_renderer.current_buffer,
            .icon = self.icon_renderer.current_buffer,
            .text_frame = self.text_renderer.current_frame,
            .atlas_frame = self.text_renderer.atlas.current_frame,
            .icon_frame = self.icon_renderer.frame_index,
        };
        const PathCheckpoint = struct { slot: usize, shrink_frame: u64, current_frame: u64 };
        const path_checkpoint: ?PathCheckpoint = if (self.persistent_gpu.path_renderer) |*pr|
            .{ .slot = pr.buffer_slot, .shrink_frame = pr.shrink_frame, .current_frame = pr.current_frame }
        else
            null;
        var submitted = false;
        errdefer if (!submitted) {
            // An aborted attempt consumed no GPU frame. Keep the next retry on
            // its available slot, and do not age retired resources on failures.
            self.frame_counter = checkpoint.frame;
            self.sdf_renderer.current_buffer = checkpoint.sdf;
            self.text_renderer.current_buffer = checkpoint.text;
            self.image_renderer.current_buffer = checkpoint.image;
            self.icon_renderer.current_buffer = checkpoint.icon;
            self.text_renderer.current_frame = checkpoint.text_frame;
            self.text_renderer.atlas.current_frame = checkpoint.atlas_frame;
            self.icon_renderer.frame_index = checkpoint.icon_frame;
            if (path_checkpoint) |previous| {
                if (self.persistent_gpu.path_renderer) |*pr| {
                    pr.restoreFrameBufferSlot(previous.slot);
                    pr.shrink_frame = previous.shrink_frame;
                    pr.current_frame = previous.current_frame;
                }
            }
        };
        const setup_start = if (@import("zenit_environment").has("ZENIT_FRAME_PROFILE")) @import("zenit_time").Instant.now(cx.io) catch null else null;
        var enc = self.createEncoder();
        defer enc.deinit();
        enc.beginFrame(viewport_width, viewport_height, scale);
        const warm_start = if (setup_start != null) @import("zenit_time").Instant.now(cx.io) catch null else null;
        if (self.config.prewarm_text) try enc.prewarmDisplay(cx);
        if (setup_start != null) {
            const warm_end = @import("zenit_time").Instant.now(cx.io) catch null;
            std.debug.print("SETUP_PROFILE frame={d} setup={d} prewarm={d}\n", .{ cx.frame_count, timerDelta(setup_start, warm_start), timerDelta(warm_start, warm_end) });
        }

        // 3. Prepare GPU submit.
        // Completed timing commands still retain their presented drawable.
        // Release them before nextDrawable, particularly after idle handoff;
        // harvesting after acquisition can permanently grow the layer pool.
        // This polls completion only and never waits for an in-flight frame.
        const newly_harvested_us = self.harvestGpuTimings();
        const gpu_execute_us: u64 = if (newly_harvested_us != 0) newly_harvested_us else self.idle_gpu_execute_us;
        self.idle_gpu_execute_us = 0;
        self.retireCompletedPresentation();
        const diagnostic_in_flight = if (clock_trace_enabled) self.diagnosticInFlight() else 0;
        const diagnostic_acquire_start = if (clock_trace_enabled) metal_glass_clock_trace_host_time() else 0;
        const acquire_start = @import("zenit_time").Instant.now(cx.io) catch null;
        if (self.acquire_fault_hook) |hook| if (hook.should_fail(hook.ctx)) return error.SurfaceTimeout;
        var surface_texture = try self.surface.acquireTexture(self.allocator);
        const acquire_end = @import("zenit_time").Instant.now(cx.io) catch null;
        defer surface_texture.deinit();

        enc.setDrawableExtent(surface_texture.texture.size.width, surface_texture.texture.size.height);

        if (comptime gpu.backend_kind == .metal) if (clock_trace_enabled) {
            var info: [4]u64 = undefined;
            macos_caret_drawable_info(@ptrCast(self.surface.layer), @ptrCast(surface_texture.drawable), &info);
            const host_time = metal_glass_clock_trace_host_time();
            var line: [1024]u8 = undefined;
            const encoded = std.fmt.bufPrint(&line, "{{\"kind\":\"caret-drawable\",\"frame\":{d},\"host_time\":{d:.9},\"acquire_start\":{d:.9},\"in_flight_before\":{d},\"in_flight_after\":{d},\"iosurface_id\":{d},\"texture_ref\":{d},\"drawable_id\":{d},\"drawable_budget\":{d},\"exit_seq\":{d},\"exit_host_time\":{d:.9},\"handoff\":{},\"hidden_preparation\":{},\"input_epoch\":{d},\"mutation_epoch\":{d},\"width\":{d},\"height\":{d}}}", .{
                self.frame_count + 1,           host_time,                  diagnostic_acquire_start,      diagnostic_in_flight, self.diagnosticInFlight(),
                info[0],                        info[1],                    info[2],                       info[3],              self.caret_diag_exit_seq,
                self.caret_diag_exit_host_time, self.caret_diag_handoff,    self.caret_background_capture, cx.input_epoch,       cx.world.mutation_epoch,
                self.surface.extent.width,      self.surface.extent.height,
            }) catch unreachable;
            metal_glass_clock_trace_line(encoded.ptr, encoded.len);
        };

        if (comptime frame_testing_enabled and gpu.backend_kind == .metal) {
            if (self.developer_empty_frames) {
                // Same device, queue, layer and drawable size; no draws, header
                // encoding or retained-present blit. For attribution only.
                var empty_encoder = try gpu.Backend.CommandEncoder.init(self.queue);
                metal_command_buffer_track_engines(@ptrCast(empty_encoder.raw));
                errdefer empty_encoder.deinit();
                var view = surface_texture.texture.binding().createView();
                defer view.destroy();
                var pass = try empty_encoder.beginRenderPass(.{ .color_attachments = &.{.{
                    .view = view,
                    .load_op = .load,
                    .store_op = .store,
                }} });
                pass.end();
                var command = try empty_encoder.finish();
                defer command.deinit();
                self.frame_sync.signalOnCompletion(&command);
                acquired_slot = false;
                surface_texture.preparePresent(&command);
                if (comptime gpu.is_direct3d) try command.submitChecked() else command.submit();
                submitted = true;
                surface_texture.presentAfterSubmit(&command);
                self.last_frame_presented = true;
                if (self.prev_frame_cmd_buffer) |*previous| previous.deinit();
                self.prev_frame_cmd_buffer = command.retained();
                self.pool_maintenance_retry.reset();
                self.retained_valid = false;
                self.frame_count += 1;
                return;
            }
        }

        // A provider may change its output while retaining the same context
        // address. It has no revision contract, so custom providers repaint.
        // The preserved texture uses BGRA; other surface formats also repaint.
        const frame_cache_enabled = if (comptime gpu.is_direct3d)
            self.device.isSoftware() and self.retained_enabled and !self.has_external_encoder and self.config.clear_color.a == 1 and self.text_renderer.font_ranges_provider == null and
                (surface_texture.texture.format == .bgra8_unorm or surface_texture.texture.format == .bgra8_unorm_srgb)
        else
            false;
        var damage: ?[4]u32 = null;
        if (frame_cache_enabled) {
            damage = try self.frame_damage.prepare(self.allocator, cx.lowerForEncoderPaintTable(), surface_texture.texture.size.width, surface_texture.texture.size.height, scale, self.frameResourceKey());
            if (!self.retained_valid or self.retained_w != surface_texture.texture.size.width or self.retained_h != surface_texture.texture.size.height) damage = null;
        } else self.frame_damage.invalidate();

        var prefix_len: usize = 0;
        var reuse_background = false;
        var background_update: ?[4]u32 = null;
        if (frame_cache_enabled and !self.frame_damage.pending_valid) {
            const commands = cx.lowerForEncoderPaintTable();
            const candidate = render.FrameDamage.flatPrefixEnd(commands);
            if (candidate > 0) {
                const change = try self.background_damage.prepare(self.allocator, commands[0..candidate], surface_texture.texture.size.width, surface_texture.texture.size.height, scale, self.frameResourceKey());
                if (self.background_damage.pending_valid) {
                    try self.ensureBackgroundTexture(surface_texture.texture.size.width, surface_texture.texture.size.height);
                    prefix_len = candidate;
                    reuse_background = self.background_valid and if (change) |rect| rect[2] == 0 or rect[3] == 0 else false;
                    if (self.background_valid and !reuse_background) background_update = change;
                }
            }
        } else if (!frame_cache_enabled) {
            self.background_damage.invalidate();
            self.background_valid = false;
        }

        var gpu_encoder = try gpu.Backend.CommandEncoder.init(self.queue);
        if (comptime gpu.backend_kind == .metal and engine_diagnostics_enabled) {
            if (frame_testing_enabled or @import("zenit_environment").has("ZENIT_DEV_ENGINE_COUNTS"))
                metal_command_buffer_track_engines(@ptrCast(gpu_encoder.raw));
        }
        // Error path fallback: encodeDisplay/flush below may error early-return, then finish()
        // never called
        // (state != .finished), command buffer unreleased. CommandEncoder.deinit prepared for this
        // "unfinished"
        // case; success path finish() sets state to .finished, deinit becomes no-op, ownership to
        // cmd_buffer,
        // no double-free.
        errdefer gpu_encoder.deinit();

        if (comptime gpu.is_direct3d) {
            if (damage != null or reuse_background or background_update != null) {
                var blit = try gpu_encoder.beginBlitPass();
                defer blit.end();
                const source = if (reuse_background or background_update != null) self.background_tex.?.binding() else self.retained_tex.?.binding();
                try blit.copyTextureRegion(source, 0, 0, source.width, source.height, surface_texture.texture.binding(), 0, 0);
            }
        }

        var texture_view = surface_texture.texture.binding().createView();
        defer texture_view.destroy();

        const cc = self.config.clear_color;
        var render_pass = try gpu_encoder.beginRenderPass(.{
            .color_attachments = &[_]gpu.RenderPassColorAttachment{
                .{
                    .view = texture_view,
                    .load_op = if (damage != null or reuse_background or background_update != null) .load else .clear,
                    .store_op = .store,
                    .clear_value = .{ .r = cc.r, .g = cc.g, .b = cc.b, .a = cc.a },
                },
            },
        });

        // 4. Encode (encoder holds render_pass ref, clip stack available).
        const encode_start = @import("zenit_time").Instant.now(cx.io) catch null;
        // **Critical**: must bind gpu_command_encoder + main_render_target to encoder, else
        // opacity_layer.beginOpacityLayer / backdrop_blur early-return at
        // `gpu_command_encoder == null` -> all offscreen surfaces (modal/sheet opacity fade,
        // GlassBox backdrop blur) are silently broken: content degrades inline and misaligned.
        enc.gpu_command_encoder = &gpu_encoder;
        enc.main_render_target = surface_texture.texture.binding();
        enc.render_pass = &render_pass;
        enc.applyOffscreenTargetViewport();
        if (prefix_len > 0) {
            if (!reuse_background) {
                if (background_update) |rect| {
                    if (comptime gpu.is_direct3d) {
                        if (!render_pass.clearOpaque(.{ cc.r, cc.g, cc.b, cc.a }, rect)) return error.FrameDamageClearFailed;
                    }
                    enc.frame_damage_scissor = rect;
                    enc.applyOffscreenTargetViewport();
                }
                try enc.encodeCommands(cx.lowerForEncoderPaintTable()[0..prefix_len]);
                try enc.flush(&render_pass);
                render_pass.end();
                enc.frame_damage_scissor = null;
                if (comptime gpu.is_direct3d) {
                    var blit = try gpu_encoder.beginBlitPass();
                    defer blit.end();
                    const source = surface_texture.texture.binding();
                    try blit.copyTextureRegion(source, 0, 0, source.width, source.height, self.background_tex.?.binding(), 0, 0);
                }
                render_pass = try gpu_encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = texture_view, .load_op = .load, .store_op = .store }} });
                enc.render_pass = &render_pass;
                enc.applyOffscreenTargetViewport();
            }
            try enc.encodeDisplayFrom(cx, prefix_len);
        } else if (damage) |rect| {
            if (comptime gpu.is_direct3d) {
                if (rect[2] > 0 and rect[3] > 0 and !render_pass.clearOpaque(.{ cc.r, cc.g, cc.b, cc.a }, rect)) return error.FrameDamageClearFailed;
            }
            enc.frame_damage_scissor = rect;
            enc.applyOffscreenTargetViewport();
            if (rect[2] > 0 and rect[3] > 0) try enc.encodeDisplay(cx);
        } else try enc.encodeDisplay(cx);
        const encode_end = @import("zenit_time").Instant.now(cx.io) catch null;
        const pending_sdf_instances = self.sdf_renderer.instances.items.len;
        const pending_text_instances = self.text_renderer.getPendingInstanceCount();

        // 5. Flush to GPU. Offscreen composite (opacity surface/backdrop blur) ends original
        //    render_pass,
        // creates restored_pass, writes back enc.render_pass. Must flush/end **encoder's current
        // pass**
        // (may be replaced), not local `render_pass`, else double-end already-ended pass, trigger
        // Metal
        // `endEncoding already called` assertion crash.
        const flush_start = @import("zenit_time").Instant.now(cx.io) catch null;
        if (enc.render_pass) |rp| {
            try enc.flush(rp);
            if (comptime gpu.is_direct3d) {
                if (self.desktop_capture_stamp) {
                    const serial = self.frame_count + 1;
                    if (serial > 0xffffff) return error.DesktopCaptureSerialOverflow;
                    const w = surface_texture.texture.size.width;
                    const h = surface_texture.texture.size.height;
                    if (w < 8 or h < 4) return error.DesktopCaptureTooSmall;
                    rp.setScissorRect(0, 0, w, h);
                    var color: [4]f32 = .{ 0, 0, 0, 1 };
                    const codes = [2][3]u8{ .{ @truncate(serial), @truncate(serial >> 8), @truncate(serial >> 16) }, .{ 53, 199, 107 } };
                    for (codes, 0..) |rgb, i| {
                        for (rgb, 0..) |v, c| {
                            const n = @as(f32, @floatFromInt(v)) / 255;
                            color[c] = if (n <= 0.04045) n / 12.92 else std.math.pow(f32, (n + 0.055) / 1.055, 2.4);
                        }
                        if (!rp.clearOpaque(color, .{ @as(u32, @intCast(i)) * 4 + 1, 1, 3, 3 })) return error.DesktopCaptureStampFailed;
                    }
                }
            }
            rp.end();
        } else {
            // The original local value may already have been ended by an
            // offscreen effect. Never fall back to it: Metal can recycle its
            // Objective-C address for a blit encoder in the meantime.
            return error.MissingActiveRenderPass;
        }
        const flush_end = @import("zenit_time").Instant.now(cx.io) catch null;

        // e2e: copy soon-presented content into retained texture (see retain_present_copy). Must
        // encode
        // into same command stream before finish.
        var frame_copy_ok = false;
        if (self.retain_present_copy or (frame_cache_enabled and self.frame_damage.pending_valid)) {
            const src = surface_texture.texture.binding();
            if (self.ensureRetainedTexture(src.width, src.height)) {
                // Valid only if this exact soon-presented frame was copied.
                if (gpu.copyTextureRegion(&gpu_encoder, src, 0, 0, src.width, src.height, self.retained_tex.?.binding(), 0, 0, false)) {
                    self.retained_valid = true;
                    frame_copy_ok = true;
                } else |err| {
                    self.retained_valid = false;
                    std.log.warn("[renderer] retained present copy failed: {s}", .{@errorName(err)});
                }
            }
        }

        if (!frame_copy_ok) self.retained_valid = false;

        // Diagnostics (ZENIT_DEBUG_GLASS_RT="x,y" device pixels): blit RT 64x64 region
        // to debug slot 2 at frame end; renderer reads RGB average next frame to compare
        // with capture/composite baselines for phase localization (sandwich method).
        const glass_rt_spec = @import("zenit_environment").getOwned(self.allocator, "ZENIT_DEBUG_GLASS_RT") catch null;
        defer if (glass_rt_spec) |spec| self.allocator.free(spec);
        if (glass_rt_spec) |spec| blk: {
            var it = std.mem.splitScalar(u8, spec, ',');
            const rx = std.fmt.parseInt(u32, it.next() orelse break :blk, 10) catch break :blk;
            const ry = std.fmt.parseInt(u32, it.next() orelse break :blk, 10) catch break :blk;
            const slot = &self.persistent_gpu.debug_glass_slots[2];
            if (slot.staging == null) {
                slot.staging = self.device.createTexture(self.allocator, .{
                    .label = "Zenit.GlassDebugRtStaging",
                    .size = .{ .width = 64, .height = 64 },
                    .format = gpu.color_format,
                    .usage = .{ .copy_dst = true, .render_attachment = gpu.backend_kind == .metal },
                    .memory = .host_upload,
                }) catch null;
            }
            const staging = &(slot.staging orelse break :blk);
            const src = surface_texture.texture.binding();
            if (rx + 64 > src.width or ry + 64 > src.height) break :blk;
            if (gpu.copyTextureRegion(&gpu_encoder, src, rx, ry, 64, 64, staging.binding(), 0, 0, false)) {
                slot.cur_pending = true;
                slot.cur_w = 64;
                slot.cur_h = 64;
                slot.last_used_frame = self.frame_counter;
            } else |_| {}
        }
        if (comptime frame_testing_enabled) {
            if (self.fail_after_encode_for_testing) {
                self.fail_after_encode_for_testing = false;
                return error.InjectedFrameFailure;
            }
        }
        if (comptime gpu.backend_kind == .metal) {
            var header_revision: u64 = 0;
            if (macos_fullscreen_header_needs_content_revision(@ptrCast(self.surface.layer)) != 0) {
                if (cx.window_header_node) |header| header_revision = nativeHeaderContentRevision(header);
            }
            macos_fullscreen_header_encode(@ptrCast(self.surface.layer), @ptrCast(surface_texture.texture.raw), @ptrCast(gpu_encoder.raw), header_revision);

            if (self.caret_background_capture) {
                self.caret_patch_ready = macos_caret_patch_encode(@ptrCast(self.surface.layer), @ptrCast(surface_texture.texture.raw), @ptrCast(gpu_encoder.raw), &cx.caret_rects, cx.caret_rect_count, scale) != 0;
            }
        }
        if (comptime gpu.is_direct3d) {
            if (self.lum_batch_cmd_buffer == null) {
                for (&self.persistent_gpu.luminance_slots) |*slot| {
                    if (!slot.cur_pending) continue;
                    if (slot.staging) |*staging| {
                        staging.prepareBgra8Readback(&gpu_encoder, slot.cur_w, slot.cur_h) catch {
                            slot.cur_pending = false;
                        };
                    }
                }
            }
        }
        var cmd_buffer = try gpu_encoder.finish();
        defer cmd_buffer.deinit();

        // Register GPU completion callback to release buffer slot.
        self.frame_sync.signalOnCompletion(&cmd_buffer);
        acquired_slot = false;

        // Read true GPU execution time from prior frame (GPUStartTime/GPUEndTime valid
        // only after command buffer completion; current frame just submitted, can't read yet).
        // In steady state prior frame already finished, so this is wait-free.
        self.queueGpuTiming(cmd_buffer.retained());
        if (self.prev_frame_cmd_buffer) |*prev| self.consumePreviousDebugGlass(prev.isCompleted());
        self.advanceDebugGlassSlots();
        // Keep the latest submitted fence until it completes. A completed
        // owner is retired before acquisition; an unfinished owner survives even
        // if this attempt fails before submit.
        // Frame wrote brightness staging & no in-flight batch: this frame starts new batch,
        // lock staging before read completes.
        if (self.lum_batch_cmd_buffer == null) {
            for (self.persistent_gpu.luminance_slots) |slot| if (slot.cur_pending) {
                self.lum_batch_cmd_buffer = cmd_buffer.retained();
                self.persistent_gpu.luminance_locked = true;
                break;
            };
        }

        if (comptime gpu.backend_kind == .metal) {
            if (clock_trace_enabled) metal_glass_clock_trace_frame(
                @ptrCast(cmd_buffer.raw),
                @ptrCast(surface_texture.drawable),
                self.frame_count + 1,
                clock_sample_host_time,
                clock_sample_frame_time_ms,
                clock_sample_frame_dt_ms,
            );
        }
        surface_texture.preparePresent(&cmd_buffer);
        if (comptime gpu.is_direct3d) {
            try cmd_buffer.submitChecked();
            if (prefix_len > 0 and gpu.Backend.CommandBuffer.error_count.load(.monotonic) == frame_error_start) {
                self.background_damage.commit();
                self.background_valid = true;
                if (reuse_background) self.background_reuse_count += 1;
                if (background_update != null) self.background_partial_count += 1;
            } else if (prefix_len > 0) {
                self.background_damage.invalidate();
                self.background_valid = false;
            }
            if (frame_copy_ok and frame_cache_enabled and gpu.Backend.CommandBuffer.error_count.load(.monotonic) == frame_error_start) {
                self.frame_damage.commit();
                if (damage) |rect| {
                    if (rect[2] == 0 or rect[3] == 0) self.frame_reuse_count += 1 else self.frame_partial_count += 1;
                }
            } else self.frame_damage.invalidate();
        } else cmd_buffer.submit();
        if (self.prev_frame_cmd_buffer) |*previous| previous.deinit();
        self.prev_frame_cmd_buffer = cmd_buffer.retained();
        self.pool_maintenance_retry.reset();
        submitted = true;

        // E2E screenshot: read drawable pixels before present. Must wait for GPU render
        // to complete before getBytes.
        if (self.pending_screenshot_path != null) {
            cmd_buffer.waitUntilCompleted();
            self.last_screenshot_ok = self.captureSurfaceToPng(
                &surface_texture.texture,
                surface_texture.texture.size.width,
                surface_texture.texture.size.height,
            );
            self.pending_screenshot_path = null;
            self.pending_screenshot_len = 0;
        }

        if (self.recording_active) {
            if (self.recording_context_fn) |record_frame| {
                // The Windows callback submits its readback to this same queue;
                // it polls completion on a later frame and never waits here.
                if (!record_frame(self.recording_context, &surface_texture.texture)) self.recording_active = false;
            } else if (self.recording_frame_fn) |record_frame| {
                // The encoder uses a separate Metal queue. Waiting establishes
                // an explicit cross-queue ownership boundary for this drawable.
                cmd_buffer.waitUntilCompleted();
                if (!record_frame(&surface_texture.texture)) self.recording_active = false;
            }
        }

        surface_texture.presentAfterSubmit(&cmd_buffer);
        self.last_frame_presented = true;

        var engine_counts: [3]u32 = .{ 0, 0, 0 };
        if (comptime gpu.backend_kind == .metal and engine_diagnostics_enabled)
            metal_command_buffer_engine_counts(@ptrCast(cmd_buffer.raw), &engine_counts);
        // Collect frame performance statistics.
        const frame_end = @import("zenit_time").Instant.now(cx.io) catch null;
        // FrameStats declared wait/acquire/cpu fields but never assigned (review report §4);
        // three timerDelta results discarded via `_ =`, so gpu_encode_us mixed wait + acquire
        // + CPU encode + submit. Split here for accurate attribution.
        const encode_us = timerDelta(encode_start, encode_end);
        const flush_us = timerDelta(flush_start, flush_end);
        const wait_us = timerDelta(wait_start, wait_end);
        const acquire_us = timerDelta(acquire_start, acquire_end);
        const total_us = timerDelta(frame_start, frame_end);
        const layout_us = timerDelta(layout_start, layout_end);
        const render_gen_us = timerDelta(render_start, render_end);
        const icon_total = render.iconDrawCallsTotal();
        const icon_draws: u32 = @intCast(icon_total -| self.prev_icon_draw_calls_total);
        self.prev_icon_draw_calls_total = icon_total;
        const image_total = render.imageDrawCallsTotal();
        const image_draws: u32 = @intCast(image_total -| self.prev_image_draw_calls_total);
        self.prev_image_draw_calls_total = image_total;
        const image_inst_total = render.imageInstancesTotal();
        const image_insts: u32 = @intCast(image_inst_total -| self.prev_image_instances_total);
        self.prev_image_instances_total = image_inst_total;
        const bind_total = render.imageTextureBindsTotal();
        const tex_binds: u32 = @intCast(bind_total -| self.prev_texture_binds_total);
        self.prev_texture_binds_total = bind_total;
        const sdf_total = render.sdfDrawCallsTotal();
        const sdf_draws: u32 = @intCast(sdf_total -| self.prev_sdf_draw_calls_total);
        self.prev_sdf_draw_calls_total = sdf_total;
        const text_total = render.textDrawCallsTotal();
        const text_draws: u32 = @intCast(text_total -| self.prev_text_draw_calls_total);
        self.prev_text_draw_calls_total = text_total;
        const path_draws: u32 = if (self.persistent_gpu.path_renderer) |*pr| pr.frame_draw_count else 0;
        self.last_frame_stats = .{
            .layout_us = layout_us,
            .render_gen_us = render_gen_us,
            // Note: still CPU-side encode+submit wall-clock, not GPU execution time.
            // True GPU time needs command buffer timestamp/counter (pending, review §4).
            .gpu_encode_us = timerDelta(render_end, frame_end),
            .wait_for_frame_us = wait_us,
            .acquire_texture_us = acquire_us,
            // Pure CPU pipeline: total minus blocking waits and drawable acquisition.
            .cpu_frame_us = total_us -| wait_us -| acquire_us,
            .gpu_execute_us = gpu_execute_us,
            .encode_us = encode_us,
            .flush_us = flush_us,
            .glass_count = render.backdrop_blur.perf.glass_count,
            .glass_us = render.backdrop_blur.perf.glass_ns / std.time.ns_per_us,
            .texture_creates = render.offscreen_texture.perf_texture_creates,
            .render_passes = if (comptime gpu.backend_kind == .metal) engine_counts[0] else if (comptime @hasDecl(gpu.Backend.CommandEncoder, "perf_counters")) gpu.Backend.CommandEncoder.perf_counters.render_passes else 0,
            .blit_passes = if (comptime gpu.backend_kind == .metal) engine_counts[1] else if (comptime @hasDecl(gpu.Backend.CommandEncoder, "perf_counters")) gpu.Backend.CommandEncoder.perf_counters.blit_passes else 0,
            .compute_passes = engine_counts[2],
            .pass_native_us = if (comptime @hasDecl(gpu.Backend.CommandEncoder, "perf_counters")) gpu.Backend.CommandEncoder.perf_counters.native_ns / std.time.ns_per_us else 0,
            .path_draw_calls = path_draws,
            .retained_hits = enc.retained_hits,
            .retained_misses = enc.retained_misses,
            .retained_partial_repaints = enc.retained_partial_repaints,
            .icon_draw_calls = icon_draws,
            .image_draw_calls = image_draws,
            .image_instances = image_insts,
            .texture_binds = tex_binds,
            .sdf_draw_calls = sdf_draws,
            .text_draw_calls = text_draws,
            .draw_calls = path_draws + icon_draws + image_draws + sdf_draws + text_draws,
            .sdf_instances = @intCast(pending_sdf_instances),
            .text_instances = @intCast(pending_text_instances),
            .command_count = @intCast(cx.lowerForEncoderPaintTable().len),
            .total_frame_us = total_us,
        };
        render.backdrop_blur.perf = .{};
        render.offscreen_texture.perf_texture_creates = 0;
        if (comptime @hasDecl(gpu.Backend.CommandEncoder, "perf_counters")) gpu.Backend.CommandEncoder.perf_counters = .{};

        // DevTools (Cx side) frame perf backfill. Performance panel reads frame_*_history /
        // perf.layout_us / perf.render_us from target Cx; chain broke when extracted from
        // downstream editor. Write after cx.render(): perf.resetFrame() clears at render start, so
        // values here survive to next frame for DevTools to read across Cx.
        cx.frame_perf.acquire.push(acquire_us);
        cx.perf.layout_us = layout_us;
        cx.perf.render_us = render_gen_us;
        if (frame_start) |fs| {
            if (self.prev_frame_start) |prev| {
                const raw_interval_us = fs.since(prev) / std.time.ns_per_us;
                const display_period_us: u64 = @intFromFloat(1_000_000.0 / @as(f64, @floatCast(@max(1.0, cx.display_refresh_hz))));
                if (@import("timing_ring.zig").frameIntervalSampleUs(raw_interval_us, display_period_us)) |sample| {
                    cx.frame_perf.pushFrameIntervalUs(sample);
                }
            }
            self.prev_frame_start = fs;
        }

        if (comptime @hasField(@TypeOf(cx.*), "glass_encoded_owners")) {
            const n = @min(enc.blur_applied_count, cx.glass_encoded_owners.len);
            // A glass drawn for the first time gets one more frame: its first-frame family probe
            // only runs once it sees the glass encoded (it does not hold frames before that).
            const newly_drawn = for (enc.blur_applied_owners[0..n]) |id| {
                if (std.mem.indexOfScalar(u32, cx.glass_encoded_owners[0..cx.glass_encoded_count], id) == null) break true;
            } else false;
            @memcpy(cx.glass_encoded_owners[0..n], enc.blur_applied_owners[0..n]);
            cx.glass_encoded_count = n;
            if (newly_drawn) cx.needs_redraw = true;
        }
        self.total_retained_hits += enc.retained_hits;
        self.total_retained_misses += enc.retained_misses;
        self.total_retained_partial_repaints += enc.retained_partial_repaints;
        self.frame_count += 1;
        // Idle skips and failed frames do not dilute the timing history.
        measured_frame = true;
    }

    /// Release completed command references before DXGI recreates back buffers.
    /// Waiting alone leaves the retained statistics/readback command alive.
    pub fn prepareSurfaceResize(self: *AppRenderer, cx: anytype) void {
        self.frame_sync.drain(FRAME_BUFFER_COUNT);
        _ = self.refreshLuminance(cx);
        // After drain, brightness batch consumed; explicit release if still retained:
        // D3D12 retained commands hold resource references until deinit, blocking ResizeBuffers.
        if (self.lum_batch_cmd_buffer) |*batch| {
            batch.deinit();
            self.lum_batch_cmd_buffer = null;
            self.persistent_gpu.luminance_locked = false;
        }
        if (self.prev_frame_cmd_buffer) |*previous| {
            previous.deinit();
            self.prev_frame_cmd_buffer = null;
        }
        self.dropGpuTimings();
    }

    /// Windows host idle-poll/pre-resize drain: luminance read unified via
    /// pollBackdropLuminance; returns whether measurement changed.
    pub fn refreshLuminance(self: *AppRenderer, cx: anytype) bool {
        if (comptime gpu.is_direct3d) {
            // The Windows host polls here even when no new frame is drawn.
            // Completed commands retain upload buffers, descriptor heaps and
            // textures through three independent owners. Retire all three;
            // preserve in-flight fences and harvest timing before dropping it.
            // Keep device-loss recovery with the host's existing frame/teardown
            // path; idle maintenance never waits or hides a render failure.
            self.frame_sync.collectChecked() catch return false;
            const latest_us = self.harvestGpuTimings();
            if (latest_us != 0) self.idle_gpu_execute_us = latest_us;
            self.retireCompletedPresentation();
        }
        return self.pollBackdropLuminance(cx);
    }

    /// Get last frame perf stats. Backdrop brightness adaptation: read shared staging (BGRA8 sRGB
    /// bytes) compute average linear luminance. Returns null on failure (retain old value). Consume
    /// completed staging copies even while window is idle. Reading before encoding another frame
    /// also avoids racing the next staging write. Changed measurement requests one frame; unchanged
    /// values permit idle.
    pub fn nextOffscreenMaintenanceDelayNs(self: *const AppRenderer) ?u64 {
        if (self.has_external_encoder) return null;
        const now: u64 = @intCast(@max(0, @import("zenit_time").monotonicTimestamp(self.io)));
        const retry = self.pool_maintenance_retry.delay(now) orelse return null;
        const delay = self.offscreen_pool.nextMaintenanceDelayNs(now) orelse return null;
        // An expired deadline with an in-flight fence gets a bounded retry,
        // not a busy-loop or a synchronous GPU wait.
        return @max(delay, retry, std.time.ns_per_ms * 5);
    }

    fn maintainOffscreenPool(self: *AppRenderer) void {
        if (self.has_external_encoder) return;
        const now: u64 = @intCast(@max(0, @import("zenit_time").monotonicTimestamp(self.io)));
        if ((self.pool_maintenance_retry.delay(now) orelse return) != 0) return;
        const delay = self.offscreen_pool.nextMaintenanceDelayNs(now) orelse return;
        if (delay != 0) return;
        if (self.prev_frame_cmd_buffer) |*last| {
            if (comptime gpu.is_direct3d) {
                last.waitChecked(0) catch |err| {
                    if (err == error.DeviceLost) {
                        // Removed devices will never advance this fence.
                        self.pool_maintenance_retry.stopped = true;
                    } else self.pool_maintenance_retry.pending(now);
                    return;
                };
            } else if (!last.isCompleted()) {
                self.pool_maintenance_retry.pending(now);
                return;
            }
        }
        self.offscreen_pool.maintain(now, true);
        self.pool_maintenance_retry.reset();
    }

    pub fn pollBackdropLuminance(self: *AppRenderer, cx: anytype) bool {
        self.maintainOffscreenPool();
        comptime {
            const Slot = @TypeOf(self.persistent_gpu.luminance_slots[0]);
            const per_slot = 1 + @typeInfo(@FieldType(Slot, "shape_keys")).array.len;
            if (@typeInfo(@TypeOf(cx.backdrop_luminance_regions)).array.len < self.persistent_gpu.luminance_slots.len * per_slot)
                @compileError("Cx.backdrop_luminance_regions 装不下全部亮度槽的读数");
        }
        var changed = false;
        // Readings arrive with the batch; the published region set is
        // recomputed on every poll because it also changes without a batch:
        // a hidden glass writes no staging but must leave the list.
        if (self.lum_batch_cmd_buffer) |*batch| if (batch.isCompleted()) {
            batch.deinit();
            self.lum_batch_cmd_buffer = null;
            self.persistent_gpu.luminance_locked = false;
            for (&self.persistent_gpu.luminance_slots) |*slot| {
                if (!slot.cur_pending) continue;
                if (slot.staging) |*staging| {
                    var buf: [64 * 64 * 4]u8 = undefined;
                    if (readCompletedLuminanceBytes(staging, slot.cur_w, slot.cur_h, &buf)) {
                        const wf: f32 = @floatFromInt(slot.cur_w);
                        const hf: f32 = @floatFromInt(slot.cur_h);
                        // The staging holds the whole padded capture: measure
                        // only the glass's own rect (content_uv), as each
                        // GlassGroup shape does below.
                        const cu = slot.content_uv;
                        const cx0: u32 = @intFromFloat(@floor(std.math.clamp(cu[0] * wf, 0, wf - 1)));
                        const cy0: u32 = @intFromFloat(@floor(std.math.clamp(cu[1] * hf, 0, hf - 1)));
                        const cx1: u32 = @max(cx0 + 1, @as(u32, @intFromFloat(@ceil(std.math.clamp((cu[0] + cu[2]) * wf, 0, wf)))));
                        const cy1: u32 = @max(cy0 + 1, @as(u32, @intFromFloat(@ceil(std.math.clamp((cu[1] + cu[3]) * hf, 0, hf)))));
                        const value = averageLuminanceIn(&buf, slot.cur_w, cx0, cy0, cx1, cy1);
                        if (slot.value == null or @abs(value.linear - slot.value.?) > 0.004) changed = true;
                        slot.value = value.linear;
                        slot.value_srgb = value.srgb;
                        // GlassGroup: each member shape averages its sub-rect within one staging
                        // texture.
                        slot.shape_value_count = slot.shape_count;
                        for (0..slot.shape_count) |i| {
                            const uv = slot.shape_uv[i];
                            const x0: u32 = @intFromFloat(@floor(std.math.clamp(uv[0] * wf, 0, wf - 1)));
                            const y0: u32 = @intFromFloat(@floor(std.math.clamp(uv[1] * hf, 0, hf - 1)));
                            const x1: u32 = @max(x0 + 1, @as(u32, @intFromFloat(@ceil(std.math.clamp(uv[2] * wf, 0, wf)))));
                            const y1: u32 = @max(y0 + 1, @as(u32, @intFromFloat(@ceil(std.math.clamp(uv[3] * hf, 0, hf)))));
                            const sv = averageLuminanceIn(&buf, slot.cur_w, x0, y0, x1, y1);
                            if (@abs(sv.linear - slot.shape_value[i]) > 0.004) changed = true;
                            slot.shape_value[i] = sv.linear;
                            slot.shape_value_srgb[i] = sv.srgb;
                        }
                    }
                }
                slot.cur_pending = false;
            }
        };
        var sum: f64 = 0;
        var count: usize = 0;
        for (self.persistent_gpu.luminance_slots) |slot| {
            if (!self.luminanceSlotLive(slot)) continue;
            if (slot.value) |value| {
                sum += value;
                count += 1;
            }
        }
        if (count > 0) self.backdrop_luminance = @floatCast(sum / @as(f64, @floatFromInt(count)));
        cx.backdrop_luminance = self.backdrop_luminance;
        // A changed region set (a slot reused by another owner, with a reading
        // within the 0.004 band of the old one) must also wake the consumers.
        const previous_count = cx.backdrop_luminance_region_count;
        var previous_ids: [cx.backdrop_luminance_regions.len]u32 = undefined;
        for (0..previous_count) |i| previous_ids[i] = cx.backdrop_luminance_regions[i].node_id;
        cx.backdrop_luminance_region_count = 0;
        for (self.persistent_gpu.luminance_slots) |slot| {
            if (!self.luminanceSlotLive(slot)) continue;
            if (slot.value) |value| {
                if (slot.key != std.math.maxInt(u32) and cx.backdrop_luminance_region_count < cx.backdrop_luminance_regions.len) {
                    cx.backdrop_luminance_regions[cx.backdrop_luminance_region_count] = .{ .node_id = slot.key, .lum = value, .lum_srgb = slot.value_srgb orelse value };
                    cx.backdrop_luminance_region_count += 1;
                }
                for (0..slot.shape_value_count) |i| {
                    if (cx.backdrop_luminance_region_count >= cx.backdrop_luminance_regions.len) break;
                    if (slot.shape_keys[i] == std.math.maxInt(u32)) continue;
                    cx.backdrop_luminance_regions[cx.backdrop_luminance_region_count] = .{ .node_id = slot.shape_keys[i], .lum = slot.shape_value[i], .lum_srgb = slot.shape_value_srgb[i] };
                    cx.backdrop_luminance_region_count += 1;
                }
            }
        }
        if (cx.backdrop_luminance_region_count != previous_count) changed = true;
        for (0..@min(cx.backdrop_luminance_region_count, previous_count)) |i| {
            if (cx.backdrop_luminance_regions[i].node_id != previous_ids[i]) changed = true;
        }
        if (changed) cx.needs_redraw = true;
        return changed;
    }

    /// Slots with an owner publish a region; `scanPaintTable` retires the
    /// owners absent from the frame's paint table, so a hidden glass leaves
    /// the published set on the next poll.
    fn luminanceSlotLive(self: *const AppRenderer, slot: anytype) bool {
        _ = self;
        return slot.key != std.math.maxInt(u32);
    }

    /// One pass over this frame's lowered paint table for the two signals
    /// only the full table carries. "Encoded this frame" is not one: the
    /// encoder reuses a flat prefix and replays cached layers, so an
    /// unchanged visible glass is never re-encoded.
    /// - Glass owners present in the table keep their luminance slot; the
    ///   others retire (a hidden or unmounted glass must leave the published
    ///   region set, as the legacy painter did). Readings arrive on the next
    ///   poll, which sees the smaller set and wakes the consumers.
    /// - Film grain is reseeded per encoded frame (paint fingerprint carries
    ///   the frame salt, so damage and retained layers repaint it), but the
    ///   grain itself has no hook to ask for frames: a visible grain asks
    ///   here. Basic quality draws no noise and stays idle.
    fn scanPaintTable(self: *AppRenderer, cx: anytype) void {
        const none = std.math.maxInt(u32);
        var seen = @as([self.persistent_gpu.luminance_slots.len]bool, @splat(false));
        var any_owner = false;
        for (self.persistent_gpu.luminance_slots) |slot| any_owner = any_owner or slot.key != none;
        var grain = false;
        for (cx.lowerForEncoderPaintTable()) |it| {
            if (any_owner and it.kind == .control and it.control_kind == .begin_blur_layer and it.glass_owner_id != none) {
                for (self.persistent_gpu.luminance_slots, 0..) |slot, i| {
                    if (slot.key == it.glass_owner_id) seen[i] = true;
                }
            }
            if (it.noise_mode == 2 and it.noise_intensity > 0) grain = true;
        }
        var retired = false;
        for (&self.persistent_gpu.luminance_slots, seen) |*slot, live| {
            if (slot.key == none or live) continue;
            slot.key = none;
            slot.value = null;
            slot.value_srgb = null;
            slot.shape_count = 0;
            slot.shape_value_count = 0;
            // An in-flight readback of the retired owner is dropped: reading
            // it into a dead slot would only raise a spurious `changed`.
            slot.cur_pending = false;
            slot.prev_pending = false;
            retired = true;
        }
        if (retired or (grain and self.visual_quality != .basic)) cx.needs_redraw = true;
    }

    fn diagnosticInFlight(self: *AppRenderer) u32 {
        var count: u32 = 0;
        for (self.gpu_timing_pending) |maybe| if (maybe) |command| {
            if (!command.isCompleted()) count += 1;
        };
        return count;
    }

    pub fn diagnosticClock() f64 {
        if (comptime gpu.backend_kind != .metal) return 0;
        return metal_glass_clock_trace_host_time();
    }

    pub fn traceCaretBoundary(self: *AppRenderer, kind: []const u8, input_epoch: u64) void {
        if (comptime gpu.backend_kind != .metal) return;
        if (!metal_glass_clock_trace_enabled()) return;
        const now = metal_glass_clock_trace_host_time();
        if (std.mem.eql(u8, kind, "caret-exit")) {
            self.caret_diag_exit_seq += 1;
            self.caret_diag_exit_host_time = now;
        }
        var line: [512]u8 = undefined;
        const encoded = std.fmt.bufPrint(&line, "{{\"kind\":\"{s}\",\"host_time\":{d:.9},\"frame\":{d},\"input_epoch\":{d},\"exit_seq\":{d},\"in_flight\":{d}}}", .{
            kind, now, self.frame_count, input_epoch, self.caret_diag_exit_seq, self.diagnosticInFlight(),
        }) catch unreachable;
        metal_glass_clock_trace_line(encoded.ptr, encoded.len);
    }

    /// A completed command still owns its presented drawable. Keeping that
    /// observer through nextDrawable needlessly expands the layer's pool after
    /// caret handoff. In-flight work must retain its fence across aborted frames.
    fn retireCompletedPresentation(self: *AppRenderer) void {
        // Test-mode causal control reproduces the pre-24af6563 ownership path.
        // It is accepted only together with opt-in clock diagnostics.
        if (comptime frame_testing_enabled and gpu.backend_kind == .metal) {
            if (metal_glass_clock_trace_enabled() and (if (@import("zenit_environment").getBorrowed("ZENIT_CARET_DIAG_RETAIN_COMPLETED")) |value| std.mem.eql(u8, value, "1") else false)) return;
        }

        if (self.prev_frame_cmd_buffer) |*previous| {
            if (!previous.isCompleted()) return;
            self.consumePreviousDebugGlass(true);
            previous.deinit();
            self.prev_frame_cmd_buffer = null;
        }
    }

    fn consumePreviousDebugGlass(self: *AppRenderer, completed: bool) void {
        if (!completed or !@import("zenit_environment").has("ZENIT_DEBUG_GLASS")) return;
        for (&self.persistent_gpu.debug_glass_slots, 0..) |*slot, si| {
            if (!slot.prev_pending) continue;
            if (slot.staging) |*staging| {
                if (readAverageRgb(staging, slot.prev_w, slot.prev_h)) |rgb| {
                    const stage_name = switch (si) {
                        0 => "capture",
                        1 => "composite",
                        else => "endrt",
                    };
                    std.debug.print("[glassdbg] stage={s} rgb=({d:.1},{d:.1},{d:.1})\n", .{ stage_name, rgb[0], rgb[1], rgb[2] });
                }
            }
            slot.prev_pending = false;
        }
    }

    fn advanceDebugGlassSlots(self: *AppRenderer) void {
        if (!@import("zenit_environment").has("ZENIT_DEBUG_GLASS")) return;
        for (&self.persistent_gpu.debug_glass_slots) |*slot| {
            slot.prev_pending = slot.cur_pending;
            slot.prev_w = slot.cur_w;
            slot.prev_h = slot.cur_h;
            slot.cur_pending = false;
        }
    }

    /// Records the GPU time of every pending frame that has completed, in
    /// submission order (stops at the first one still running). Returns the
    /// newest recorded interval, 0 when none completed since the last call.
    fn harvestGpuTimings(self: *AppRenderer) u64 {
        var latest: u64 = 0;
        while (self.gpu_timing_pending[0]) |*oldest| {
            if (!oldest.isCompleted()) break;
            if (comptime @hasDecl(gpu.Backend.CommandBuffer, "gpuTimingResult")) {
                switch (oldest.gpuTimingResult()) {
                    .pending => break,
                    .disjoint => self.gpu_timing_disjoint_samples += 1,
                    .failed => self.gpu_timing_failed_samples += 1,
                    .elapsed => |elapsed| {
                        latest = elapsed;
                        self.gpu_timing_ring.push(.{ .gpu_execute_us = elapsed });
                    },
                }
            } else if (oldest.gpuElapsedMicros()) |elapsed| {
                latest = elapsed;
                self.gpu_timing_ring.push(.{ .gpu_execute_us = elapsed });
            }
            oldest.deinit();
            std.mem.copyForwards(?gpu.Backend.CommandBuffer, self.gpu_timing_pending[0 .. self.gpu_timing_pending.len - 1], self.gpu_timing_pending[1..]);
            self.gpu_timing_pending[self.gpu_timing_pending.len - 1] = null;
        }
        return latest;
    }

    /// Appends a retained submitted frame; when full the oldest is released
    /// unread (its sample is lost, never waited for).
    fn queueGpuTiming(self: *AppRenderer, cmd: gpu.Backend.CommandBuffer) void {
        const slots = &self.gpu_timing_pending;
        if (slots[slots.len - 1] != null) {
            slots[0].?.deinit();
            std.mem.copyForwards(?gpu.Backend.CommandBuffer, slots[0 .. slots.len - 1], slots[1..]);
            slots[slots.len - 1] = null;
        }
        for (slots) |*slot| if (slot.* == null) {
            slot.* = cmd;
            return;
        };
    }

    /// Releases pending timing references (they hold back buffers that block
    /// ResizeBuffers, and must go before teardown).
    fn dropGpuTimings(self: *AppRenderer) void {
        for (&self.gpu_timing_pending) |*slot| if (slot.*) |*cmd| {
            cmd.deinit();
            slot.* = null;
        };
    }

    pub fn hasPendingBackdropLuminance(self: *const AppRenderer) bool {
        for (self.persistent_gpu.luminance_slots) |slot| {
            if (slot.cur_pending) return true;
        }
        return false;
    }

    const AverageLuminance = struct { linear: f32, srgb: f32 };
    fn readCompletedLuminanceBytes(staging: *gpu.Backend.Texture, w: u32, h: u32, buf: *[64 * 64 * 4]u8) bool {
        if (comptime gpu.is_direct3d) {
            if (w == 0 or h == 0 or w > 64 or h > 64) return false;
            staging.readPreparedBgra8(w, h, buf, w * 4) catch return false;
            return true;
        } else return readLuminanceBytes(staging, w, h, buf);
    }

    fn readLuminanceBytes(staging: *const gpu.Backend.Texture, w: u32, h: u32, buf: *[64 * 64 * 4]u8) bool {
        if (w == 0 or h == 0 or w > 64 or h > 64) return false;
        const bpr = w * 4;
        staging.readBgra8(w, h, buf, bpr) catch return false;
        if (@import("zenit_environment").has("ZENIT_DEBUG_GLASS")) {
            std.debug.print("[lum] read {d}x{d} px0=({d},{d},{d},{d}) pxmid=({d},{d},{d},{d})\n", .{ w, h, buf[0], buf[1], buf[2], buf[3], buf[(w * h / 2) * 4], buf[(w * h / 2) * 4 + 1], buf[(w * h / 2) * 4 + 2], buf[(w * h / 2) * 4 + 3] });
        }
        return true;
    }

    /// Sub-rect [x0,x1)x[y0,y1) average luminance: linear light + sRGB domain.
    fn averageLuminanceIn(buf: *const [64 * 64 * 4]u8, w: u32, x0: u32, y0: u32, x1: u32, y1: u32) AverageLuminance {
        var sum: f64 = 0;
        var sum_srgb: f64 = 0;
        var n: usize = 0;
        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const i = (@as(usize, y) * @as(usize, w) + @as(usize, x)) * 4;
                const b = srgbByteToLinear(buf[i + 0]);
                const g = srgbByteToLinear(buf[i + 1]);
                const r = srgbByteToLinear(buf[i + 2]);
                sum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
                // Encoded-domain mean: the native family switch thresholds were
                // measured as sRGB means (black/white coverage cases diverge
                // strongly between linear and encoded means).
                sum_srgb += (0.2126 * @as(f64, @floatFromInt(buf[i + 2])) + 0.7152 * @as(f64, @floatFromInt(buf[i + 1])) + 0.0722 * @as(f64, @floatFromInt(buf[i + 0]))) / 255.0;
                n += 1;
            }
        }
        const nf = @as(f64, @floatFromInt(@max(n, 1)));
        return .{ .linear = @floatCast(sum / nf), .srgb = @floatCast(sum_srgb / nf) };
    }

    /// Diagnostics: staging raw sRGB byte average (BGRA -> return [r,g,b], 0..255),
    /// same dimension as screenshot PNG average for direct comparison.
    fn readAverageRgb(staging: *const gpu.Backend.Texture, w: u32, h: u32) ?[3]f64 {
        if (w == 0 or h == 0 or w > 64 or h > 64) return null;
        var buf: [64 * 64 * 4]u8 = undefined;
        const bpr = w * 4;
        staging.readBgra8(w, h, &buf, bpr) catch return null;
        var rs: f64 = 0;
        var gs: f64 = 0;
        var bs: f64 = 0;
        var i: usize = 0;
        const n = @as(usize, w) * @as(usize, h);
        while (i < n) : (i += 1) {
            bs += @floatFromInt(buf[i * 4 + 0]);
            gs += @floatFromInt(buf[i * 4 + 1]);
            rs += @floatFromInt(buf[i * 4 + 2]);
        }
        const nf = @as(f64, @floatFromInt(n));
        return .{ rs / nf, gs / nf, bs / nf };
    }

    fn srgbByteToLinear(c: u8) f64 {
        const v = @as(f64, @floatFromInt(c)) / 255.0;
        if (v <= 0.04045) return v / 12.92;
        return std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
    }

    pub fn getLastFrameStats(self: *const AppRenderer) FrameStats {
        return self.last_frame_stats;
    }

    /// Render one frame, manual control mode. No Cx use; accumulate render commands
    /// manually then submit. Returns encoder for external use.
    pub fn beginFrame(self: *AppRenderer, viewport_width: f32, viewport_height: f32, scale: f32) RenderCommandEncoder {
        var enc = self.getEncoder();
        enc.beginFrame(viewport_width, viewport_height, scale);
        return enc;
    }

    /// Destroy.
    pub fn deinit(self: *AppRenderer) void {
        self.clearCaretPreparation();
        self.frame_damage.deinit(self.allocator);
        self.background_damage.deinit(self.allocator);
        // Wait for all in-flight frames to complete, prevent GPU reading buffer during deinit.
        self.frame_sync.drain(FRAME_BUFFER_COUNT);
        if (self.background_tex) |*tex| tex.destroy();
        // Release last frame's command buffer (retained for GPU timestamp reads;
        // omitting here leaks the final frame).
        if (self.prev_frame_cmd_buffer) |*prev| {
            prev.deinit();
            self.prev_frame_cmd_buffer = null;
        }
        self.dropGpuTimings();
        if (self.lum_batch_cmd_buffer) |*batch| {
            batch.deinit();
            self.lum_batch_cmd_buffer = null;
        }
        // Pooled textures and persistent PSOs may be referenced by final frames'
        // command buffers; release after drain.
        self.offscreen_pool.deinit();
        self.persistent_gpu.deinit();
        // Test-harness mode present copy (retain_present_copy) of window size: previously
        // destroyed only on resize, leaked full BGRA texture on close (~20MB at 2880x1800).
        if (self.retained_tex) |*tex| tex.destroy();
        self.retained_tex = null;
        if (self.fonts) |fonts| {
            if (fonts.drawn_width_ctx == @as(*anyopaque, @ptrCast(&self.text_renderer))) {
                fonts.setDrawnWidthSource(null, null);
            }
        }
        self.text_renderer.deinit();
        self.icon_renderer.deinit();
        self.image_renderer.deinit();
        self.sdf_renderer.deinit();
        // Drain balanced slots; safe to release now (multi-window repeated open/close
        // no longer accumulates leaks).
        self.frame_sync.deinit();
    }
};

/// Calculate microsecond delta between two time points.
fn timerDelta(start: ?@import("zenit_time").Instant, end: ?@import("zenit_time").Instant) u64 {
    if (start) |s| {
        if (end) |e| {
            return e.since(s) / 1000; // ns → us
        }
    }
    return 0;
}
