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
    vec4 _3320 = instances_1._data[input_instance_id].corner_radii * _1766.uniforms.scale_factor;
    float _3335 = instances_1._data[input_instance_id].border_width * _1766.uniforms.scale_factor;
    bool _3350 = instances_1._data[input_instance_id].shape_type == 0u;
    float _6540 = 0.0;
    if (_3350)
    {
        bool _4212 = input_local_pos.y < 0.0;
        float _4226 = (input_local_pos.x < 0.0) ? (_4212 ? _3320.x : _3320.w) : (_4212 ? _3320.y : _3320.z);
        vec2 _4233 = (abs(input_local_pos) - input_size) + vec2(_4226);
        _6540 = (min(max(_4233.x, _4233.y), 0.0) + length(max(_4233, vec2(0.0)))) - _4226;
    }
    else
    {
        float _6541 = 0.0;
        if (instances_1._data[input_instance_id].shape_type == 1u)
        {
            _6541 = length(input_local_pos) - min(input_size.x, input_size.y);
        }
        else
        {
            float _6542 = 0.0;
            if (instances_1._data[input_instance_id].shape_type == 2u)
            {
                _6542 = abs(input_local_pos.y) - _3320.x;
            }
            else
            {
                float _6543 = 0.0;
                if (instances_1._data[input_instance_id].shape_type == 3u)
                {
                    float _3391 = _3320.x;
                    float _6539 = 0.0;
                    do
                    {
                        float _4275 = _3335 * 0.5;
                        float _4285 = abs(length(input_local_pos) - (_3391 - _4275)) - _4275;
                        float _4289 = clamp(instances_1._data[input_instance_id].shadow_offset_y - instances_1._data[input_instance_id].shadow_offset_x, 0.0, 6.283185482025146484375);
                        if (_4289 >= 6.283085346221923828125)
                        {
                            _6539 = _4285;
                            break;
                        }
                        if (_4289 <= 0.0)
                        {
                            _6539 = max(_4285, 0.0) + 1.0;
                            break;
                        }
                        float _4305 = max(_3391 - _3335, 0.0);
                        vec2 _4354 = vec2(cos(instances_1._data[input_instance_id].shadow_offset_x), sin(instances_1._data[input_instance_id].shadow_offset_x));
                        float _4361 = _3391 - _4305;
                        vec2 _4362 = _4354 * _4361;
                        vec2 _4365 = input_local_pos - (_4354 * _4305);
                        float _4313 = instances_1._data[input_instance_id].shadow_offset_x + _4289;
                        vec2 _4390 = vec2(cos(_4313), sin(_4313));
                        vec2 _4398 = _4390 * _4361;
                        vec2 _4401 = input_local_pos - (_4390 * _4305);
                        float _4318 = min(length(_4365 - (_4362 * clamp(dot(_4365, _4362) / max(dot(_4362, _4362), 9.9999999747524270787835121154785e-07), 0.0, 1.0))), length(_4401 - (_4398 * clamp(dot(_4401, _4398) / max(dot(_4398, _4398), 9.9999999747524270787835121154785e-07), 0.0, 1.0))));
                        float _4326 = atan(input_local_pos.y, input_local_pos.x) - instances_1._data[input_instance_id].shadow_offset_x;
                        _6539 = ((_4326 - (floor(_4326 * 0.15915493667125701904296875) * 6.283185482025146484375)) <= _4289) ? max(_4285, -_4318) : _4318;
                        break;
                    } while(false);
                    _6543 = _6539;
                }
                else
                {
                    float _6544 = 0.0;
                    if (instances_1._data[input_instance_id].shape_type == 4u)
                    {
                        float _6538 = 0.0;
                        do
                        {
                            vec2 _4426 = max(input_size, vec2(0.001000000047497451305389404296875));
                            float _4431 = length(input_local_pos / _4426);
                            if (_4431 < 9.9999999747524270787835121154785e-07)
                            {
                                _6538 = -min(_4426.x, _4426.y);
                                break;
                            }
                            _6538 = (_4431 - 1.0) / max(length(input_local_pos / (_4426 * _4426)) / _4431, 9.9999999747524270787835121154785e-07);
                            break;
                        } while(false);
                        _6544 = _6538;
                    }
                    else
                    {
                        _6544 = 1.0;
                    }
                    _6543 = _6544;
                }
                _6542 = _6543;
            }
            _6541 = _6542;
        }
        _6540 = _6541;
    }
    float _4460 = dFdxFine(_6540);
    float _4462 = dFdyFine(_6540);
    float _3414 = max(length(vec2(_4460, _4462)) * 0.5, 0.5);
    float _6553 = 0.0;
    do
    {
        if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
        {
            _6553 = 1.0;
            break;
        }
        vec2 _4553 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1766.uniforms.scale_factor)) - ((input_rect_clip.zw * _1766.uniforms.scale_factor) * 0.5);
        float _4566 = min(max(_4553.x, _4553.y), 0.0) + length(max(_4553, vec2(0.0)));
        float _4539 = max((abs(dFdxFine(_4566)) + abs(dFdyFine(_4566))) * 0.5, 0.5);
        _6553 = smoothstep(_4539, -_4539, _4566);
        break;
    } while(false);
    float _6593 = 0.0;
    do
    {
        if (_1766.uniforms.clip_shape_kind == 0u)
        {
            _6593 = 1.0;
            break;
        }
        vec2 _4626 = (_1766.uniforms.clip_rect.xy + (_1766.uniforms.clip_rect.zw * 0.5)) * _1766.uniforms.scale_factor;
        vec2 _4633 = (_1766.uniforms.clip_rect.zw * _1766.uniforms.scale_factor) * 0.5;
        float _6591 = 0.0;
        if (_1766.uniforms.clip_shape_kind == 1u)
        {
            float _4642 = _1766.uniforms.clip_radius * _1766.uniforms.scale_factor;
            vec2 _4799 = (abs(input_screen_pos - _4626) - _4633) + vec2(_4642);
            _6591 = (min(max(_4799.x, _4799.y), 0.0) + length(max(_4799, vec2(0.0)))) - _4642;
        }
        else
        {
            float _6592 = 0.0;
            if (_1766.uniforms.clip_shape_kind == 2u)
            {
                _6592 = length((input_screen_pos - _4626) / max(_4633, vec2(0.001000000047497451305389404296875))) - 1.0;
            }
            else
            {
                if (_1766.uniforms.clip_shape_kind == 3u)
                {
                    uint _4666 = min(_1766.uniforms.clip_point_count, 32u);
                    uint _4669 = min(_1766.uniforms.clip_contour_count, 8u);
                    if ((_4666 < 3u) || (_4669 == 0u))
                    {
                        _6593 = 1.0;
                        break;
                    }
                    vec2 _4684 = input_screen_pos - (_1766.uniforms.clip_rect.xy * _1766.uniforms.scale_factor);
                    bool _6574 = false;
                    do
                    {
                        if (_1766.uniforms.clip_fill_rule == 0u)
                        {
                            bool _6573 = false;
                            _6573 = false;
                            uint _4862 = 0u;
                            bool _6695 = false;
                            for (uint _6572 = 0u, _6583 = 0u; _6572 < _4669; _6583 = _4862, _6573 = _6695, _6572++)
                            {
                                _4862 = min(_1766.uniforms.clip_polygon_end_points[_6572 / 4u][_6572 % 4u], _4666);
                                if (_4862 <= (_6583 + 1u))
                                {
                                    _6695 = _6573;
                                    continue;
                                }
                                bool _6586 = false;
                                _6586 = _6573;
                                bool _6700 = false;
                                for (uint _6584 = _6583; _6584 < _4862; _6586 = _6700, _6584++)
                                {
                                    uint _4878 = _6584 + 1u;
                                    uint _4884 = (_4878 < _4862) ? _4878 : _6583;
                                    uint _4977 = _6584 / 2u;
                                    bvec2 _4987 = bvec2((_6584 % 2u) == 0u);
                                    vec2 _4890 = vec2(_4987.x ? _1766.uniforms.clip_polygon_points[_4977].xy.x : _1766.uniforms.clip_polygon_points[_4977].zw.x, _4987.y ? _1766.uniforms.clip_polygon_points[_4977].xy.y : _1766.uniforms.clip_polygon_points[_4977].zw.y) * _1766.uniforms.scale_factor;
                                    uint _4993 = _4884 / 2u;
                                    bvec2 _5003 = bvec2((_4884 % 2u) == 0u);
                                    vec2 _4896 = vec2(_5003.x ? _1766.uniforms.clip_polygon_points[_4993].xy.x : _1766.uniforms.clip_polygon_points[_4993].zw.x, _5003.y ? _1766.uniforms.clip_polygon_points[_4993].xy.y : _1766.uniforms.clip_polygon_points[_4993].zw.y) * _1766.uniforms.scale_factor;
                                    float _4898 = _4896.y;
                                    float _4900 = _4890.y;
                                    float _4901 = _4898 - _4900;
                                    float _4913 = _4684.y;
                                    float _4926 = _4890.x;
                                    if (((_4900 > _4913) != (_4898 > _4913)) && (_4684.x < ((((_4896.x - _4926) * (_4913 - _4900)) / ((abs(_4901) < 9.9999997473787516355514526367188e-05) ? ((_4901 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _4901)) + _4926)))
                                    {
                                        _6700 = !_6586;
                                    }
                                    else
                                    {
                                        _6700 = _6586;
                                    }
                                }
                                _6695 = _6586;
                            }
                            _6574 = _6573;
                            break;
                        }
                        int _6555 = 0;
                        _6555 = 0;
                        uint _5033 = 0u;
                        int _6683 = 0;
                        for (uint _6554 = 0u, _6556 = 0u; _6554 < _4669; _6556 = _5033, _6555 = _6683, _6554++)
                        {
                            _5033 = min(_1766.uniforms.clip_polygon_end_points[_6554 / 4u][_6554 % 4u], _4666);
                            if (_5033 <= (_6556 + 1u))
                            {
                                _6683 = _6555;
                                continue;
                            }
                            int _6559 = 0;
                            _6559 = _6555;
                            int _6690 = 0;
                            for (uint _6557 = _6556; _6557 < _5033; _6559 = _6690, _6557++)
                            {
                                uint _5049 = _6557 + 1u;
                                uint _5055 = (_5049 < _5033) ? _5049 : _6556;
                                uint _5170 = _6557 / 2u;
                                bvec2 _5180 = bvec2((_6557 % 2u) == 0u);
                                vec2 _5061 = vec2(_5180.x ? _1766.uniforms.clip_polygon_points[_5170].xy.x : _1766.uniforms.clip_polygon_points[_5170].zw.x, _5180.y ? _1766.uniforms.clip_polygon_points[_5170].xy.y : _1766.uniforms.clip_polygon_points[_5170].zw.y) * _1766.uniforms.scale_factor;
                                uint _5186 = _5055 / 2u;
                                bvec2 _5196 = bvec2((_5055 % 2u) == 0u);
                                vec2 _5067 = vec2(_5196.x ? _1766.uniforms.clip_polygon_points[_5186].xy.x : _1766.uniforms.clip_polygon_points[_5186].zw.x, _5196.y ? _1766.uniforms.clip_polygon_points[_5186].xy.y : _1766.uniforms.clip_polygon_points[_5186].zw.y) * _1766.uniforms.scale_factor;
                                float _5069 = _5061.y;
                                float _5071 = _4684.y;
                                if (_5069 <= _5071)
                                {
                                    float _5075 = _5067.y;
                                    int _6691 = 0;
                                    if (_5075 > _5071)
                                    {
                                        float _5083 = _5061.x;
                                        int _6692 = 0;
                                        if ((((_5067.x - _5083) * (_5071 - _5069)) - ((_4684.x - _5083) * (_5075 - _5069))) > 0.0)
                                        {
                                            _6692 = _6559 + 1;
                                        }
                                        else
                                        {
                                            _6692 = _6559;
                                        }
                                        _6691 = _6692;
                                    }
                                    else
                                    {
                                        _6691 = _6559;
                                    }
                                    _6690 = _6691;
                                }
                                else
                                {
                                    float _5112 = _5067.y;
                                    int _6693 = 0;
                                    if (_5112 <= _5071)
                                    {
                                        float _5120 = _5061.x;
                                        int _6694 = 0;
                                        if ((((_5067.x - _5120) * (_5071 - _5069)) - ((_4684.x - _5120) * (_5112 - _5069))) < 0.0)
                                        {
                                            _6694 = _6559 - 1;
                                        }
                                        else
                                        {
                                            _6694 = _6559;
                                        }
                                        _6693 = _6694;
                                    }
                                    else
                                    {
                                        _6693 = _6559;
                                    }
                                    _6690 = _6693;
                                }
                            }
                            _6683 = _6559;
                        }
                        _6574 = _6555 != 0;
                        break;
                    } while(false);
                    float _6576 = 0.0;
                    uint _6577 = 0u;
                    _6577 = 0u;
                    _6576 = uintBitsToFloat(0x7f800000u /* inf */);
                    uint _4701 = 0u;
                    float _6696 = 0.0;
                    for (uint _6575 = 0u; _6575 < _4669; _6577 = _4701, _6576 = _6696, _6575++)
                    {
                        _4701 = min(_1766.uniforms.clip_polygon_end_points[_6575 / 4u][_6575 % 4u], _4666);
                        if (_4701 <= (_6577 + 1u))
                        {
                            _6696 = _6576;
                            continue;
                        }
                        float _6580 = 0.0;
                        _6580 = _6576;
                        for (uint _6578 = _6577; _6578 < _4701; )
                        {
                            uint _4717 = _6578 + 1u;
                            uint _4723 = (_4717 < _4701) ? _4717 : _6577;
                            uint _5210 = _6578 / 2u;
                            bvec2 _5220 = bvec2((_6578 % 2u) == 0u);
                            vec2 _4729 = vec2(_5220.x ? _1766.uniforms.clip_polygon_points[_5210].xy.x : _1766.uniforms.clip_polygon_points[_5210].zw.x, _5220.y ? _1766.uniforms.clip_polygon_points[_5210].xy.y : _1766.uniforms.clip_polygon_points[_5210].zw.y) * _1766.uniforms.scale_factor;
                            uint _5226 = _4723 / 2u;
                            bvec2 _5236 = bvec2((_4723 % 2u) == 0u);
                            vec2 _5245 = (vec2(_5236.x ? _1766.uniforms.clip_polygon_points[_5226].xy.x : _1766.uniforms.clip_polygon_points[_5226].zw.x, _5236.y ? _1766.uniforms.clip_polygon_points[_5226].xy.y : _1766.uniforms.clip_polygon_points[_5226].zw.y) * _1766.uniforms.scale_factor) - _4729;
                            _6580 = min(_6580, length(_4684 - (_4729 + (_5245 * clamp(dot(_4684 - _4729, _5245) / max(dot(_5245, _5245), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                            _6578++;
                            continue;
                        }
                        _6696 = _6580;
                    }
                    float _4760 = max(length(vec2(dFdxFine(input_screen_pos.x), dFdyFine(input_screen_pos.y))) * 0.5, 0.75);
                    _6593 = smoothstep(_4760, -_4760, _6574 ? (-_6576) : _6576);
                    break;
                }
                _6592 = 1.0;
            }
            _6591 = _6592;
        }
        float _4782 = max((abs(dFdxFine(_6591)) + abs(dFdyFine(_6591))) * 0.5, 0.5);
        _6593 = smoothstep(_4782, -_4782, _6591);
        break;
    } while(false);
    vec4 _3502 = instances_1._data[input_instance_id].border_widths * _1766.uniforms.scale_factor;
    float _3504 = _3502.x;
    float _3506 = _3502.y;
    float _3509 = _3502.z;
    float _3512 = _3502.w;
    float _6634 = 0.0;
    if (true && (((((_3504 + _3506) + _3509) + _3512) > 0.0) && _3350))
    {
        vec4 _3599 = max(_3320 - vec4(max(_3504, _3512), max(_3504, _3506), max(_3509, _3506), max(_3509, _3512)), vec4(0.0));
        vec2 _3603 = input_local_pos - vec2((_3512 - _3506) * 0.5, (_3504 - _3509) * 0.5);
        bool _5275 = _3603.y < 0.0;
        float _5289 = (_3603.x < 0.0) ? (_5275 ? _3599.x : _3599.w) : (_5275 ? _3599.y : _3599.z);
        vec2 _5296 = (abs(_3603) - max(vec2(input_size.x - ((_3506 + _3512) * 0.5), input_size.y - ((_3504 + _3509) * 0.5)), vec2(0.0))) + vec2(_5289);
        float _5316 = -_3414;
        _6634 = smoothstep(_3414, _5316, _6540) - smoothstep(_3414, _5316, (min(max(_5296.x, _5296.y), 0.0) + length(max(_5296, vec2(0.0)))) - _5289);
    }
    else
    {
        float _6635 = 0.0;
        if (true && (_3335 > 0.0))
        {
            float _5336 = -_3414;
            _6635 = smoothstep(_3414, _5336, _6540) - smoothstep(_3414, _5336, _6540 + _3335);
        }
        else
        {
            _6635 = 0.0;
        }
        _6634 = _6635;
    }
    vec4 _6838 = vec4(0.0);
    if (true && (_6634 > 0.0))
    {
        float _4173 = instances_1._data[input_instance_id].border_color.w * _6634;
        _6838 = vec4(instances_1._data[input_instance_id].border_color.xyz * _4173, _4173) * 1.0;
    }
    else
    {
        _6838 = vec4(0.0);
    }
    vec4 _4193 = _6838 * (_6553 * _6593);
    if (_4193.w < 0.001000000047497451305389404296875)
    {
        discard;
    }
    _entryPointOutput = _4193;
}

