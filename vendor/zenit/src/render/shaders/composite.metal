#ifndef ZENIT_FRAMEBUFFER_FETCH
#define ZENIT_FRAMEBUFFER_FETCH 1
#endif
#include <metal_stdlib>
using namespace metal;

struct BlendUniforms {
    float2 target_size;
    float2 rect_size; // Layer-local physical px
    float2 src_uv_scale;
    float2 inv_offset;     // local = inv · pixel + inv_offset
    float4 inv;            // a, b, c, d
    float4 params; // opacity, blend_mode, corner_radius (layer-local physical px), mask inset (px: the clip rect inside the quad)
    float4 clip_rect; // Destination physical px rect clipping (w < 0 = none)
    float4 clip_shape; // x = kind (0-1 rounded rect, 2 ellipse), y = radius (destination physical px)
    float4 clip_shape_rect;
    float4 warp;           // lens warp (physical px): x across the rounded ends, y across the long edges (+ = toward the centre), z fade start, w fade width
    float4 src_uv_origin;  // xy = src UV of the quad's origin (grid-aligned rounded layers)
};

/// Destination pixel clipping coverage (rect x shape), 0.5px antialiasing band; consistent with
/// image pipeline.
float zb_clip_coverage(float2 pixel, constant BlendUniforms& u) {
    float coverage = 1.0;
    if (u.clip_rect.z >= 0.0 && u.clip_rect.w >= 0.0) {
        float2 half_size = u.clip_rect.zw * 0.5;
        float2 q = abs(pixel - (u.clip_rect.xy + half_size)) - half_size;
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
        coverage *= clamp(0.5 - d, 0.0, 1.0);
    }
    uint kind = uint(u.clip_shape.x);
    if (kind == 1u || kind == 2u) {
        float2 half_size = u.clip_shape_rect.zw * 0.5;
        float2 p = pixel - (u.clip_shape_rect.xy + half_size);
        float d;
        if (kind == 1u) {
            float r = min(u.clip_shape.y, min(half_size.x, half_size.y));
            float2 q = abs(p) - half_size + r;
            d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
        } else {
            float2 safe = max(half_size, 0.001);
            d = (length(p / safe) - 1.0) * min(safe.x, safe.y);
        }
        coverage *= clamp(0.5 - d, 0.0, 1.0);
    }
    return coverage;
}

struct VOut { float4 position [[position]]; };

vertex VOut blend_vertex_main(uint vid [[vertex_id]]) {
    VOut out;
    float2 point = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
    out.position = float4(point, 0.0, 1.0);
    return out;
}

float4 zb_unpremul(float4 color) {
    if (color.a < 0.0001) return float4(0.0);
    return float4(color.rgb / color.a, color.a);
}

float3 zb_multiply(float3 source, float3 destination) { return source * destination; }
float3 zb_screen(float3 source, float3 destination) { return source + destination - source * destination; }
float3 zb_hard_light(float3 source, float3 destination) {
    float3 low = 2.0 * source * destination;
    float3 high = 1.0 - 2.0 * (1.0 - source) * (1.0 - destination);
    return select(high, low, source <= 0.5);
}
float3 zb_overlay(float3 source, float3 destination) { return zb_hard_light(destination, source); }
float3 zb_darken(float3 source, float3 destination) { return min(source, destination); }
float3 zb_lighten(float3 source, float3 destination) { return max(source, destination); }
float3 zb_color_dodge(float3 source, float3 destination) {
    return select(min(float3(1.0), destination / max(1.0 - source, 0.0001)), float3(1.0), source >= 1.0);
}
float3 zb_color_burn(float3 source, float3 destination) {
    return select(1.0 - min(float3(1.0), (1.0 - destination) / max(source, 0.0001)), float3(0.0), source <= 0.0);
}
float3 zb_soft_light(float3 source, float3 destination) {
    float3 dd = select(sqrt(destination), ((16.0 * destination - 12.0) * destination + 4.0) * destination, destination <= 0.25);
    float3 low = destination - (1.0 - 2.0 * source) * destination * (1.0 - destination);
    float3 high = destination + (2.0 * source - 1.0) * (dd - destination);
    return select(high, low, source <= 0.5);
}
float3 zb_difference(float3 source, float3 destination) { return abs(source - destination); }
float3 zb_exclusion(float3 source, float3 destination) { return source + destination - 2.0 * source * destination; }

float zb_rounded_rect_mask(float2 point, float2 size, float radius) {
    if (radius <= 0.5) return 1.0;
    float2 half_size = size * 0.5;
    float2 q = abs(point - half_size) - half_size + radius;
    float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    return clamp(0.5 - distance, 0.0, 1.0);
}

