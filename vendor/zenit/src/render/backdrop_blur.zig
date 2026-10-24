/// Backdrop blur subsystem, factored out from command_encoder.zig.
/// Contains Dual Kawase blur pipeline + Liquid Glass composite. All public entry points accept
/// `encoder: anytype` to avoid circular import with RenderCommandEncoder.
const std = @import("std");
const gpu = @import("gpu");
const TextureLease = @import("offscreen_texture.zig").TextureLease;
const debug_env = @import("debug_env.zig");

/// Warn once per resource on pass skip (avoid per-frame spam); always returns false for `orelse
/// return warnPassSkipped(...)`
fn warnPassSkipped(comptime what: []const u8) bool {
    const S = struct {
        var warned: bool = false;
    };
    if (!S.warned) {
        std.log.warn("[backdrop-blur] " ++ what ++ " unavailable; pass skipped (degraded output)", .{});
        S.warned = true;
    }
    return false;
}

const blur_shader_source: []const u8 = @import("shader_sources.zig").blur;
const glass_shader_source: []const u8 = @import("shader_sources.zig").glass;

/// Frames needed for blur chain raise hysteresis (inter-frame lag; see
/// PersistentGpuCache.blur_level_slots). Constraints on both ends:
/// - Floor: observed oscillation period is 3 frames; offscreen_texture.zig REUSE_LAG_FRAMES=3
///   (retained miss: draw->reject 2 frames). Must be >= 3 to span one period; N=1/2 still bump the
///   level during the reject phase and hysteresis is ineffective.
/// - Ceiling: N frames of visible delay for blur after the window grows / glass shrinks. At 60Hz
///   N=6 ~= 100ms reads as progressive quality recovery, not an artifact (level jumps = periodic
///   flicker). Larger values cause visible 'blurry-then-sharp' during window drag/resize.
/// 6 = 2 complete REUSE_LAG periods + 1x margin against phase alignment coincidence.
pub const BLUR_LEVEL_RAISE_FRAMES: u32 = 6;

/// Pure-value form of hysteresis state (1:1 with PersistentGpuCache.BlurLevelSlot fields).
/// Factored for unit-testable state machine; real path needs GPU pool.
pub const BlurLevelState = struct { committed: u32 = 0, streak: u32 = 0, backoff: u32 = 0 };

/// Max chain depth allowed this frame.
/// - committed == 0: no history (first frame / slot handoff) -> no limit, one-shot.
/// - streak reaches threshold -> allow one raise attempt (up to max_levels).
/// - else capped at last frame's actual commit (degrade is immediate, no fallback needed).
/// Raise attempt interval: baseline BLUR_LEVEL_RAISE_FRAMES, doubled on each failure (max 8x ~=
/// 48 frames / 0.8s). Without backoff, hard saturation turns 'flicker every 3 frames' into
/// 'every N frames', still a visible periodic flicker.
pub fn levelCap(committed: u32, streak: u32, backoff: u32, max_levels: u32) u32 {
    if (committed == 0) return max_levels;
    const threshold = BLUR_LEVEL_RAISE_FRAMES *| (@as(u32, 1) << @intCast(@min(backoff, 3)));
    if (streak +| 1 >= threshold) return max_levels;
    return @min(max_levels, committed);
}

/// Advance hysteresis after frame end. cap = this frame's cap, actual = level produced.
pub fn levelSettle(prev: BlurLevelState, cap: u32, actual: u32, max_levels: u32) BlurLevelState {
    var next = prev;
    next.committed = actual;
    if (cap < max_levels) {
        // Capped by hysteresis: running to cap accumulates; under cap means pool can't provide
        // current level -> reset (continuity is hysteresis's entire point).
        next.streak = if (actual >= cap) prev.streak +| 1 else 0;
        return next;
    }
    // This frame cleared to max_levels: either a raise attempt or was never capped.
    next.streak = 0;
    if (prev.committed != 0 and prev.committed < max_levels) {
        next.backoff = if (actual > prev.committed) 0 else prev.backoff +| 1;
    } else if (actual >= max_levels) {
        next.backoff = 0;
    }
    return next;
}

pub const max_kawase_uniform_updates: u32 = 512;
// 512 x 128B = 64KB, one-time alloc. Old 128 too low: over-limit every glass composite in hot
// render path does createBuffer+destroy (driver alloc + page_allocator mmap).
pub const max_glass_uniform_updates: u32 = 512;
comptime {
    // Uniform via setFragmentBytes, Metal 4KiB spec limit.
    std.debug.assert(@sizeOf(KawaseUniforms) <= 4096);
    std.debug.assert(@sizeOf(GlassUniforms) <= 4096);
}

pub const KawaseUniforms = extern struct {
    texel_size: [2]f32,
    offset_scale: f32,
    _padding: f32 = 0,
    /// UV sub-rect {x0, y0, x1, y1} of 'real backdrop' within source texture. Default full=1 entire
    /// texture valid.
    /// Capture texture allocated in 64px buckets (pool reuse); actually blit copy_w x copy_h,
    /// right/bottom pad cleared to transparent-black never written.
    /// Without clamp Kawase blurs this black into valid per-level (radius 180 -> 6 levels, very far
    /// pollution), dims backdrop + gray fringe.
    /// Clamp to valid = clamp-to-edge extend on boundary, matches CSS backdrop-filter / Core Image
    /// semantics.
    valid_uv: [4]f32 = .{ 0, 0, 1, 1 },
};

pub const GaussianAreaUniforms = extern struct {
    source_size: [2]f32,
    output_size: [2]f32,
    input_gamma: f32 = 0,
    _padding: [3]f32 = .{ 0, 0, 0 },
};

/// A Gaussian is specified by its measured standard deviation, in source
/// pixels. Upload normalized weights once per pass; no exp() in the fragment.
pub const GaussianUniforms = extern struct {
    texel_size: [2]f32,
    direction: [2]f32,
    valid_uv: [4]f32,
    weights: [385]f32,
    radius: u32,
    _padding: [2]u32 = .{ 0, 0 },
};

/// Taps on each side of the center for a Gaussian of standard deviation sigma.
pub fn gaussianRadius(sigma: f32) u32 {
    return @min(384, @as(u32, @intFromFloat(@ceil(4.0 * @max(sigma, 0.01)))));
}

pub fn gaussianUniforms(sigma: f32, width: u32, height: u32, vertical: bool, valid: [4]f32) GaussianUniforms {
    const sd = @max(sigma, 0.01);
    const radius = gaussianRadius(sigma);
    var u = GaussianUniforms{
        .texel_size = .{ 1.0 / @as(f32, @floatFromInt(width)), 1.0 / @as(f32, @floatFromInt(height)) },
        .direction = if (vertical) .{ 0, 1 } else .{ 1, 0 },
        .valid_uv = valid,
        .weights = @splat(0),
        .radius = radius,
    };
    var sum: f32 = 0;
    for (0..radius + 1) |i| {
        const x: f32 = @floatFromInt(i);
        const weight = @exp(-x * x / (2.0 * sd * sd));
        u.weights[i] = weight;
        sum += weight * (if (i == 0) @as(f32, 1) else 2);
    }
    for (u.weights[0 .. radius + 1]) |*weight| weight.* /= sum;
    return u;
}

comptime {
    // Metal KawaseUniforms valid_uv must land on float4-aligned boundary (16B).
    if (@offsetOf(KawaseUniforms, "valid_uv") != 16) @compileError("KawaseUniforms.valid_uv must match Metal layout");
}

pub const GlassUniforms = extern struct {
    texel_size: [2]f32,
    corner_radius: f32,
    glass_intensity: f32,
    rect_size: [2]f32,
    scale_factor: f32,
    tint_mode: f32 = 0,
    glass_tint: [4]f32,
    specular_params: [4]f32 = .{ 0.35, 6.0, 1.0, 1.0 },
    /// {warp gain, logical thickness, logical backdrop distance, blur UV remap}.
    /// Remap is 1 when Kawase has stretched the valid capture region to fill
    /// its output; 0 when blur and sharp both refer to the original capture.
    optic_params: [4]f32 = .{ 1.0, 4.0, 0.0, 0.0 },
    surface_params: [4]f32 = .{ 2.0, 0.18, -std.math.pi / 3.0, 0.0 },
    bottom_surface_params: [4]f32 = .{ 0.0, 0.12, 1.0, 1.0 },
    lens_params: [4]f32 = .{ 0.58, 2.2, 1.0, 1.0 },
    /// Glass rect within padded capture texture UV sub-region (off_x, off_y, scale_x, scale_y)
    content_uv: [4]f32 = .{ 0, 0, 1, 1 },
    /// Blur gradient: {direction (0=off, 1=to_bottom, 2=to_top, 3=to_right, 4=to_left), unused,
    /// global intensity 0~1, stop count}
    edge_params: [4]f32 = .{ 0, 0, 0, 0 },
    /// Blur gradient stop positions (0~1 as % of node size along gradient axis, ascending,
    /// tail-padded)
    edge_stop_pos: [4]f32 = .{ 0, 1, 1, 1 },
    /// Blur gradient stop intensities (0~1)
    edge_stop_str: [4]f32 = .{ 1, 0, 0, 0 },
    /// 'Real backdrop' UV sub-rect {x0, y0, x1, y1} within capture texture. Pad beyond window RT is
    /// transparent-black; sampling must clamp to this region, else edge-glass rim samples pure
    /// black.
    valid_uv: [4]f32 = .{ 0, 0, 1, 1 },
    /// Native Liquid Glass lens {bevel width, bevel height, base thickness} (logical px) + edge
    /// blur blend; x=0 uses old surface model (see glass.metal native_glass).
    native_params: [4]f32 = .{ 0, 0, 0, 1 },
    /// {fine sigma, coarse sigma, fine weight, coarse weight}; sigma in logical px.
    native_blur: [4]f32 = .{ 0, 0, 0, 0 },
    /// Whole-window coarse backdrop UVs for this glass rectangle.
    coarse_uv: [4]f32 = .{ 0, 0, 1, 1 },
    native_blur_profile: [4]f32 = .{ 0, 0, 0, 0 },
    native_gamma: [4]f32 = .{ 0, 0, 0, 0 },
    native_rim: [4]f32 = .{ 0, 0, 0, 0 },
    native_chroma: [4]f32 = .{ 0, 0, 0, 0 },
    native_chroma_profile: [4]f32 = .{ 0, 0, 0, 0 },
    native_tint_response: [4]f32 = .{ 0, 0, 0, 0 },
    /// GlassGroup: x = shape count (0 = single rect path), y = merge distance (physical px, M3)
    group_params: [4]f32 = .{ 0, 0, 0, 0 },
    /// Per-shape: center xy, half-size xy (physical px, origin at glass rect center)
    shape_rect: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 0, 0, 0, 0 })),
    /// Per-shape: corner radius, bevel width, bevel height, base thickness (logical px)
    shape_lens: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 0, 0, 0, 0 })),
    shape_tint: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 0, 0, 0, 0 })),
    shape_rim: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 0, 0, 0, 0 })),
    shape_resp: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 0, 0, 0, 0 })),
    /// Per-shape: rim peak alpha, min edge (logical px), edge blur blend, tint_mode
    shape_misc: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 0, 0, 0, 0 })),
    /// Per-shape shadow: alpha, blur (logical px), offset x/y (logical px); drawn within glass pass
    /// per-union SDF
    shape_shadow: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 0, 0, 0, 0 })),
    /// Per-shape: materialize level (x), rest reserved
    shape_level: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 1, 0, 0, 0 })),
    /// Knob lens bicolor edge: dark-line color / alpha; bright-line {lift, dark-side dir xy, line
    /// width logical px} (w=0 off)
    knob_rim_dark: [4]f32 = .{ 0, 0, 0, 0 },
    knob_rim_light: [4]f32 = .{ 0, 0, 0, 0 },
    /// Accessibility: {mode 0 off / 1 reduce-transparency / 2 increase-contrast, untinted base hue,
    /// background luminance slope, preserve background hue}
    a11y_params: [4]f32 = .{ 0, 0, 0, 0 },
    /// Single-glass corner radii TL/TR/BR/BL (world logical px); x<0 = uniform corner_radius
    corner_radii: [4]f32 = .{ -1, -1, -1, -1 },
    /// Popover arrow (single glass): {edge 0 none / 1 bottom / 2 top / 3 left / 4 right, along-edge
    /// offset, protrude len, tip round} (world logical px)
    arrow_params: [4]f32 = .{ 0, 0, 0, 0 },
    /// Partial Glass.tint (`tintColor` alpha < 1): surface veil (sRGB 0-1) of the untinted share;
    /// alpha < 0 = none (the veil branch uses glass_tint). See ResolvedGlassParams.tint_mode.
    base_veil: [4]f32 = .{ 0, 0, 0, -1 },
    /// Veil transfer curve (single glass): 17 knots + enabled flag at [17] (ResolvedGlassParams).
    veil_curve: [5][4]f32 = @as([5][4]f32, @splat(.{ 0, 0, 0, 0 })),
    /// iOS tab lens displacement (ResolvedGlassParams.tab_lens; [0].x <= 0 = off)
    /// [2] = knob lens filter inputs {displacement amount, SDF height, inner refraction amount,
    /// inner refraction height} (pt)
    /// [3..5] = the knob's key highlight colour matrix rows {m1, m2, m3, offset} (vibrantColorMatrix)
    tab_lens_params: [6][4]f32 = @as([6][4]f32, @splat(.{ 0, 0, 0, 0 })),
};

