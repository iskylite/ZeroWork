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
layout(location = 11) flat in uint input_solid_shape;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _6860 = vec4(0.0);
    do
    {
        SPIRV_CROSS_BRANCH
        if (input_solid_shape == 99u)
        {
            if (input_solid_fill.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _6860 = vec4(input_solid_fill.xyz * input_solid_fill.w, input_solid_fill.w);
            break;
        }
        vec4 _6859 = vec4(0.0);
        do
        {
            vec4 _3401 = input_solid_radii * _1780.uniforms.scale_factor;
            float _3416 = input_solid_metrics.x * _1780.uniforms.scale_factor;
            bool _4293 = input_local_pos.y < 0.0;
            float _4307 = (input_local_pos.x < 0.0) ? (_4293 ? _3401.x : _3401.w) : (_4293 ? _3401.y : _3401.z);
            vec2 _4314 = (abs(input_local_pos) - input_size) + vec2(_4307);
            float _4326 = (min(max(_4314.x, _4314.y), 0.0) + length(max(_4314, vec2(0.0)))) - _4307;
            float _4541 = dFdxFine(_4326);
            float _4543 = dFdyFine(_4326);
            float _3495 = max(length(vec2(_4541, _4543)) * 0.5, 0.5);
            float _4554 = -_3495;
            float _4556 = smoothstep(_3495, _4554, _4326);
            float _6730 = 0.0;
            do
            {
                if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
                {
                    _6730 = 1.0;
                    break;
                }
                vec2 _4634 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1780.uniforms.scale_factor)) - ((input_rect_clip.zw * _1780.uniforms.scale_factor) * 0.5);
                float _4647 = min(max(_4634.x, _4634.y), 0.0) + length(max(_4634, vec2(0.0)));
                float _4620 = max((abs(dFdxFine(_4647)) + abs(dFdyFine(_4647))) * 0.5, 0.5);
                _6730 = smoothstep(_4620, -_4620, _4647);
                break;
            } while(false);
            float _6770 = 0.0;
            do
            {
                if (_1780.uniforms.clip_shape_kind == 0u)
                {
                    _6770 = 1.0;
                    break;
                }
                vec2 _4707 = (_1780.uniforms.clip_rect.xy + (_1780.uniforms.clip_rect.zw * 0.5)) * _1780.uniforms.scale_factor;
                vec2 _4714 = (_1780.uniforms.clip_rect.zw * _1780.uniforms.scale_factor) * 0.5;
                float _6768 = 0.0;
                if (_1780.uniforms.clip_shape_kind == 1u)
                {
                    float _4723 = _1780.uniforms.clip_radius * _1780.uniforms.scale_factor;
                    vec2 _4880 = (abs(input_screen_pos - _4707) - _4714) + vec2(_4723);
                    _6768 = (min(max(_4880.x, _4880.y), 0.0) + length(max(_4880, vec2(0.0)))) - _4723;
                }
                else
                {
                    float _6769 = 0.0;
                    if (_1780.uniforms.clip_shape_kind == 2u)
                    {
                        _6769 = length((input_screen_pos - _4707) / max(_4714, vec2(0.001000000047497451305389404296875))) - 1.0;
                    }
                    else
                    {
                        if (_1780.uniforms.clip_shape_kind == 3u)
                        {
                            uint _4747 = min(_1780.uniforms.clip_point_count, 32u);
                            uint _4750 = min(_1780.uniforms.clip_contour_count, 8u);
                            if ((_4747 < 3u) || (_4750 == 0u))
                            {
                                _6770 = 1.0;
                                break;
                            }
                            vec2 _4765 = input_screen_pos - (_1780.uniforms.clip_rect.xy * _1780.uniforms.scale_factor);
                            bool _6751 = false;
                            do
                            {
                                if (_1780.uniforms.clip_fill_rule == 0u)
                                {
                                    bool _6750 = false;
                                    _6750 = false;
                                    uint _4943 = 0u;
                                    bool _6873 = false;
                                    for (uint _6749 = 0u, _6760 = 0u; _6749 < _4750; _6760 = _4943, _6750 = _6873, _6749++)
                                    {
                                        _4943 = min(_1780.uniforms.clip_polygon_end_points[_6749 / 4u][_6749 % 4u], _4747);
                                        if (_4943 <= (_6760 + 1u))
                                        {
                                            _6873 = _6750;
                                            continue;
                                        }
                                        bool _6763 = false;
                                        _6763 = _6750;
                                        bool _6878 = false;
                                        for (uint _6761 = _6760; _6761 < _4943; _6763 = _6878, _6761++)
                                        {
                                            uint _4959 = _6761 + 1u;
                                            uint _4965 = (_4959 < _4943) ? _4959 : _6760;
                                            uint _5058 = _6761 / 2u;
                                            bvec2 _5068 = bvec2((_6761 % 2u) == 0u);
                                            vec2 _4971 = vec2(_5068.x ? _1780.uniforms.clip_polygon_points[_5058].xy.x : _1780.uniforms.clip_polygon_points[_5058].zw.x, _5068.y ? _1780.uniforms.clip_polygon_points[_5058].xy.y : _1780.uniforms.clip_polygon_points[_5058].zw.y) * _1780.uniforms.scale_factor;
                                            uint _5074 = _4965 / 2u;
                                            bvec2 _5084 = bvec2((_4965 % 2u) == 0u);
                                            vec2 _4977 = vec2(_5084.x ? _1780.uniforms.clip_polygon_points[_5074].xy.x : _1780.uniforms.clip_polygon_points[_5074].zw.x, _5084.y ? _1780.uniforms.clip_polygon_points[_5074].xy.y : _1780.uniforms.clip_polygon_points[_5074].zw.y) * _1780.uniforms.scale_factor;
                                            float _4979 = _4977.y;
                                            float _4981 = _4971.y;
                                            float _4982 = _4979 - _4981;
                                            float _4994 = _4765.y;
                                            float _5007 = _4971.x;
                                            if (((_4981 > _4994) != (_4979 > _4994)) && (_4765.x < ((((_4977.x - _5007) * (_4994 - _4981)) / ((abs(_4982) < 9.9999997473787516355514526367188e-05) ? ((_4982 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _4982)) + _5007)))
                                            {
                                                _6878 = !_6763;
                                            }
                                            else
                                            {
                                                _6878 = _6763;
                                            }
                                        }
                                        _6873 = _6763;
                                    }
                                    _6751 = _6750;
                                    break;
                                }
                                int _6732 = 0;
                                _6732 = 0;
                                uint _5114 = 0u;
                                int _6861 = 0;
                                for (uint _6731 = 0u, _6733 = 0u; _6731 < _4750; _6733 = _5114, _6732 = _6861, _6731++)
                                {
                                    _5114 = min(_1780.uniforms.clip_polygon_end_points[_6731 / 4u][_6731 % 4u], _4747);
                                    if (_5114 <= (_6733 + 1u))
                                    {
                                        _6861 = _6732;
                                        continue;
                                    }
                                    int _6736 = 0;
                                    _6736 = _6732;
                                    int _6868 = 0;
                                    for (uint _6734 = _6733; _6734 < _5114; _6736 = _6868, _6734++)
                                    {
                                        uint _5130 = _6734 + 1u;
                                        uint _5136 = (_5130 < _5114) ? _5130 : _6733;
                                        uint _5251 = _6734 / 2u;
                                        bvec2 _5261 = bvec2((_6734 % 2u) == 0u);
                                        vec2 _5142 = vec2(_5261.x ? _1780.uniforms.clip_polygon_points[_5251].xy.x : _1780.uniforms.clip_polygon_points[_5251].zw.x, _5261.y ? _1780.uniforms.clip_polygon_points[_5251].xy.y : _1780.uniforms.clip_polygon_points[_5251].zw.y) * _1780.uniforms.scale_factor;
                                        uint _5267 = _5136 / 2u;
                                        bvec2 _5277 = bvec2((_5136 % 2u) == 0u);
                                        vec2 _5148 = vec2(_5277.x ? _1780.uniforms.clip_polygon_points[_5267].xy.x : _1780.uniforms.clip_polygon_points[_5267].zw.x, _5277.y ? _1780.uniforms.clip_polygon_points[_5267].xy.y : _1780.uniforms.clip_polygon_points[_5267].zw.y) * _1780.uniforms.scale_factor;
                                        float _5150 = _5142.y;
                                        float _5152 = _4765.y;
                                        if (_5150 <= _5152)
                                        {
                                            float _5156 = _5148.y;
                                            int _6869 = 0;
                                            if (_5156 > _5152)
                                            {
                                                float _5164 = _5142.x;
                                                int _6870 = 0;
                                                if ((((_5148.x - _5164) * (_5152 - _5150)) - ((_4765.x - _5164) * (_5156 - _5150))) > 0.0)
                                                {
                                                    _6870 = _6736 + 1;
                                                }
                                                else
                                                {
                                                    _6870 = _6736;
                                                }
                                                _6869 = _6870;
                                            }
                                            else
                                            {
                                                _6869 = _6736;
                                            }
                                            _6868 = _6869;
                                        }
                                        else
                                        {
                                            float _5193 = _5148.y;
                                            int _6871 = 0;
                                            if (_5193 <= _5152)
                                            {
                                                float _5201 = _5142.x;
                                                int _6872 = 0;
                                                if ((((_5148.x - _5201) * (_5152 - _5150)) - ((_4765.x - _5201) * (_5193 - _5150))) < 0.0)
                                                {
                                                    _6872 = _6736 - 1;
                                                }
                                                else
                                                {
                                                    _6872 = _6736;
                                                }
                                                _6871 = _6872;
                                            }
                                            else
                                            {
                                                _6871 = _6736;
                                            }
                                            _6868 = _6871;
                                        }
                                    }
                                    _6861 = _6736;
                                }
                                _6751 = _6732 != 0;
                                break;
                            } while(false);
                            float _6753 = 0.0;
                            uint _6754 = 0u;
                            _6754 = 0u;
                            _6753 = uintBitsToFloat(0x7f800000u /* inf */);
                            uint _4782 = 0u;
                            float _6874 = 0.0;
                            for (uint _6752 = 0u; _6752 < _4750; _6754 = _4782, _6753 = _6874, _6752++)
                            {
                                _4782 = min(_1780.uniforms.clip_polygon_end_points[_6752 / 4u][_6752 % 4u], _4747);
                                if (_4782 <= (_6754 + 1u))
                                {
                                    _6874 = _6753;
                                    continue;
                                }
                                float _6757 = 0.0;
                                _6757 = _6753;
                                for (uint _6755 = _6754; _6755 < _4782; )
                                {
                                    uint _4798 = _6755 + 1u;
                                    uint _4804 = (_4798 < _4782) ? _4798 : _6754;
                                    uint _5291 = _6755 / 2u;
                                    bvec2 _5301 = bvec2((_6755 % 2u) == 0u);
                                    vec2 _4810 = vec2(_5301.x ? _1780.uniforms.clip_polygon_points[_5291].xy.x : _1780.uniforms.clip_polygon_points[_5291].zw.x, _5301.y ? _1780.uniforms.clip_polygon_points[_5291].xy.y : _1780.uniforms.clip_polygon_points[_5291].zw.y) * _1780.uniforms.scale_factor;
                                    uint _5307 = _4804 / 2u;
                                    bvec2 _5317 = bvec2((_4804 % 2u) == 0u);
                                    vec2 _5326 = (vec2(_5317.x ? _1780.uniforms.clip_polygon_points[_5307].xy.x : _1780.uniforms.clip_polygon_points[_5307].zw.x, _5317.y ? _1780.uniforms.clip_polygon_points[_5307].xy.y : _1780.uniforms.clip_polygon_points[_5307].zw.y) * _1780.uniforms.scale_factor) - _4810;
                                    _6757 = min(_6757, length(_4765 - (_4810 + (_5326 * clamp(dot(_4765 - _4810, _5326) / max(dot(_5326, _5326), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                                    _6755++;
                                    continue;
                                }
                                _6874 = _6757;
                            }
                            float _4841 = max(length(vec2(dFdxFine(input_screen_pos.x), dFdyFine(input_screen_pos.y))) * 0.5, 0.75);
                            _6770 = smoothstep(_4841, -_4841, _6751 ? (-_6753) : _6753);
                            break;
                        }
                        _6769 = 1.0;
                    }
                    _6768 = _6769;
                }
                float _4863 = max((abs(dFdxFine(_6768)) + abs(dFdyFine(_6768))) * 0.5, 0.5);
                _6770 = smoothstep(_4863, -_4863, _6768);
                break;
            } while(false);
            float _4572 = _6730 * _6770;
            SPIRV_CROSS_BRANCH
            if (((true && (input_solid_metrics.x == 0.0)) && all(equal(input_solid_widths, vec4(0.0)))) && true)
            {
                float _3557 = input_solid_fill.w * _4556;
                vec4 _3572 = vec4(input_solid_fill.xyz * _3557, _3557) * _4572;
                if (_3572.w < 0.001000000047497451305389404296875)
                {
                    discard;
                }
                _6859 = _3572;
                break;
            }
            vec4 _3583 = input_solid_widths * _1780.uniforms.scale_factor;
            float _3585 = _3583.x;
            float _3587 = _3583.y;
            float _3590 = _3583.z;
            float _3593 = _3583.w;
            float _6811 = 0.0;
            if (true && (((((_3585 + _3587) + _3590) + _3593) > 0.0) && true))
            {
                vec4 _3680 = max(_3401 - vec4(max(_3585, _3593), max(_3585, _3587), max(_3590, _3587), max(_3590, _3593)), vec4(0.0));
                vec2 _3684 = input_local_pos - vec2((_3593 - _3587) * 0.5, (_3585 - _3590) * 0.5);
                bool _5356 = _3684.y < 0.0;
                float _5370 = (_3684.x < 0.0) ? (_5356 ? _3680.x : _3680.w) : (_5356 ? _3680.y : _3680.z);
                vec2 _5377 = (abs(_3684) - max(vec2(input_size.x - ((_3587 + _3593) * 0.5), input_size.y - ((_3585 + _3590) * 0.5)), vec2(0.0))) + vec2(_5370);
                _6811 = _4556 - smoothstep(_3495, _4554, (min(max(_5377.x, _5377.y), 0.0) + length(max(_5377, vec2(0.0)))) - _5370);
            }
            else
            {
                float _6812 = 0.0;
                if (true && (_3416 > 0.0))
                {
                    _6812 = _4556 - smoothstep(_3495, _4554, _4326 + _3416);
                }
                else
                {
                    _6812 = 0.0;
                }
                _6811 = _6812;
            }
            vec4 _7035 = vec4(0.0);
            if (_4556 > 0.0)
            {
                float _3725 = input_solid_fill.w * _4556;
                _7035 = vec4(input_solid_fill.xyz * _3725, _3725) * 1.0;
            }
            else
            {
                _7035 = vec4(0.0);
            }
            vec4 _7036 = vec4(0.0);
            if (_6811 > 0.0)
            {
                float _3751 = input_solid_border.w * _6811;
                _7036 = _7035 + (vec4(input_solid_border.xyz * _3751, _3751) * (1.0 - _7035.w));
            }
            else
            {
                _7036 = _7035;
            }
            vec4 _3771 = _7036 * _4572;
            if (_3771.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _6859 = _3771;
            break;
        } while(false);
        _6860 = _6859;
        break;
    } while(false);
    _entryPointOutput = _6860;
}