fragment float4 blend_fragment_main(
    VOut in [[stage_in]],
    texture2d<float> source_texture [[texture(0)]],
#if ZENIT_FRAMEBUFFER_FETCH
    float4 destination_premul [[color(0)]],
#else
    texture2d<float> destination_texture [[texture(1)]],
#endif
    sampler texture_sampler [[sampler(0)]],
    constant BlendUniforms& uniforms [[buffer(0)]])
{
    float2 fragment_pixel = in.position.xy;
#if !ZENIT_FRAMEBUFFER_FETCH
    float4 destination_premul = destination_texture.read(uint2(fragment_pixel));
#endif
    // Destination pixel -> layer-local pixel (arbitrary affine: rotate / draw_transform)
    float2 local = float2(uniforms.inv.x * fragment_pixel.x + uniforms.inv.z * fragment_pixel.y,
                          uniforms.inv.y * fragment_pixel.x + uniforms.inv.w * fragment_pixel.y) + uniforms.inv_offset;
    if (local.x < 0.0 || local.y < 0.0 ||
        local.x >= uniforms.rect_size.x || local.y >= uniforms.rect_size.y) {
        return destination_premul;
    }

    // Lens warp: sample the surface shifted along the contour's normal, fading inward from the
    // contour (the rounded rect of params.z, inset by params.w).
    float2 sample_local = local;
    if (uniforms.warp.x != 0.0 || uniforms.warp.y != 0.0) {
        float2 half_size = uniforms.rect_size * 0.5;
        float2 clip_half = max(half_size - uniforms.params.w, float2(0.5));
        float r = min(uniforms.params.z, min(clip_half.x, clip_half.y));
        float2 p = local - half_size;
        float2 q = abs(p) - clip_half + r;
        float inset = max(-(length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r), 0.0);
        // along the contour's normal (the displacement follows the SDF gradient: straight across
        // the long edges, radial only within the rounded ends)
        float2 sp = float2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
        float2 dir = (q.x > 0.0 && q.y > 0.0) ? normalize(q) : (q.x > q.y ? float2(1.0, 0.0) : float2(0.0, 1.0));
        dir *= sp;
        float ny2 = dir.y * dir.y;
        float amount = mix(uniforms.warp.x, uniforms.warp.y, ny2);
        float fade = 1.0 - smoothstep(uniforms.warp.z, uniforms.warp.z + max(uniforms.warp.w, 0.01), inset);
        sample_local = clamp(local - dir * amount * fade, float2(0.0), uniforms.rect_size - 1.0);
    }
    float2 source_uv = uniforms.src_uv_origin.xy + (sample_local / uniforms.rect_size) * uniforms.src_uv_scale;
    source_uv = min(source_uv, uniforms.src_uv_origin.zw);
    float4 source_premul = source_texture.sample(texture_sampler, source_uv);
    source_premul *= zb_rounded_rect_mask(local - uniforms.params.w, uniforms.rect_size - 2.0 * uniforms.params.w, uniforms.params.z) * zb_clip_coverage(fragment_pixel, uniforms);
    float4 source = zb_unpremul(source_premul);
    float4 destination = zb_unpremul(destination_premul);

    float3 blended;
    switch (uint(uniforms.params.y)) {
        case 1u:  blended = zb_multiply(source.rgb, destination.rgb);    break;
        case 2u:  blended = zb_screen(source.rgb, destination.rgb);      break;
        case 3u:  blended = zb_overlay(source.rgb, destination.rgb);     break;
        case 4u:  blended = zb_darken(source.rgb, destination.rgb);      break;
        case 5u:  blended = zb_lighten(source.rgb, destination.rgb);     break;
        case 6u:  blended = zb_color_dodge(source.rgb, destination.rgb); break;
        case 7u:  blended = zb_color_burn(source.rgb, destination.rgb);  break;
        case 8u:  blended = zb_hard_light(source.rgb, destination.rgb);  break;
        case 9u:  blended = zb_soft_light(source.rgb, destination.rgb);  break;
        case 10u: blended = zb_difference(source.rgb, destination.rgb);  break;
        case 11u: blended = zb_exclusion(source.rgb, destination.rgb);   break;
        default:  blended = source.rgb; break;
    }

    float source_alpha = source.a * uniforms.params.x;
    float result_alpha = source_alpha + destination.a * (1.0 - source_alpha);
    float3 result_rgb = float3(0.0);
    if (result_alpha >= 0.0001) {
        result_rgb = (
            (1.0 - source_alpha) * destination.a * destination.rgb +
            source_alpha * destination.a * blended +
            (1.0 - destination.a) * source_alpha * source.rgb
        ) / result_alpha;
    }
    return float4(result_rgb * result_alpha, result_alpha);
}