comptime {
    if (@offsetOf(GlassUniforms, "glass_tint") != 32) @compileError("GlassUniforms.glass_tint must match Metal layout");
    if (@offsetOf(GlassUniforms, "specular_params") != 48) @compileError("GlassUniforms.specular_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "optic_params") != 64) @compileError("GlassUniforms.optic_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "surface_params") != 80) @compileError("GlassUniforms.surface_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "bottom_surface_params") != 96) @compileError("GlassUniforms.bottom_surface_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "lens_params") != 112) @compileError("GlassUniforms.lens_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "content_uv") != 128) @compileError("GlassUniforms.content_uv must match Metal layout");
    if (@offsetOf(GlassUniforms, "edge_params") != 144) @compileError("GlassUniforms.edge_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "edge_stop_pos") != 160) @compileError("GlassUniforms.edge_stop_pos must match Metal layout");
    if (@offsetOf(GlassUniforms, "edge_stop_str") != 176) @compileError("GlassUniforms.edge_stop_str must match Metal layout");
    if (@offsetOf(GlassUniforms, "valid_uv") != 192) @compileError("GlassUniforms.valid_uv must match Metal layout");
    if (@offsetOf(GlassUniforms, "native_params") != 208) @compileError("GlassUniforms.native_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "native_blur") != 224) @compileError("GlassUniforms.native_blur must match Metal layout");
    if (@offsetOf(GlassUniforms, "coarse_uv") != 240) @compileError("GlassUniforms.coarse_uv must match Metal layout");
    if (@offsetOf(GlassUniforms, "native_tint_response") != 336) @compileError("GlassUniforms.native_tint_response must match Metal layout");
    if (@offsetOf(GlassUniforms, "group_params") != 352) @compileError("GlassUniforms.group_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "shape_rect") != 368) @compileError("GlassUniforms.shape_rect must match Metal layout");
    if (@offsetOf(GlassUniforms, "shape_misc") != 1008) @compileError("GlassUniforms.shape_misc must match Metal layout");
    if (@offsetOf(GlassUniforms, "shape_shadow") != 1136) @compileError("GlassUniforms.shape_shadow must match Metal layout");
    if (@offsetOf(GlassUniforms, "shape_level") != 1264) @compileError("GlassUniforms.shape_level must match Metal layout");
    if (@offsetOf(GlassUniforms, "knob_rim_dark") != 1392) @compileError("GlassUniforms.knob_rim_dark must match Metal layout");
    if (@offsetOf(GlassUniforms, "a11y_params") != 1424) @compileError("GlassUniforms.a11y_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "corner_radii") != 1440) @compileError("GlassUniforms.corner_radii must match Metal layout");
    if (@offsetOf(GlassUniforms, "arrow_params") != 1456) @compileError("GlassUniforms.arrow_params must match Metal layout");
    if (@offsetOf(GlassUniforms, "base_veil") != 1472) @compileError("GlassUniforms.base_veil must match Metal layout");
    if (@offsetOf(GlassUniforms, "veil_curve") != 1488) @compileError("GlassUniforms.veil_curve must match Metal layout");
    if (@offsetOf(GlassUniforms, "tab_lens_params") != 1568) @compileError("GlassUniforms.tab_lens_params must match Metal layout");
    if (@sizeOf(GlassUniforms) != 1664) @compileError("GlassUniforms size must match Metal layout");
}

pub const KawasePassKind = enum { downsample, upsample };

pub var blur_pipeline_compile_count: u64 = 0;

pub fn ensureBlurPipeline(encoder: anytype) bool {
    // First-use cost (D3D12 compiles HLSL at runtime): report once so a slow
    // first glass frame can be attributed.
    const build_start = profileNow(encoder);
    const built_before = encoder.persistent.blur_downsample_pipeline != null and encoder.persistent.glass_pipeline != null;
    defer if (!built_before) if (build_start) |t0| if (profileNow(encoder)) |t1| {
        const ms = @as(f64, @floatFromInt(t1.since(t0))) / 1e6;
        if (ms >= 1) std.log.info("[glass] first-use pipeline build took {d:.1} ms (blur+glass HLSL compile + PSO)", .{ms});
    };
    // Sticky failure flag: try once only. Otherwise a persistent failure (Metal compiler exception
    // / source regression) would recompile the full source on every blur frame (tens of ms) and
    // spam the log.
    // Template same as opacity_layer.ensureDamageClearPipeline.
    if (encoder.persistent.blur_pipeline_failed) return false;
    if (encoder.persistent.blur_downsample_pipeline == null) {
        blur_pipeline_compile_count += 1;
        if (!buildBlurPipeline(encoder)) {
            encoder.persistent.blur_pipeline_failed = true;
            return false;
        }
    }
    // Glass has separate failure flag: after blur built, glass persistent failure can't re-compile
    // per frame.
    // Glass failure doesn't affect return; caller can fall back to pure blur+tint.
    if (encoder.persistent.glass_pipeline == null and !encoder.persistent.glass_pipeline_failed) {
        if (!buildGlassPipeline(encoder)) {
            encoder.persistent.glass_pipeline_failed = true;
            std.log.err("[glass] pipeline setup failed — glass 节点退化为纯 blur+tint（本消息只报一次）", .{});
        }
    }
    return true;
}

fn buildBlurPipeline(encoder: anytype) bool {
    const device = encoder.sdf_renderer.device;
    var shader = gpu.Backend.ShaderModule.initFromSource(device, blur_shader_source) catch |e| {
        std.log.err("[blur] shader compile failed: {} — backdrop blur 永久停用（本消息只报一次）", .{e});
        return false;
    };
    defer shader.deinit();

    var vertex_func = shader.getFunction("kawase_vertex_main") catch |e| {
        std.log.err("[blur] getFunction(kawase_vertex_main) failed: {}", .{e});
        return false;
    };
    defer vertex_func.deinit();
    var down_func = shader.getFunction("kawase_downsample") catch |e| {
        std.log.err("[blur] getFunction(kawase_downsample) failed: {}", .{e});
        return false;
    };
    defer down_func.deinit();
    var up_func = shader.getFunction("kawase_upsample") catch |e| {
        std.log.err("[blur] getFunction(kawase_upsample) failed: {}", .{e});
        return false;
    };
    defer up_func.deinit();

    encoder.persistent.blur_downsample_pipeline = gpu.Backend.createRenderPipeline(device, .{
        .vertex_function = &vertex_func,
        .fragment_function = &down_func,
        .color_attachment_formats = &[_]gpu.TextureFormat{gpu.color_format},
        .blend_state = null,
    }) catch |e| {
        std.log.err("[blur] downsample PSO failed: {}", .{e});
        return false;
    };

    encoder.persistent.blur_upsample_pipeline = gpu.Backend.createRenderPipeline(device, .{
        .vertex_function = &vertex_func,
        .fragment_function = &up_func,
        .color_attachment_formats = &[_]gpu.TextureFormat{gpu.color_format},
        .blend_state = null,
    }) catch |e| {
        std.log.err("[blur] upsample PSO failed: {}", .{e});
        return false;
    };

    encoder.persistent.blur_sampler = device.createSampler(std.heap.page_allocator, .{
        .label = "Zenit.Kawase.LinearSampler",
        .min_filter = .linear,
        .mag_filter = .linear,
    }) catch |e| {
        // Sampler failure affects more than blur: applyGlass depends on it; missing sampler makes
        // glass no-op (clear background visible).
        // Treat as full failure, don't leave half-broken state.
        std.log.err("[blur] sampler create failed: {}", .{e});
        return false;
    };
    // Native optics path (native_params) Gaussian pipeline.
    {
        var gaussian_func = shader.getFunction("gaussian_blur") catch |e| {
            std.log.err("[blur] getFunction(gaussian_blur) failed: {}", .{e});
            return false;
        };
        defer gaussian_func.deinit();
        var box_func = shader.getFunction("gaussian_downsample") catch |e| {
            std.log.err("[blur] getFunction(gaussian_downsample) failed: {}", .{e});
            return false;
        };
        defer box_func.deinit();
        encoder.persistent.gaussian_pipeline = gpu.Backend.createRenderPipeline(device, .{
            .vertex_function = &vertex_func,
            .fragment_function = &gaussian_func,
            .color_attachment_formats = &.{gpu.color_format},
            .blend_state = null,
        }) catch |e| {
            std.log.err("[blur] Gaussian PSO failed: {}", .{e});
            return false;
        };
        encoder.persistent.gaussian_downsample_pipeline = gpu.Backend.createRenderPipeline(device, .{
            .vertex_function = &vertex_func,
            .fragment_function = &box_func,
            .color_attachment_formats = &.{gpu.color_format},
            .blend_state = null,
        }) catch |e| {
            std.log.err("[blur] Gaussian downsample PSO failed: {}", .{e});
            return false;
        };
        inline for (.{ .{ "gaussian_filter_gamma", "gaussian_gamma_pipeline" }, .{ "gaussian_encode", "gaussian_encode_pipeline" }, .{ "gaussian_downsample_gamma", "gaussian_box_gamma_pipeline" } }) |spec| {
            var function = shader.getFunction(spec[0]) catch return false;
            defer function.deinit();
            @field(encoder.persistent, spec[1]) = gpu.Backend.createRenderPipeline(device, .{
                .vertex_function = &vertex_func,
                .fragment_function = &function,
                .color_attachment_formats = &.{.rgba16_float},
                .blend_state = null,
            }) catch |e| {
                std.log.err("[blur] {s} RGBA16 float PSO failed: {}", .{ spec[0], e });
                return false;
            };
        }
    }
    return true;
}

fn buildGlassPipeline(encoder: anytype) bool {
    const device = encoder.sdf_renderer.device;
    var glass_shader = gpu.Backend.ShaderModule.initFromSource(device, glass_shader_source) catch |e| {
        std.log.err("[glass] shader compile failed: {}", .{e});
        return false;
    };
    defer glass_shader.deinit();
    var glass_vtx = glass_shader.getFunction("glass_vertex_main") catch |e| {
        std.log.err("[glass] getFunction(glass_vertex_main) failed: {}", .{e});
        return false;
    };
    defer glass_vtx.deinit();
    var glass_frag = glass_shader.getFunction("glass_fragment_main") catch |e| {
        std.log.err("[glass] getFunction(glass_fragment_main) failed: {}", .{e});
        return false;
    };
    defer glass_frag.deinit();
    encoder.persistent.glass_pipeline = gpu.Backend.createRenderPipeline(device, .{
        .vertex_function = &glass_vtx,
        .fragment_function = &glass_frag,
        .color_attachment_formats = &[_]gpu.TextureFormat{gpu.color_format},
        .blend_state = null,
    }) catch |e| {
        std.log.err("[glass] PSO failed: {}", .{e});
        return false;
    };
    return true;
}

/// Allocate one Kawase uniform slot; null if exhausted.
/// Cannot wrap to reuse last: draw already encoded, later write overwrites previous pass uniform
/// (silent bad frame, garbled texel_size/valid_uv).
/// Caller gets null should terminate this blur chain (executeKawasePass returns false = that
/// semantic, both down/up chains break on false and output last completed level).
pub fn acquireKawaseUniformSlot(encoder: anytype) ?u32 {
    if (encoder.persistent.blur_uniform_write_offset >= max_kawase_uniform_updates) return null;
    const slot = encoder.persistent.blur_uniform_write_offset;
    encoder.persistent.blur_uniform_write_offset += 1;
    return slot;
}

pub fn acquireGlassUniformSlot(encoder: anytype) u32 {
    const slot = @min(encoder.persistent.glass_uniform_write_offset, max_glass_uniform_updates - 1);
    encoder.persistent.glass_uniform_write_offset += 1;
    return slot;
}

pub fn resetDynamicUniformOffsets(encoder: anytype) void {
    encoder.persistent.blur_uniform_write_offset = 0;
    encoder.persistent.glass_uniform_write_offset = 0;
    encoder.persistent.glass_uniform_overflow_warned = false;
}

/// Re-open render target after backdrop work temporarily switches command buffer through
/// render/blit passes.
/// Keeping in one helper is lifetime invariant: once old pass ends, every exit either installs
/// fresh pass or leaves render_pass==null.
/// Debug (ZENIT_DEBUG_GLASS): blit center 64x64 of some level into
/// persistent.debug_glass_slots[slot_idx] staging; renderer next frame reads and prints RGB mean.
/// Used to bisect scroll flicker fork (capture vs composite).
fn debugGlassBlit(
    encoder: anytype,
    src: gpu.Backend.TextureBinding,
    src_x: u32,
    src_y: u32,
    w: u32,
    h: u32,
    slot_idx: usize,
) void {
    if (!@import("zenit_environment").has("ZENIT_DEBUG_GLASS")) return;
    const slot = &encoder.persistent.debug_glass_slots[slot_idx];
    const dw = @min(w, 64);
    const dh = @min(h, 64);
    if (dw == 0 or dh == 0) return;
    if (slot.staging == null) {
        slot.staging = encoder.sdf_renderer.device.createTexture(std.heap.page_allocator, .{
            .label = "Zenit.GlassDebugStaging",
            .size = .{ .width = 64, .height = 64 },
            .format = gpu.color_format,
            .usage = .{ .copy_dst = true, .copy_src = true, .render_attachment = gpu.backend_kind == .metal },
            .memory = .host_upload,
        }) catch null;
    }
    if (slot.staging) |*staging| {
        const copied = blk: {
            encoder.copyTextureRegion(src, src_x, src_y, dw, dh, staging.binding(), 0, 0, false) catch break :blk false;
            break :blk true;
        };
        if (copied) {
            slot.cur_pending = true;
            slot.cur_w = dw;
            slot.cur_h = dh;
            slot.last_used_frame = encoder.frame_index;
        }
    }
}

fn restoreRenderTargetPass(
    encoder: anytype,
    restore_rt: gpu.Backend.TextureBinding,
    image_renderer: anytype,
    scale: f32,
) bool {
    if (encoder.render_pass != null) return true;

    var rt_view = restore_rt.createView();
    defer rt_view.destroy();
    const restored_pass = encoder.gpu_command_encoder.?.beginRenderPass(.{
        .color_attachments = &[_]gpu.RenderPassColorAttachment{.{
            .view = rt_view,
            .load_op = .load,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    }) catch return false;
    encoder.pass_count += 1;
    encoder.pass_sites[5] += 1;

    const slot = if (encoder.offscreen_depth > 0) encoder.offscreen_depth - 1 else 0;
    encoder.offscreen_stack[slot].render_pass = restored_pass;
    encoder.render_pass = &encoder.offscreen_stack[slot].render_pass;

    encoder.sdf_renderer.setViewport(encoder.viewport_width, encoder.viewport_height, scale);
    encoder.text_renderer.setViewport(encoder.viewport_width, encoder.viewport_height, scale);
    image_renderer.setViewport(encoder.viewport_width, encoder.viewport_height, scale);
    if (encoder.icon_renderer) |icon_renderer| icon_renderer.setViewport(encoder.viewport_width, encoder.viewport_height, scale);
    if (encoder.persistent.path_renderer) |*pr| {
        pr.setViewport(encoder.viewport_width, encoder.viewport_height, scale);
        if (encoder.offscreen_depth > 0) pr.setOffscreenViewport();
    }
    encoder.applyOffscreenTargetViewport();
    encoder.syncRectClipState();
    encoder.syncRendererClipMask();
    encoder.syncTextClipX();
    return true;
}

/// Execute one Kawase pass (downsample or upsample).
/// Returns false = resource missing, pass skipped (dst unwritten; caller must not treat it as a
/// blur result). A void return would let `try` callers see "success-but-noop" and downstream use
/// an unrendered texture as the deepest blur for brightness sampling.
/// Compute the UV sub-rect for sampling from effective pixel size + texture alloc size.
/// Inset by half a texel: clamp to the boundary pixel CENTER, not the boundary line, else
/// bilinear blends valid/pad edge and still mixes in transparent-black (clamp ineffective).
/// Pure function for unit-testability.
pub fn validUv(off_x: u32, off_y: u32, valid_w: u32, valid_h: u32, tex_w: u32, tex_h: u32) [4]f32 {
    if (tex_w == 0 or tex_h == 0) return .{ 0, 0, 1, 1 };
    const tw: f32 = @floatFromInt(tex_w);
    const th: f32 = @floatFromInt(tex_h);
    const half_x = 0.5 / tw;
    const half_y = 0.5 / th;
    // Start cannot be constant 0: glass on window edge (GlassEdge / downstream apps header) pad
    // clipped, valid content starts at dst_x/dst_y (measured dst=(160,160)).
    // Missing offset treats pad as valid, maps entire area wrong, stretches background.
    const x0: f32 = @as(f32, @floatFromInt(@min(off_x, tex_w))) / tw + half_x;
    const y0: f32 = @as(f32, @floatFromInt(@min(off_y, tex_h))) / th + half_y;
    const x1_raw: f32 = @as(f32, @floatFromInt(@min(off_x + valid_w, tex_w))) / tw - half_x;
    const y1_raw: f32 = @as(f32, @floatFromInt(@min(off_y + valid_h, tex_h))) / th - half_y;
    return .{ x0, y0, @max(x0, x1_raw), @max(y0, y1_raw) };
}

pub fn executeKawasePass(
    encoder: anytype,
    kind: KawasePassKind,
    src_texture: gpu.Backend.TextureBinding,
    src_w: u32,
    src_h: u32,
    dst_texture: gpu.Backend.TextureBinding,
    dst_w: u32,
    dst_h: u32,
    offset_scale: f32,
    /// Effective backdrop UV sub-rect within source texture (see KawaseUniforms.valid_uv)
    src_valid_uv: [4]f32,
) !bool {
    var pipeline = switch (kind) {
        .downsample => encoder.persistent.blur_downsample_pipeline orelse return warnPassSkipped("kawase pipeline"),
        .upsample => encoder.persistent.blur_upsample_pipeline orelse return warnPassSkipped("kawase pipeline"),
    };
    var sampler_state = encoder.persistent.blur_sampler orelse return warnPassSkipped("kawase sampler");

    const uniforms = KawaseUniforms{
        .texel_size = .{ 1.0 / @as(f32, @floatFromInt(src_w)), 1.0 / @as(f32, @floatFromInt(src_h)) },
        .offset_scale = offset_scale,
        .valid_uv = src_valid_uv,
    };
    // Slot budgets single-frame blur chain; data via setFragmentBytes (copied at encode, no
    // in-flight overwrite by next frame).
    _ = acquireKawaseUniformSlot(encoder) orelse return warnPassSkipped("kawase uniform slots exhausted");

    var dst_view = dst_texture.createView();
    const pass = encoder.gpu_command_encoder.?.beginRenderPass(.{
        .color_attachments = &[_]gpu.RenderPassColorAttachment{.{
            .view = dst_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    }) catch {
        dst_view.destroy();
        return warnPassSkipped("kawase render pass");
    };
    encoder.pass_count += 1; // v0.9-§D audit
    encoder.pass_sites[6] += 1;
    dst_view.destroy();

    var mutable_pass = pass;
    mutable_pass.setPipeline(&pipeline);
    mutable_pass.setFragmentBytes(0, std.mem.asBytes(&uniforms));
    mutable_pass.setFragmentTextureBinding(0, src_texture);
    mutable_pass.setFragmentSampler(0, &sampler_state);
    mutable_pass.setViewport(0, 0, @floatFromInt(dst_w), @floatFromInt(dst_h), 0, 1);
    mutable_pass.draw(3, 1, 0, 0);
    mutable_pass.end();
    return true;
}

/// Texel rectangle [x0, x1) × [y0, y1) of one texture. The native grid banks
/// are window-sized, but the composite reads only the texels under the glass;
/// passes write just the region their consumer reads (scissor), the rest of
/// the target is cleared and never sampled. Every bound below is derived from
/// the consumer's exact read footprint, so the read texels are unchanged.
pub const PixelRegion = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    pub fn unite(a: PixelRegion, b: PixelRegion) PixelRegion {
        return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
    }

    pub fn grow(r: PixelRegion, dx: i32, dy: i32) PixelRegion {
        return .{ .x0 = r.x0 - dx, .y0 = r.y0 - dy, .x1 = r.x1 + dx, .y1 = r.y1 + dy };
    }

    /// Scissor {x, y, w, h} inside a width×height target; null when empty.
    pub fn scissor(r: PixelRegion, width: u32, height: u32) ?[4]u32 {
        const x0: u32 = @intCast(std.math.clamp(r.x0, 0, @as(i32, @intCast(width))));
        const y0: u32 = @intCast(std.math.clamp(r.y0, 0, @as(i32, @intCast(height))));
        const x1: u32 = @intCast(std.math.clamp(r.x1, 0, @as(i32, @intCast(width))));
        const y1: u32 = @intCast(std.math.clamp(r.y1, 0, @as(i32, @intCast(height))));
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ x0, y0, x1 - x0, y1 - y0 };
    }
};

/// Texels of a width×height texture that bilinear sampling touches for
/// sample points inside the continuous rect (in that texture's normalized
/// coordinates scaled by `src`, i.e. pixels of a src_w×src_h grid).
pub fn bilinearFootprint(rect: [4]f32, src_w: u32, src_h: u32, width: u32, height: u32) PixelRegion {
    const sx = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(src_w));
    const sy = @as(f32, @floatFromInt(height)) / @as(f32, @floatFromInt(src_h));
    // A sample at texel coordinate t reads floor(t - 0.5) and floor(t - 0.5) + 1.
    return .{
        .x0 = @as(i32, @intFromFloat(@floor(rect[0] * sx - 0.5))) - 1,
        .y0 = @as(i32, @intFromFloat(@floor(rect[1] * sy - 0.5))) - 1,
        .x1 = @as(i32, @intFromFloat(@floor((rect[0] + rect[2]) * sx - 0.5))) + 3,
        .y1 = @as(i32, @intFromFloat(@floor((rect[1] + rect[3]) * sy - 0.5))) + 3,
    };
}

/// Input texels gaussian_filter_gamma reads for an output region: along the
/// blur axis the paired bilinear tap at offset ≤ radius touches radius + 1.
pub fn gaussianInputRegion(output: PixelRegion, radius: u32, vertical: bool) PixelRegion {
    const reach: i32 = @intCast(radius + 2);
    return if (vertical) output.grow(0, reach) else output.grow(reach, 0);
}

/// Source texels gaussian_downsample_gamma integrates for an output region:
/// output texel o covers source [o·cell, (o+1)·cell), read as a 4×4 block
/// starting at floor(o·cell).
pub fn areaSourceRegion(output: PixelRegion, src_w: u32, src_h: u32, width: u32, height: u32) PixelRegion {
    const cx = @as(f32, @floatFromInt(src_w)) / @as(f32, @floatFromInt(width));
    const cy = @as(f32, @floatFromInt(src_h)) / @as(f32, @floatFromInt(height));
    return .{
        .x0 = @as(i32, @intFromFloat(@floor(@as(f32, @floatFromInt(output.x0)) * cx))) - 1,
        .y0 = @as(i32, @intFromFloat(@floor(@as(f32, @floatFromInt(output.y0)) * cy))) - 1,
        .x1 = @as(i32, @intFromFloat(@floor(@as(f32, @floatFromInt(output.x1 - 1)) * cx))) + 5,
        .y1 = @as(i32, @intFromFloat(@floor(@as(f32, @floatFromInt(output.y1 - 1)) * cy))) + 5,
    };
}

/// Upper bound of the native lens displacement (glass.metal
/// native_lens_displacement): (height + base) · tan(θi − θr) with n = 1.5,
/// largest at grazing incidence, tan(90° − asin(1/1.5)) = 1.118.
pub fn nativeLensReach(bevel_height: f32, base_thickness: f32) f32 {
    return 1.125 * (@max(bevel_height, 0) + @max(base_thickness, 0));
}

/// Main-target pixels the native composite can read from its window-sized
/// banks: the shape bounds (node rect, or the union of group members, which
/// may extend past it), widened by the antialiasing band (mask ≥ 0.001 lies
/// within 2 px of the contour) and the lens displacement bound. Physical px.
pub fn nativeBankNeedRect(node_px: [4]f32, group: GroupUniformInput, native_params: [4]f32, scale: f32) [4]f32 {
    var x0 = node_px[0];
    var y0 = node_px[1];
    var x1 = node_px[0] + node_px[2];
    var y1 = node_px[1] + node_px[3];
    var reach = nativeLensReach(native_params[1], native_params[2]);
    const cx = node_px[0] + node_px[2] * 0.5;
    const cy = node_px[1] + node_px[3] * 0.5;
    for (group.rect[0..group.count], group.lens[0..group.count]) |r, lens| {
        x0 = @min(x0, cx + r[0] - r[2]);
        y0 = @min(y0, cy + r[1] - r[3]);
        x1 = @max(x1, cx + r[0] + r[2]);
        y1 = @max(y1, cy + r[1] + r[3]);
        reach = @max(reach, nativeLensReach(lens[2], lens[3]));
    }
    // A smooth union bulges past the member bounding box near a bridge by at
    // most 0.29·k (circular smin, glass.metal group_union); k is physical px.
    const merge = if (group.count > 0) @max(group.merge_k0_px, group.merge_kdyn_px) else 0;
    const margin = reach * scale + merge + 2;
    return .{ x0 - margin, y0 - margin, x1 - x0 + 2 * margin, y1 - y0 + 2 * margin };
}

fn regionHas(r: PixelRegion, x: i64, y: i64) bool {
    return x >= r.x0 and x < r.x1 and y >= r.y0 and y < r.y1;
}

test "bank regions: bilinear reads of every sample in the need rect stay in the footprint" {
    const sizes = [_][4]u32{ .{ 1925, 1750, 481, 437 }, .{ 2200, 2000, 550, 500 }, .{ 481, 437, 240, 218 }, .{ 1001, 999, 250, 249 } };
    const rects = [_][4]f32{ .{ 600.3, 1560.7, 720.2, 160.9 }, .{ -40, -12.5, 90, 70 }, .{ 0.2, 0.7, 1.1, 0.4 } };
    for (sizes) |sz| for (rects) |rect| {
        const r = bilinearFootprint(rect, sz[0], sz[1], sz[2], sz[3]);
        var i: u32 = 0;
        while (i <= 64) : (i += 1) {
            var j: u32 = 0;
            while (j <= 64) : (j += 1) {
                const px = rect[0] + rect[2] * @as(f32, @floatFromInt(i)) / 64;
                const py = rect[1] + rect[3] * @as(f32, @floatFromInt(j)) / 64;
                // Texel coordinate in the destination grid (uv · size − 0.5).
                const tx = px / @as(f32, @floatFromInt(sz[0])) * @as(f32, @floatFromInt(sz[2])) - 0.5;
                const ty = py / @as(f32, @floatFromInt(sz[1])) * @as(f32, @floatFromInt(sz[3])) - 0.5;
                const fx: i64 = @intFromFloat(@floor(tx));
                const fy: i64 = @intFromFloat(@floor(ty));
                try std.testing.expect(regionHas(r, fx, fy) and regionHas(r, fx + 1, fy + 1));
            }
        }
    };
}

test "bank regions: Gaussian taps for every output texel stay in the input region" {
    const out = PixelRegion{ .x0 = 40, .y0 = 300, .x1 = 230, .y1 = 350 };
    for ([_]f32{ 0.3, 0.6, 2.0, 5.2, 7.5, 31.0, 120.0 }) |sigma| for ([_]bool{ false, true }) |vertical| {
        const u = gaussianUniforms(sigma, 481, 437, vertical, .{ 0, 0, 1, 1 });
        const input = gaussianInputRegion(out, gaussianRadius(sigma), vertical);
        var o = out.x0;
        while (o < out.x1) : (o += 1) {
            var q = out.y0;
            while (q < out.y1) : (q += 37) {
                // gaussian_filter_gamma: paired bilinear taps at ±(i + w1 / (w0 + w1)).
                var i: u32 = 1;
                while (i <= u.radius) : (i += 2) {
                    const w1: f32 = if (i < u.radius) u.weights[i + 1] else 0;
                    const offset = @as(f32, @floatFromInt(i)) + w1 / @max(u.weights[i] + w1, 1e-20);
                    for ([_]f32{ -offset, offset }) |d| {
                        const center: f32 = @as(f32, @floatFromInt(if (vertical) q else o)) + d;
                        const lo: i64 = @intFromFloat(@floor(center));
                        for ([_]i64{ lo, lo + 1 }) |t| {
                            const x: i64 = if (vertical) o else t;
                            const y: i64 = if (vertical) t else q;
                            try std.testing.expect(regionHas(input, x, y));
                        }
                    }
                }
            }
        }
    };
}

test "bank regions: area reduction reads for every output texel stay in the source region" {
    const cases = [_][4]u32{ .{ 1925, 1750, 962, 875 }, .{ 962, 875, 481, 437 }, .{ 481, 437, 240, 218 }, .{ 7, 5, 3, 2 } };
    for (cases) |c| {
        const out = PixelRegion{ .x0 = 1, .y0 = 0, .x1 = @intCast(c[2] - 1), .y1 = @intCast(c[3]) };
        const src = areaSourceRegion(out, c[0], c[1], c[2], c[3]);
        const cx = @as(f32, @floatFromInt(c[0])) / @as(f32, @floatFromInt(c[2]));
        const cy = @as(f32, @floatFromInt(c[1])) / @as(f32, @floatFromInt(c[3]));
        var x = out.x0;
        while (x < out.x1) : (x += 1) {
            var y = out.y0;
            while (y < out.y1) : (y += 1) {
                // gaussian_downsample_gamma: 4×4 block from floor(o · cell).
                const fx: i64 = @intFromFloat(@floor(@as(f32, @floatFromInt(x)) * cx));
                const fy: i64 = @intFromFloat(@floor(@as(f32, @floatFromInt(y)) * cy));
                try std.testing.expect(regionHas(src, fx, fy) and regionHas(src, fx + 3, fy + 3));
            }
        }
    }
}

test "bank regions: need rect covers group members, lens reach and merge bulge" {
    var group: GroupUniformInput = .{};
    group.count = 2;
    group.rect[0] = .{ -150, 0, 60, 22 }; // extends 10 px left of a 280-wide node
    group.rect[1] = .{ 100, 0, 40, 22 };
    group.lens[0] = .{ 22, 8, 4, 2 };
    group.lens[1] = .{ 22, 8, 10, 6 };
    group.merge_k0_px = 30;
    const need = nativeBankNeedRect(.{ 100, 200, 280, 44 }, group, .{ 8, 3, 1, 0 }, 2);
    const margin = nativeLensReach(10, 6) * 2 + 30 + 2;
    try std.testing.expectApproxEqAbs(@as(f32, 240 - 210 - margin), need[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 200 - margin), need[1], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 380 + 2 * margin - (240 - 210)), need[2], 1e-3);
    // Grazing-incidence displacement of the lens model never exceeds the reach.
    try std.testing.expect(nativeLensReach(1, 0) >= 1.118);
}

pub fn executeGaussianPass(
    encoder: anytype,
    src: gpu.Backend.TextureBinding,
    dst: gpu.Backend.TextureBinding,
    width: u32,
    height: u32,
    sigma: f32,
    vertical: bool,
    valid: [4]f32,
    /// Output texels the consumer reads; null = the whole target.
    region: ?PixelRegion,
) !bool {
    var pipeline = encoder.persistent.gaussian_gamma_pipeline orelse return warnPassSkipped("Gaussian pipeline");
    var sampler = encoder.persistent.blur_sampler orelse return warnPassSkipped("Gaussian sampler");
    _ = acquireKawaseUniformSlot(encoder) orelse return warnPassSkipped("Gaussian uniform slots exhausted");
    const uniforms = gaussianUniforms(sigma, width, height, vertical, valid);
    var view = dst.createView();
    defer view.destroy();
    var pass = encoder.gpu_command_encoder.?.beginRenderPass(.{
        .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }},
    }) catch return warnPassSkipped("Gaussian render pass");
    encoder.pass_count += 1;
    encoder.pass_sites[6] += 1;
    pass.setPipeline(&pipeline);
    pass.setFragmentBytes(0, std.mem.asBytes(&uniforms));
    pass.setFragmentTextureBinding(0, src);
    pass.setFragmentSampler(0, &sampler);
    pass.setViewport(0, 0, @floatFromInt(width), @floatFromInt(height), 0, 1);
    if (region) |r| if (r.scissor(width, height)) |sc| pass.setScissorRect(sc[0], sc[1], sc[2], sc[3]);
    pass.draw(3, 1, 0, 0);
    pass.end();
    return true;
}

fn gaussianTexture(encoder: anytype, source: gpu.Backend.TextureBinding, width: u32, height: u32, sigma: f32, valid: [4]f32) !?TextureLease {
    return gaussianTextureXY(encoder, source, width, height, .{ sigma, sigma }, valid, null);
}

/// Separable Gaussian. With `region`, only the output texels in it (and the
/// horizontal-pass texels they need) are computed.
fn gaussianTextureXY(encoder: anytype, source: gpu.Backend.TextureBinding, width: u32, height: u32, sigma: [2]f32, valid: [4]f32, region: ?PixelRegion) !?TextureLease {
    const device = encoder.sdf_renderer.device;
    const tmp = encoder.offscreen_pool.acquireWithFormat(device, width, height, encoder.frame_index, .rgba16_float) orelse return null;
    defer _ = encoder.offscreen_pool.releaseForReuseInFrame(tmp);
    const output = encoder.offscreen_pool.acquireWithFormat(device, width, height, encoder.frame_index, .rgba16_float) orelse return null;
    var keep = false;
    defer if (!keep) {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(output);
    };
    const tb = encoder.offscreen_pool.binding(tmp) orelse return null;
    const ob = encoder.offscreen_pool.binding(output) orelse return null;
    const horizontal_region = if (region) |r| gaussianInputRegion(r, gaussianRadius(sigma[1]), true) else null;
    if (!try executeGaussianPass(encoder, source, tb, width, height, sigma[0], false, valid, horizontal_region)) return null;
    if (!try executeGaussianPass(encoder, tb, ob, width, height, sigma[1], true, valid, region)) return null;
    keep = true;
    return output;
}

/// One fixed two-source-pixel gamma area reduction over the entire window.
/// Every bank shares the same window origin; no material crop defines its UV.
fn halfGammaTexture(encoder: anytype, source: gpu.Backend.TextureBinding, input_gamma: bool, region: ?PixelRegion) !?TextureLease {
    const width = @max(1, source.width / 2);
    const height = @max(1, source.height / 2);
    const output = encoder.offscreen_pool.acquireWithFormat(encoder.sdf_renderer.device, width, height, encoder.frame_index, .rgba16_float) orelse return null;
    var keep = false;
    defer if (!keep) {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(output);
    };
    const ob = encoder.offscreen_pool.binding(output) orelse return null;
    var pipeline = encoder.persistent.gaussian_box_gamma_pipeline orelse return null;
    var sampler = encoder.persistent.blur_sampler orelse return null;
    const u = GaussianAreaUniforms{
        .source_size = .{ @floatFromInt(source.width), @floatFromInt(source.height) },
        .output_size = .{ @floatFromInt(width), @floatFromInt(height) },
        .input_gamma = if (input_gamma) 1 else 0,
    };
    var view = ob.createView();
    defer view.destroy();
    var pass = encoder.gpu_command_encoder.?.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }} }) catch return null;
    encoder.pass_count += 1;
    encoder.pass_sites[6] += 1;
    pass.setPipeline(&pipeline);
    pass.setFragmentBytes(0, std.mem.asBytes(&u));
    pass.setFragmentTextureBinding(0, source);
    pass.setFragmentSampler(0, &sampler);
    pass.setViewport(0, 0, @floatFromInt(width), @floatFromInt(height), 0, 1);
    if (region) |r| if (r.scissor(width, height)) |sc| pass.setScissorRect(sc[0], sc[1], sc[2], sc[3]);
    pass.draw(3, 1, 0, 0);
    pass.end();
    keep = true;
    return output;
}

