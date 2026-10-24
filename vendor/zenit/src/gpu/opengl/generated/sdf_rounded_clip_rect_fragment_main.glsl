#version 430
#extension GL_ARB_derivative_control : require
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
} _1780;

layout(location = 0) in vec2 input_local_pos;
layout(location = 1) in vec2 input_size;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 6) flat in vec4 input_solid_fill;
layout(location = 7) flat in vec4 input_solid_border;
layout(location = 8) flat in vec4 input_solid_radii;
layout(location = 9) flat in vec4 input_solid_widths;
layout(location = 10) flat in vec3 input_solid_metrics;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _6795 = vec4(0.0);
    do
    {
        vec4 _3344 = input_solid_radii * _1780.uniforms.scale_factor;
        float _3359 = input_solid_metrics.x * _1780.uniforms.scale_factor;
        bool _4236 = input_local_pos.y < 0.0;
        float _4250 = (input_local_pos.x < 0.0) ? (_4236 ? _3344.x : _3344.w) : (_4236 ? _3344.y : _3344.z);
        vec2 _4257 = (abs(input_local_pos) - input_size) + vec2(_4250);
        float _4269 = (min(max(_4257.x, _4257.y), 0.0) + length(max(_4257, vec2(0.0)))) - _4250;
        float _4484 = dFdxFine(_4269);
        float _4486 = dFdyFine(_4269);
        float _3438 = max(length(vec2(_4484, _4486)) * 0.5, 0.5);
        float _4497 = -_3438;
        float _4499 = smoothstep(_3438, _4497, _4269);
        float _6666 = 0.0;
        do
        {
            if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
            {
                _6666 = 1.0;
                break;
            }
            vec2 _4577 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1780.uniforms.scale_factor)) - ((input_rect_clip.zw * _1780.uniforms.scale_factor) * 0.5);
            float _4590 = min(max(_4577.x, _4577.y), 0.0) + length(max(_4577, vec2(0.0)));
            float _4563 = max((abs(dFdxFine(_4590)) + abs(dFdyFine(_4590))) * 0.5, 0.5);
            _6666 = smoothstep(_4563, -_4563, _4590);
            break;
        } while(false);
        float _4666 = _1780.uniforms.clip_radius * _1780.uniforms.scale_factor;
        vec2 _4823 = (abs(input_screen_pos - ((_1780.uniforms.clip_rect.xy + (_1780.uniforms.clip_rect.zw * 0.5)) * _1780.uniforms.scale_factor)) - ((_1780.uniforms.clip_rect.zw * _1780.uniforms.scale_factor) * 0.5)) + vec2(_4666);
        float _4835 = (min(max(_4823.x, _4823.y), 0.0) + length(max(_4823, vec2(0.0)))) - _4666;
        float _4799 = dFdxFine(_4835);
        float _4802 = dFdyFine(_4835);
        float _4806 = max((abs(_4799) + abs(_4802)) * 0.5, 0.5);
        float _4515 = _6666 * smoothstep(_4806, -_4806, _4835);
        SPIRV_CROSS_BRANCH
        if (((true && (input_solid_metrics.x == 0.0)) && all(equal(input_solid_widths, vec4(0.0)))) && true)
        {
            float _3500 = input_solid_fill.w * _4499;
            vec4 _3515 = vec4(input_solid_fill.xyz * _3500, _3500) * _4515;
            if (_3515.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _6795 = _3515;
            break;
        }
        vec4 _3526 = input_solid_widths * _1780.uniforms.scale_factor;
        float _3528 = _3526.x;
        float _3530 = _3526.y;
        float _3533 = _3526.z;
        float _3536 = _3526.w;
        float _6747 = 0.0;
        if (true && (((((_3528 + _3530) + _3533) + _3536) > 0.0) && true))
        {
            vec4 _3623 = max(_3344 - vec4(max(_3528, _3536), max(_3528, _3530), max(_3533, _3530), max(_3533, _3536)), vec4(0.0));
            vec2 _3627 = input_local_pos - vec2((_3536 - _3530) * 0.5, (_3528 - _3533) * 0.5);
            bool _5299 = _3627.y < 0.0;
            float _5313 = (_3627.x < 0.0) ? (_5299 ? _3623.x : _3623.w) : (_5299 ? _3623.y : _3623.z);
            vec2 _5320 = (abs(_3627) - max(vec2(input_size.x - ((_3530 + _3536) * 0.5), input_size.y - ((_3528 + _3533) * 0.5)), vec2(0.0))) + vec2(_5313);
            _6747 = _4499 - smoothstep(_3438, _4497, (min(max(_5320.x, _5320.y), 0.0) + length(max(_5320, vec2(0.0)))) - _5313);
        }
        else
        {
            float _6748 = 0.0;
            if (true && (_3359 > 0.0))
            {
                _6748 = _4499 - smoothstep(_3438, _4497, _4269 + _3359);
            }
            else
            {
                _6748 = 0.0;
            }
            _6747 = _6748;
        }
        vec4 _6934 = vec4(0.0);
        if (_4499 > 0.0)
        {
            float _3668 = input_solid_fill.w * _4499;
            _6934 = vec4(input_solid_fill.xyz * _3668, _3668) * 1.0;
        }
        else
        {
            _6934 = vec4(0.0);
        }
        vec4 _6935 = vec4(0.0);
        if (_6747 > 0.0)
        {
            float _3694 = input_solid_border.w * _6747;
            _6935 = _6934 + (vec4(input_solid_border.xyz * _3694, _3694) * (1.0 - _6934.w));
        }
        else
        {
            _6935 = _6934;
        }
        vec4 _3714 = _6935 * _4515;
        if (_3714.w < 0.001000000047497451305389404296875)
        {
            discard;
        }
        _6795 = _3714;
        break;
    } while(false);
    _entryPointOutput = _6795;
}

