// HLSL physics mirror of src/render/shaders/glass.metal v15.
// Two independent D2D inputs; shader runs in linear premultiplied light.
static const char glass_shader[]=R"hlsl(
cbuffer Params:register(b0){
 float4 extent,rect,radii,tint,specular,optic,surface,bottom,lens,edge,positions,strengths;
 float4 local0,local1,forward0,forward1;
};
Texture2D<float4> blur_tex:register(t0);SamplerState blur_sampler:register(s0);
Texture2D<float4> sharp_tex:register(t1);SamplerState sharp_sampler:register(s1);
float sdf_rr(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}
float2 sdf_grad(float2 p, float2 b, float r) {
    const float h = 0.8;
    float2 n = float2(
        sdf_rr(p + float2(h,0), b, r) - sdf_rr(p - float2(h,0), b, r),
        sdf_rr(p + float2(0,h), b, r) - sdf_rr(p - float2(0,h), b, r)
    );
    float m = length(n);
    return m > 1e-5 ? n / m : float2(0, -1);
}
float luma(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}
float3 saturate_color(float3 c, float sat) {
    float l = luma(c);
    return clamp(lerp(float3(l,l,l), c, sat), 0.0, 1.0);
}
struct SurfaceSample {
    float height;
    float slope;
    float center_bias;
};
static const float kDispersionIOR_R = 1.430;
static const float kDispersionIOR_G = 1.450;
static const float kDispersionIOR_B = 1.478;
float circle_height(float t) {
    float omt = 1.0 - saturate(t);
    return sqrt(max(1.0 - omt * omt, 0.0));
}
float circle_deriv(float t) {
    float omt = 1.0 - saturate(t);
    float base = max(circle_height(t), 1e-5);
    return omt / base;
}
float squircle_height(float t) {
    float omt = 1.0 - saturate(t);
    return pow(max(1.0 - omt * omt * omt * omt, 1e-6), 0.25);
}
float squircle_deriv(float t) {
    t = saturate(t);
    float omt = 1.0 - t;
    float poly = omt * omt * omt * omt;
    float base = max(1.0 - poly, 1e-6);
    return (omt * omt * omt) / pow(base, 0.75);
}
SurfaceSample make_surface(float h,float s,float b) { SurfaceSample r; r.height=h;r.slope=s;r.center_bias=b;return r; }
SurfaceSample sample_surface(uint kind, float t) {
    t = saturate(t);
    if (kind == 0) {
        return make_surface( 0.0, 0.0, 0.0 );
    }
    if (kind == 1) {
        return make_surface( circle_height(t), circle_deriv(t) * 1.08, 0.18 );
    }
    if (kind == 3) {
        return make_surface( 1.0 - squircle_height(t), -squircle_deriv(t), -0.42 );
    }
    if (kind == 4) {
        float outer_h = circle_height(t) * 1.06;
        float inner_h = (1.0 - squircle_height(t)) * 1.18;
        float blend = smoothstep(0.18, 0.68, t);
        return make_surface(
            lerp(outer_h, inner_h, blend),
            lerp(circle_deriv(t) * 1.08, -squircle_deriv(t) * 1.26, blend),
            -0.42
        );
    }
    return make_surface( squircle_height(t), squircle_deriv(t), 0.05 );
}
float snell_displacement(float slope, float height, float thickness_px, float bezel_w, float ior) {
    float physical_slope = slope * thickness_px / max(bezel_w, 1.0);
    // tan(asin(sin(atan(q))/n)) = q / sqrt(n*n + (n*n-1)*q*q).
    // All dispersion IORs exceed one, so the denominator stays positive.
    // Preserve Snell's law without five transcendental operations per channel.
    float ior2 = ior * ior;
    float refracted_tangent = physical_slope * rsqrt(ior2 + (ior2 - 1.0) * physical_slope * physical_slope);
    return height * thickness_px * (physical_slope - refracted_tangent);
}
float4 main(float4 pixel:SV_POSITION,float4 scene:SCENE_POSITION,float4 uv0:TEXCOORD0,float4 uv1:TEXCOORD1):SV_Target {
    float gi  = clamp(rect.w,         0.0,  2.0);
    float gi_gate = clamp(gi, 0.0, 1.0);
    float sop = clamp(specular.x,       0.0,  1.0);
    float sst = clamp(specular.y,       1.0, 12.0);
    float rl  = clamp(specular.z,       0.0,  1.0);
    float bl  = clamp(specular.w,       0.0,  1.0);
    float wg  = clamp(optic.x,          0.0,  3.0);
    float ct  = clamp(optic.y,          0.0, 20.0);
    float gap = clamp(optic.z,          0.0, 40.0);
    uint  top_surface_kind = (uint)clamp(round(surface.x), 0.0, 4.0);
    float top_bezel_ratio  = clamp(surface.y, 0.04, 0.45);
    float spec_angle       = surface.z;
    float magnify          = clamp(surface.w, -1.0, 2.0);
    uint  bottom_surface_kind = (uint)clamp(round(bottom.x), 0.0, 4.0);
    float bottom_bezel_ratio  = clamp(bottom.y, 0.04, 0.45);
    float field_radius        = clamp(lens.x, 0.1, 1.5);
    float field_falloff       = clamp(lens.y, 0.4, 6.0);
    float edge_field_strength = clamp(lens.z, 0.2, 4.0);
    float scale_ratio         = clamp(lens.w, 0.35, 1.6);
    float s=max(rect.z,.1);
    float2 rect_px=max(rect.xy,float2(2,2));
    float2 half_px=rect_px*.5;
    float mh=max(min(half_px.x,half_px.y),1);
    float2 p=float2(dot(scene.xy,local0.xy)+local0.z,dot(scene.xy,local1.xy)+local1.z);
    float2 node_uv=p/rect_px+.5;
    float cr=clamp(p.y<0?(p.x<0?radii.x:radii.y):(p.x<0?radii.w:radii.z),0,mh);
    float  d    = sdf_rr(p, half_px, cr);
    float  aa   = max(fwidth(d) * 0.5, 0.5);
    float  mask = smoothstep(aa, -aa, d);
    float  inset = max(-d, 0.0);
    float2 out_n = sdf_grad(p, half_px, cr);
    float  top_bezel_w = clamp(mh * top_bezel_ratio, 2.0, mh);
    float  bottom_bezel_w = clamp(mh * bottom_bezel_ratio, 2.0, mh);
    float  t_top    = clamp(inset / top_bezel_w, 0.0, 1.0);
    float  t_bottom = clamp(inset / bottom_bezel_w, 0.0, 1.0);
    SurfaceSample top_surf = sample_surface(top_surface_kind, t_top);
    SurfaceSample bot_surf = sample_surface(bottom_surface_kind, t_bottom);
    float  top_edge_factor = pow(1.0 - t_top, 2.3);
    float  bottom_edge_factor = pow(1.0 - t_bottom, 2.1);
    float  top_thick = min(top_bezel_w * (0.52 + 0.48 * top_surf.height), 20.0);
    float  bottom_thick = min(bottom_bezel_w * (0.38 + 0.58 * bot_surf.height), 20.0);
    float  gap_scale = 1.0 + min(gap * 0.085, 2.6);
    float  d_eff = max(
        ct +
        top_thick * (0.38 + top_edge_factor * 0.62) +
        bottom_thick * (0.24 + bottom_edge_factor * 0.76) +
        gap * 0.78,
        0.5
    );
    float  tilt = 0.52 + gap * 0.01;
    float  top_slope_n = top_surf.slope * tilt * (0.30 + 0.70 * (1.0 - t_top));
    float  bottom_presence = clamp(abs(bot_surf.center_bias) + abs(bot_surf.height) * 0.26, 0.0, 1.4);
    float  bot_slope_n = bot_surf.slope * tilt * (0.18 + 0.38 * rl + bottom_presence * 0.22) * (0.25 + 0.75 * (1.0 - t_bottom));
    float  scale_t = saturate((scale_ratio - 0.35) / 1.25);
    float  slab_t = saturate(inset / max(mh, 0.001));
    float  spread_gain = lerp(1.15, 3.75, scale_t);
    float  body_t = 1.0 - pow(saturate(1.0 - slab_t), spread_gain);
    float  body_coord = 1.0 - slab_t;
    SurfaceSample top_body = sample_surface(top_surface_kind, body_t);
    SurfaceSample bot_body = sample_surface(bottom_surface_kind, body_t);
    float  body_profile = top_body.height + bot_body.height * 0.55;
    float  body_t_slope = spread_gain * pow(saturate(1.0 - slab_t), max(spread_gain - 1.0, 0.0)) / max(mh, 0.001);
    float  body_profile_slope = (top_body.slope + bot_body.slope * 0.55) * tilt * body_t_slope;
    float  field_cover = max(saturate((field_radius - 0.1) / 1.4), 0.02);
    float  field_hardness = saturate((field_falloff - 0.4) / 5.6);
    float  field_base = 1.0 - exp(-body_t * (0.8 + field_cover * 4.2));
    float  field_envelope = pow(saturate(field_base), lerp(0.78, 2.4, field_hardness));
    float  body_grad_gain = 0.18 + 0.82 * pow(saturate(1.0 - body_coord), 0.55) * (0.28 + 0.72 * field_envelope);
    float2 ellipse_axis = max(half_px - float2(cr * 0.35,cr * 0.35), float2(1.0,1.0));
    float2 ellipse_p = p / ellipse_axis;
    float2 radial_dir = normalize(dot(ellipse_p,ellipse_p)>1e-6?ellipse_p:float2(0,-1));
    float  body_dir_mix = smoothstep(0.10, 0.92, body_t);
    float2 body_dir = normalize(lerp(out_n, radial_dir, body_dir_mix));
    float2 body_grad = -body_dir * body_profile_slope * body_grad_gain;
    float2 edge_grad = out_n * (top_slope_n + bot_slope_n) * (0.16 + 0.34 * top_edge_factor + 0.10 * bottom_edge_factor);
    float3 N = normalize(float3(body_grad + edge_grad, 1.0));
    float  combined_slope = top_surf.slope + bot_surf.slope * 0.55;
    float  combined_height = top_surf.height + bot_surf.height * 0.55;
    float  total_slope = lerp(combined_slope, top_body.slope + bot_body.slope * 0.55, body_t);
    float  total_height = lerp(combined_height, body_profile, body_t);
    float  effective_bezel = lerp(top_bezel_w, mh, body_t) * scale_ratio;
    float  disp_r = snell_displacement(total_slope, total_height, d_eff, effective_bezel, kDispersionIOR_R);
    float  disp_g = snell_displacement(total_slope, total_height, d_eff, effective_bezel, kDispersionIOR_G);
    float  disp_b = snell_displacement(total_slope, total_height, d_eff, effective_bezel, kDispersionIOR_B);
    float  edge_boost = lerp(edge_field_strength, 1.0, body_t);
    disp_r *= edge_boost;
    disp_g *= edge_boost;
    disp_b *= edge_boost;
    float  body_disp_envelope = 0.15 + 0.85 * field_envelope;
    disp_r *= lerp(1.0, body_disp_envelope, body_t);
    disp_g *= lerp(1.0, body_disp_envelope, body_t);
    disp_b *= lerp(1.0, body_disp_envelope, body_t);
    float  rl_wg = rl * wg * gi_gate;
    disp_r *= rl_wg * gap_scale;
    disp_g *= rl_wg * gap_scale;
    disp_b *= rl_wg * gap_scale;
    float2 disp_dir = normalize(lerp(out_n, radial_dir, body_dir_mix));
    float2 disp_scene=float2(dot(disp_dir,forward0.xy),dot(disp_dir,forward1.xy));
    float2 offset_r=clamp(disp_scene*disp_r,-extent.xy*.45,extent.xy*.45);
    float2 offset_g=clamp(disp_scene*disp_g,-extent.xy*.45,extent.xy*.45);
    float2 offset_b=clamp(disp_scene*disp_b,-extent.xy*.45,extent.xy*.45);
    float magnify_mix=clamp(magnify*(.10+.26*field_envelope),-.55,.75);
    float2 center=float2(forward0.z,forward1.z);
    float2 sample_position=center+(scene.xy-center)*(1-magnify_mix);
    float2 uvr=clamp(sample_position+offset_r,.5,extent.xy-.5);
    float2 uvg=clamp(sample_position+offset_g,.5,extent.xy-.5);
    float2 uvb=clamp(sample_position+offset_b,.5,extent.xy-.5);
    float rim_sharp_w = min(top_bezel_w, 8.0 * s);
    float t_rim = clamp(inset / rim_sharp_w, 0.0, 1.0);
    float rim_sharp = (1.0 - smoothstep(0.0, 0.85, t_rim)) * step(0.5, (float)(top_surface_kind != 0)) * gi_gate;
    float local_bl = bl;
    float gradient_scale = 1.0;
    if (edge.x > 0.5 && edge.z > 0.001) {
        int   grad_dir = int(edge.x + 0.5);
        float gt = (grad_dir == 1) ? node_uv.y
                 : (grad_dir == 2) ? (1.0 - node_uv.y)
                 : (grad_dir == 3) ? node_uv.x
                 : (1.0 - node_uv.x);
        gt = clamp(gt, 0.0, 1.0);
        int   stop_n = clamp(int(edge.w + 0.5), 2, 4);
        float prof = strengths[0];
        for (int i = 0; i < stop_n - 1; i++) {
            float p0 = positions[i];
            float p1 = max(positions[i + 1], p0 + 1e-4);
            if (gt >= p0)
                prof = lerp(strengths[i], strengths[i + 1], smoothstep(p0, p1, gt));
        }
        float str  = clamp(edge.z, 0.0, 1.0);
        float pf   = clamp(prof, 0.0, 1.0);
        gradient_scale = lerp(1.0, pf, str);
        local_bl = lerp(bl, pf, str);
    }
    float effective_blur = clamp(local_bl + gap * 0.045 * gradient_scale, 0.0, 1.0) * (1.0 - rim_sharp * 0.85);
    float4 br = blur_tex.Sample(blur_sampler, uv0.xy+(uvr-scene.xy)*uv0.zw);
    float4 bg = blur_tex.Sample(blur_sampler, uv0.xy+(uvg-scene.xy)*uv0.zw);
    float4 bb = blur_tex.Sample(blur_sampler, uv0.xy+(uvb-scene.xy)*uv0.zw);
    float3 blur_c = float3(br.r / max(br.a, 1e-3),
                           bg.g / max(bg.a, 1e-3),
                           bb.b / max(bb.a, 1e-3));
    float4 sr = sharp_tex.Sample(sharp_sampler, uv1.xy+(uvr-scene.xy)*uv1.zw);
    float4 sg = sharp_tex.Sample(sharp_sampler, uv1.xy+(uvg-scene.xy)*uv1.zw);
    float4 sb = sharp_tex.Sample(sharp_sampler, uv1.xy+(uvb-scene.xy)*uv1.zw);
    float3 sharp_c = float3(lerp(blur_c.r, sr.r / max(sr.a, 1e-3), saturate(sr.a)),
                            lerp(blur_c.g, sg.g / max(sg.a, 1e-3), saturate(sg.a)),
                            lerp(blur_c.b, sb.b / max(sb.a, 1e-3), saturate(sb.a)));
    float3 base = lerp(blur_c, sharp_c, 1.0 - effective_blur);
    float bd_sat = bottom.z;
    float bd_bri = bottom.w;
    if (abs(bd_sat - 1.0) > 1e-3) base = saturate_color(base, bd_sat);
    if (abs(bd_bri - 1.0) > 1e-3) base = clamp(base * bd_bri, 0.0, 1.0);
    float combined_edge = top_edge_factor + bottom_edge_factor * 0.45;
    float sat_boost = lerp(1.0, 1.02 + combined_edge * 0.18, gi_gate);
    base = saturate_color(base, sat_boost);
    float2 screen_light=float2(cos(spec_angle),sin(spec_angle));
    float2 light2d=normalize(float2(dot(screen_light,local0.xy),dot(screen_light,local1.xy)));
    float3 light_dir = normalize(float3(light2d, 0.55));
    float  ndotl     = dot(N, light_dir);
    float  rim_light = smoothstep(-0.3, 1.0, ndotl);
    float  rim_mask  = saturate(top_edge_factor * top_edge_factor + 0.08);
    float3 spec_base = saturate_color(base, sst);
    float3 spec_col  = lerp(spec_base, float3(1.0,1.0,1.0), clamp(rim_light * rim_light + top_surf.height * 0.25, 0.0, 1.0));
    float  spec_str  = clamp(rim_light * rim_mask * sop * gi, 0.0, 1.0);
    base = lerp(base, spec_col, spec_str);
    if (bottom_surface_kind != 0) {
        float  bot_rim_mask = saturate(bottom_edge_factor * bottom_edge_factor);
        float  bot_ndotl    = dot(N, normalize(float3(-light2d * 0.6, 0.75)));
        float  bot_rim      = smoothstep(-0.2, 0.8, bot_ndotl);
        float  bot_spec_str = clamp(bot_rim * bot_rim_mask * sop * gi * 0.30, 0.0, 0.35);
        float3 bot_spec_col = lerp(spec_base, float3(1.0, 1.0, 0.98), bot_rim * 0.5 + bot_surf.height * 0.2);
        base = lerp(base, bot_spec_col, bot_spec_str);
    }
    float cosV     = max(dot(N, float3(0.0, 0.0, -1.0)), 0.0);
    float fresnel  = 0.04 + 0.96 * pow(1.0 - cosV, 5.0);
    float lit_side = max(dot(out_n, light2d), 0.0);
    float rim_w_top = clamp(top_bezel_w * 0.20, 1.5, 5.0);
    float edge_rim_top = 1.0 - smoothstep(0.0, rim_w_top, inset);
    float f_str_top = clamp(fresnel * lit_side * edge_rim_top * (0.78 + gap * 0.015), 0.0, 0.9) * gi_gate;
    base = lerp(base, float3(1.0, 1.0, 1.02), f_str_top);
    if (bottom_surface_kind != 0) {
        float rim_w_bot = clamp(bottom_bezel_w * 0.20, 1.5, 5.0);
        float edge_rim_bot = 1.0 - smoothstep(0.0, rim_w_bot, inset);
        float f_str_bot = clamp(fresnel * lit_side * edge_rim_bot * 0.35, 0.0, 0.4) * gi_gate;
        base = lerp(base, float3(1.0, 1.0, 1.01), f_str_bot);
    }
    float2 shad2d = -light2d;
    float  edge_rim_combined = edge_rim_top;
    if (bottom_surface_kind != 0) {
        float rim_w_bot2 = clamp(bottom_bezel_w * 0.20, 1.5, 5.0);
        edge_rim_combined = max(edge_rim_top, (1.0 - smoothstep(0.0, rim_w_bot2, inset)) * 0.5);
    }
    float  shad_str = clamp(edge_rim_combined * max(dot(out_n, shad2d), 0.0) * 0.22, 0.0, 0.4) * gi_gate;
    base = base * (1.0 - shad_str);
    float ta = clamp(tint.a, 0.0, 1.0);
    if (ta > 0.005) {
        const float d_ref = 8.0;
        float3 T_ref = lerp(float3(1.0,1.0,1.0), clamp(tint.rgb, float3(0.0,0.0,0.0), float3(1.0,1.0,1.0)), ta * 0.60);
        T_ref = max(T_ref, float3(0.05,0.05,0.05));
        float3 sigma_a = -log(T_ref) / d_ref;
        float  d_eff_clamped = clamp(d_eff, 0.0, 50.0);
        float3 absorb = exp(-sigma_a * d_eff_clamped);
        absorb = clamp(absorb, float3(0.02,0.02,0.02), float3(1.0,1.0,1.0));
        base = base * absorb;
    }
    base = clamp(base, 0.0, 1.0);
    return float4(base,1);
}
)hlsl";