/// Output size of one halfGammaTexture reduction.
fn halfSize(n: u32) u32 {
    return @max(1, n / 2);
}

/// Four-pixel bank, including gamma area integration before reconstruction.
/// With `region` (quarter texels), only what feeds it is reduced.
fn quarterGammaTexture(encoder: anytype, source: gpu.Backend.TextureBinding, region: ?PixelRegion) !?TextureLease {
    const half_w = halfSize(source.width);
    const half_h = halfSize(source.height);
    const half_region = if (region) |r| areaSourceRegion(r, half_w, half_h, halfSize(half_w), halfSize(half_h)) else null;
    const half = try halfGammaTexture(encoder, source, false, half_region) orelse return null;
    defer _ = encoder.offscreen_pool.releaseForReuseInFrame(half);
    const input = encoder.offscreen_pool.binding(half) orelse return null;
    return try halfGammaTexture(encoder, input, true, region);
}

fn coarseGaussianTexture(encoder: anytype, source: gpu.Backend.TextureBinding, sigma: f32) !?TextureLease {
    const quarter = try quarterGammaTexture(encoder, source, null) orelse return null;
    defer _ = encoder.offscreen_pool.releaseForReuseInFrame(quarter);
    const input = encoder.offscreen_pool.binding(quarter) orelse return null;
    // Odd dimensions cover the full source with fractional area cells. Their
    // horizontal/vertical scale factors differ, so retain an isotropic blur
    // in source pixels rather than assuming both axes shrink exactly fourfold.
    return try gaussianTextureXY(encoder, input, input.width, input.height, .{
        sigma * @as(f32, @floatFromInt(input.width)) / @as(f32, @floatFromInt(source.width)),
        sigma * @as(f32, @floatFromInt(input.height)) / @as(f32, @floatFromInt(source.height)),
    }, validUv(0, 0, input.width, input.height, input.width, input.height), null);
}

/// Quarter-grid reduction factor at which the ambient bank is filtered: the
/// coarsest power-of-two grid (relative to the window) on which its Gaussian
/// still spans at least `min_grid_sigma` texels. Area reduction plus bilinear
/// reconstruction adds factor^2/4 px^2 of variance (see nativeBankSigma);
/// against a sigma of hundreds of pixels that is far below one percent.
pub fn ambientBankFactor(sigma_physical: f32, quarter_w: u32, quarter_h: u32) u32 {
    const min_grid_sigma: f32 = 8;
    var factor: u32 = 4;
    var w = quarter_w;
    var h = quarter_h;
    while (w >= 16 and h >= 16 and sigma_physical / @as(f32, @floatFromInt(factor * 2)) >= min_grid_sigma) {
        factor *= 2;
        w /= 2;
        h /= 2;
    }
    return factor;
}

test "ambient bank factor keeps the Gaussian resolved on the grid" {
    // Native regular ambient (384 px) runs on a 1/32 grid with sigma 12.
    try std.testing.expectEqual(@as(u32, 32), ambientBankFactor(384, 550, 500));
    try std.testing.expectEqual(@as(u32, 4), ambientBankFactor(40, 550, 500));
    // Small windows stop before the grid falls below 8 texels (40 -> 20 -> 10).
    try std.testing.expectEqual(@as(u32, 16), ambientBankFactor(384, 40, 40));
}

/// The ambient (very wide) Gaussian, filtered on a coarse whole-window grid
/// instead of the quarter grid: the quarter-grid kernel read ~3σ ≈ 290 texels
/// per pixel per pass over the whole window, once per glass, and was about
/// half of the GPU time of glass scenes. Preserves the fitted total variance:
/// sigma^2 plus the quarter grid's own 4 px^2 (the bank was fitted with it).
fn ambientBankTexture(encoder: anytype, quarter: gpu.Backend.TextureBinding, rt_w: u32, rt_h: u32, sigma_physical: f32) !?TextureLease {
    const factor = ambientBankFactor(sigma_physical, quarter.width, quarter.height);
    var grid: ?TextureLease = null;
    defer if (grid) |lease| {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(lease);
    };
    var input = quarter;
    var level: u32 = 4;
    while (level < factor) : (level *= 2) {
        const next = try halfGammaTexture(encoder, input, true, null) orelse return null;
        if (grid) |lease| _ = encoder.offscreen_pool.releaseForReuseInFrame(lease);
        grid = next;
        input = encoder.offscreen_pool.binding(next) orelse return null;
    }
    const fitted = @sqrt(sigma_physical * sigma_physical + 4.0);
    const factor_f: f32 = @floatFromInt(factor);
    return try gaussianTextureXY(encoder, input, input.width, input.height, .{
        nativeBankSigma(fitted, rt_w, input.width, factor_f),
        nativeBankSigma(fitted, rt_h, input.height, factor_f),
    }, validUv(0, 0, input.width, input.height, input.width, input.height), null);
}

/// The measured compact fine bank is a 4x box followed by gamma bilinear
/// reconstruction, whose low-frequency variance is exactly 4 source px^2.
/// Preserve earlier measured Gaussian widths for sizes whose grid filter is
/// not independently identifiable; remove that known resampling variance.
pub fn nativeGridSigma(sigma_physical: f32, source_size: u32, quarter_size: u32) f32 {
    return nativeBankSigma(sigma_physical, source_size, quarter_size, 4);
}

/// Box reduction plus bilinear reconstruction contributes factor^2 / 4 to
/// the measured low-frequency source variance. Retain explicit bank factors
/// for odd axes while mapping sigma by their actual full-window extents.
pub fn nativeBankSigma(sigma_physical: f32, source_size: u32, grid_size: u32, factor: f32) f32 {
    const corrected = @sqrt(@max(0, sigma_physical * sigma_physical - factor * factor / 4.0));
    return corrected * @as(f32, @floatFromInt(grid_size)) / @as(f32, @floatFromInt(source_size));
}

test "native grid sigma: compact fine needs no Gaussian, main retains measured width" {
    try std.testing.expectEqual(@as(f32, 0), nativeGridSigma(2, 1280, 320));
    try std.testing.expectApproxEqAbs(@as(f32, 2.175), nativeGridSigma(@sqrt(4.0 + 8.7 * 8.7), 1280, 320), 0.00001);
    // Odd axes use the actual area-reduction ratio, retaining source-space
    // isotropy and registration rather than treating floor(W/4) as W/4.
    const x = nativeGridSigma(12, 1283, 320);
    const y = nativeGridSigma(12, 963, 240);
    try std.testing.expectApproxEqAbs(x * 1283 / 320, y * 963 / 240, 0.00001);
}

/// Conservative legacy rounded-rect support in target pixels. The viewport/UV
/// mapping stays unchanged. Outside this box the shader's first mask discards.
pub fn legacyGlassScissor(width: u32, height: u32, u: *const GlassUniforms) ?[4]u32 {
    // Keep numerically unusual inputs, groups and native silhouettes on the old
    // full pass. These limits also keep f32 mapping error well below the 2px guard.
    if (width == 0 or height == 0 or width > 65536 or height > 65536 or
        u.group_params[0] != 0 or !std.math.isFinite(u.surface_params[0]) or
        !std.math.isFinite(u.native_params[0]) or !std.math.isFinite(u.corner_radius) or
        !std.math.isFinite(u.scale_factor) or u.scale_factor <= 0) return null;
    if (@round(u.surface_params[0]) == 5 and u.native_params[0] > 0) return null;
    const scale = @max(u.scale_factor, 0.1);
    const dimensions = [2]u32{ width, height };
    var slope: [2]f64 = undefined;
    for (0..2) |axis| {
        const extent = u.content_uv[axis + 2];
        if (!std.math.isFinite(u.content_uv[axis]) or @abs(u.content_uv[axis]) > 2 or
            !std.math.isFinite(extent) or extent < 1e-4 or extent > 2 or
            !std.math.isFinite(u.rect_size[axis]) or u.rect_size[axis] <= 0) return null;
        // Match the shader's f32 multiply and max before widening the bounds.
        const rect_px = @max(u.rect_size[axis] * scale, 2.0);
        if (!std.math.isFinite(rect_px) or rect_px > 65536) return null;
        slope[axis] = @as(f64, rect_px) / (@as(f64, extent) * @as(f64, @floatFromInt(dimensions[axis])));
        if (slope[axis] < 1.0 / 64.0 or slope[axis] > 64) return null;
    }
    const ratio = slope[0] / slope[1];
    if (ratio < 1.0 / 256.0 or ratio > 256) return null;
    // sdf_rr is 1-Lipschitz: |ddx(d)| <= sx, |ddy(d)| <= sy, hence
    // aa <= max((sx+sy)/2, .5). Use twice that bound plus two target
    // pixels per axis for floating-point/rounding slack and derivative helpers.
    const aa = @max(slope[0] + slope[1], 1.0);
    var lo: [2]u32 = undefined;
    var hi: [2]u32 = undefined;
    for (0..2) |axis| {
        const limit: f64 = @floatFromInt(dimensions[axis]);
        const offset: f64 = u.content_uv[axis];
        const extent: f64 = u.content_uv[axis + 2];
        const margin = aa / slope[axis] + 2;
        // content_uv stores offset + extent, never left/right endpoints.
        // Outward 4px alignment preserves whole derivative quads; at attachment
        // edges the original full pass has exactly the same clipped helpers.
        const lower = std.math.clamp(@floor((offset * limit - margin) / 4) * 4, 0, limit);
        const upper = std.math.clamp(@ceil(((offset + extent) * limit + margin) / 4) * 4, 0, limit);
        lo[axis] = @intFromFloat(lower);
        hi[axis] = @intFromFloat(upper);
        if (hi[axis] <= lo[axis]) return null;
    }
    if (lo[0] == 0 and lo[1] == 0 and hi[0] == width and hi[1] == height) return null;
    return .{ lo[0], lo[1], hi[0] - lo[0], hi[1] - lo[1] };
}

fn legacyScissorTestUniforms() GlassUniforms {
    return .{ .texel_size = .{ 1.0 / 128.0, 1.0 / 128.0 }, .corner_radius = 8, .glass_intensity = 1, .rect_size = .{ 64, 64 }, .scale_factor = 1, .glass_tint = .{ 1, 1, 1, 0 }, .content_uv = .{ 0.25, 0.25, 0.5, 0.5 } };
}

test "legacy glass scissor: extent, outward alignment and anisotropic AA bounds" {
    var u = legacyScissorTestUniforms();
    try std.testing.expectEqual([4]u32{ 28, 28, 72, 72 }, legacyGlassScissor(128, 128, &u).?);
    u.rect_size[1] = 16;
    // sx=1, sy=.25: y needs a larger support than the isotropic case.
    try std.testing.expectEqual([4]u32{ 28, 24, 72, 80 }, legacyGlassScissor(128, 128, &u).?);
    u.content_uv = .{ -0.125, 0.25, 0.5, 0.5 };
    const sc = legacyGlassScissor(131, 127, &u).?;
    try std.testing.expectEqual(@as(u32, 0), sc[0]);
    try std.testing.expect(sc[0] + sc[2] >= 50); // right=(offset+extent)*131, not extent*131
    try std.testing.expect(sc[0] + sc[2] <= 131 and sc[1] + sc[3] <= 127);
    try std.testing.expect(sc[1] % 4 == 0 and (sc[1] + sc[3]) % 4 == 0);
}

test "legacy glass scissor: native, groups, empty/full and unstable mappings retain full pass" {
    var u = legacyScissorTestUniforms();
    u.surface_params[0] = 5;
    u.native_params[0] = 1;
    try std.testing.expect(legacyGlassScissor(128, 128, &u) == null);
    u.native_params[0] = 0;
    try std.testing.expect(legacyGlassScissor(128, 128, &u) != null); // surface 5 can still be legacy
    u.group_params[0] = 1;
    try std.testing.expect(legacyGlassScissor(128, 128, &u) == null);
    u = legacyScissorTestUniforms();
    u.content_uv = .{ 0, 0, 1, 1 };
    try std.testing.expect(legacyGlassScissor(128, 128, &u) == null);
    u.content_uv = .{ 2, 2, 0.5, 0.5 };
    try std.testing.expect(legacyGlassScissor(128, 128, &u) == null);
    u = legacyScissorTestUniforms();
    u.rect_size[0] = 0.001;
    u.rect_size[1] = 4096;
    try std.testing.expect(legacyGlassScissor(128, 128, &u) == null); // extreme axis ratio
    for ([_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32), 1e-8 }) |extent| {
        u = legacyScissorTestUniforms();
        u.content_uv[2] = extent;
        try std.testing.expect(legacyGlassScissor(128, 128, &u) == null);
    }
    u = legacyScissorTestUniforms();
    try std.testing.expect(legacyGlassScissor(0, 128, &u) == null);
    try std.testing.expect(legacyGlassScissor(std.math.maxInt(u32), 128, &u) == null);
    u.content_uv[0] = std.math.nan(f32);
    try std.testing.expect(legacyGlassScissor(128, 128, &u) == null);
}

