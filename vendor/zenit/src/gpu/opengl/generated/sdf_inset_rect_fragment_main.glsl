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
    uint frame_seed;
};

struct InstanceData
{
    vec4 rect;
    vec4 rect_clip;
    vec4 fill_color;
    vec4 border_color;
    vec4 shadow_color;
    vec4 gradient_to_color;
    vec4 corner_radii;
    float border_width;
    float shadow_blur;
    float shadow_offset_x;
    float shadow_offset_y;
    uint shape_type;
    uint packed_flags;
    float noise_scale;
    float noise_intensity;
    vec4 border_widths;
    uint gradient_stop_offset;
    uint gradient_stop_count;
    uint shadow2_index;
    uint _ext_reserved;
};

layout(binding = 0, std140) uniform Params
{
    Uniforms uniforms;
} _1766;

layout(binding = 1, std430) readonly buffer instances
{
    InstanceData _data[];
} instances_1;

layout(location = 0) in vec2 input_local_pos;
layout(location = 1) in vec2 input_size;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 5) flat in uint input_instance_id;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _3328 = instances_1._data[input_instance_id].corner_radii * _1766.uniforms.scale_factor;
    float _3343 = instances_1._data[input_instance_id].border_width * _1766.uniforms.scale_factor;
    bool _4220 = input_local_pos.y < 0.0;
    float _4222 = _3328.x;
    float _4224 = _3328.w;
    float _4230 = _3328.y;
    float _4232 = _3328.z;
    float _4234 = (input_local_pos.x < 0.0) ? (_4220 ? _4222 : _4224) : (_4220 ? _4230 : _4232);
    vec2 _4241 = (abs(input_local_pos) - input_size) + vec2(_4234);
    float _4253 = (min(max(_4241.x, _4241.y), 0.0) + length(max(_4241, vec2(0.0)))) - _4234;
    float _4468 = dFdxFine(_4253);
    float _4470 = dFdyFine(_4253);
    float _3422 = max(length(vec2(_4468, _4470)) * 0.5, 0.5);
    float _4481 = -_3422;
    float _4483 = smoothstep(_3422, _4481, _4253);
    float _6620 = 0.0;
    do
    {
        if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
        {
            _6620 = 1.0;
            break;
        }
        vec2 _4561 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1766.uniforms.scale_factor)) - ((input_rect_clip.zw * _1766.uniforms.scale_factor) * 0.5);
        float _4574 = min(max(_4561.x, _4561.y), 0.0) + length(max(_4561, vec2(0.0)));
        float _4547 = max((abs(dFdxFine(_4574)) + abs(dFdyFine(_4574))) * 0.5, 0.5);
        _6620 = smoothstep(_4547, -_4547, _4574);
        break;
    } while(false);
    float _6660 = 0.0;
    do
    {
        if (_1766.uniforms.clip_shape_kind == 0u)
        {
            _6660 = 1.0;
            break;
        }
        vec2 _4634 = (_1766.uniforms.clip_rect.xy + (_1766.uniforms.clip_rect.zw * 0.5)) * _1766.uniforms.scale_factor;
        vec2 _4641 = (_1766.uniforms.clip_rect.zw * _1766.uniforms.scale_factor) * 0.5;
        float _6658 = 0.0;
        if (_1766.uniforms.clip_shape_kind == 1u)
        {
            float _4650 = _1766.uniforms.clip_radius * _1766.uniforms.scale_factor;
            vec2 _4807 = (abs(input_screen_pos - _4634) - _4641) + vec2(_4650);
            _6658 = (min(max(_4807.x, _4807.y), 0.0) + length(max(_4807, vec2(0.0)))) - _4650;
        }
        else
        {
            float _6659 = 0.0;
            if (_1766.uniforms.clip_shape_kind == 2u)
            {
                _6659 = length((input_screen_pos - _4634) / max(_4641, vec2(0.001000000047497451305389404296875))) - 1.0;
            }
            else
            {
                if (_1766.uniforms.clip_shape_kind == 3u)
                {
                    uint _4674 = min(_1766.uniforms.clip_point_count, 32u);
                    uint _4677 = min(_1766.uniforms.clip_contour_count, 8u);
                    if ((_4674 < 3u) || (_4677 == 0u))
                    {
                        _6660 = 1.0;
                        break;
                    }
                    vec2 _4692 = input_screen_pos - (_1766.uniforms.clip_rect.xy * _1766.uniforms.scale_factor);
                    bool _6641 = false;
                    do
                    {
                        if (_1766.uniforms.clip_fill_rule == 0u)
                        {
                            bool _6640 = false;
                            _6640 = false;
                            uint _4870 = 0u;
                            bool _6762 = false;
                            for (uint _6639 = 0u, _6650 = 0u; _6639 < _4677; _6650 = _4870, _6640 = _6762, _6639++)
                            {
                                _4870 = min(_1766.uniforms.clip_polygon_end_points[_6639 / 4u][_6639 % 4u], _4674);
                                if (_4870 <= (_6650 + 1u))
                                {
                                    _6762 = _6640;
                                    continue;
                                }
                                bool _6653 = false;
                                _6653 = _6640;
                                bool _6767 = false;
                                for (uint _6651 = _6650; _6651 < _4870; _6653 = _6767, _6651++)
                                {
                                    uint _4886 = _6651 + 1u;
                                    uint _4892 = (_4886 < _4870) ? _4886 : _6650;
                                    uint _4985 = _6651 / 2u;
                                    bvec2 _4995 = bvec2((_6651 % 2u) == 0u);
                                    vec2 _4898 = vec2(_4995.x ? _1766.uniforms.clip_polygon_points[_4985].xy.x : _1766.uniforms.clip_polygon_points[_4985].zw.x, _4995.y ? _1766.uniforms.clip_polygon_points[_4985].xy.y : _1766.uniforms.clip_polygon_points[_4985].zw.y) * _1766.uniforms.scale_factor;
                                    uint _5001 = _4892 / 2u;
                                    bvec2 _5011 = bvec2((_4892 % 2u) == 0u);
                                    vec2 _4904 = vec2(_5011.x ? _1766.uniforms.clip_polygon_points[_5001].xy.x : _1766.uniforms.clip_polygon_points[_5001].zw.x, _5011.y ? _1766.uniforms.clip_polygon_points[_5001].xy.y : _1766.uniforms.clip_polygon_points[_5001].zw.y) * _1766.uniforms.scale_factor;
                                    float _4906 = _4904.y;
                                    float _4908 = _4898.y;
                                    float _4909 = _4906 - _4908;
                                    float _4921 = _4692.y;
                                    float _4934 = _4898.x;
                                    if (((_4908 > _4921) != (_4906 > _4921)) && (_4692.x < ((((_4904.x - _4934) * (_4921 - _4908)) / ((abs(_4909) < 9.9999997473787516355514526367188e-05) ? ((_4909 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _4909)) + _4934)))
                                    {
                                        _6767 = !_6653;
                                    }
                                    else
                                    {
                                        _6767 = _6653;
                                    }
                                }
                                _6762 = _6653;
                            }
                            _6641 = _6640;
                            break;
                        }
                        int _6622 = 0;
                        _6622 = 0;
                        uint _5041 = 0u;
                        int _6750 = 0;
                        for (uint _6621 = 0u, _6623 = 0u; _6621 < _4677; _6623 = _5041, _6622 = _6750, _6621++)
                        {
                            _5041 = min(_1766.uniforms.clip_polygon_end_points[_6621 / 4u][_6621 % 4u], _4674);
                            if (_5041 <= (_6623 + 1u))
                            {
                                _6750 = _6622;
                                continue;
                            }
                            int _6626 = 0;
                            _6626 = _6622;
                            int _6757 = 0;
                            for (uint _6624 = _6623; _6624 < _5041; _6626 = _6757, _6624++)
                            {
                                uint _5057 = _6624 + 1u;
                                uint _5063 = (_5057 < _5041) ? _5057 : _6623;
                                uint _5178 = _6624 / 2u;
                                bvec2 _5188 = bvec2((_6624 % 2u) == 0u);
                                vec2 _5069 = vec2(_5188.x ? _1766.uniforms.clip_polygon_points[_5178].xy.x : _1766.uniforms.clip_polygon_points[_5178].zw.x, _5188.y ? _1766.uniforms.clip_polygon_points[_5178].xy.y : _1766.uniforms.clip_polygon_points[_5178].zw.y) * _1766.uniforms.scale_factor;
                                uint _5194 = _5063 / 2u;
                                bvec2 _5204 = bvec2((_5063 % 2u) == 0u);
                                vec2 _5075 = vec2(_5204.x ? _1766.uniforms.clip_polygon_points[_5194].xy.x : _1766.uniforms.clip_polygon_points[_5194].zw.x, _5204.y ? _1766.uniforms.clip_polygon_points[_5194].xy.y : _1766.uniforms.clip_polygon_points[_5194].zw.y) * _1766.uniforms.scale_factor;
                                float _5077 = _5069.y;
                                float _5079 = _4692.y;
                                if (_5077 <= _5079)
                                {
                                    float _5083 = _5075.y;
                                    int _6758 = 0;
                                    if (_5083 > _5079)
                                    {
                                        float _5091 = _5069.x;
                                        int _6759 = 0;
                                        if ((((_5075.x - _5091) * (_5079 - _5077)) - ((_4692.x - _5091) * (_5083 - _5077))) > 0.0)
                                        {
                                            _6759 = _6626 + 1;
                                        }
                                        else
                                        {
                                            _6759 = _6626;
                                        }
                                        _6758 = _6759;
                                    }
                                    else
                                    {
                                        _6758 = _6626;
                                    }
                                    _6757 = _6758;
                                }
                                else
                                {
                                    float _5120 = _5075.y;
                                    int _6760 = 0;
                                    if (_5120 <= _5079)
                                    {
                                        float _5128 = _5069.x;
                                        int _6761 = 0;
                                        if ((((_5075.x - _5128) * (_5079 - _5077)) - ((_4692.x - _5128) * (_5120 - _5077))) < 0.0)
                                        {
                                            _6761 = _6626 - 1;
                                        }
                                        else
                                        {
                                            _6761 = _6626;
                                        }
                                        _6760 = _6761;
                                    }
                                    else
                                    {
                                        _6760 = _6626;
                                    }
                                    _6757 = _6760;
                                }
                            }
                            _6750 = _6626;
                        }
                        _6641 = _6622 != 0;
                        break;
                    } while(false);
                    float _6643 = 0.0;
                    uint _6644 = 0u;
                    _6644 = 0u;
                    _6643 = uintBitsToFloat(0x7f800000u /* inf */);
                    uint _4709 = 0u;
                    float _6763 = 0.0;
                    for (uint _6642 = 0u; _6642 < _4677; _6644 = _4709, _6643 = _6763, _6642++)
                    {
                        _4709 = min(_1766.uniforms.clip_polygon_end_points[_6642 / 4u][_6642 % 4u], _4674);
                        if (_4709 <= (_6644 + 1u))
                        {
                            _6763 = _6643;
                            continue;
                        }
                        float _6647 = 0.0;
                        _6647 = _6643;
                        for (uint _6645 = _6644; _6645 < _4709; )
                        {
                            uint _4725 = _6645 + 1u;
                            uint _4731 = (_4725 < _4709) ? _4725 : _6644;
                            uint _5218 = _6645 / 2u;
                            bvec2 _5228 = bvec2((_6645 % 2u) == 0u);
                            vec2 _4737 = vec2(_5228.x ? _1766.uniforms.clip_polygon_points[_5218].xy.x : _1766.uniforms.clip_polygon_points[_5218].zw.x, _5228.y ? _1766.uniforms.clip_polygon_points[_5218].xy.y : _1766.uniforms.clip_polygon_points[_5218].zw.y) * _1766.uniforms.scale_factor;
                            uint _5234 = _4731 / 2u;
                            bvec2 _5244 = bvec2((_4731 % 2u) == 0u);
                            vec2 _5253 = (vec2(_5244.x ? _1766.uniforms.clip_polygon_points[_5234].xy.x : _1766.uniforms.clip_polygon_points[_5234].zw.x, _5244.y ? _1766.uniforms.clip_polygon_points[_5234].xy.y : _1766.uniforms.clip_polygon_points[_5234].zw.y) * _1766.uniforms.scale_factor) - _4737;
                            _6647 = min(_6647, length(_4692 - (_4737 + (_5253 * clamp(dot(_4692 - _4737, _5253) / max(dot(_5253, _5253), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                            _6645++;
                            continue;
                        }
                        _6763 = _6647;
                    }
                    float _4768 = max(length(vec2(dFdxFine(input_screen_pos.x), dFdyFine(input_screen_pos.y))) * 0.5, 0.75);
                    _6660 = smoothstep(_4768, -_4768, _6641 ? (-_6643) : _6643);
                    break;
                }
                _6659 = 1.0;
            }
            _6658 = _6659;
        }
        float _4790 = max((abs(dFdxFine(_6658)) + abs(dFdyFine(_6658))) * 0.5, 0.5);
        _6660 = smoothstep(_4790, -_4790, _6658);
        break;
    } while(false);
    vec4 _3510 = instances_1._data[input_instance_id].border_widths * _1766.uniforms.scale_factor;
    float _3512 = _3510.x;
    float _3514 = _3510.y;
    float _3517 = _3510.z;
    float _3520 = _3510.w;
    bool _3539 = true && (_4483 > 0.0);
    float _6701 = 0.0;
    if (true && (((((_3512 + _3514) + _3517) + _3520) > 0.0) && true))
    {
        vec4 _3607 = max(_3328 - vec4(max(_3512, _3520), max(_3512, _3514), max(_3517, _3514), max(_3517, _3520)), vec4(0.0));
        vec2 _3611 = input_local_pos - vec2((_3520 - _3514) * 0.5, (_3512 - _3517) * 0.5);
        bool _5283 = _3611.y < 0.0;
        float _5297 = (_3611.x < 0.0) ? (_5283 ? _3607.x : _3607.w) : (_5283 ? _3607.y : _3607.z);
        vec2 _5304 = (abs(_3611) - max(vec2(input_size.x - ((_3514 + _3520) * 0.5), input_size.y - ((_3512 + _3517) * 0.5)), vec2(0.0))) + vec2(_5297);
        _6701 = _4483 - smoothstep(_3422, _4481, (min(max(_5304.x, _5304.y), 0.0) + length(max(_5304, vec2(0.0)))) - _5297);
    }
    else
    {
        float _6702 = 0.0;
        if (true && (_3343 > 0.0))
        {
            _6702 = _4483 - smoothstep(_3422, _4481, _4253 + _3343);
        }
        else
        {
            _6702 = 0.0;
        }
        _6701 = _6702;
    }
    vec4 _6933 = vec4(0.0);
    if (_3539)
    {
        float _4109 = instances_1._data[input_instance_id].fill_color.w * _4483;
        _6933 = vec4(instances_1._data[input_instance_id].fill_color.xyz * _4109, _4109) * 1.0;
    }
    else
    {
        _6933 = vec4(0.0);
    }
    vec4 _6934 = vec4(0.0);
    if (_3539)
    {
        vec2 _4132 = input_local_pos - (vec2(instances_1._data[input_instance_id].shadow_offset_x, instances_1._data[input_instance_id].shadow_offset_y) * _1766.uniforms.scale_factor);
        bool _6238 = _4132.y < 0.0;
        float _6252 = (_4132.x < 0.0) ? (_6238 ? _4222 : _4224) : (_6238 ? _4230 : _4232);
        vec2 _6259 = (abs(_4132) - input_size) + vec2(_6252);
        float _4153 = instances_1._data[input_instance_id].shadow_color.w * (_4483 * smoothstep(-max(instances_1._data[input_instance_id].shadow_blur * _1766.uniforms.scale_factor, 1.0), 0.0, (min(max(_6259.x, _6259.y), 0.0) + length(max(_6259, vec2(0.0)))) - _6252));
        _6934 = _6933 + (vec4(instances_1._data[input_instance_id].shadow_color.xyz * _4153, _4153) * (1.0 - _6933.w));
    }
    else
    {
        _6934 = _6933;
    }
    vec4 _6935 = vec4(0.0);
    if (true && (_6701 > 0.0))
    {
        float _4181 = instances_1._data[input_instance_id].border_color.w * _6701;
        _6935 = _6934 + (vec4(instances_1._data[input_instance_id].border_color.xyz * _4181, _4181) * (1.0 - _6934.w));
    }
    else
    {
        _6935 = _6934;
    }
    vec4 _4201 = _6935 * (_6620 * _6660);
    if (_4201.w < 0.001000000047497451305389404296875)
    {
        discard;
    }
    _entryPointOutput = _4201;
}

