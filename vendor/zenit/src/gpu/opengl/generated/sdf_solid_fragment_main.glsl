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
layout(location = 11) flat in uint input_solid_shape;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _6795 = vec4(0.0);
    do
    {
        vec4 _3344 = input_solid_radii * _1780.uniforms.scale_factor;
        float _3359 = input_solid_metrics.x * _1780.uniforms.scale_factor;
        bool _3374 = input_solid_shape == 0u;
        float _6653 = 0.0;
        if (_3374)
        {
            bool _4236 = input_local_pos.y < 0.0;
            float _4250 = (input_local_pos.x < 0.0) ? (_4236 ? _3344.x : _3344.w) : (_4236 ? _3344.y : _3344.z);
            vec2 _4257 = (abs(input_local_pos) - input_size) + vec2(_4250);
            _6653 = (min(max(_4257.x, _4257.y), 0.0) + length(max(_4257, vec2(0.0)))) - _4250;
        }
        else
        {
            float _6654 = 0.0;
            if (input_solid_shape == 1u)
            {
                _6654 = length(input_local_pos) - min(input_size.x, input_size.y);
            }
            else
            {
                float _6655 = 0.0;
                if (input_solid_shape == 2u)
                {
                    _6655 = abs(input_local_pos.y) - _3344.x;
                }
                else
                {
                    float _6656 = 0.0;
                    if (input_solid_shape == 3u)
                    {
                        float _3415 = _3344.x;
                        float _6652 = 0.0;
                        do
                        {
                            float _4299 = _3359 * 0.5;
                            float _4309 = abs(length(input_local_pos) - (_3415 - _4299)) - _4299;
                            float _4313 = clamp(input_solid_metrics.z - input_solid_metrics.y, 0.0, 6.283185482025146484375);
                            if (_4313 >= 6.283085346221923828125)
                            {
                                _6652 = _4309;
                                break;
                            }
                            if (_4313 <= 0.0)
                            {
                                _6652 = max(_4309, 0.0) + 1.0;
                                break;
                            }
                            float _4329 = max(_3415 - _3359, 0.0);
                            vec2 _4378 = vec2(cos(input_solid_metrics.y), sin(input_solid_metrics.y));
                            float _4385 = _3415 - _4329;
                            vec2 _4386 = _4378 * _4385;
                            vec2 _4389 = input_local_pos - (_4378 * _4329);
                            float _4337 = input_solid_metrics.y + _4313;
                            vec2 _4414 = vec2(cos(_4337), sin(_4337));
                            vec2 _4422 = _4414 * _4385;
                            vec2 _4425 = input_local_pos - (_4414 * _4329);
                            float _4342 = min(length(_4389 - (_4386 * clamp(dot(_4389, _4386) / max(dot(_4386, _4386), 9.9999999747524270787835121154785e-07), 0.0, 1.0))), length(_4425 - (_4422 * clamp(dot(_4425, _4422) / max(dot(_4422, _4422), 9.9999999747524270787835121154785e-07), 0.0, 1.0))));
                            float _4350 = atan(input_local_pos.y, input_local_pos.x) - input_solid_metrics.y;
                            _6652 = ((_4350 - (floor(_4350 * 0.15915493667125701904296875) * 6.283185482025146484375)) <= _4313) ? max(_4309, -_4342) : _4342;
                            break;
                        } while(false);
                        _6656 = _6652;
                    }
                    else
                    {
                        float _6657 = 0.0;
                        if (input_solid_shape == 4u)
                        {
                            float _6651 = 0.0;
                            do
                            {
                                vec2 _4450 = max(input_size, vec2(0.001000000047497451305389404296875));
                                float _4455 = length(input_local_pos / _4450);
                                if (_4455 < 9.9999999747524270787835121154785e-07)
                                {
                                    _6651 = -min(_4450.x, _4450.y);
                                    break;
                                }
                                _6651 = (_4455 - 1.0) / max(length(input_local_pos / (_4450 * _4450)) / _4455, 9.9999999747524270787835121154785e-07);
                                break;
                            } while(false);
                            _6657 = _6651;
                        }
                        else
                        {
                            _6657 = 1.0;
                        }
                        _6656 = _6657;
                    }
                    _6655 = _6656;
                }
                _6654 = _6655;
            }
            _6653 = _6654;
        }
        float _4484 = dFdxFine(_6653);
        float _4486 = dFdyFine(_6653);
        float _3438 = max(length(vec2(_4484, _4486)) * 0.5, 0.5);
        float _4497 = -_3438;
        float _4499 = smoothstep(_3438, _4497, _6653);
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
        float _6706 = 0.0;
        do
        {
            if (_1780.uniforms.clip_shape_kind == 0u)
            {
                _6706 = 1.0;
                break;
            }
            vec2 _4650 = (_1780.uniforms.clip_rect.xy + (_1780.uniforms.clip_rect.zw * 0.5)) * _1780.uniforms.scale_factor;
            vec2 _4657 = (_1780.uniforms.clip_rect.zw * _1780.uniforms.scale_factor) * 0.5;
            float _6704 = 0.0;
            if (_1780.uniforms.clip_shape_kind == 1u)
            {
                float _4666 = _1780.uniforms.clip_radius * _1780.uniforms.scale_factor;
                vec2 _4823 = (abs(input_screen_pos - _4650) - _4657) + vec2(_4666);
                _6704 = (min(max(_4823.x, _4823.y), 0.0) + length(max(_4823, vec2(0.0)))) - _4666;
            }
            else
            {
                float _6705 = 0.0;
                if (_1780.uniforms.clip_shape_kind == 2u)
                {
                    _6705 = length((input_screen_pos - _4650) / max(_4657, vec2(0.001000000047497451305389404296875))) - 1.0;
                }
                else
                {
                    if (_1780.uniforms.clip_shape_kind == 3u)
                    {
                        uint _4690 = min(_1780.uniforms.clip_point_count, 32u);
                        uint _4693 = min(_1780.uniforms.clip_contour_count, 8u);
                        if ((_4690 < 3u) || (_4693 == 0u))
                        {
                            _6706 = 1.0;
                            break;
                        }
                        vec2 _4708 = input_screen_pos - (_1780.uniforms.clip_rect.xy * _1780.uniforms.scale_factor);
                        bool _6687 = false;
                        do
                        {
                            if (_1780.uniforms.clip_fill_rule == 0u)
                            {
                                bool _6686 = false;
                                _6686 = false;
                                uint _4886 = 0u;
                                bool _6808 = false;
                                for (uint _6685 = 0u, _6696 = 0u; _6685 < _4693; _6696 = _4886, _6686 = _6808, _6685++)
                                {
                                    _4886 = min(_1780.uniforms.clip_polygon_end_points[_6685 / 4u][_6685 % 4u], _4690);
                                    if (_4886 <= (_6696 + 1u))
                                    {
                                        _6808 = _6686;
                                        continue;
                                    }
                                    bool _6699 = false;
                                    _6699 = _6686;
                                    bool _6813 = false;
                                    for (uint _6697 = _6696; _6697 < _4886; _6699 = _6813, _6697++)
                                    {
                                        uint _4902 = _6697 + 1u;
                                        uint _4908 = (_4902 < _4886) ? _4902 : _6696;
                                        uint _5001 = _6697 / 2u;
                                        bvec2 _5011 = bvec2((_6697 % 2u) == 0u);
                                        vec2 _4914 = vec2(_5011.x ? _1780.uniforms.clip_polygon_points[_5001].xy.x : _1780.uniforms.clip_polygon_points[_5001].zw.x, _5011.y ? _1780.uniforms.clip_polygon_points[_5001].xy.y : _1780.uniforms.clip_polygon_points[_5001].zw.y) * _1780.uniforms.scale_factor;
                                        uint _5017 = _4908 / 2u;
                                        bvec2 _5027 = bvec2((_4908 % 2u) == 0u);
                                        vec2 _4920 = vec2(_5027.x ? _1780.uniforms.clip_polygon_points[_5017].xy.x : _1780.uniforms.clip_polygon_points[_5017].zw.x, _5027.y ? _1780.uniforms.clip_polygon_points[_5017].xy.y : _1780.uniforms.clip_polygon_points[_5017].zw.y) * _1780.uniforms.scale_factor;
                                        float _4922 = _4920.y;
                                        float _4924 = _4914.y;
                                        float _4925 = _4922 - _4924;
                                        float _4937 = _4708.y;
                                        float _4950 = _4914.x;
                                        if (((_4924 > _4937) != (_4922 > _4937)) && (_4708.x < ((((_4920.x - _4950) * (_4937 - _4924)) / ((abs(_4925) < 9.9999997473787516355514526367188e-05) ? ((_4925 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _4925)) + _4950)))
                                        {
                                            _6813 = !_6699;
                                        }
                                        else
                                        {
                                            _6813 = _6699;
                                        }
                                    }
                                    _6808 = _6699;
                                }
                                _6687 = _6686;
                                break;
                            }
                            int _6668 = 0;
                            _6668 = 0;
                            uint _5057 = 0u;
                            int _6796 = 0;
                            for (uint _6667 = 0u, _6669 = 0u; _6667 < _4693; _6669 = _5057, _6668 = _6796, _6667++)
                            {
                                _5057 = min(_1780.uniforms.clip_polygon_end_points[_6667 / 4u][_6667 % 4u], _4690);
                                if (_5057 <= (_6669 + 1u))
                                {
                                    _6796 = _6668;
                                    continue;
                                }
                                int _6672 = 0;
                                _6672 = _6668;
                                int _6803 = 0;
                                for (uint _6670 = _6669; _6670 < _5057; _6672 = _6803, _6670++)
                                {
                                    uint _5073 = _6670 + 1u;
                                    uint _5079 = (_5073 < _5057) ? _5073 : _6669;
                                    uint _5194 = _6670 / 2u;
                                    bvec2 _5204 = bvec2((_6670 % 2u) == 0u);
                                    vec2 _5085 = vec2(_5204.x ? _1780.uniforms.clip_polygon_points[_5194].xy.x : _1780.uniforms.clip_polygon_points[_5194].zw.x, _5204.y ? _1780.uniforms.clip_polygon_points[_5194].xy.y : _1780.uniforms.clip_polygon_points[_5194].zw.y) * _1780.uniforms.scale_factor;
                                    uint _5210 = _5079 / 2u;
                                    bvec2 _5220 = bvec2((_5079 % 2u) == 0u);
                                    vec2 _5091 = vec2(_5220.x ? _1780.uniforms.clip_polygon_points[_5210].xy.x : _1780.uniforms.clip_polygon_points[_5210].zw.x, _5220.y ? _1780.uniforms.clip_polygon_points[_5210].xy.y : _1780.uniforms.clip_polygon_points[_5210].zw.y) * _1780.uniforms.scale_factor;
                                    float _5093 = _5085.y;
                                    float _5095 = _4708.y;
                                    if (_5093 <= _5095)
                                    {
                                        float _5099 = _5091.y;
                                        int _6804 = 0;
                                        if (_5099 > _5095)
                                        {
                                            float _5107 = _5085.x;
                                            int _6805 = 0;
                                            if ((((_5091.x - _5107) * (_5095 - _5093)) - ((_4708.x - _5107) * (_5099 - _5093))) > 0.0)
                                            {
                                                _6805 = _6672 + 1;
                                            }
                                            else
                                            {
                                                _6805 = _6672;
                                            }
                                            _6804 = _6805;
                                        }
                                        else
                                        {
                                            _6804 = _6672;
                                        }
                                        _6803 = _6804;
                                    }
                                    else
                                    {
                                        float _5136 = _5091.y;
                                        int _6806 = 0;
                                        if (_5136 <= _5095)
                                        {
                                            float _5144 = _5085.x;
                                            int _6807 = 0;
                                            if ((((_5091.x - _5144) * (_5095 - _5093)) - ((_4708.x - _5144) * (_5136 - _5093))) < 0.0)
                                            {
                                                _6807 = _6672 - 1;
                                            }
                                            else
                                            {
                                                _6807 = _6672;
                                            }
                                            _6806 = _6807;
                                        }
                                        else
                                        {
                                            _6806 = _6672;
                                        }
                                        _6803 = _6806;
                                    }
                                }
                                _6796 = _6672;
                            }
                            _6687 = _6668 != 0;
                            break;
                        } while(false);
                        float _6689 = 0.0;
                        uint _6690 = 0u;
                        _6690 = 0u;
                        _6689 = uintBitsToFloat(0x7f800000u /* inf */);
                        uint _4725 = 0u;
                        float _6809 = 0.0;
                        for (uint _6688 = 0u; _6688 < _4693; _6690 = _4725, _6689 = _6809, _6688++)
                        {
                            _4725 = min(_1780.uniforms.clip_polygon_end_points[_6688 / 4u][_6688 % 4u], _4690);
                            if (_4725 <= (_6690 + 1u))
                            {
                                _6809 = _6689;
                                continue;
                            }
                            float _6693 = 0.0;
                            _6693 = _6689;
                            for (uint _6691 = _6690; _6691 < _4725; )
                            {
                                uint _4741 = _6691 + 1u;
                                uint _4747 = (_4741 < _4725) ? _4741 : _6690;
                                uint _5234 = _6691 / 2u;
                                bvec2 _5244 = bvec2((_6691 % 2u) == 0u);
                                vec2 _4753 = vec2(_5244.x ? _1780.uniforms.clip_polygon_points[_5234].xy.x : _1780.uniforms.clip_polygon_points[_5234].zw.x, _5244.y ? _1780.uniforms.clip_polygon_points[_5234].xy.y : _1780.uniforms.clip_polygon_points[_5234].zw.y) * _1780.uniforms.scale_factor;
                                uint _5250 = _4747 / 2u;
                                bvec2 _5260 = bvec2((_4747 % 2u) == 0u);
                                vec2 _5269 = (vec2(_5260.x ? _1780.uniforms.clip_polygon_points[_5250].xy.x : _1780.uniforms.clip_polygon_points[_5250].zw.x, _5260.y ? _1780.uniforms.clip_polygon_points[_5250].xy.y : _1780.uniforms.clip_polygon_points[_5250].zw.y) * _1780.uniforms.scale_factor) - _4753;
                                _6693 = min(_6693, length(_4708 - (_4753 + (_5269 * clamp(dot(_4708 - _4753, _5269) / max(dot(_5269, _5269), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                                _6691++;
                                continue;
                            }
                            _6809 = _6693;
                        }
                        float _4784 = max(length(vec2(dFdxFine(input_screen_pos.x), dFdyFine(input_screen_pos.y))) * 0.5, 0.75);
                        _6706 = smoothstep(_4784, -_4784, _6687 ? (-_6689) : _6689);
                        break;
                    }
                    _6705 = 1.0;
                }
                _6704 = _6705;
            }
            float _4806 = max((abs(dFdxFine(_6704)) + abs(dFdyFine(_6704))) * 0.5, 0.5);
            _6706 = smoothstep(_4806, -_4806, _6704);
            break;
        } while(false);
        float _4515 = _6666 * _6706;
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
        if (true && (((((_3528 + _3530) + _3533) + _3536) > 0.0) && _3374))
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
                _6748 = _4499 - smoothstep(_3438, _4497, _6653 + _3359);
            }
            else
            {
                _6748 = 0.0;
            }
            _6747 = _6748;
        }
        vec4 _6974 = vec4(0.0);
        if (_4499 > 0.0)
        {
            float _3668 = input_solid_fill.w * _4499;
            _6974 = vec4(input_solid_fill.xyz * _3668, _3668) * 1.0;
        }
        else
        {
            _6974 = vec4(0.0);
        }
        vec4 _6975 = vec4(0.0);
        if (_6747 > 0.0)
        {
            float _3694 = input_solid_border.w * _6747;
            _6975 = _6974 + (vec4(input_solid_border.xyz * _3694, _3694) * (1.0 - _6974.w));
        }
        else
        {
            _6975 = _6974;
        }
        vec4 _3714 = _6975 * _4515;
        if (_3714.w < 0.001000000047497451305389404296875)
        {
            discard;
        }
        _6795 = _3714;
        break;
    } while(false);
    _entryPointOutput = _6795;
}