test "legacy glass scissor: every excluded pixel lies beyond the rounded-rect AA support" {
    // Independent SDF/finite-difference oracle, including clipping, small physical
    // rectangles, odd target extents and opposing anisotropy. The helper itself
    // never evaluates the SDF or per-pixel derivatives.
    const cases = [_]struct { rect: [2]f32, uv: [4]f32, radius: f32 }{
        .{ .rect = .{ 64, 64 }, .uv = .{ 0.25, 0.25, 0.5, 0.5 }, .radius = 16 },
        .{ .rect = .{ 96, 4 }, .uv = .{ 0.125, 0.375, 0.75, 0.125 }, .radius = 2 },
        .{ .rect = .{ 4, 96 }, .uv = .{ 0.375, 0.125, 0.125, 0.75 }, .radius = 2 },
        .{ .rect = .{ 32, 48 }, .uv = .{ -0.125, 0.25, 0.5, 0.5 }, .radius = 12 },
        .{ .rect = .{ 0.5, 0.75 }, .uv = .{ 0.375, 0.375, 0.125, 0.125 }, .radius = 8 },
    };
    const Oracle = struct {
        fn distance(x: u32, y: u32, u: *const GlassUniforms) f32 {
            const s = @max(u.scale_factor, 0.1);
            const rx = @max(u.rect_size[0] * s, 2.0);
            const ry = @max(u.rect_size[1] * s, 2.0);
            const r = std.math.clamp(u.corner_radius * s, 0, @max(@min(rx, ry) * 0.5, 1));
            const px = ((@as(f32, @floatFromInt(x)) + 0.5) / 131 - u.content_uv[0]) / u.content_uv[2] * rx - 0.5 * rx;
            const py = ((@as(f32, @floatFromInt(y)) + 0.5) / 127 - u.content_uv[1]) / u.content_uv[3] * ry - 0.5 * ry;
            const qx = @abs(px) - rx * 0.5 + r;
            const qy = @abs(py) - ry * 0.5 + r;
            return @min(@max(qx, qy), 0) + @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) - r;
        }
    };
    for (cases) |c| {
        var u = legacyScissorTestUniforms();
        u.rect_size = c.rect;
        u.content_uv = c.uv;
        u.corner_radius = c.radius;
        const sc = legacyGlassScissor(131, 127, &u) orelse return error.ExpectedReducedScissor;
        var excluded: u32 = 0;
        for (0..127) |y| for (0..131) |x| {
            if (x >= sc[0] and x < sc[0] + sc[2] and y >= sc[1] and y < sc[1] + sc[3]) continue;
            const qx: u32 = @intCast(x & ~@as(usize, 1));
            const qy: u32 = @intCast(y & ~@as(usize, 1));
            const d00 = Oracle.distance(qx, qy, &u);
            const d10 = Oracle.distance(qx + 1, qy, &u);
            const d01 = Oracle.distance(qx, qy + 1, &u);
            const d11 = Oracle.distance(qx + 1, qy + 1, &u);
            const aa = @max((@max(@abs(d10 - d00), @abs(d11 - d01)) + @max(@abs(d01 - d00), @abs(d11 - d10))) * 0.5, 0.5);
            try std.testing.expect(Oracle.distance(@intCast(x), @intCast(y), &u) > aa);
            excluded += 1;
        };
        try std.testing.expect(excluded > 0);
    }
}

/// Glass composite pass: overlay refraction + Fresnel highlight on blur texture.
/// Input src (blur result), output dst (glass composite result)
pub fn executeGlassComposite(
    encoder: anytype,
    sharp_texture: gpu.Backend.TextureBinding,
    src_texture: gpu.Backend.TextureBinding,
    /// Softly filtered detail input (quarter-res downsample) for the native
    /// regular material; equals sharp_texture when unavailable.
    soft_texture: gpu.Backend.TextureBinding,
    coarse_texture: gpu.Backend.TextureBinding,
    alternate_main_texture: gpu.Backend.TextureBinding,
    dst_texture: gpu.Backend.TextureBinding,
    tex_w: u32,
    tex_h: u32,
    rect_w: f32,
    rect_h: f32,
    corner_radius: f32,
    glass_tint: [4]f32,
    glass_intensity: f32,
    specular_opacity: f32,
    specular_saturation: f32,
    refraction_level: f32,
    blur_level: f32,
    warp_gain: f32,
    center_thickness: f32,
    surface_kind: f32,
    bezel_width: f32,
    bottom_surface_kind: f32,
    bottom_bezel_width: f32,
    specular_angle: f32,
    magnification: f32,
    scale_ratio: f32,
    edge_field_strength: f32,
    center_zoom_radius: f32,
    center_zoom_falloff: f32,
    backdrop_distance: f32,
    content_uv: [4]f32,
    edge_params: [4]f32,
    edge_stop_pos: [4]f32,
    edge_stop_str: [4]f32,
    valid_uv: [4]f32,
    /// Background saturate / brightness (CSS backdrop-filter); {1,1} = no adjust.
    backdrop_adjust: [2]f32,
    /// Capture texture physical/logical scale (main RT scale; not offscreen layer magnification
    /// scale).
    capture_scale: f32,
    blur_is_resampled: bool,
    tint_mode: f32,
    base_veil: [4]f32,
    veil_curve: [20]f32,
    tab_lens: [24]f32,
    /// Native lens {bevel width, bevel height, base thickness} (logical px) + edge blur blend
    native_params: [4]f32,
    native_blur: [4]f32,
    coarse_uv: [4]f32,
    native_blur_profile: [4]f32,
    native_gamma: [4]f32,
    native_rim: [4]f32,
    native_chroma: [4]f32,
    native_chroma_profile: [4]f32,
    native_tint_response: [4]f32,
    group: GroupUniformInput,
) !bool {
    // Returns false = skipped (dst unwritten). Caller must revert to blur_tex composite, cannot
    // treat unrendered glass_tex as result else glass region is garbage.
    var pipeline = encoder.persistent.glass_pipeline orelse return warnPassSkipped("glass pipeline");
    var sampler_state = encoder.persistent.blur_sampler orelse return warnPassSkipped("glass sampler");

    const uniforms = GlassUniforms{
        .texel_size = .{ 1.0 / @as(f32, @floatFromInt(tex_w)), 1.0 / @as(f32, @floatFromInt(tex_h)) },
        .corner_radius = corner_radius,
        .glass_intensity = glass_intensity,
        .rect_size = .{ rect_w, rect_h },
        .scale_factor = capture_scale,
        .tint_mode = tint_mode,
        .base_veil = base_veil,
        .veil_curve = @bitCast(veil_curve),
        .tab_lens_params = @bitCast(tab_lens),
        .glass_tint = glass_tint,
        .specular_params = .{ specular_opacity, specular_saturation, refraction_level, blur_level },
        .optic_params = .{ warp_gain, center_thickness, backdrop_distance, if (blur_is_resampled) 1.0 else 0.0 },
        .surface_params = .{ surface_kind, bezel_width, specular_angle, magnification },
        .bottom_surface_params = .{ bottom_surface_kind, bottom_bezel_width, backdrop_adjust[0], backdrop_adjust[1] },
        .lens_params = .{ center_zoom_radius, center_zoom_falloff, edge_field_strength, scale_ratio },
        .content_uv = content_uv,
        .edge_params = edge_params,
        .edge_stop_pos = edge_stop_pos,
        .edge_stop_str = edge_stop_str,
        .valid_uv = valid_uv,
        .native_params = native_params,
        .native_blur = native_blur,
        .coarse_uv = coarse_uv,
        .native_blur_profile = native_blur_profile,
        .native_gamma = native_gamma,
        .native_rim = native_rim,
        .native_chroma = native_chroma,
        .native_chroma_profile = native_chroma_profile,
        .native_tint_response = native_tint_response,
        .group_params = .{ @floatFromInt(group.count), group.merge_k0_px, group.merge_c, group.merge_kdyn_px },
        .shape_rect = group.rect,
        .shape_lens = group.lens,
        .shape_tint = group.tint,
        .shape_rim = group.rim,
        .shape_resp = group.resp,
        .shape_misc = group.misc,
        .shape_shadow = group.shadow,
        .shape_level = group.level,
        .arrow_params = group.arrow,
        .knob_rim_dark = group.knob_rim_dark,
        .knob_rim_light = group.knob_rim_light,
        .corner_radii = group.corner_radii,
        .a11y_params = group.a11y,
    };
    // Data via setFragmentBytes (copied at encode): no slot exhaustion, no in-flight uniform
    // overwrite race by next frame.
    // Count kept for diagnostics only.
    _ = acquireGlassUniformSlot(encoder);

    var dst_view = dst_texture.createView();
    const pass = encoder.gpu_command_encoder.?.beginRenderPass(.{
        .color_attachments = &[_]gpu.RenderPassColorAttachment{.{
            .view = dst_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    }) catch {
        dst_view.destroy();
        return warnPassSkipped("glass render pass");
    };
    encoder.pass_count += 1; // v0.9-§D audit
    encoder.pass_sites[7] += 1;
    dst_view.destroy();

    var mutable_pass = pass;
    mutable_pass.setPipeline(&pipeline);
    mutable_pass.setFragmentBytes(0, std.mem.asBytes(&uniforms));
    mutable_pass.setFragmentTextureBinding(0, src_texture);
    mutable_pass.setFragmentTextureBinding(1, sharp_texture);
    mutable_pass.setFragmentTextureBinding(2, soft_texture);
    mutable_pass.setFragmentTextureBinding(3, coarse_texture);
    mutable_pass.setFragmentTextureBinding(4, alternate_main_texture);
    mutable_pass.setFragmentSampler(0, &sampler_state);
    mutable_pass.setViewport(0, 0, @floatFromInt(tex_w), @floatFromInt(tex_h), 0, 1);
    if (comptime gpu.backend_kind == .metal) {
        if (legacyGlassScissor(tex_w, tex_h, &uniforms)) |sc| mutable_pass.setScissorRect(sc[0], sc[1], sc[2], sc[3]);
    }
    mutable_pass.draw(3, 1, 0, 0);
    mutable_pass.end();
    return true;
}

/// Backdrop blur entry params; more readable than bare 30+ floats
pub const max_group_shapes = 8;

pub const MergeBlend = struct { k0: f32, c: f32 };

/// GlassEffectContainer(spacing:) -> union smooth-min blend radius k = k0 + c*gap (k0 logical px;
/// applyBackdropBlur multiplies cap_s then uploads physical px; c dimensionless).
/// Per-contour fit of native (native_container_merge.swift, two 120x44 regular capsules, macOS
/// 26.4): S=20/40/80 gives k0=13/20/31, c=0.40/0.70/0.90 (c~=0.1*sqrt(S)), rmse 0.5/0.5/1.7px;
/// S=0 merges only at touch (k0~=3.5). Interpolate within the table, extrapolate beyond 80 at the
/// last slope.
/// At full materialize (level>=0.99), the pairwise minimum signed gap per the static law yields a
/// pixel-independent merge radius (physical px).
/// Gap definition matches shader group_union: skeleton gap minus two corner radii; overlap is
/// negative.
/// Separate: k=k0+c*gap; overlap: drop linearly to 0 by depth (native static-overlap capsule
/// contour is flat; smooth union would add a bulge k(sqrt(2)-1) on the shared edge, see
/// native_tint_merge.swift overlap case).
pub fn staticMergeK(rects: []const [4]f32, lens: []const [4]f32, level: []const [4]f32, scale: f32, k0_px: f32, c: f32) f32 {
    var min_gap: f32 = std.math.inf(f32);
    for (rects, 0..) |ra, i| {
        if (level[i][0] < 0.99) continue;
        const cra = std.math.clamp(lens[i][0] * scale, 0, @min(ra[2], ra[3]));
        for (rects[i + 1 ..], i + 1..) |rb, j| {
            if (level[j][0] < 0.99) continue;
            const crb = std.math.clamp(lens[j][0] * scale, 0, @min(rb[2], rb[3]));
            const sx = @max(@abs(ra[0] - rb[0]) - (ra[2] - cra) - (rb[2] - crb), 0);
            const sy = @max(@abs(ra[1] - rb[1]) - (ra[3] - cra) - (rb[3] - crb), 0);
            const gap = @sqrt(sx * sx + sy * sy) - cra - crb;
            min_gap = @min(min_gap, gap);
        }
    }
    if (!std.math.isFinite(min_gap)) return k0_px;
    if (min_gap >= 0) return k0_px + c * min_gap;
    return k0_px * @max(0, 1 + min_gap / @max(k0_px, 1e-3));
}

test "staticMergeK: smallest gap among fully formed shapes, materializing ones ignored" {
    const rects = [_][4]f32{ .{ 0, 0, 100, 22 }, .{ 260, 0, 50, 22 }, .{ 150, 0, 10, 22 } };
    const lens = [_][4]f32{ .{ 22, 0, 0, 0 }, .{ 22, 0, 0, 0 }, .{ 10, 0, 0, 0 } };
    var level = [_][4]f32{ .{ 1, 0, 0, 0 }, .{ 1, 0, 0, 0 }, .{ 1, 0, 0, 0 } };
    // gap(0,2) = (150 - (100-22) - (10-10)) - 22 - 10 = 40; gap(2,1) = (110 - 0 - 28) - 10 - 22 = 50
    try std.testing.expectApproxEqAbs(@as(f32, 10 + 0.5 * 40), staticMergeK(&rects, &lens, &level, 1, 10, 0.5), 1e-4);
    level[2][0] = 0.5; // Fading-in/out shape doesn't participate: only (0,1) left, gap=260-78-28-44=110
    try std.testing.expectApproxEqAbs(@as(f32, 10 + 0.5 * 110), staticMergeK(&rects, &lens, &level, 1, 10, 0.5), 1e-4);
    // Overlap: two half-width-60 corner-22 capsules, center distance 90 -> signed gap -30; k0=20
    // drops to 0 (hard union)
    const ov = [_][4]f32{ .{ 0, 0, 60, 22 }, .{ 90, 0, 60, 22 } };
    const ovl = [_][4]f32{ .{ 22, 0, 0, 0 }, .{ 22, 0, 0, 0 } };
    const lv = [_][4]f32{ .{ 1, 0, 0, 0 }, .{ 1, 0, 0, 0 } };
    try std.testing.expectEqual(@as(f32, 0), staticMergeK(&ov, &ovl, &lv, 1, 20, 0.5));
    const ov2 = [_][4]f32{ .{ 0, 0, 60, 22 }, .{ 115, 0, 60, 22 } }; // Overlap 5 -> k=20*(1-5/20)=15
    try std.testing.expectApproxEqAbs(@as(f32, 15), staticMergeK(&ov2, &ovl, &lv, 1, 20, 0.5), 1e-4);
}

/// glassEffectUnion: merge one member into existing entry (container local logical coords).
/// Native measured (native_union.swift): composite shape = all same-id members' overall bounding
/// box shape, independent of member spacing / height diff / offset / other-id members in between.
pub fn mergeUnionInto(dst: *GroupShape, x: f32, y: f32, w: f32, h: f32, capsule: bool) void {
    const x0 = @min(dst.x, x);
    const y0 = @min(dst.y, y);
    const x1 = @max(dst.x + dst.w, x + w);
    const y1 = @max(dst.y + dst.h, y + h);
    dst.x = x0;
    dst.y = y0;
    dst.w = x1 - x0;
    dst.h = y1 - y0;
    if (capsule) dst.radius = @min(dst.w, dst.h) / 2;
}

test "mergeUnionInto: union of members is the capsule of their bounding box" {
    var g: GroupShape = .{ .x = 0, .y = 0, .w = 80, .h = 80, .radius = 40, .lens = .{ 0, 0, 0, 0 }, .tint = .{ 0, 0, 0, 0 }, .specular_opacity = 0, .rim = .{ 0, 0, 0, 0 }, .tint_response = .{ 0, 0, 0, 0 } };
    mergeUnionInto(&g, 100, 0, 80, 80, true); // Apple sample: two 80x80, spacing 20 -> 180x80 capsule
    try std.testing.expectEqual(@as(f32, 180), g.w);
    try std.testing.expectEqual(@as(f32, 40), g.radius);
    var h: GroupShape = .{ .x = 0, .y = 0, .w = 100, .h = 44, .radius = 22, .lens = .{ 0, 0, 0, 0 }, .tint = .{ 0, 0, 0, 0 }, .specular_opacity = 0, .rim = .{ 0, 0, 0, 0 }, .tint_response = .{ 0, 0, 0, 0 } };
    mergeUnionInto(&h, 120, 30, 100, 44, true); // vertically offset by 30 -> 220x74, radius 37
    try std.testing.expectEqual(@as(f32, 74), h.h);
    try std.testing.expectEqual(@as(f32, 37), h.radius);
}

pub fn mergeBlendParams(spacing: f32) MergeBlend {
    const sp = @max(spacing, 0);
    const xs = [_]f32{ 0, 20, 40, 80 };
    const k0s = [_]f32{ 4.8, 13, 20, 31 }; // S=0: contact neck 16px needs k~=9.6 physical (review audited)
    var k0: f32 = undefined;
    if (sp >= xs[xs.len - 1]) {
        const slope = (k0s[3] - k0s[2]) / (xs[3] - xs[2]);
        k0 = k0s[3] + (sp - xs[3]) * slope;
    } else {
        var i: usize = 0;
        while (sp > xs[i + 1]) : (i += 1) {}
        const t = (sp - xs[i]) / (xs[i + 1] - xs[i]);
        k0 = k0s[i] + (k0s[i + 1] - k0s[i]) * t;
    }
    return .{ .k0 = k0, .c = 0.1 * @sqrt(sp) };
}

test "mergeBlendParams reproduces the measured native blend radii" {
    const t20 = mergeBlendParams(20);
    try std.testing.expectApproxEqAbs(@as(f32, 13), t20.k0, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.447), t20.c, 0.01);
    const t80 = mergeBlendParams(80);
    try std.testing.expectApproxEqAbs(@as(f32, 31), t80.k0, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.894), t80.c, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 20), mergeBlendParams(40).k0, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 16.5), mergeBlendParams(30).k0, 0.01);
    try std.testing.expectEqual(@as(f32, 4.8), mergeBlendParams(0).k0);
    try std.testing.expect(mergeBlendParams(160).k0 > 31);
}

/// GlassGroup member shape (container surface local logical px + per-shape material slice).
pub const GroupShape = struct {
    node_id: u32 = std.math.maxInt(u32),
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    radius: f32,
    /// {bevel width, bevel height, base thickness, edge blur blend} (logical px)
    lens: [4]f32,
    tint: [4]f32,
    specular_opacity: f32,
    rim: [4]f32,
    tint_response: [4]f32,
    /// Surface-veil share: 0 = absorption (Glass.tint), 1 = surface veil (untinted regular), in
    /// between = partial tint (tintColor alpha)
    tint_mode: f32 = 0,
    /// Base coat no-tint {grayscale, alpha} (see types.GlassGroupShape.base_veil)
    base_veil: [2]f32 = .{ 247.0 / 255.0, 0 },
    press_offset: f32 = 0,
    /// {alpha 0..1, blur, offset x, offset y} (logical px); alpha 0 = no shadow
    shadow: [4]f32 = .{ 0, 0, 0, 0 },
    /// Materialize amount (1 = fully formed)
    level: f32 = 1,
};

