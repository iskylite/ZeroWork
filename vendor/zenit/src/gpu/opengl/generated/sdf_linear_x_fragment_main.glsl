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

struct GradientStop
{
    vec4 color;
    float position;
    float _pad0;
    float _pad1;
    float _pad2;
};

const uint _642[256] = uint[](0u, 128u, 32u, 160u, 8u, 136u, 40u, 168u, 2u, 130u, 34u, 162u, 10u, 138u, 42u, 170u, 192u, 64u, 224u, 96u, 200u, 72u, 232u, 104u, 194u, 66u, 226u, 98u, 202u, 74u, 234u, 106u, 48u, 176u, 16u, 144u, 56u, 184u, 24u, 152u, 50u, 178u, 18u, 146u, 58u, 186u, 26u, 154u, 240u, 112u, 208u, 80u, 248u, 120u, 216u, 88u, 242u, 114u, 210u, 82u, 250u, 122u, 218u, 90u, 12u, 140u, 44u, 172u, 4u, 132u, 36u, 164u, 14u, 142u, 46u, 174u, 6u, 134u, 38u, 166u, 204u, 76u, 236u, 108u, 196u, 68u, 228u, 100u, 206u, 78u, 238u, 110u, 198u, 70u, 230u, 102u, 60u, 188u, 28u, 156u, 52u, 180u, 20u, 148u, 62u, 190u, 30u, 158u, 54u, 182u, 22u, 150u, 252u, 124u, 220u, 92u, 244u, 116u, 212u, 84u, 254u, 126u, 222u, 94u, 246u, 118u, 214u, 86u, 3u, 131u, 35u, 163u, 11u, 139u, 43u, 171u, 1u, 129u, 33u, 161u, 9u, 137u, 41u, 169u, 195u, 67u, 227u, 99u, 203u, 75u, 235u, 107u, 193u, 65u, 225u, 97u, 201u, 73u, 233u, 105u, 51u, 179u, 19u, 147u, 59u, 187u, 27u, 155u, 49u, 177u, 17u, 145u, 57u, 185u, 25u, 153u, 243u, 115u, 211u, 83u, 251u, 123u, 219u, 91u, 241u, 113u, 209u, 81u, 249u, 121u, 217u, 89u, 15u, 143u, 47u, 175u, 7u, 135u, 39u, 167u, 13u, 141u, 45u, 173u, 5u, 133u, 37u, 165u, 207u, 79u, 239u, 111u, 199u, 71u, 231u, 103u, 205u, 77u, 237u, 109u, 197u, 69u, 229u, 101u, 63u, 191u, 31u, 159u, 55u, 183u, 23u, 151u, 61u, 189u, 29u, 157u, 53u, 181u, 21u, 149u, 255u, 127u, 223u, 95u, 247u, 119u, 215u, 87u, 253u, 125u, 221u, 93u, 245u, 117u, 213u, 85u);

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

struct ShadowParam
{
    vec4 color;
    float blur;
    float offset_x;
    float offset_y;
    float _pad;
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
} _1774;

layout(binding = 3, std430) readonly buffer shadow_params
{
    ShadowParam _data[];
} shadow_params_1;

layout(binding = 2, std430) readonly buffer grad_stops
{
    GradientStop _data[];
} grad_stops_1;

layout(binding = 1, std430) readonly buffer instances
{
    InstanceData _data[];
} instances_1;

