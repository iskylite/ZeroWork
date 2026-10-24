#version 430
#extension GL_ARB_derivative_control : require

struct Uniforms
{
    vec2 viewport_size;
    float scale_factor;
    uint clip_shape_kind;
    vec4 clip_rect;
    float clip_radius;
    uint clip_fill_rule;
    uint clip_point_count;
    uint clip_contour_count;
    uvec4 clip_polygon_end_points[2];
    vec4 clip_polygon_points[16];
};

layout(binding = 0, std140) uniform ImageParams
{
    Uniforms uniforms;
} _777;

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combinedimage_textureimage_sampler;

layout(location = 0) in vec2 input_uv;
layout(location = 1) in vec2 input_local_pos;
layout(location = 2) in vec2 input_size;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 5) flat in vec4 input_tint_color;
layout(location = 6) flat in vec3 input_material;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    float _1102 = input_material.x * _777.uniforms.scale_factor;
    vec4 _1108 = texture(SPIRV_Cross_Combinedimage_textureimage_sampler, input_uv);
    vec4 _1112 = _1108 * input_tint_color;
    float _2172 = 0.0;
    if (_1102 > 0.0)
    {
        vec2 _1191 = (abs(input_local_pos) - input_size) + vec2(_1102);
        float _1203 = (min(max(_1191.x, _1191.y), 0.0) + length(max(_1191, vec2(0.0)))) - _1102;
        float _1128 = abs(dFdxFine(_1203)) + abs(dFdyFine(_1203));
        _2172 = smoothstep(_1128 * 0.5, _1128 * (-0.5), _1203);
    }
    else
    {
        _2172 = 1.0;
    }
    float _2129 = 0.0;
    do
    {
        if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
        {
            _2129 = 1.0;
            break;
        }
        vec2 _1281 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _777.uniforms.scale_factor)) - ((input_rect_clip.zw * _777.uniforms.scale_factor) * 0.5);
        float _1294 = min(max(_1281.x, _1281.y), 0.0) + length(max(_1281, vec2(0.0)));
        float _1267 = max((abs(dFdxFine(_1294)) + abs(dFdyFine(_1294))) * 0.5, 0.5);
        _2129 = smoothstep(_1267, -_1267, _1294);
        break;
    } while(false);
    float _1149 = (_2172 * _2129) * input_material.y;
    vec4 _2264 = vec4(0.0);
    if (input_material.z > 0.5)
    {
        _2264 = _1112 * _1149;
    }
    else
    {
        float _1161 = _1112.w * _1149;
        _2264 = vec4(_1112.xyz * _1161, _1161);
    }
    if (_2264.w < 0.001000000047497451305389404296875)
    {
        discard;
    }
    _entryPointOutput = _2264;
}