/// executeGlassComposite's GlassGroup input (shader units already converted).
pub const GroupUniformInput = struct {
    count: u8 = 0,
    /// Union blend: k=k0+c*gap (physical px; see mergeBlendParams)
    merge_k0_px: f32 = 0,
    merge_c: f32 = 0,
    /// Transition merge radius (physical px); shader takes max(static law, this)
    merge_kdyn_px: f32 = 0,
    rect: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 0, 0, 0, 0 })),
    lens: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 0, 0, 0, 0 })),
    tint: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 0, 0, 0, 0 })),
    rim: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 0, 0, 0, 0 })),
    resp: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 0, 0, 0, 0 })),
    misc: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 0, 0, 0, 0 })),
    /// {alpha, blur(logical px), offset x, offset y(world logical px)}
    shadow: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 0, 0, 0, 0 })),
    /// {materialize level, reserved x3}
    level: [max_group_shapes][4]f32 = @as([max_group_shapes][4]f32, @splat(.{ 1, 0, 0, 0 })),
    /// Composite quad sides (left, top, right, bottom) world logical px to expand:
    /// member shapes beyond container rect + shadow extent; all 0 = don't expand
    expand: [4]f32 = .{ 0, 0, 0, 0 },
    /// Single-glass popover arrow (world logical px, shader multiplies by scale_factor; see
    /// GlassUniforms.arrow_params)
    arrow: [4]f32 = .{ 0, 0, 0, 0 },
    knob_rim_dark: [4]f32 = .{ 0, 0, 0, 0 },
    knob_rim_light: [4]f32 = .{ 0, 0, 0, 0 },
    corner_radii: [4]f32 = .{ -1, -1, -1, -1 },
    a11y: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const BackdropBlurParams = struct {
    /// GlassGroup: >0 when glass rect is container surface, composite N shapes per table
    group_count: u8 = 0,
    /// GlassEffectContainer(spacing:) (logical px)
    group_spacing: f32 = 0,
    /// Merge blend scale (0 = hard union)
    group_blend: f32 = 1,
    /// Transition merge radius k/S (written by GlassBox; 0 = no transition)
    group_motion: f32 = 0,
    /// Container has member in transition: entire container no snap-to-pixel
    group_continuous: bool = false,
    group_shapes: [max_group_shapes]GroupShape = undefined,
    /// glassEffectUnion member unioned into another entry: {member node id, merged-into
    /// group_shapes index}.
    /// Brightness slot also registers reads for them (uses merged entry's region), else these
    /// members never get own background luminance.
    group_aliases: [max_group_shapes][2]u32 = undefined,
    group_alias_count: u8 = 0,
    /// Glass owner node id (brightness region slot stable key; maxInt = unknown)
    glass_owner_id: u32 = std.math.maxInt(u32),
    /// Blur gradient (like CSS linear-gradient): direction 0=off 1=to_bottom 2=to_top 3=to_right
    /// 4=to_left / global intensity 0~1 / stops (pos 0~1 as % node size, ascending) / count
    blur_gradient_direction: f32 = 0,
    blur_gradient_strength: f32 = 0,
    blur_gradient_stop_pos: [4]f32 = .{ 0, 1, 1, 1 },
    blur_gradient_stop_str: [4]f32 = .{ 1, 0, 0, 0 },
    blur_gradient_stop_count: f32 = 2,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    blur_radius: f32,
    corner_radius: f32,
    glass_tint: [4]f32,
    /// See ResolvedGlassParams.tint_mode / base_veil.
    tint_mode: f32 = 0,
    base_veil: [4]f32 = .{ 0, 0, 0, -1 },
    veil_curve: [20]f32 = @splat(0),
    tab_lens: [24]f32 = @as([24]f32, @splat(0)),
    glass_intensity: f32,
    specular_opacity: f32,
    specular_saturation: f32,
    refraction_level: f32,
    blur_level: f32,
    warp_gain: f32,
    center_thickness: f32,
    surface_kind: f32,
    bezel_width: f32,
    bottom_surface_kind: f32,
    bottom_bezel_width: f32,
    backdrop_saturation: f32 = 1.0,
    backdrop_brightness: f32 = 1.0,
    specular_angle: f32,
    magnification: f32,
    scale_ratio: f32,
    edge_field_strength: f32,
    center_zoom_radius: f32,
    center_zoom_falloff: f32,
    backdrop_distance: f32,
    /// Native Liquid Glass lens {bevel width, bevel height, base thickness} (logical px) + edge
    /// blur blend
    native_params: [4]f32 = .{ 0, 0, 0, 1 },
    native_blur: [4]f32 = .{ 0, 0, 0, 0 },
    native_blur_profile: [4]f32 = .{ 0, 0, 0, 0 },
    native_rim: [4]f32 = .{ 0, 0, 0, 0 },
    native_chroma: [4]f32 = .{ 0, 0, 0, 0 },
    /// Animating shapes rasterize at continuous positions (no edge snapping).
    native_continuous_geometry: bool = false,
    /// Press-feedback sRGB offset (shader edge_params.y)
    press_offset: f32 = 0,
    /// Popover arrow {edge, along-edge offset, protrude len, tip round} (logical px; see
    /// types.GlassParams.arrow)
    arrow: [4]f32 = .{ 0, 0, 0, 0 },
    knob_rim_dark: [4]f32 = .{ 0, 0, 0, 0 },
    knob_rim_light: [4]f32 = .{ 0, 0, 0, 0 },
    /// Corner radii TL/TR/BR/BL (logical px); x<0 = uniform corner_radius
    corner_radii: [4]f32 = .{ -1, -1, -1, -1 },
    /// Accessibility params (see GlassUniforms.a11y_params)
    a11y: [4]f32 = .{ 0, 0, 0, 0 },
    /// Capture doesn't expand, blur clamps edge (sample only within node rect background)
    capture_clamp: bool = false,
    capture_current_target: bool = false,
    native_chroma_profile: [4]f32 = .{ 0, 0, 0, 0 },
    native_tint_response: [4]f32 = .{ 0, 0, 0, 0 },
    draw_x: f32,
    draw_y: f32,
    draw_w: f32,
    draw_h: f32,
    use_draw_transform: bool,
    draw_transform: [6]f32,
    rotate: f32,
};

/// Offscreen surface local rect -> world (main RT) AABB.
/// Current target texture local = local + offscreenOffset() (same conversion as content draw).
/// Then outward per-layer: draw_transform layer uses matrix mapping texture-local to 'post-pop
/// target frame not-localized' coords, plus cumulative offset from layers below to parent
/// texture-local; non-matrix layer maps by draw rect (already parent texture-local) ratio.
/// Stack bottom = main RT coords. Four corners for AABB; rotation/skew also covers full.
pub fn offscreenLocalRectToWorld(encoder: anytype, x: f32, y: f32, w: f32, h: f32) [4]f32 {
    const off = encoder.offscreenOffset();
    var pts = [4][2]f32{
        .{ x + off[0], y + off[1] },
        .{ x + w + off[0], y + off[1] },
        .{ x + off[0], y + h + off[1] },
        .{ x + w + off[0], y + h + off[1] },
    };
    var depth: usize = encoder.offscreen_depth;
    while (depth > 0) {
        depth -= 1;
        const layer = encoder.offscreen_stack[depth];
        // Cumulative offset to target (below this depth layer) after popping.
        var below_dx: f32 = 0;
        var below_dy: f32 = 0;
        for (encoder.offscreen_stack[0..depth]) |l| {
            below_dx -= l.x;
            below_dy -= l.y;
        }
        for (&pts) |*pt| {
            if (layer.use_draw_transform) {
                const t = layer.draw_transform;
                const nx = t[0] * pt[0] + t[2] * pt[1] + t[4] + below_dx;
                const ny = t[1] * pt[0] + t[3] * pt[1] + t[5] + below_dy;
                pt.* = .{ nx, ny };
            } else {
                const sx = if (layer.w > 0 and layer.draw_w > 0) layer.draw_w / layer.w else 1;
                const sy = if (layer.h > 0 and layer.draw_h > 0) layer.draw_h / layer.h else 1;
                const ox = if (std.math.isNan(layer.draw_x)) layer.x else layer.draw_x;
                const oy = if (std.math.isNan(layer.draw_y)) layer.y else layer.draw_y;
                pt.* = .{ ox + pt[0] * sx, oy + pt[1] * sy };
            }
        }
    }
    var x0: f32 = std.math.inf(f32);
    var y0: f32 = std.math.inf(f32);
    var x1: f32 = -std.math.inf(f32);
    var y1: f32 = -std.math.inf(f32);
    for (pts) |pt| {
        x0 = @min(x0, pt[0]);
        y0 = @min(y0, pt[1]);
        x1 = @max(x1, pt[0]);
        y1 = @max(y1, pt[1]);
    }
    return .{ x0, y0, x1 - x0, y1 - y0 };
}

/// blur_radius (logical px) -> Kawase chain params. Pure function for unit-testing
/// continuity/DPI-independence.
/// blur_radius is continuously adjustable (like CSS backdrop-filter: blur(px)), range [0, 96]
/// (types.zig resolve clamps and documents):
/// - Depth n = ceil(log2(r_phys/3)); per-level texel offset in physical px, so visual softness is
///   DPI-independent.
/// - Fractional-level interpolation: remainder r_phys/(3*2^n) in (0.5, 1] scales the whole chain,
///   so softness is continuous at boundaries, no step jumps. The n=1 segment (r_phys <= 6) scales
///   down to 0, so the curve is continuous from 0.
/// - Max depth 6: covers 2x full screen (96 logical = 192 physical px). 3x screen saturates at
///   64+ logical px.
pub const BlurChainParams = struct { levels: u32, offset_scale: f32 };
pub fn blurChainParams(radius_logical: f32, scale: f32) BlurChainParams {
    const radius_phys = @min(radius_logical, 96.0) * scale;
    const levels: u32 = if (radius_phys <= 6.0)
        1
    else
        @min(@max(@as(u32, @intFromFloat(@ceil(std.math.log2(radius_phys / 3.0)))), 1), 6);
    return .{
        .levels = levels,
        .offset_scale = radius_phys / (3.0 * std.math.pow(f32, 2.0, @floatFromInt(levels))),
    };
}

/// Backdrop blur: Dual Kawase downsample + upsample chain.
/// Semantics: blur rendered background below node, children render normally after (stay sharp).
/// Flow: blit region -> downsample chain -> upsample chain -> composite back to RT
pub fn snapNativeRect(rect: [4]f32, scale: f32) [4]f32 {
    const s = @max(scale, 0.1);
    const left = @floor(rect[0] * s + 0.5) / s;
    const top = @floor(rect[1] * s + 0.5) / s;
    const right = @floor((rect[0] + rect[2]) * s + 0.5) / s;
    const bottom = @floor((rect[1] + rect[3]) * s + 0.5) / s;
    return .{ left, top, @max(0, right - left), @max(0, bottom - top) };
}

test "native geometry: round shared physical edges, not origin and extent separately" {
    const a = snapNativeRect(.{ 160.125, 208.125, 320.125, 64.125 }, 2);
    const b = snapNativeRect(.{ 160, 208, 320.25, 64.25 }, 2);
    try std.testing.expectEqual([4]f32{ 160, 208, 320.5, 64.5 }, a);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual([4]f32{ 160, 208, 320, 64 }, snapNativeRect(.{ 160.125, 208.125, 320, 64 }, 2));
    try std.testing.expectEqual([4]f32{ 160.5, 208.5, 320, 64 }, snapNativeRect(.{ 160.25, 208.25, 320, 64 }, 2));
}

/// Fallback opaque (missing resources): preserve readable texture, not hole. Windows-only for basic
/// quality (WARP software render) or D3D12 backend.
/// Metal normal quality maintains semantics: skip blur is no-draw (ZENIT_NO_BLUR control group,
/// empty capture regions depend on this).
/// Per-frame glass cost (render thread). App renderer reads and resets for FrameStats.
pub var perf: struct { glass_count: u32 = 0, glass_ns: u64 = 0 } = .{};

pub fn applyBackdropBlur(encoder: anytype, p: BackdropBlurParams) !void {
    const start = profileNow(encoder);
    defer if (start) |t0| if (profileNow(encoder)) |t1| {
        perf.glass_count += 1;
        perf.glass_ns += t1.since(t0);
    };
    return applyBackdropBlurImpl(encoder, p);
}

fn applyBackdropBlurImpl(encoder: anytype, p: BackdropBlurParams) !void {
    if (p.w <= 0 or p.h <= 0 or p.blur_radius < 0.5) return;
    // Any reduced tier can always present the material layer; full quality
    // falls back to it only on D3D12 (where blur pipeline failure latches basic).
    const fallback_allowed = encoder.visual_quality != .full or comptime gpu.is_direct3d;
    if (encoder.visual_quality != .basic and try tryBackdropBlur(encoder, p)) return;
    if (!fallback_allowed) return;
    if (encoder.render_pass == null) return error.MissingRenderPass;
    try encoder.flushAllPending();
    try drawMaterialLayer(encoder, p, .basic);
}

/// Glass material veil of the frosted / basic tiers: each GlassGroup member
/// (or the single glass) keeps its own shape, radius and tint; alpha follows
/// the tier, materialize level and Reduce Transparency.
fn drawMaterialLayer(encoder: anytype, p: BackdropBlurParams, quality: @import("visual_quality.zig").Quality) !void {
    const vq = @import("visual_quality.zig");
    const reduce_transparency = p.a11y[0] > 0.5 and p.a11y[0] < 1.5;
    const off = encoder.offscreenOffset();
    if (p.group_count > 0) {
        // GlassGroup: the container only hosts its members.
        const sx = (if (p.draw_w > 0) p.draw_w else p.w) / p.w;
        const sy = (if (p.draw_h > 0) p.draw_h else p.h) / p.h;
        for (p.group_shapes[0..@min(p.group_count, max_group_shapes)]) |sh| {
            const level = std.math.clamp(sh.level, 0, 1);
            if (level <= 0.001 or sh.w <= 0 or sh.h <= 0) continue;
            var color = basicMaterial(sh.tint, sh.base_veil[0]);
            color[3] = level * vq.materialAlpha(quality, sh.tint[3] > 0.005, reduce_transparency);
            const r = sh.radius * @min(sx, sy);
            try drawBasicMaterial(encoder, p, off, .{ sh.x * sx, sh.y * sy, sh.w * sx, sh.h * sy }, color, .{ r, r, r, r });
        }
        return;
    }
    var tint = vq.opaqueTint(p.glass_tint);
    tint[3] = vq.materialAlpha(quality, p.tint_mode < 0.5 and p.glass_tint[3] > 0.005, reduce_transparency);
    const radii: [4]f32 = if (p.corner_radii[0] >= 0) p.corner_radii else .{ p.corner_radius, p.corner_radius, p.corner_radius, p.corner_radius };
    try drawBasicMaterial(encoder, p, off, .{ 0, 0, if (p.draw_w > 0) p.draw_w else p.w, if (p.draw_h > 0) p.draw_h else p.h }, tint, radii);
}

/// Opaque basic-quality material for a group member: its tint, or the
/// untinted coating gray.
fn basicMaterial(tint: [4]f32, veil_gray: f32) [4]f32 {
    if (tint[3] > 0.005) return @import("visual_quality.zig").opaqueTint(tint);
    return .{ veil_gray, veil_gray, veil_gray, 1 };
}

/// One opaque rounded rectangle at `rect` (x, y relative to the glass draw
/// origin, in its draw units), through the SDF pipeline when axis-aligned or
/// the image pipeline to preserve affine geometry.
fn drawBasicMaterial(encoder: anytype, p: BackdropBlurParams, off: [2]f32, rect: [4]f32, color: [4]f32, radii: [4]f32) !void {
    if (!p.use_draw_transform and p.rotate == 0) {
        try encoder.sdf_renderer.addRoundedRect(p.draw_x + off[0] + rect[0], p.draw_y + off[1] + rect[1], rect[2], rect[3], color, radii);
        return;
    }
    const ir = encoder.image_renderer orelse return error.MissingImageRenderer;
    const id = try ir.solidFallbackTexture();
    const radius = @max(@max(radii[0], radii[1]), @max(radii[2], radii[3]));
    if (p.use_draw_transform) {
        // Member offsets are local (pre-transform) units: fold them into the
        // translation, x' = tx + a·dx + c·dy.
        var t = encoder.localizeDrawTransformForCurrentTarget(p.draw_transform);
        const dx = rect[0] * p.w / (if (p.draw_w > 0) p.draw_w else p.w);
        const dy = rect[1] * p.h / (if (p.draw_h > 0) p.draw_h else p.h);
        t[4] += t[0] * dx + t[2] * dy;
        t[5] += t[1] * dx + t[3] * dy;
        const lw = rect[2] * p.w / (if (p.draw_w > 0) p.draw_w else p.w);
        const lh = rect[3] * p.h / (if (p.draw_h > 0) p.draw_h else p.h);
        try ir.addImageUVWithTransform(id, lw, lh, .{ 0, 0, 1, 1 }, color, radius, 1, t, false);
    } else {
        try ir.addImageUV(id, p.draw_x + off[0] + rect[0], p.draw_y + off[1] + rect[1], rect[2], rect[3], .{ 0, 0, 1, 1 }, color, radius, 1, p.rotate);
    }
    try ir.flush(encoder.render_pass.?);
}