layout(location = 0) in vec2 input_local_pos;
layout(location = 1) in vec2 input_size;
layout(location = 2) in vec2 input_uv;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 5) flat in uint input_instance_id;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _3097 = instances_1._data[input_instance_id].shadow_color;
    _3097.w = 0.0;
    vec4 _3364 = instances_1._data[input_instance_id].corner_radii * _1774.uniforms.scale_factor;
    float _3379 = instances_1._data[input_instance_id].border_width * _1774.uniforms.scale_factor;
    float _3383 = instances_1._data[input_instance_id].shadow_blur * _1774.uniforms.scale_factor;
    vec2 _3390 = vec2(instances_1._data[input_instance_id].shadow_offset_x, instances_1._data[input_instance_id].shadow_offset_y) * _1774.uniforms.scale_factor;
    bool _4256 = input_local_pos.y < 0.0;
    float _4270 = (input_local_pos.x < 0.0) ? (_4256 ? _3364.x : _3364.w) : (_4256 ? _3364.y : _3364.z);
    vec2 _4277 = (abs(input_local_pos) - input_size) + vec2(_4270);
    float _4289 = (min(max(_4277.x, _4277.y), 0.0) + length(max(_4277, vec2(0.0)))) - _4270;
    float _4504 = dFdxFine(_4289);
    float _4506 = dFdyFine(_4289);
    float _3458 = max(length(vec2(_4504, _4506)) * 0.5, 0.5);
    float _4517 = -_3458;
    float _4519 = smoothstep(_3458, _4517, _4289);
    float _6657 = 0.0;
    do
    {
        if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
        {
            _6657 = 1.0;
            break;
        }
        vec2 _4597 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1774.uniforms.scale_factor)) - ((input_rect_clip.zw * _1774.uniforms.scale_factor) * 0.5);
        float _4610 = min(max(_4597.x, _4597.y), 0.0) + length(max(_4597, vec2(0.0)));
        float _4583 = max((abs(dFdxFine(_4610)) + abs(dFdyFine(_4610))) * 0.5, 0.5);
        _6657 = smoothstep(_4583, -_4583, _4610);
        break;
    } while(false);
    float _6697 = 0.0;
    do
    {
        if (_1774.uniforms.clip_shape_kind == 0u)
        {
            _6697 = 1.0;
            break;
        }
        vec2 _4670 = (_1774.uniforms.clip_rect.xy + (_1774.uniforms.clip_rect.zw * 0.5)) * _1774.uniforms.scale_factor;
        vec2 _4677 = (_1774.uniforms.clip_rect.zw * _1774.uniforms.scale_factor) * 0.5;
        float _6695 = 0.0;
        if (_1774.uniforms.clip_shape_kind == 1u)
        {
            float _4686 = _1774.uniforms.clip_radius * _1774.uniforms.scale_factor;
            vec2 _4843 = (abs(input_screen_pos - _4670) - _4677) + vec2(_4686);
            _6695 = (min(max(_4843.x, _4843.y), 0.0) + length(max(_4843, vec2(0.0)))) - _4686;
        }
        else
        {
            float _6696 = 0.0;
            if (_1774.uniforms.clip_shape_kind == 2u)
            {
                _6696 = length((input_screen_pos - _4670) / max(_4677, vec2(0.001000000047497451305389404296875))) - 1.0;
            }
            else
            {
                if (_1774.uniforms.clip_shape_kind == 3u)
                {
                    uint _4710 = min(_1774.uniforms.clip_point_count, 32u);
                    uint _4713 = min(_1774.uniforms.clip_contour_count, 8u);
                    if ((_4710 < 3u) || (_4713 == 0u))
                    {
                        _6697 = 1.0;
                        break;
                    }
                    vec2 _4728 = input_screen_pos - (_1774.uniforms.clip_rect.xy * _1774.uniforms.scale_factor);
                    bool _6678 = false;
                    do
                    {
                        if (_1774.uniforms.clip_fill_rule == 0u)
                        {
                            bool _6677 = false;
                            _6677 = false;
                            uint _4906 = 0u;
                            bool _6799 = false;
                            for (uint _6676 = 0u, _6687 = 0u; _6676 < _4713; _6687 = _4906, _6677 = _6799, _6676++)
                            {
                                _4906 = min(_1774.uniforms.clip_polygon_end_points[_6676 / 4u][_6676 % 4u], _4710);
                                if (_4906 <= (_6687 + 1u))
                                {
                                    _6799 = _6677;
                                    continue;
                                }
                                bool _6690 = false;
                                _6690 = _6677;
                                bool _6804 = false;
                                for (uint _6688 = _6687; _6688 < _4906; _6690 = _6804, _6688++)
                                {
                                    uint _4922 = _6688 + 1u;
                                    uint _4928 = (_4922 < _4906) ? _4922 : _6687;
                                    uint _5021 = _6688 / 2u;
                                    bvec2 _5031 = bvec2((_6688 % 2u) == 0u);
                                    vec2 _4934 = vec2(_5031.x ? _1774.uniforms.clip_polygon_points[_5021].xy.x : _1774.uniforms.clip_polygon_points[_5021].zw.x, _5031.y ? _1774.uniforms.clip_polygon_points[_5021].xy.y : _1774.uniforms.clip_polygon_points[_5021].zw.y) * _1774.uniforms.scale_factor;
                                    uint _5037 = _4928 / 2u;
                                    bvec2 _5047 = bvec2((_4928 % 2u) == 0u);
                                    vec2 _4940 = vec2(_5047.x ? _1774.uniforms.clip_polygon_points[_5037].xy.x : _1774.uniforms.clip_polygon_points[_5037].zw.x, _5047.y ? _1774.uniforms.clip_polygon_points[_5037].xy.y : _1774.uniforms.clip_polygon_points[_5037].zw.y) * _1774.uniforms.scale_factor;
                                    float _4942 = _4940.y;
                                    float _4944 = _4934.y;
                                    float _4945 = _4942 - _4944;
                                    float _4957 = _4728.y;
                                    float _4970 = _4934.x;
                                    if (((_4944 > _4957) != (_4942 > _4957)) && (_4728.x < ((((_4940.x - _4970) * (_4957 - _4944)) / ((abs(_4945) < 9.9999997473787516355514526367188e-05) ? ((_4945 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _4945)) + _4970)))
                                    {
                                        _6804 = !_6690;
                                    }
                                    else
                                    {
                                        _6804 = _6690;
                                    }
                                }
                                _6799 = _6690;
                            }
                            _6678 = _6677;
                            break;
                        }
                        int _6659 = 0;
                        _6659 = 0;
                        uint _5077 = 0u;
                        int _6787 = 0;
                        for (uint _6658 = 0u, _6660 = 0u; _6658 < _4713; _6660 = _5077, _6659 = _6787, _6658++)
                        {
                            _5077 = min(_1774.uniforms.clip_polygon_end_points[_6658 / 4u][_6658 % 4u], _4710);
                            if (_5077 <= (_6660 + 1u))
                            {
                                _6787 = _6659;
                                continue;
                            }
                            int _6663 = 0;
                            _6663 = _6659;
                            int _6794 = 0;
                            for (uint _6661 = _6660; _6661 < _5077; _6663 = _6794, _6661++)
                            {
                                uint _5093 = _6661 + 1u;
                                uint _5099 = (_5093 < _5077) ? _5093 : _6660;
                                uint _5214 = _6661 / 2u;
                                bvec2 _5224 = bvec2((_6661 % 2u) == 0u);
                                vec2 _5105 = vec2(_5224.x ? _1774.uniforms.clip_polygon_points[_5214].xy.x : _1774.uniforms.clip_polygon_points[_5214].zw.x, _5224.y ? _1774.uniforms.clip_polygon_points[_5214].xy.y : _1774.uniforms.clip_polygon_points[_5214].zw.y) * _1774.uniforms.scale_factor;
                                uint _5230 = _5099 / 2u;
                                bvec2 _5240 = bvec2((_5099 % 2u) == 0u);
                                vec2 _5111 = vec2(_5240.x ? _1774.uniforms.clip_polygon_points[_5230].xy.x : _1774.uniforms.clip_polygon_points[_5230].zw.x, _5240.y ? _1774.uniforms.clip_polygon_points[_5230].xy.y : _1774.uniforms.clip_polygon_points[_5230].zw.y) * _1774.uniforms.scale_factor;
                                float _5113 = _5105.y;
                                float _5115 = _4728.y;
                                if (_5113 <= _5115)
                                {
                                    float _5119 = _5111.y;
                                    int _6795 = 0;
                                    if (_5119 > _5115)
                                    {
                                        float _5127 = _5105.x;
                                        int _6796 = 0;
                                        if ((((_5111.x - _5127) * (_5115 - _5113)) - ((_4728.x - _5127) * (_5119 - _5113))) > 0.0)
                                        {
                                            _6796 = _6663 + 1;
                                        }
                                        else
                                        {
                                            _6796 = _6663;
                                        }
                                        _6795 = _6796;
                                    }
                                    else
                                    {
                                        _6795 = _6663;
                                    }
                                    _6794 = _6795;
                                }
                                else
                                {
                                    float _5156 = _5111.y;
                                    int _6797 = 0;
                                    if (_5156 <= _5115)
                                    {
                                        float _5164 = _5105.x;
                                        int _6798 = 0;
                                        if ((((_5111.x - _5164) * (_5115 - _5113)) - ((_4728.x - _5164) * (_5156 - _5113))) < 0.0)
                                        {
                                            _6798 = _6663 - 1;
                                        }
                                        else
                                        {
                                            _6798 = _6663;
                                        }
                                        _6797 = _6798;
                                    }
                                    else
                                    {
                                        _6797 = _6663;
                                    }
                                    _6794 = _6797;
                                }
                            }
                            _6787 = _6663;
                        }
                        _6678 = _6659 != 0;
                        break;
                    } while(false);
                    float _6680 = 0.0;
                    uint _6681 = 0u;
                    _6681 = 0u;
                    _6680 = uintBitsToFloat(0x7f800000u /* inf */);
                    uint _4745 = 0u;
                    float _6800 = 0.0;
                    for (uint _6679 = 0u; _6679 < _4713; _6681 = _4745, _6680 = _6800, _6679++)
                    {
                        _4745 = min(_1774.uniforms.clip_polygon_end_points[_6679 / 4u][_6679 % 4u], _4710);
                        if (_4745 <= (_6681 + 1u))
                        {
                            _6800 = _6680;
                            continue;
                        }
                        float _6684 = 0.0;
                        _6684 = _6680;
                        for (uint _6682 = _6681; _6682 < _4745; )
                        {
                            uint _4761 = _6682 + 1u;
                            uint _4767 = (_4761 < _4745) ? _4761 : _6681;
                            uint _5254 = _6682 / 2u;
                            bvec2 _5264 = bvec2((_6682 % 2u) == 0u);
                            vec2 _4773 = vec2(_5264.x ? _1774.uniforms.clip_polygon_points[_5254].xy.x : _1774.uniforms.clip_polygon_points[_5254].zw.x, _5264.y ? _1774.uniforms.clip_polygon_points[_5254].xy.y : _1774.uniforms.clip_polygon_points[_5254].zw.y) * _1774.uniforms.scale_factor;
                            uint _5270 = _4767 / 2u;
                            bvec2 _5280 = bvec2((_4767 % 2u) == 0u);
                            vec2 _5289 = (vec2(_5280.x ? _1774.uniforms.clip_polygon_points[_5270].xy.x : _1774.uniforms.clip_polygon_points[_5270].zw.x, _5280.y ? _1774.uniforms.clip_polygon_points[_5270].xy.y : _1774.uniforms.clip_polygon_points[_5270].zw.y) * _1774.uniforms.scale_factor) - _4773;
                            _6684 = min(_6684, length(_4728 - (_4773 + (_5289 * clamp(dot(_4728 - _4773, _5289) / max(dot(_5289, _5289), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                            _6682++;
                            continue;
                        }
                        _6800 = _6684;
                    }
                    float _4804 = max(length(vec2(dFdxFine(input_screen_pos.x), dFdyFine(input_screen_pos.y))) * 0.5, 0.75);
                    _6697 = smoothstep(_4804, -_4804, _6678 ? (-_6680) : _6680);
                    break;
                }
                _6696 = 1.0;
            }
            _6695 = _6696;
        }
        float _4826 = max((abs(dFdxFine(_6695)) + abs(dFdyFine(_6695))) * 0.5, 0.5);
        _6697 = smoothstep(_4826, -_4826, _6695);
        break;
    } while(false);
    vec4 _3546 = instances_1._data[input_instance_id].border_widths * _1774.uniforms.scale_factor;
    float _3548 = _3546.x;
    float _3550 = _3546.y;
    float _3553 = _3546.z;
    float _3556 = _3546.w;
    float _6738 = 0.0;
    if (true && (((((_3548 + _3550) + _3553) + _3556) > 0.0) && true))
    {
        vec4 _3643 = max(_3364 - vec4(max(_3548, _3556), max(_3548, _3550), max(_3553, _3550), max(_3553, _3556)), vec4(0.0));
        vec2 _3647 = input_local_pos - vec2((_3556 - _3550) * 0.5, (_3548 - _3553) * 0.5);
        bool _5319 = _3647.y < 0.0;
        float _5333 = (_3647.x < 0.0) ? (_5319 ? _3643.x : _3643.w) : (_5319 ? _3643.y : _3643.z);
        vec2 _5340 = (abs(_3647) - max(vec2(input_size.x - ((_3550 + _3556) * 0.5), input_size.y - ((_3548 + _3553) * 0.5)), vec2(0.0))) + vec2(_5333);
        _6738 = _4519 - smoothstep(_3458, _4517, (min(max(_5340.x, _5340.y), 0.0) + length(max(_5340, vec2(0.0)))) - _5333);
    }
    else
    {
        float _6739 = 0.0;
        if (true && (_3379 > 0.0))
        {
            _6739 = _4519 - smoothstep(_3458, _4517, _4289 + _3379);
        }
        else
        {
            _6739 = 0.0;
        }
        _6738 = _6739;
    }
    vec4 _6994 = vec4(0.0);
    _6994 = vec4(0.0);
    vec4 _7001 = vec4(0.0);
    SPIRV_CROSS_LOOP
    for (uint _6718 = 0u; _6718 < 2u; _6994 = _7001, _6718++)
    {
        bool _3764 = _6718 == 0u;
        if (true && (_3764 ? (_3383 > 0.0) : false))
        {
            vec2 _6761 = vec2(0.0);
            vec2 _6763 = vec2(0.0);
            vec4 _6766 = vec4(0.0);
            vec4 _6772 = vec4(0.0);
            float _6776 = 0.0;
            if (_3764)
            {
                _6776 = _3383;
                _6772 = _3097;
                _6766 = max(_3364, vec4(0.0));
                _6763 = max(input_size, vec2(0.0));
                _6761 = _3390;
            }
            else
            {
                _6776 = shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].blur * _1774.uniforms.scale_factor;
                _6772 = shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].color;
                _6766 = _3364;
                _6763 = input_size;
                _6761 = vec2(shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].offset_x, shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].offset_y) * _1774.uniforms.scale_factor;
            }
            vec2 _3855 = input_local_pos - _6761;
            bool _5459 = _3855.y < 0.0;
            float _5473 = (_3855.x < 0.0) ? (_5459 ? _6766.x : _6766.w) : (_5459 ? _6766.y : _6766.z);
            vec2 _5480 = (abs(_3855) - _6763) + vec2(_5473);
            float _3872 = _6772.w * (smoothstep(_6776, -_6776, (min(max(_5480.x, _5480.y), 0.0) + length(max(_5480, vec2(0.0)))) - _5473) * (1.0 - _4519));
            _7001 = _6994 + (vec4(_6772.xyz * _3872, _3872) * (1.0 - _6994.w));
        }
        else
        {
            _7001 = _6994;
        }
    }
    vec4 _6998 = vec4(0.0);
    if (true && (_4519 > 0.0))
    {
        float _3974 = ((instances_1._data[input_instance_id].shadow_blur * 2.0) + abs(instances_1._data[input_instance_id].shadow_offset_x)) + abs(instances_1._data[input_instance_id].shadow_offset_y);
        float _4042 = clamp(clamp(((input_uv * (instances_1._data[input_instance_id].rect.zw + vec2(_3974 * 2.0))) - vec2(_3974)) / max(instances_1._data[input_instance_id].rect.zw, vec2(0.001000000047497451305389404296875)), vec2(0.0), vec2(1.0)).y, 0.0, 1.0);
        vec4 _6992 = vec4(0.0);
        if (instances_1._data[input_instance_id].gradient_stop_count > 0u)
        {
            vec4 _6730 = vec4(0.0);
            do
            {
                if (instances_1._data[input_instance_id].gradient_stop_count == 0u)
                {
                    _6730 = vec4(0.0);
                    break;
                }
                if (instances_1._data[input_instance_id].gradient_stop_count > 16u)
                {
                    _6730 = vec4(1.0, 0.0, 1.0, 1.0);
                    break;
                }
                if (instances_1._data[input_instance_id].gradient_stop_count == 1u)
                {
                    _6730 = grad_stops_1._data[instances_1._data[input_instance_id].gradient_stop_offset].color;
                    break;
                }
                uint _5587 = (instances_1._data[input_instance_id].gradient_stop_offset + instances_1._data[input_instance_id].gradient_stop_count) - 1u;
                float _5593 = clamp(_4042, grad_stops_1._data[instances_1._data[input_instance_id].gradient_stop_offset].position, grad_stops_1._data[_5587].position);
                vec4 _6727 = vec4(0.0);
                _6727 = grad_stops_1._data[_5587].color;
                bool _7008 = false;
                vec4 _6805 = vec4(0.0);
                uint _6726 = 0u;
                bool _6728 = false;
                for (; _6726 < (instances_1._data[input_instance_id].gradient_stop_count - 1u); _6728 = _7008, _6727 = _6805, _6726++)
                {
                    uint _5609 = instances_1._data[input_instance_id].gradient_stop_offset + _6726;
                    uint _5625 = _5609 + 1u;
                    bool _5649 = ((!_6728) && (_5593 >= grad_stops_1._data[_5609].position)) && (_5593 <= grad_stops_1._data[_5625].position);
                    if (_5649)
                    {
                        float _5655 = grad_stops_1._data[_5625].position - grad_stops_1._data[_5609].position;
                        vec4 _5673 = mix(vec4(grad_stops_1._data[_5609].color.xyz * grad_stops_1._data[_5609].color.w, grad_stops_1._data[_5609].color.w), vec4(grad_stops_1._data[_5625].color.xyz * grad_stops_1._data[_5625].color.w, grad_stops_1._data[_5625].color.w), vec4((_5655 > 9.9999999747524270787835121154785e-07) ? ((_5593 - grad_stops_1._data[_5609].position) / _5655) : 0.0));
                        vec4 _5725 = vec4(_5673.xyz / vec3(_5673.w), _5673.w);
                        bvec4 _5726 = bvec4(_5673.w > 9.9999999747524270787835121154785e-07);
                        _6805 = vec4(_5726.x ? _5725.x : vec4(0.0).x, _5726.y ? _5725.y : vec4(0.0).y, _5726.z ? _5725.z : vec4(0.0).z, _5726.w ? _5725.w : vec4(0.0).w);
                    }
                    else
                    {
                        _6805 = _6727;
                    }
                    _7008 = _5649 ? true : _6728;
                }
                _6730 = _6727;
                break;
            } while(false);
            _6992 = _6730;
        }
        else
        {
            vec4 _4066 = mix(vec4(instances_1._data[input_instance_id].fill_color.xyz * instances_1._data[input_instance_id].fill_color.w, instances_1._data[input_instance_id].fill_color.w), vec4(instances_1._data[input_instance_id].gradient_to_color.xyz * instances_1._data[input_instance_id].gradient_to_color.w, instances_1._data[input_instance_id].gradient_to_color.w), vec4(_4042));
            float _5757 = _4066.w;
            vec4 _5770 = vec4(_4066.xyz / vec3(_5757), _5757);
            bvec4 _5771 = bvec4(_5757 > 9.9999999747524270787835121154785e-07);
            _6992 = vec4(_5771.x ? _5770.x : vec4(0.0).x, _5771.y ? _5770.y : vec4(0.0).y, _5771.z ? _5770.z : vec4(0.0).z, _5771.w ? _5770.w : vec4(0.0).w);
        }
        float _4145 = _6992.w * _4519;
        vec4 _7005 = vec4(clamp(_6992.xyz + vec3((float(_642[((uint(input_screen_pos.y) & 15u) * 16u) + (uint(input_screen_pos.x) & 15u)]) - 127.5) * 1.5378700481960549950599670410156e-05), vec3(0.0), vec3(1.0)), _4145);
        vec3 _4151 = _7005.xyz * _4145;
        _7005.x = _4151.x;
        _7005.y = _4151.y;
        _7005.z = _4151.z;
        _6998 = _6994 + (_7005 * (1.0 - _6994.w));
    }
    else
    {
        _6998 = _6994;
    }
    vec4 _6999 = vec4(0.0);
    if (true && (_6738 > 0.0))
    {
        float _4217 = instances_1._data[input_instance_id].border_color.w * _6738;
        _6999 = _6998 + (vec4(instances_1._data[input_instance_id].border_color.xyz * _4217, _4217) * (1.0 - _6998.w));
    }
    else
    {
        _6999 = _6998;
    }
    vec4 _4237 = _6999 * (_6657 * _6697);
    if (_4237.w < 0.001000000047497451305389404296875)
    {
        discard;
    }
    _entryPointOutput = _4237;
}

