#version 430
#if defined(GL_EXT_control_flow_attributes)
#extension GL_EXT_control_flow_attributes : require
#define SPIRV_CROSS_FLATTEN [[flatten]]
#define SPIRV_CROSS_BRANCH [[dont_flatten]]
#define SPIRV_CROSS_UNROLL [[unroll]]
#define SPIRV_CROSS_LOOP [[dont_unroll]]
#else
#define SPIRV_CROSS_FLATTEN
#define SPIRV_CROSS_BRANCH
#define SPIRV_CROSS_UNROLL
#define SPIRV_CROSS_LOOP
#endif
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
    uint frame_seed;
};

layout(binding = 0, std140) uniform Params
{
    Uniforms uniforms;
} _273;

layout(location = 0) in vec2 input_local_pos;
layout(location = 1) in vec2 input_size;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 6) flat in vec4 input_solid_fill;
layout(location = 11) flat in uint input_solid_shape;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _912 = vec4(0.0);
    do
    {
        SPIRV_CROSS_BRANCH
        if (input_solid_shape == 99u)
        {
            if (input_solid_fill.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _912 = vec4(input_solid_fill.xyz * input_solid_fill.w, input_solid_fill.w);
            break;
        }
        vec2 _751 = abs(input_local_pos) - input_size;
        float _764 = min(max(_751.x, _751.y), 0.0) + length(max(_751, vec2(0.0)));
        float _770 = dFdxFine(_764);
        float _772 = dFdyFine(_764);
        float _685 = max(length(vec2(_770, _772)) * 0.5, 0.5);
        float _693 = input_solid_fill.w * smoothstep(_685, -_685, _764);
        float _911 = 0.0;
        do
        {
            if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
            {
                _911 = 1.0;
                break;
            }
            vec2 _847 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _273.uniforms.scale_factor)) - ((input_rect_clip.zw * _273.uniforms.scale_factor) * 0.5);
            float _860 = min(max(_847.x, _847.y), 0.0) + length(max(_847, vec2(0.0)));
            float _833 = max((abs(dFdxFine(_860)) + abs(dFdyFine(_860))) * 0.5, 0.5);
            _911 = smoothstep(_833, -_833, _860);
            break;
        } while(false);
        vec4 _714 = vec4(input_solid_fill.xyz * _693, _693) * _911;
        if (_714.w < 0.001000000047497451305389404296875)
        {
            discard;
        }
        _912 = _714;
        break;
    } while(false);
    _entryPointOutput = _912;
}