fn tryBackdropBlur(encoder: anytype, p: BackdropBlurParams) !bool {
    // Diagnostic switch: disable all backdrop blur (Kawase chain + glass composite).
    // Each glass region ~10 render passes + 1 blit, absolute top of per-frame pass count (69 of
    // 86).
    // Use as control group to isolate GPU memory/perf attribution.
    if (debug_env.flag("ZENIT_NO_BLUR")) return false;
    if (p.blur_radius < 0.5) return false;
    if (encoder.render_pass == null) return false;
    if (encoder.gpu_command_encoder == null) return false;
    if (!ensureBlurPipeline(encoder)) return false;

    const ir = encoder.image_renderer orelse return false;
    // s = current target (may be magnified offscreen layer) scale, used only to restore pass.
    // Regular glass in layers samples the window backdrop. An image-only
    // material can opt into the current surface after drawing its own floor
    // and image, before any veil, tint or foreground is encoded.
    const sampling_main = encoder.offscreen_depth > 0 and !p.capture_current_target;
    const s = encoder.scale;
    const cap_s: f32 = if (sampling_main) encoder.offscreen_stack[0].saved_scale else s;
    const device = encoder.sdf_renderer.device;

    const chain = blurChainParams(p.blur_radius, cap_s);
    // Frosted tier: plain Kawase blur of the glass region, composited through
    // the member shapes with a translucent material veil (drawMaterialLayer);
    // no native banks or optical glass pass.
    const frosted = encoder.visual_quality == .frosted;
    const native_gaussian = !frosted and p.native_params[0] > 0 and encoder.persistent.gaussian_pipeline != null;
    // Native optics use a Gaussian below. Keep one small Kawase level only
    // for the asynchronous backdrop-luminance readback and fallback.
    const max_levels = if (native_gaussian) @as(u32, 1) else chain.levels;
    const offset_boost = chain.offset_scale;

    // Resolve every resource needed to recover the active target *before*
    // ending it.  Returning between end() and recovery used to leave a stale
    // RenderPass pointer in RenderCommandEncoder.
    const active_rt: gpu.Backend.TextureBinding = if (encoder.offscreen_depth > 0)
        encoder.offscreen_pool.binding(encoder.offscreen_stack[encoder.offscreen_depth - 1].texture) orelse return false
    else
        (encoder.main_render_target orelse return false);
    const restore_rt = active_rt;
    const current_rt: gpu.Backend.TextureBinding = if (sampling_main)
        (encoder.main_render_target orelse active_rt)
    else
        active_rt;

    // ---- 1. Flush + end current render pass ----
    if (@import("zenit_environment").has("ZENIT_DEBUG_GLASS")) {
        const pending_paths: usize = if (encoder.persistent.path_renderer) |*pr| pr.vertices.items.len else 0;
        const pending_img: usize = if (encoder.image_renderer) |imr| imr.instances.items.len else 0;
        const pending_icon: usize = if (encoder.icon_renderer) |icr| icr.instances.items.len else 0;
        std.debug.print("[glasspend] frame={d} owner={d} sdf={d} img={d} icon={d} txt={d} path={d} dt=({d:.3},{d:.3},{d:.3},{d:.3},{d:.2},{d:.2})\n", .{
            encoder.frame_index, p.glass_owner_id,    encoder.sdf_renderer.instances.items.len, pending_img,         pending_icon,        encoder.text_renderer.getPendingInstanceCount(), pending_paths,
            p.draw_transform[0], p.draw_transform[1], p.draw_transform[2],                      p.draw_transform[3], p.draw_transform[4], p.draw_transform[5],
        });
    }
    try encoder.sdf_renderer.flush(encoder.render_pass.?);
    if (encoder.image_renderer) |imr| try imr.flush(encoder.render_pass.?);
    if (encoder.icon_renderer) |icr| try icr.flush(encoder.render_pass.?);
    try encoder.text_renderer.flush(encoder.render_pass.?);
    encoder.render_pass.?.end();
    // Never retain an ended pass. Objective-C may immediately reuse that raw
    // address for the next blit encoder, which was the GlassBox crash.
    encoder.render_pass = null;
    defer if (encoder.render_pass == null) {
        _ = restoreRenderTargetPass(encoder, restore_rt, ir, s);
    };

    // Default glass captures the window backdrop in world coordinates.
    // Explicit image-only capture uses the current surface's coordinates and
    // scale; that surface has already drawn its opaque floor and raw image.
    if (@import("zenit_environment").has("ZENIT_DEBUG_GLASS")) {
        std.debug.print("[glassenc] frame={d} owner={d} depth={d}\n", .{ encoder.frame_index, p.glass_owner_id, encoder.offscreen_depth });
    }
    const blur_off: [2]f32 = if (sampling_main) .{ 0, 0 } else encoder.offscreenOffset();
    // Capture must sample parent RT in world frame. CA-pure unified path: p.x/p.y owner-local src
    // coords (always ~0), only draw_x/draw_y world AABB.
    // Sampling src always grabs background from RT top-left (black + wrong content).
    const local_x = if (std.math.isNan(p.draw_x)) p.x else p.draw_x;
    const local_y = if (std.math.isNan(p.draw_y)) p.y else p.draw_y;
    const local_w = if (p.draw_w > 0) p.draw_w else p.w;
    const local_h = if (p.draw_h > 0) p.draw_h else p.h;
    // Glass inside offscreen surface (opacity fade / scale / composited group): params in surface
    // coords, sample source is main RT.
    // Must map node rect through offscreen stack to world (screen) coords then capture. Else always
    // grabs RT top-left (window other region content).
    // Capture by world size; compose back pins this region to local rect, scale naturally cancels.
    const raw_world = if (sampling_main)
        offscreenLocalRectToWorld(encoder, local_x, local_y, local_w, local_h)
    else
        [4]f32{ local_x, local_y, local_w, local_h };
    // Controlled SwiftUI captures prove independent rounding of all four
    // physical edges (rounding x/y/w/h independently fails the .125+.125 case).
    // Keep layout/hit testing unchanged and share this rect across capture,
    // optical SDF, lens/rim and final composite. Rotated affine shapes remain
    // unsnapped: their rasterization has not been measured by this experiment.
    const snap_native = native_gaussian and !p.native_continuous_geometry and !(p.group_count > 0 and p.group_continuous) and (!p.use_draw_transform or
        (@abs(p.draw_transform[1]) < 1e-6 and @abs(p.draw_transform[2]) < 1e-6 and
            p.draw_transform[0] > 0 and p.draw_transform[3] > 0));
    const world = if (snap_native) snapNativeRect(raw_world, cap_s) else raw_world;
    if (debug_env.flag("ZENIT_DEBUG_GLASSCAP") and sampling_main) {
        const L = encoder.offscreen_stack[encoder.offscreen_depth - 1];
        std.debug.print("[glassworld] local=({d:.1},{d:.1},{d:.1},{d:.1}) world=({d:.1},{d:.1},{d:.1},{d:.1}) depth={d} L.x={d:.1} L.w={d:.1} udt={} dt=({d:.3},{d:.3},{d:.3},{d:.3},{d:.1},{d:.1}) draw=({d:.1},{d:.1},{d:.1},{d:.1}) off={any}\n", .{ local_x, local_y, local_w, local_h, world[0], world[1], world[2], world[3], encoder.offscreen_depth, L.x, L.w, L.use_draw_transform, L.draw_transform[0], L.draw_transform[1], L.draw_transform[2], L.draw_transform[3], L.draw_transform[4], L.draw_transform[5], L.draw_x, L.draw_y, L.draw_w, L.draw_h, encoder.offscreenOffset() });
    }
    const node_x = world[0];
    const node_y = world[1];
    const node_w = world[2];
    const node_h = world[3];
    // World / local size ratio: shape mask (corner radius, bevel) generated in world pixels of
    // capture texture.
    const world_scale: f32 = if (local_w > 0 and local_h > 0) 0.5 * (raw_world[2] / local_w + raw_world[3] / local_h) else 1;
    // Padded capture: larger than the glass rect. Magnification / edge displacement push sample
    // points beyond the node rect; clipping to node size causes edge stretch or small-texture
    // magnification blur. The pad lets displacement/magnification reach the true full-resolution
    // backdrop.
    // Pad must cover two things:
    //   (a) magnification/edge displacement pushing samples outside the node rect (depends on node
    //       size)
    //   (b) the blur kernel's own sample reach (depends on blur_radius)
    // With only (a), a large-radius kernel samples the valid area clamped to edge extension:
    // visually it 'stretches' boundary color into the clear area + overall gray (repeated edge
    // blends).
    // Take the max of both.
    const geom_pad = std.math.clamp(0.35 * @min(node_w, node_h) + 8, 12, 80);
    const blur_pad = @min(p.blur_radius, 96.0);
    // GlassGroup shadows drawn in glass pass, composite quad expands with it: pad must cover shadow
    // extent.
    // GlassGroup: member shapes may exceed container rect (drag / absolute members); expand
    // per-side as needed (overflow + merge bulge + shadow).
    // Capture pad is max of four sides.
    var group_expand: [4]f32 = .{ 0, 0, 0, 0 };
    for (p.group_shapes[0..@min(p.group_count, max_group_shapes)]) |sh| {
        const wx = raw_world[0] + sh.x * world_scale;
        const wy = raw_world[1] + sh.y * world_scale;
        const ww = sh.w * world_scale;
        const wh = sh.h * world_scale;
        const shadow_ext: f32 = if (sh.shadow[0] > 0.001) (sh.shadow[1] + @max(@abs(sh.shadow[2]), @abs(sh.shadow[3]))) * world_scale else 0;
        const bulge: f32 = 4;
        group_expand[0] = @max(group_expand[0], node_x - wx + bulge + shadow_ext);
        group_expand[1] = @max(group_expand[1], node_y - wy + bulge + shadow_ext);
        group_expand[2] = @max(group_expand[2], (wx + ww) - (node_x + node_w) + bulge + shadow_ext);
        group_expand[3] = @max(group_expand[3], (wy + wh) - (node_y + node_h) + bulge + shadow_ext);
    }
    var shadow_pad: f32 = 0;
    for (group_expand) |e| shadow_pad = @max(shadow_pad, e + 2);
    // capture_clamp: only node rect itself, blur edge-clamps extend (backgroundExtensionEffect:
    // blur area top/bottom stays full color, no bleed beyond).
    const pad: f32 = if (debug_env.flag("ZENIT_GLASS_NOPAD") or p.capture_clamp) 0 else @max(@max(geom_pad, blur_pad), shadow_pad);
    const cap_x = node_x - pad;
    const cap_y = node_y - pad;
    const cap_w = node_w + pad * 2;
    const cap_h = node_h + pad * 2;
    const sample_x = cap_x + blur_off[0];
    const sample_y = cap_y + blur_off[1];
    // Clip frame must match sample source: sampling main RT when currentRectClip is surface-local
    // frame, unusable; use full viewport instead.
    // At sampling_main encoder.viewport_* already changed to surface size by offscreen layer; real
    // screen viewport in stack[0] entry-time saved field.
    const capture_clip: ?[4]f32 = if (sampling_main)
        .{ 0, 0, encoder.offscreen_stack[0].saved_viewport_width, encoder.offscreen_stack[0].saved_viewport_height }
    else
        encoder.currentRectClip();
    if (debug_env.flag("ZENIT_DEBUG_GLASSCAP")) {
        const clip = capture_clip;
        std.debug.print("[glasscap] p=({d:.0},{d:.0},{d:.0},{d:.0}) draw=({d:.0},{d:.0},{d:.0},{d:.0}) udt={} off=({d:.0},{d:.0}) depth={d} clip={?any}\n", .{
            p.x, p.y, p.w, p.h, p.draw_x, p.draw_y, p.draw_w, p.draw_h, p.use_draw_transform, blur_off[0], blur_off[1], encoder.offscreen_depth, clip,
        });
    }
    const capture_region = @TypeOf(encoder.*).computeBackdropCaptureRegion(sample_x, sample_y, cap_w, cap_h, cap_s, capture_clip, current_rt.width, current_rt.height) orelse {
        _ = restoreRenderTargetPass(encoder, restore_rt, ir, s);
        return false;
    };
    const tex_w = capture_region.tex_w;
    const tex_h = capture_region.tex_h;
    // The blit origin is quantized to physical pixels. Derive this subrect from
    // that origin, not the fractional requested padding, to preserve background
    // registration and avoid filtering the already antialiased shape a second time.
    const content_uv = capture_region.contentUv(.{ node_x + blur_off[0], node_y + blur_off[1], node_w, node_h }, cap_s);
    // GlassGroup: member shapes convert container local logical px to shader units (physical px,
    // glass rect center origin).
    // Static: snap all four sides per physical pixel like container rect.
    var group_in: GroupUniformInput = .{};
    group_in.knob_rim_dark = p.knob_rim_dark;
    group_in.knob_rim_light = p.knob_rim_light;
    group_in.a11y = p.a11y;
    // Increase-contrast outline half outside contour: expand composite quad four sides +1 logical
    // px (else clipped by node rect).
    if (p.a11y[0] > 1.5 and p.group_count == 0) {
        for (&group_in.expand) |*e| e.* = @max(e.*, world_scale);
    }
    if (p.corner_radii[0] >= 0) group_in.corner_radii = .{ p.corner_radii[0] * world_scale, p.corner_radii[1] * world_scale, p.corner_radii[2] * world_scale, p.corner_radii[3] * world_scale };
    if (p.arrow[0] > 0.5) {
        group_in.arrow = .{ p.arrow[0], p.arrow[1] * world_scale, p.arrow[2] * world_scale, p.arrow[3] * world_scale };
        // Arrow tip exactly on node edge: expand composite quad that side +1 logical px, leave
        // space for tip antialiasing (else node rect flattens it).
        const side: usize = switch (@as(u8, @intFromFloat(@round(p.arrow[0])))) {
            1 => 3,
            2 => 1,
            3 => 0,
            else => 2,
        };
        group_in.expand[side] = world_scale;
    }
    if (p.group_count > 0) {
        group_in.count = @intCast(@min(p.group_count, max_group_shapes));
        const mb = mergeBlendParams(p.group_spacing);
        const blend = std.math.clamp(p.group_blend, 0.0, 1.0);
        group_in.merge_k0_px = mb.k0 * cap_s * blend;
        group_in.merge_c = mb.c * blend;
        // Transition merge radius: group_motion = k/S (GlassBox writes per-frame: deformation
        // 2*sqrt(1-s), matched insert 0.75, remove 0.5).
        // Take max with static law (shader group_union).
        group_in.merge_kdyn_px = @max(p.group_motion, 0.0) * p.group_spacing * cap_s * blend;
        const node_cx = (node_x + node_w * 0.5) * cap_s;
        const node_cy = (node_y + node_h * 0.5) * cap_s;
        for (p.group_shapes[0..group_in.count], 0..) |sh, i| {
            const wx = raw_world[0] + sh.x * world_scale;
            const wy = raw_world[1] + sh.y * world_scale;
            const ww = sh.w * world_scale;
            const wh = sh.h * world_scale;
            var x0 = wx * cap_s;
            var y0 = wy * cap_s;
            var x1 = (wx + ww) * cap_s;
            var y1 = (wy + wh) * cap_s;
            if (snap_native) {
                x0 = @round(x0);
                y0 = @round(y0);
                x1 = @round(x1);
                y1 = @round(y1);
            }
            group_in.rect[i] = .{ (x0 + x1) * 0.5 - node_cx, (y0 + y1) * 0.5 - node_cy, @max((x1 - x0) * 0.5, 1), @max((y1 - y0) * 0.5, 1) };
            group_in.lens[i] = .{ sh.radius * world_scale, sh.lens[0], sh.lens[1], sh.lens[2] };
            group_in.tint[i] = sh.tint;
            group_in.rim[i] = sh.rim;
            group_in.resp[i] = sh.tint_response;
            // size_dim same basis as single-rect-path rect_size (world logical px)
            group_in.misc[i] = .{ sh.specular_opacity, @min(ww, wh), sh.lens[3], sh.tint_mode };
            group_in.shadow[i] = .{ sh.shadow[0], sh.shadow[1] * world_scale, sh.shadow[2] * world_scale, sh.shadow[3] * world_scale };
            group_in.level[i] = .{ std.math.clamp(sh.level, 0.0, 1.0), sh.base_veil[0], sh.base_veil[1], sh.press_offset };
        }
        // Static law folded to one constant per container: k = k0 + c*(min gap between
        // fully-materialized pairs).
        // If shader took 'nearest pair' per-pixel, k jumps when pixel falls on different bisector
        // side, merge field discontinuous at bisector (card expand: V-line in concave corner).
        group_in.merge_k0_px = staticMergeK(group_in.rect[0..group_in.count], group_in.lens[0..group_in.count], group_in.level[0..group_in.count], cap_s, group_in.merge_k0_px, group_in.merge_c);
        group_in.merge_c = 0;
        group_in.expand = group_expand;
    }

    const level0 = encoder.offscreen_pool.acquire(device, tex_w, tex_h, encoder.frame_index) orelse return false;
    const level0_binding = encoder.offscreen_pool.binding(level0) orelse {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(level0);
        return false;
    };

    // ---- 2. Pixel-region capture (render-only on Metal) ----
    // One clear+copy pass also clears uncaptured padding for edge glass.
    encoder.copyTextureRegion(current_rt, capture_region.src_x, capture_region.src_y, capture_region.copy_w, capture_region.copy_h, level0_binding, capture_region.dst_x, capture_region.dst_y, !capture_region.coversFullTexture()) catch {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(level0);
        return false;
    };
    // Debug: capture content center region -> debug slot 0
    debugGlassBlit(
        encoder,
        level0_binding,
        capture_region.dst_x + (capture_region.copy_w -| 64) / 2,
        capture_region.dst_y + (capture_region.copy_h -| 64) / 2,
        capture_region.copy_w,
        capture_region.copy_h,
        0,
    );

    // ---- 3. Downsample chain ----
    var tex_chain: [7]TextureLease = undefined;
    var w_chain: [7]u32 = undefined;
    var h_chain: [7]u32 = undefined;
    // Real content pixel size **within** each level texture. Differs from w_chain/h_chain (alloc
    // size) only at level0:
    // texture allocated in 64px buckets, actual blit only copy_w x copy_h, rest transparent-black
    // pad.
    // Each downstream dst texture allocated exactly lw x lh, so effective size and alloc size sync
    // halve; ratio preserved.
    var vw_chain: [7]u32 = undefined;
    var vh_chain: [7]u32 = undefined;
    tex_chain[0] = level0;
    w_chain[0] = tex_w;
    h_chain[0] = tex_h;
    var ox_chain: [7]u32 = undefined;
    var oy_chain: [7]u32 = undefined;
    ox_chain[0] = capture_region.dst_x;
    oy_chain[0] = capture_region.dst_y;
    vw_chain[0] = capture_region.copy_w;
    vh_chain[0] = capture_region.copy_h;

    // actual_levels increments only AFTER that level's downsample truly executes: used to count
    // before execute, break/skip mid-loop left tex_chain[actual_levels] pointing to unrendered
    // garbage, directly blitted into brightness sample.
    // On failure, acquired textures immediately returned to pool (else each failure leaks).
    var actual_levels: u32 = 0;

    // ---- Chain depth inter-frame hysteresis ----
    // Under pool pressure, one island's actual_levels oscillating between n and n-1 each frame
    // shows
    // as flicker; n-1 vs n are visually near-identical, so the level change is the defect. Hence:
    // degrade immediately (less work), raise only after BLUR_LEVEL_RAISE_FRAMES consecutive frames
    // of availability.
    // Slots are matched by glass_owner_id, logic isomorphic to luminance_slots below.
    // No slot (full / unknown owner) -> level_slot = null -> fully degrades to unlimited behavior.
    // Slot type is inferred from the encoder to avoid a backdrop_blur <-> command_encoder cycle.
    const LevelSlot = @typeInfo(@TypeOf(&encoder.persistent.blur_level_slots[0])).pointer.child;
    const level_slot: ?*LevelSlot = blk: {
        if (p.glass_owner_id == std.math.maxInt(u32)) break :blk null;
        var lru_idx: usize = 0;
        var lru_frame: u64 = std.math.maxInt(u64);
        for (&encoder.persistent.blur_level_slots, 0..) |*slot, i| {
            if (slot.key == p.glass_owner_id) break :blk slot;
            if (slot.last_used_frame < lru_frame) {
                lru_frame = slot.last_used_frame;
                lru_idx = i;
            }
        }
        // No match: LRU reuse. Only usurp if reused slot truly stale (unused last frame); else this
        // frame islands > slots, usurp makes islands clear each other's history,
        // hysteresis devolves to noise. Better no hysteresis than that.
        const victim = &encoder.persistent.blur_level_slots[lru_idx];
        if (victim.last_used_frame + 1 >= encoder.frame_index and victim.key != std.math.maxInt(u32)) break :blk null;
        victim.key = p.glass_owner_id;
        victim.committed_levels = 0; // Handoff: old history void (no limit first frame).
        victim.requested_levels = 0;
        victim.raise_streak = 0;
        victim.raise_backoff = 0;
        break :blk victim;
    };
    if (level_slot) |slot| {
        if (slot.requested_levels != max_levels) {
            slot.requested_levels = max_levels;
            slot.committed_levels = 0;
            slot.raise_streak = 0;
            slot.raise_backoff = 0;
        }
    }
    // Debug/control: disable hysteresis revert to original (mutation verify; see commit message
    // measured data).
    const level_cap: u32 = if (debug_env.flag("ZENIT_NO_BLUR_HYSTERESIS")) max_levels else if (level_slot) |slot|
        levelCap(slot.committed_levels, slot.raise_streak, slot.raise_backoff, max_levels)
    else
        max_levels;

    for (0..level_cap) |i| {
        const lw = @max(1, w_chain[i] / 2);
        const lh = @max(1, h_chain[i] / 2);
        if (lw < 2 or lh < 2) break;
        const src_binding = encoder.offscreen_pool.binding(tex_chain[i]) orelse break;
        const tex = encoder.offscreen_pool.acquire(device, lw, lh, encoder.frame_index) orelse break;
        const dst_binding = encoder.offscreen_pool.binding(tex) orelse {
            _ = encoder.offscreen_pool.releaseForReuseInFrame(tex);
            break;
        };
        // Effective region of src (normalized). Half-texel inset avoids bilinear blending valid/pad
        // edge into black: clamp to boundary pixel CENTER not boundary line.
        const src_valid = validUv(ox_chain[i], oy_chain[i], vw_chain[i], vh_chain[i], w_chain[i], h_chain[i]);
        const ran = try executeKawasePass(
            encoder,
            .downsample,
            src_binding,
            w_chain[i],
            h_chain[i],
            dst_binding,
            lw,
            lh,
            (1.5 + @as(f32, @floatFromInt(i)) * 1.0) * offset_boost,
            src_valid,
        );
        if (!ran) {
            _ = encoder.offscreen_pool.releaseForReuseInFrame(tex);
            break;
        }
        tex_chain[i + 1] = tex;
        w_chain[i + 1] = lw;
        h_chain[i + 1] = lh;
        // dst allocated exactly lw x lh, viewport fills it; entire dst is valid content but sourced
        // from src valid region, proportions inherited (round-up avoids edge loss).
        // dst fills and content from src valid -> dst entire valid, offset zero.
        ox_chain[i + 1] = 0;
        oy_chain[i + 1] = 0;
        vw_chain[i + 1] = lw;
        vh_chain[i + 1] = lh;
        actual_levels += 1;
    }
    if (level_slot) |slot| {
        slot.last_used_frame = encoder.frame_index;
        const next = levelSettle(
            .{ .committed = slot.committed_levels, .streak = slot.raise_streak, .backoff = slot.raise_backoff },
            level_cap,
            actual_levels,
            max_levels,
        );
        slot.committed_levels = next.committed;
        slot.raise_streak = next.streak;
        slot.raise_backoff = next.backoff;
    }
    if (@import("zenit_environment").has("ZENIT_DEBUG_GLASS")) {
        const dbg_streak: u32 = if (level_slot) |ls| ls.raise_streak else 0;
        const dbg_backoff: u32 = if (level_slot) |ls| ls.raise_backoff else 0;
        std.debug.print("[glasschain] frame={d} owner={d} levels={d}/{d} cap={d} streak={d} backoff={d} boost={d:.2}\n", .{ encoder.frame_index, p.glass_owner_id, actual_levels, max_levels, level_cap, dbg_streak, dbg_backoff, offset_boost });
    }

    // ---- 3.5 Backdrop luminance adapt: deepest level blit to this glass region's dedicated slot
    // ----
    // Deepest Kawase level already low-res mean approximation. Larger levels shrunk to 64x64,
    // cannot just crop top-left;
    // else large panel luminance would change with blur chain depth. Slot matched by draw rect
    // quantize key (no match: LRU reuse oldest unused); single staging shared 'last-encoder wins'
    // is scroll-swap bug root.
    if (actual_levels > 0 and !encoder.persistent.luminance_locked) lum: {
        const deep = tex_chain[actual_levels];
        // Just checked in loop, but no unreachable (ReleaseFast UB): missing skips brightness
        // sample, slot keeps previous frame value.
        const deep_binding = encoder.offscreen_pool.binding(deep) orelse break :lum;
        const dw = @min(w_chain[actual_levels], 64);
        const dh = @min(h_chain[actual_levels], 64);
        // Slot key = glass owner node id: constant across scroll/layout changes (geometry key
        // changes per-frame with scroll -> 12 slots all churn -> values clear -> fallback global
        // mean -> scroll flicker).
        const key = p.glass_owner_id;
        var slot_idx: ?usize = null;
        var lru_idx: usize = 0;
        var lru_frame: u64 = std.math.maxInt(u64);
        for (&encoder.persistent.luminance_slots, 0..) |*slot, i| {
            if (slot.key == key and key != std.math.maxInt(u32)) {
                slot_idx = i;
                break;
            }
            if (slot.last_used_frame < lru_frame) {
                lru_frame = slot.last_used_frame;
                lru_idx = i;
            }
        }
        // No match only usurp slots used last frame or earlier: if this-frame-registered slot
        // usurped by later-encoded glass and islands > slots,
        // all slots each frame clear each other, none get data; prefer letting extra glass skip
        // this frame's sample.
        if (slot_idx == null and lru_frame >= encoder.frame_index) break :lum;
        const idx = slot_idx orelse blk: {
            const slot = &encoder.persistent.luminance_slots[lru_idx];
            slot.key = key;
            slot.value = null; // Handoff: old value void.
            slot.cur_pending = false;
            slot.prev_pending = false;
            break :blk lru_idx;
        };
        const slot = &encoder.persistent.luminance_slots[idx];
        slot.content_uv = content_uv;
        // GlassGroup: per-shape subrect (staging covers entire capture texture, uv = capture).
        slot.shape_count = group_in.count;
        for (p.group_shapes[0..group_in.count], 0..) |sh, i| {
            const wx = raw_world[0] + sh.x * world_scale;
            const wy = raw_world[1] + sh.y * world_scale;
            const inv_w = 1.0 / @max(node_w, 1e-3);
            const inv_h = 1.0 / @max(node_h, 1e-3);
            const su0 = content_uv[0] + (wx - node_x) * inv_w * content_uv[2];
            const sv0 = content_uv[1] + (wy - node_y) * inv_h * content_uv[3];
            slot.shape_keys[i] = sh.node_id;
            slot.shape_uv[i] = .{ su0, sv0, su0 + sh.w * world_scale * inv_w * content_uv[2], sv0 + sh.h * world_scale * inv_h * content_uv[3] };
        }
        for (p.group_aliases[0..p.group_alias_count]) |al| {
            if (slot.shape_count >= slot.shape_keys.len or al[1] >= group_in.count) break;
            slot.shape_keys[slot.shape_count] = al[0];
            slot.shape_uv[slot.shape_count] = slot.shape_uv[al[1]];
            slot.shape_count += 1;
        }
        if (slot.staging == null) {
            // BGRA8Unorm_sRGB matches source (blit requires same format); storageMode Shared for
            // getBytes; fixed 64x64, created once per slot.
            // D3D12 readBgra8 copies this texture into readback buffer, so staging must permit
            // copy_src (Metal reads directly).
            slot.staging = encoder.sdf_renderer.device.createTexture(std.heap.page_allocator, .{
                .label = "Zenit.LuminanceStaging",
                .size = .{ .width = 64, .height = 64 },
                .format = gpu.color_format,
                .usage = .{ .copy_dst = true, .copy_src = true, .render_attachment = true },
                .memory = .host_upload,
            }) catch null;
        }
        if (slot.staging) |*staging| {
            if (w_chain[actual_levels] > 64 or h_chain[actual_levels] > 64) {
                const sw: f32 = @floatFromInt(w_chain[actual_levels]);
                const sh: f32 = @floatFromInt(h_chain[actual_levels]);
                const ran = try executeKawasePass(encoder, .downsample, deep_binding, w_chain[actual_levels], h_chain[actual_levels], staging.binding(), 64, 64, @max(sw, sh) / 64, .{ 0.5 / sw, 0.5 / sh, 1 - 0.5 / sw, 1 - 0.5 / sh });
                if (ran) {
                    slot.cur_pending = true;
                    slot.cur_w = 64;
                    slot.cur_h = 64;
                    slot.last_used_frame = encoder.frame_index;
                }
                break :lum;
            }
            const copied = blk: {
                encoder.copyTextureRegion(deep_binding, 0, 0, dw, dh, staging.binding(), 0, 0, false) catch break :blk false;
                break :blk true;
            };
            if (copied) {
                slot.cur_pending = true;
                slot.cur_w = dw;
                slot.cur_h = dh;
                slot.last_used_frame = encoder.frame_index;
            }
        }
    }

    // ---- 4. Upsample chain ----
    // End at tex_chain[1] (half-resolution): glass shader normalized UV throughout, blur content
    // low-freq, half-res visual diff tiny, skip last pass back to full.
    // level0 stays clear throughout, directly serves as composite sharp input (no separate blit).
    // Softly filtered detail for native regular material:
    // half-resolution downsample (sigma ~= 2-3 physical px at 2x; native grid-line dips 9px wide 6
    // deep) copied before upsample overwrites.
    // With one level there is no upsample overwrite: the blur input itself
    // already holds the soft pixels. Borrow its binding at composite time,
    // rather than allocating and copying an identical texture. Native Gaussian
    // success replaces that input and supplies its own fine bank instead.
    // Unavailable (no chain / pool pressure) -> composite gets level0.
    var soft_tex: ?TextureLease = null;
    const single_level_soft = actual_levels == 1 and p.native_params[0] > 0;
    if (actual_levels > 1 and p.native_params[0] > 0) soft: {
        const src_binding = encoder.offscreen_pool.binding(tex_chain[1]) orelse break :soft;
        const tex = encoder.offscreen_pool.acquire(device, w_chain[1], h_chain[1], encoder.frame_index) orelse break :soft;
        const dst_binding = encoder.offscreen_pool.binding(tex) orelse {
            _ = encoder.offscreen_pool.releaseForReuseInFrame(tex);
            break :soft;
        };
        const copied = blk: {
            encoder.copyTextureRegion(src_binding, 0, 0, w_chain[1], h_chain[1], dst_binding, 0, 0, false) catch break :blk false;
            break :blk true;
        };
        if (!copied) {
            _ = encoder.offscreen_pool.releaseForReuseInFrame(tex);
            break :soft;
        }
        soft_tex = tex;
    }
    var upsample_ran: u32 = 0;
    if (actual_levels > 0) {
        var lvl: u32 = actual_levels;
        while (lvl > 1) : (lvl -= 1) {
            // Binding missing/pass skipped -> stop upsample: tex_chain[1] keeps existing content
            // (blur downgrade, not garbage pixels).
            const src_binding = encoder.offscreen_pool.binding(tex_chain[lvl]) orelse break;
            const dst_binding = encoder.offscreen_pool.binding(tex_chain[lvl - 1]) orelse break;
            const ran = try executeKawasePass(
                encoder,
                .upsample,
                src_binding,
                w_chain[lvl],
                h_chain[lvl],
                dst_binding,
                w_chain[lvl - 1],
                h_chain[lvl - 1],
                (1.2 + @as(f32, @floatFromInt(actual_levels - lvl)) * 0.8) * offset_boost,
                validUv(ox_chain[lvl], oy_chain[lvl], vw_chain[lvl], vh_chain[lvl], w_chain[lvl], h_chain[lvl]),
            );
            if (!ran) break;
            upsample_ran += 1;
        }
    }
    // Luminance and upsampling have encoded their last reads of the deeper
    // levels. Make these leases reusable before allocating the native banks;
    // later commands in this buffer may reuse them after those reads finish.
    if (actual_levels > 1) for (2..actual_levels + 1) |i| {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(tex_chain[i]);
    };
    if (@import("zenit_environment").has("ZENIT_DEBUG_GLASS")) {
        std.debug.print("[glassup] frame={d} owner={d} up={d}/{d}\n", .{ encoder.frame_index, p.glass_owner_id, upsample_ran, if (actual_levels > 0) actual_levels - 1 else 0 });
    }
    // actual_levels==0 degrade: no downsample levels, sharp and blur both level0 (Metal: two
    // read-only sample slots on same texture legal; mix result identical).
    var blur_tex: TextureLease = if (actual_levels > 0) tex_chain[1] else level0;
    var blur_is_resampled = actual_levels > 0;
    var alternate_main_tex: ?TextureLease = null;
    var main_grid_mix: f32 = 0;
    defer if (alternate_main_tex) |lease| {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(lease);
    };
    var coarse_tex: ?TextureLease = null;
    var native_gamma: [4]f32 = .{ 0, 0, 0, 0 };
    defer if (coarse_tex) |lease| {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(lease);
    };
    // Regular alone has the measured ambient Gaussian bank. tint_mode cannot
    // identify the variant: clear and regular share surface mode, and tinted
    // regular uses absorption mode.
    if (native_gaussian and p.native_blur[1] > 0) native_grid: {
        // Window-sized banks, computed only where the composite reads them.
        const rt_w = current_rt.width;
        const rt_h = current_rt.height;
        const quarter_w = halfSize(halfSize(rt_w));
        const quarter_h = halfSize(halfSize(rt_h));
        const eighth_w = halfSize(quarter_w);
        const eighth_h = halfSize(quarter_h);
        const need = nativeBankNeedRect(.{ node_x * cap_s, node_y * cap_s, node_w * cap_s, node_h * cap_s }, group_in, p.native_params, cap_s);
        const main_sigma = p.blur_radius * cap_s;
        const main_xy: [2]f32 = .{ nativeGridSigma(main_sigma, rt_w, quarter_w), nativeGridSigma(main_sigma, rt_h, quarter_h) };
        const alternate_xy: [2]f32 = .{ nativeBankSigma(main_sigma, rt_w, eighth_w, 8), nativeBankSigma(main_sigma, rt_h, eighth_h, 8) };
        const fine_sigma = (if (p.native_blur[0] > 0) p.native_blur[0] else p.center_thickness) * cap_s;
        const fine_x = nativeGridSigma(fine_sigma, rt_w, quarter_w);
        const fine_y = nativeGridSigma(fine_sigma, rt_h, quarter_h);
        const ambient_sigma = p.native_blur[1] * cap_s;
        const ambient_xy: [2]f32 = .{
            ambient_sigma * @as(f32, @floatFromInt(quarter_w)) / @as(f32, @floatFromInt(rt_w)),
            ambient_sigma * @as(f32, @floatFromInt(quarter_h)) / @as(f32, @floatFromInt(rt_h)),
        };
        // Bank outputs read by the composite, and the quarter texels each
        // separable Gaussian reads to produce them.
        const out_q = bilinearFootprint(need, rt_w, rt_h, quarter_w, quarter_h);
        const out_e = bilinearFootprint(need, rt_w, rt_h, eighth_w, eighth_h);
        const bank_input = struct {
            fn of(out: PixelRegion, sigma: [2]f32) PixelRegion {
                return gaussianInputRegion(gaussianInputRegion(out, gaussianRadius(sigma[1]), true), gaussianRadius(sigma[0]), false);
            }
        }.of;
        var quarter_region = bank_input(out_q, main_xy).unite(bank_input(out_q, .{ fine_x, fine_y })).unite(bank_input(out_q, ambient_xy));
        const eighth_region = bank_input(out_e, alternate_xy);
        if (p.native_chroma[3] > 0) quarter_region = quarter_region.unite(areaSourceRegion(eighth_region, quarter_w, quarter_h, eighth_w, eighth_h));

        const quarter = try quarterGammaTexture(encoder, current_rt, quarter_region) orelse break :native_grid;
        var quarter_kept = false;
        defer if (!quarter_kept) {
            _ = encoder.offscreen_pool.releaseForReuseInFrame(quarter);
        };
        const source = encoder.offscreen_pool.binding(quarter) orelse break :native_grid;
        std.debug.assert(source.width == quarter_w and source.height == quarter_h);
        const valid = validUv(0, 0, source.width, source.height, source.width, source.height);
        const main = try gaussianTextureXY(encoder, source, source.width, source.height, main_xy, valid, out_q) orelse break :native_grid;
        var committed = false;
        defer if (!committed) {
            _ = encoder.offscreen_pool.releaseForReuseInFrame(main);
        };
        // Independent medium-size waves expose grid8 reconstruction aliases.
        // Blend fixed banks rather than changing an allocation grid each frame.
        var alternate: ?TextureLease = null;
        defer if (!committed) {
            if (alternate) |lease| _ = encoder.offscreen_pool.releaseForReuseInFrame(lease);
        };
        if (p.native_chroma[3] > 0) {
            const eighth = try halfGammaTexture(encoder, source, true, eighth_region) orelse break :native_grid;
            defer _ = encoder.offscreen_pool.releaseForReuseInFrame(eighth);
            const input = encoder.offscreen_pool.binding(eighth) orelse break :native_grid;
            alternate = try gaussianTextureXY(encoder, input, input.width, input.height, alternate_xy, validUv(0, 0, input.width, input.height, input.width, input.height), out_e) orelse break :native_grid;
        }
        const fine = if (fine_x > 0.01 or fine_y > 0.01)
            try gaussianTextureXY(encoder, source, source.width, source.height, .{ fine_x, fine_y }, valid, out_q) orelse break :native_grid
        else
            quarter;
        defer if (!committed and !fine.eql(quarter)) {
            _ = encoder.offscreen_pool.releaseForReuseInFrame(fine);
        };
        // Commit main and fine together: an allocation/pass failure leaves the
        // original linear-sRGB Kawase fallback intact. Never hand an encoded
        // float intermediate to that fallback with gamma flags unset.
        if (!blur_tex.eql(level0)) _ = encoder.offscreen_pool.releaseForReuseInFrame(blur_tex);
        if (soft_tex) |st| _ = encoder.offscreen_pool.releaseForReuseInFrame(st);
        blur_tex = main;
        soft_tex = fine;
        quarter_kept = fine.eql(quarter);
        committed = true;
        alternate_main_tex = alternate;
        main_grid_mix = if (alternate != null) p.native_chroma[3] else 0;
        blur_is_resampled = false;
        native_gamma = .{ 1, 1, 0, 1 };
        if (p.native_blur[1] > 0) {
            // The ambient bank shares the whole-window gamma box. Its width
            // is very large; retain its independently fitted source sigma.
            coarse_tex = try ambientBankTexture(encoder, source, rt_w, rt_h, ambient_sigma);
        }
        native_gamma[2] = if (coarse_tex != null) 1 else 0;
    } else if (native_gaussian) {
        const valid = validUv(capture_region.dst_x, capture_region.dst_y, capture_region.copy_w, capture_region.copy_h, tex_w, tex_h);
        // Capture texture itself sRGB-encoded values (not _sRGB target): gaussian directly in
        // encoding, no encode pass needed.
        {
            const gamma_source = level0_binding;
            if (try gaussianTexture(encoder, gamma_source, tex_w, tex_h, p.blur_radius * cap_s, valid)) |gaussian| {
                native_gamma[0] = 1;
                if (!blur_tex.eql(level0)) _ = encoder.offscreen_pool.releaseForReuseInFrame(blur_tex);
                blur_tex = gaussian;
                blur_is_resampled = false;
                if (soft_tex) |st| _ = encoder.offscreen_pool.releaseForReuseInFrame(st);
                const fine_sigma = if (p.native_blur[0] > 0) p.native_blur[0] else p.center_thickness;
                soft_tex = if (fine_sigma > 0.01)
                    try gaussianTexture(encoder, gamma_source, tex_w, tex_h, fine_sigma * cap_s, valid)
                else
                    null;
                if (p.native_blur[1] > 0)
                    coarse_tex = try coarseGaussianTexture(encoder, current_rt, p.native_blur[1] * cap_s);
                native_gamma[1] = if (soft_tex != null) 1 else 0;
                native_gamma[2] = if (coarse_tex != null) 1 else 0;
            }
        }
    }

    // ---- 6. Glass composite ----
    // Fallback (no glass pipeline / glass_tex fetch failed): composite back to RT must be blur
    // result blur_tex (half-res stretched draw).
    const tex_w_f: f32 = @floatFromInt(tex_w);
    const tex_h_f: f32 = @floatFromInt(tex_h);
    const capture_valid_uv: [4]f32 = .{
        @as(f32, @floatFromInt(capture_region.dst_x)) / tex_w_f,
        @as(f32, @floatFromInt(capture_region.dst_y)) / tex_h_f,
        @as(f32, @floatFromInt(capture_region.dst_x + capture_region.copy_w)) / tex_w_f,
        @as(f32, @floatFromInt(capture_region.dst_y + capture_region.copy_h)) / tex_h_f,
    };
    var composite_tex = blur_tex;
    // Surface tint is an additive material veil, not image multiplication.
    // A failed optical pass still presents the opaque blurred backdrop.
    var composite_tint: [4]f32 = if (p.tint_mode >= 0.5 or frosted) .{ 1, 1, 1, 1 } else p.glass_tint;
    var composite_has_baked_shape_mask = false;
    // Whether level0 already early-returned (see 'fairness under pool pressure' comment below).
    var level0_released = false;
    if (encoder.persistent.glass_pipeline != null and !frosted) glass: {
        if (encoder.offscreen_pool.acquire(device, tex_w, tex_h, encoder.frame_index)) |glass_tex| {
            // Binding missing or composite skipped -> release glass_tex fallback to blur_tex
            // composite; never use unrendered glass_tex as result.
            const blur_binding = encoder.offscreen_pool.binding(blur_tex) orelse {
                _ = encoder.offscreen_pool.releaseForReuseInFrame(glass_tex);
                if (@import("zenit_environment").has("ZENIT_DEBUG_GLASS"))
                    std.debug.print("[glass-fallback] blur_binding missing owner={d}\n", .{p.glass_owner_id});
                break :glass;
            };
            const glass_binding = encoder.offscreen_pool.binding(glass_tex) orelse {
                _ = encoder.offscreen_pool.releaseForReuseInFrame(glass_tex);
                if (@import("zenit_environment").has("ZENIT_DEBUG_GLASS"))
                    std.debug.print("[glass-fallback] glass_binding missing owner={d}\n", .{p.glass_owner_id});
                break :glass;
            };
            const soft_binding: gpu.Backend.TextureBinding = if (soft_tex) |st|
                (encoder.offscreen_pool.binding(st) orelse level0_binding)
            else if (single_level_soft and blur_tex.eql(tex_chain[1]))
                blur_binding
            else
                level0_binding;
            const coarse_binding = if (coarse_tex) |ct| (encoder.offscreen_pool.binding(ct) orelse level0_binding) else level0_binding;
            const ran = try executeGlassComposite(
                encoder,
                level0_binding,
                blur_binding,
                soft_binding,
                coarse_binding,
                if (alternate_main_tex) |lease| (encoder.offscreen_pool.binding(lease) orelse blur_binding) else blur_binding,
                glass_binding,
                tex_w,
                tex_h,
                node_w,
                node_h,
                p.corner_radius * world_scale,
                p.glass_tint,
                p.glass_intensity,
                p.specular_opacity,
                p.specular_saturation,
                p.refraction_level,
                p.blur_level,
                p.warp_gain,
                p.center_thickness,
                p.surface_kind,
                p.bezel_width,
                p.bottom_surface_kind,
                p.bottom_bezel_width,
                p.specular_angle,
                p.magnification,
                p.scale_ratio,
                p.edge_field_strength,
                p.center_zoom_radius,
                p.center_zoom_falloff,
                p.backdrop_distance,
                content_uv,
                .{ p.blur_gradient_direction, p.press_offset, p.blur_gradient_strength, p.blur_gradient_stop_count },
                p.blur_gradient_stop_pos,
                p.blur_gradient_stop_str,
                capture_valid_uv,
                .{ p.backdrop_saturation, p.backdrop_brightness },
                cap_s,
                blur_is_resampled,
                p.tint_mode,
                p.base_veil,
                p.veil_curve,
                p.tab_lens,
                p.native_params,
                p.native_blur,
                .{ node_x * cap_s / @as(f32, @floatFromInt(current_rt.width)), node_y * cap_s / @as(f32, @floatFromInt(current_rt.height)), node_w * cap_s / @as(f32, @floatFromInt(current_rt.width)), node_h * cap_s / @as(f32, @floatFromInt(current_rt.height)) },
                p.native_blur_profile,
                native_gamma,
                p.native_rim,
                .{ p.native_chroma[0], p.native_chroma[1], p.native_chroma[2], main_grid_mix },
                p.native_chroma_profile,
                p.native_tint_response,
                group_in,
            );
            if (!ran) {
                _ = encoder.offscreen_pool.releaseForReuseInFrame(glass_tex);
                if (@import("zenit_environment").has("ZENIT_DEBUG_GLASS"))
                    std.debug.print("[glass-fallback] composite not ran owner={d}\n", .{p.glass_owner_id});
                break :glass;
            }
            if (!blur_tex.eql(level0)) {
                _ = encoder.offscreen_pool.releaseForReuseInFrame(blur_tex);
            }
            if (soft_tex) |st| {
                _ = encoder.offscreen_pool.releaseForReuseInFrame(st);
                soft_tex = null;
            }
            composite_tex = glass_tex;
            composite_tint = .{ 1, 1, 1, 1 };
            composite_has_baked_shape_mask = true;
            // Debug: composite output center region -> debug slot 1
            debugGlassBlit(encoder, glass_binding, (tex_w -| 64) / 2, (tex_h -| 64) / 2, tex_w, tex_h, 1);
        } else {
            if (@import("zenit_environment").has("ZENIT_DEBUG_GLASS"))
                std.debug.print("[glass-fallback] glass_tex acquire failed owner={d} {d}x{d}\n", .{ p.glass_owner_id, tex_w, tex_h });
        }
    }
    if (!composite_has_baked_shape_mask and native_gamma[0] > 0.5) {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(composite_tex);
        composite_tex = level0;
        blur_is_resampled = false;
    }
    if (soft_tex) |st| _ = encoder.offscreen_pool.releaseForReuseInFrame(st);
    // WARNING: **fairness** under pool pressure: reaching here means composite either succeeded or
    // already degraded. In both cases level0 (the full-resolution capture, this function's largest
    // texture) is no longer needed: success already sampled it, fallback never used it.
    // If held to function end, a **failed island occupies the pool longer than a succeeded one**:
    // the
    // success path early-returns blur_tex, the fail path keeps level0+blur_tex together. Then the
    // largest island failing composite monopolizes the pool and **islands after it are blank for
    // the
    // entire frame** (e.g. Inspector + toolbar flicker).
    // releaseForReuseInFrame clears reusable_after_frame => reusable immediately in the same frame,
    // so the early release directly benefits the following islands.
    if (!composite_tex.eql(level0)) {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(level0);
        level0_released = true;
    }
    // composite_tex==level0 only if actual_levels==0 and fallback, level0 released at end, don't
    // double-release here.
    if (!level0_released and !composite_tex.eql(level0)) {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(level0);
    }

    // ---- 7. Restore render pass ----
    if (!restoreRenderTargetPass(encoder, restore_rt, ir, s)) {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(composite_tex);
        return false;
    }

    // ---- 8. Composite to RT ----
    const comp_draw_x = if (encoder.offscreen_depth > 0)
        p.draw_x - encoder.offscreen_stack[encoder.offscreen_depth - 1].x
    else
        p.draw_x;
    const comp_draw_y = if (encoder.offscreen_depth > 0)
        p.draw_y - encoder.offscreen_stack[encoder.offscreen_depth - 1].y
    else
        p.draw_y;
    const composite_binding = encoder.offscreen_pool.binding(composite_tex) orelse {
        // Pass restored; missing binding gives up blur composite this frame (region stays
        // background).
        _ = encoder.offscreen_pool.releaseForReuseInFrame(composite_tex);
        std.log.warn("[backdrop-blur] composite binding lost; dropping blur composite this frame", .{});
        return false;
    };
    const comp_id = ir.registerTextureBinding(composite_binding, tex_w, tex_h) catch {
        _ = encoder.offscreen_pool.releaseForReuseInFrame(composite_tex);
        return false;
    };
    const composite_corner_radius: f32 = if (composite_has_baked_shape_mask) 0 else p.corner_radius;
    var comp_uv: [4]f32 = .{
        content_uv[0],
        content_uv[1],
        content_uv[0] + content_uv[2],
        content_uv[1] + content_uv[3],
    };
    if (!composite_has_baked_shape_mask and blur_is_resampled) {
        // The blur-only fallback samples a repacked Kawase texture too.
        // Keep the same background position when the glass pass is unavailable.
        const valid_w = @max(capture_valid_uv[2] - capture_valid_uv[0], 1.0 / tex_w_f);
        const valid_h = @max(capture_valid_uv[3] - capture_valid_uv[1], 1.0 / tex_h_f);
        comp_uv = .{
            (comp_uv[0] - capture_valid_uv[0]) / valid_w,
            (comp_uv[1] - capture_valid_uv[1]) / valid_h,
            (comp_uv[2] - capture_valid_uv[0]) / valid_w,
            (comp_uv[3] - capture_valid_uv[1]) / valid_h,
        };
    }
    const raw_composite_w = if (p.use_draw_transform) p.w else if (p.draw_w > 0) p.draw_w else p.w;
    const raw_composite_h = if (p.use_draw_transform) p.h else if (p.draw_h > 0) p.draw_h else p.h;
    const composite_w = raw_composite_w * node_w / @max(raw_world[2], 1e-4);
    const composite_h = raw_composite_h * node_h / @max(raw_world[3], 1e-4);
    var composite_transform: [6]f32 = if (p.use_draw_transform)
        encoder.localizeDrawTransformForCurrentTarget(p.draw_transform)
    else
        .{ 1, 0, 0, 1, comp_draw_x, comp_draw_y };
    composite_transform[4] += (node_x - raw_world[0]) * local_w / @max(raw_world[2], 1e-4);
    composite_transform[5] += (node_y - raw_world[1]) * local_h / @max(raw_world[3], 1e-4);
    // The native SDF already rasterizes coverage outside the exact node rect.
    // Include that texel fringe when replaying it; an exact quad would hard-clip
    // fractional straight edges even though their baked mask is antialiased.
    var composite_quad = if (composite_has_baked_shape_mask and p.native_params[0] > 0)
        expandGlassCompositeFringe(composite_w, composite_h, comp_uv, .{ tex_w, tex_h }, composite_transform)
    else
        GlassCompositeQuad{ .width = composite_w, .height = composite_h, .uv = comp_uv, .transform = composite_transform };
    if (composite_has_baked_shape_mask and (group_in.expand[0] > 0 or group_in.expand[1] > 0 or group_in.expand[2] > 0 or group_in.expand[3] > 0)) {
        // GlassGroup shadow/overflow members drawn in glass texture pad: quad expands per-side in
        // world logical px (no overflow texture).
        composite_quad = expandGlassCompositeBy(composite_quad, group_in.expand, .{ composite_w / @max(node_w, 1e-3), composite_h / @max(node_h, 1e-3) }, .{ content_uv[2] / @max(node_w, 1e-3), content_uv[3] / @max(node_h, 1e-3) });
    }
    if (frosted and p.group_count > 0) {
        // Each member shows the blurred backdrop through its own rounded shape.
        const qw = composite_quad.width;
        const qh = composite_quad.height;
        const uw = composite_quad.uv[2] - composite_quad.uv[0];
        const uh = composite_quad.uv[3] - composite_quad.uv[1];
        for (p.group_shapes[0..@min(p.group_count, max_group_shapes)]) |sh| {
            if (std.math.clamp(sh.level, 0, 1) <= 0.001 or sh.w <= 0 or sh.h <= 0) continue;
            const fx = sh.x / p.w;
            const fy = sh.y / p.h;
            const fw = sh.w / p.w;
            const fh = sh.h / p.h;
            var t = composite_quad.transform;
            t[4] += t[0] * fx * qw + t[2] * fy * qh;
            t[5] += t[1] * fx * qw + t[3] * fy * qh;
            const uv = [4]f32{ composite_quad.uv[0] + fx * uw, composite_quad.uv[1] + fy * uh, composite_quad.uv[0] + (fx + fw) * uw, composite_quad.uv[1] + (fy + fh) * uh };
            const radius = sh.radius * qw / p.w;
            if (p.use_draw_transform) {
                try ir.addImageUVWithTransform(comp_id, fw * qw, fh * qh, uv, composite_tint, radius, 1.0, t, true);
            } else {
                try ir.addImageUVPremultiplied(comp_id, t[4], t[5], fw * qw, fh * qh, uv, composite_tint, radius, 1.0, p.rotate);
            }
        }
    } else if (p.use_draw_transform) {
        try ir.addImageUVWithTransform(
            comp_id,
            composite_quad.width,
            composite_quad.height,
            composite_quad.uv,
            composite_tint,
            composite_corner_radius,
            1.0,
            composite_quad.transform,
            true,
        );
    } else {
        try ir.addImageUVPremultiplied(
            comp_id,
            composite_quad.transform[4],
            composite_quad.transform[5],
            composite_quad.width,
            composite_quad.height,
            composite_quad.uv,
            composite_tint,
            composite_corner_radius,
            1.0,
            p.rotate,
        );
    }
    try ir.flush(encoder.render_pass.?);
    ir.unregisterTextureBinding(comp_id);
    _ = encoder.offscreen_pool.releaseForReuseInFrame(composite_tex);
    if (frosted) try drawMaterialLayer(encoder, p, .frosted);
    return true;
}

/// Expand composite quad four sides by `expand` (left, top, right, bottom; world logical px) to fit
/// shadow/overflow members in pad.
/// local_per_world = quad local units / world logical px; uv_per_world = texture uv / world logical
/// px.
/// Each side clamped to texture [0, 1], doesn't shift texture sample.
pub fn expandGlassCompositeBy(q: GlassCompositeQuad, expand: [4]f32, local_per_world: [2]f32, uv_per_world: [2]f32) GlassCompositeQuad {
    const dl = @min(@max(expand[0], 0), q.uv[0] / @max(uv_per_world[0], 1e-6));
    const dt = @min(@max(expand[1], 0), q.uv[1] / @max(uv_per_world[1], 1e-6));
    const dr = @min(@max(expand[2], 0), (1.0 - q.uv[2]) / @max(uv_per_world[0], 1e-6));
    const db = @min(@max(expand[3], 0), (1.0 - q.uv[3]) / @max(uv_per_world[1], 1e-6));
    const pl = @max(dl, 0) * local_per_world[0];
    const pt = @max(dt, 0) * local_per_world[1];
    const pr = @max(dr, 0) * local_per_world[0];
    const pb = @max(db, 0) * local_per_world[1];
    var t = q.transform;
    t[4] -= t[0] * pl + t[2] * pt;
    t[5] -= t[1] * pl + t[3] * pt;
    return .{
        .width = q.width + pl + pr,
        .height = q.height + pt + pb,
        .uv = .{ q.uv[0] - @max(dl, 0) * uv_per_world[0], q.uv[1] - @max(dt, 0) * uv_per_world[1], q.uv[2] + @max(dr, 0) * uv_per_world[0], q.uv[3] + @max(db, 0) * uv_per_world[1] },
        .transform = t,
    };
}

test "expandGlassCompositeBy expands symmetrically inside the texture and clamps at its edges" {
    const q = GlassCompositeQuad{ .width = 100, .height = 50, .uv = .{ 0.25, 0.25, 0.75, 0.75 }, .transform = .{ 1, 0, 0, 1, 10, 20 } };
    // 1 local unit per world px; uv 0.005 per world px (100 px -> 0.5 uv)
    const e = expandGlassCompositeBy(q, .{ 20, 20, 20, 20 }, .{ 1, 1 }, .{ 0.005, 0.01 });
    try std.testing.expectApproxEqAbs(@as(f32, 140), e.width, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 90), e.height, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -10), e.transform[4], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), e.transform[5], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), e.uv[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), e.uv[2], 1e-5);
    // Stuck on texture left: left can only expand to uv 0
    const edge = GlassCompositeQuad{ .width = 100, .height = 50, .uv = .{ 0.05, 0.25, 0.55, 0.75 }, .transform = .{ 1, 0, 0, 1, 0, 0 } };
    const c = expandGlassCompositeBy(edge, .{ 20, 20, 20, 20 }, .{ 1, 1 }, .{ 0.005, 0.01 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), c.uv[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 130), c.width, 1e-4); // left 10 + right 20
    try std.testing.expectApproxEqAbs(@as(f32, -10), c.transform[4], 1e-4);
    // Asymmetric: only expand right 60 (member dragged past container right)
    const r = expandGlassCompositeBy(q, .{ 0, 0, 60, 0 }, .{ 1, 1 }, .{ 0.005, 0.01 });
    try std.testing.expectApproxEqAbs(@as(f32, 150), r.width, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 50), r.height, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 10), r.transform[4], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), r.uv[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), r.uv[2], 1e-5); // Right only 50px available to expand, clamp to texture edge
}

pub const GlassCompositeQuad = struct {
    width: f32,
    height: f32,
    uv: [4]f32,
    transform: [6]f32,
};

/// Include one physical capture texel on each edge without moving or scaling
/// the original texture samples. The origin shift is local to the affine map.
pub fn expandGlassCompositeFringe(w: f32, h: f32, uv: [4]f32, texture_size: [2]u32, transform: [6]f32) GlassCompositeQuad {
    const du = 1.0 / @as(f32, @floatFromInt(texture_size[0]));
    const dv = 1.0 / @as(f32, @floatFromInt(texture_size[1]));
    const pad_x = w * du / (uv[2] - uv[0]);
    const pad_y = h * dv / (uv[3] - uv[1]);
    var expanded_transform = transform;
    expanded_transform[4] -= transform[0] * pad_x + transform[2] * pad_y;
    expanded_transform[5] -= transform[1] * pad_x + transform[3] * pad_y;
    return .{
        .width = w + 2 * pad_x,
        .height = h + 2 * pad_y,
        .uv = .{ uv[0] - du, uv[1] - dv, uv[2] + du, uv[3] + dv },
        .transform = expanded_transform,
    };
}

test "validUv: 满幅纹理钳到边界像素中心" {
    // Valid == texture size still insets half texel: bilinear samples outermost pixel center only,
    // not beyond texture.
    // Metal clamp-to-edge handles it, but inset makes semantics explicit and aligns partial capture
    // paths.
    const uv = validUv(0, 0, 64, 64, 64, 64);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5 / 64.0), uv[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 - 0.5 / 64.0), uv[2], 1e-6);
}

test "validUv: 部分捕获时上界收在有效区内（pad 被排除）" {
    // Reason this function exists: texture allocated 960 in 64px buckets, actually 934 valid.
    // If upper bound 1.0, Kawase blurs right 26px transparent-black into valid.
    const uv = validUv(0, 0, 934, 183, 960, 192);
    const expect_x1 = 934.0 / 960.0 - 0.5 / 960.0;
    const expect_y1 = 183.0 / 192.0 - 0.5 / 192.0;
    try std.testing.expectApproxEqAbs(@as(f32, expect_x1), uv[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, expect_y1), uv[3], 1e-6);
    // Inverse assert: upper bound must be strictly < 1.0, else pad still sampled.
    try std.testing.expect(uv[2] < 1.0);
    try std.testing.expect(uv[3] < 1.0);
    // And cannot over-inset to cut valid content.
    try std.testing.expect(uv[2] > 0.96);
}

test "validUv: 退化输入不产生非法区间" {
    const zero = validUv(0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(f32, 1.0), zero[2]);
    // Valid exceeds tex: clamp back (prevent uv > 1 out-of-bounds)
    const over = validUv(0, 0, 999, 999, 64, 64);
    try std.testing.expect(over[2] <= 1.0);
    // Tiny texture cannot have x1 < x0 reverse interval
    const tiny = validUv(0, 0, 1, 1, 1, 1);
    try std.testing.expect(tiny[2] >= tiny[0]);
}

test "validUv: 非零起点（贴窗口边）—— 下界必须跟着偏移走" {
    // GlassEdge / downstream app header on window edge: pad clipped, valid content starts dst=(160,
    // 160) (measured).
    // Used to constant 0 for lower, so 160px blank pad treated as valid, mapped entire area wrong
    // -> background stretched-blur, sidebar text mushed.
    const uv = validUv(160, 160, 640, 2000, 832, 2368);
    try std.testing.expectApproxEqAbs(@as(f32, 160.0 / 832.0 + 0.5 / 832.0), uv[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 160.0 / 2368.0 + 0.5 / 2368.0), uv[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 800.0 / 832.0 - 0.5 / 832.0), uv[2], 1e-6);
    // Inverse assert: lower bound must be significantly > 0, else offset missed.
    try std.testing.expect(uv[0] > 0.18);
    try std.testing.expect(uv[1] > 0.06);
}

// ---- Chain depth hysteresis (issue 33: Inspector/toolbar oscillate per frame) ----
// Model: `pool_ok(n)` = can offscreen pool provide level n this frame.
// Measured symptom: pool on threshold oscillates level 5 accept/reject with REUSE_LAG_FRAMES=3
// period, so actual_levels flickers 5/4/4/5/4/4... per frame.

/// Run hysteresis state machine, return per-frame actual_levels sequence. `achievable(frame)`
/// simulates max levels pool provides this frame.
fn simulateLevels(
    comptime achievable: fn (u64) u32,
    max_levels: u32,
    frames: u64,
    out: []u32,
) void {
    var st: BlurLevelState = .{};
    for (0..frames) |f| {
        const cap = levelCap(st.committed, st.streak, st.backoff, max_levels);
        const actual = @min(cap, achievable(f));
        out[f] = actual;
        st = levelSettle(st, cap, actual, max_levels);
    }
}

test "levelCap: 无历史不设限（首帧/换主一次到位）" {
    try std.testing.expectEqual(@as(u32, 5), levelCap(0, 0, 0, 5));
    try std.testing.expectEqual(@as(u32, 6), levelCap(0, 99, 3, 6));
}

test "levelCap: 有历史时压在上一帧提交的级数" {
    try std.testing.expectEqual(@as(u32, 4), levelCap(4, 0, 0, 5));
    try std.testing.expectEqual(@as(u32, 4), levelCap(4, BLUR_LEVEL_RAISE_FRAMES - 2, 0, 5));
    // Streak reaches threshold -> allow one raise attempt.
    try std.testing.expectEqual(@as(u32, 5), levelCap(4, BLUR_LEVEL_RAISE_FRAMES - 1, 0, 5));
}

test "levelCap: 退避把上调间隔按 2^backoff 拉长，封顶 8×" {
    const base = BLUR_LEVEL_RAISE_FRAMES;
    // With backoff=1, base-1 insufficient; 2*base-1 required.
    try std.testing.expectEqual(@as(u32, 4), levelCap(4, base - 1, 1, 5));
    try std.testing.expectEqual(@as(u32, 5), levelCap(4, 2 * base - 1, 1, 5));
    // Cap: backoff 3 and 9 share the same threshold.
    try std.testing.expectEqual(levelCap(4, 8 * base - 1, 3, 5), levelCap(4, 8 * base - 1, 9, 5));
    try std.testing.expectEqual(@as(u32, 5), levelCap(4, 8 * base - 1, 9, 5));
}

test "降级立即生效：池掉一级，下一帧就压到低值（不留垃圾纹理）" {
    const st = levelSettle(.{ .committed = 5, .streak = 0, .backoff = 0 }, 5, 4, 5);
    try std.testing.expectEqual(@as(u32, 4), st.committed);
    try std.testing.expectEqual(@as(u32, 4), levelCap(st.committed, st.streak, st.backoff, 5));
}

test "回归 issue 33：3 帧周期的池振荡不再让 levels 逐帧跳变" {
    // Pool cycles every 3 frames: 5/4/4 (measured phase with REUSE_LAG_FRAMES=3).
    const Osc = struct {
        fn f(frame: u64) u32 {
            return if (frame % 3 == 0) 5 else 4;
        }
    };
    var seq: [60]u32 = undefined;
    simulateLevels(Osc.f, 5, seq.len, &seq);

    // First frame uncapped (5); thereafter must converge. In steady state (skip first 12 frames)
    // convergence), adjacent frames cannot jump again - this is the visible flicker.
    var changes: u32 = 0;
    for (seq[12..], 13..) |v, i| {
        if (v != seq[i - 1]) changes += 1;
    }
    try std.testing.expectEqual(@as(u32, 0), changes);
    // Stable at low value acceptable (visually near-identical to constant 5), but not zero.
    try std.testing.expect(seq[seq.len - 1] > 0);

    // Mutation control: without hysteresis the pool itself flickers each frame as expected.
    var raw_changes: u32 = 0;
    for (13..seq.len) |i| {
        if (Osc.f(i) != Osc.f(i - 1)) raw_changes += 1;
    }
    try std.testing.expect(raw_changes > 20);
}

test "池恢复后链深会回升（迟滞不是单向锁死）" {
    const Recover = struct {
        fn f(frame: u64) u32 {
            return if (frame < 10) 4 else 5;
        }
    };
    var seq: [80]u32 = undefined;
    simulateLevels(Recover.f, 5, seq.len, &seq);
    try std.testing.expectEqual(@as(u32, 4), seq[9]);
    // Recovery should climb back to 5 within O(BLUR_LEVEL_RAISE_FRAMES) frames and hold.
    try std.testing.expectEqual(@as(u32, 5), seq[seq.len - 1]);
    var rise_at: usize = seq.len;
    for (seq[10..], 10..) |v, i| {
        if (v == 5) {
            rise_at = i;
            break;
        }
    }
    try std.testing.expect(rise_at - 10 <= 2 * BLUR_LEVEL_RAISE_FRAMES);
}

test "硬饱和：第 5 级永远给不出时，退避让尝试频率收敛（不退化为低频闪）" {
    const Hard = struct {
        fn f(_: u64) u32 {
            return 4;
        }
    };
    var seq: [200]u32 = undefined;
    simulateLevels(Hard.f, 5, seq.len, &seq);
    // Pool always returns 4; cap passes through to 5 but runs as 4 -> constant sequence, no jumps.
    for (seq[1..]) |v| try std.testing.expectEqual(@as(u32, 4), v);
}

fn profileNow(encoder: anytype) ?@import("zenit_time").Instant {
    if (comptime @hasField(@TypeOf(encoder.*), "io")) {
        const io = encoder.io orelse return null;
        return @import("zenit_time").Instant.now(io) catch null;
    }
    return null;
}
