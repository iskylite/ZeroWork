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
    vec4 _6775 = vec4(0.0);
    do
    {
        vec4 _3354 = instances_1._data[input_instance_id].corner_radii * _1774.uniforms.scale_factor;
        float _3369 = instances_1._data[input_instance_id].border_width * _1774.uniforms.scale_factor;
        float _3373 = instances_1._data[input_instance_id].shadow_blur * _1774.uniforms.scale_factor;
        vec2 _3380 = vec2(instances_1._data[input_instance_id].shadow_offset_x, instances_1._data[input_instance_id].shadow_offset_y) * _1774.uniforms.scale_factor;
        bool _3384 = instances_1._data[input_instance_id].shape_type == 0u;
        float _6633 = 0.0;
        if (_3384)
        {
            bool _4246 = input_local_pos.y < 0.0;
            float _4260 = (input_local_pos.x < 0.0) ? (_4246 ? _3354.x : _3354.w) : (_4246 ? _3354.y : _3354.z);
            vec2 _4267 = (abs(input_local_pos) - input_size) + vec2(_4260);
            _6633 = (min(max(_4267.x, _4267.y), 0.0) + length(max(_4267, vec2(0.0)))) - _4260;
        }
        else
        {
            float _6634 = 0.0;
            if (instances_1._data[input_instance_id].shape_type == 1u)
            {
                _6634 = length(input_local_pos) - min(input_size.x, input_size.y);
            }
            else
            {
                float _6635 = 0.0;
                if (instances_1._data[input_instance_id].shape_type == 2u)
                {
                    _6635 = abs(input_local_pos.y) - _3354.x;
                }
                else
                {
                    float _6636 = 0.0;
                    if (instances_1._data[input_instance_id].shape_type == 3u)
                    {
                        float _3425 = _3354.x;
                        float _6632 = 0.0;
                        do
                        {
                            float _4309 = _3369 * 0.5;
                            float _4319 = abs(length(input_local_pos) - (_3425 - _4309)) - _4309;
                            float _4323 = clamp(instances_1._data[input_instance_id].shadow_offset_y - instances_1._data[input_instance_id].shadow_offset_x, 0.0, 6.283185482025146484375);
                            if (_4323 >= 6.283085346221923828125)
                            {
                                _6632 = _4319;
                                break;
                            }
                            if (_4323 <= 0.0)
                            {
                                _6632 = max(_4319, 0.0) + 1.0;
                                break;
                            }
                            float _4339 = max(_3425 - _3369, 0.0);
                            vec2 _4388 = vec2(cos(instances_1._data[input_instance_id].shadow_offset_x), sin(instances_1._data[input_instance_id].shadow_offset_x));
                            float _4395 = _3425 - _4339;
                            vec2 _4396 = _4388 * _4395;
                            vec2 _4399 = input_local_pos - (_4388 * _4339);
                            float _4347 = instances_1._data[input_instance_id].shadow_offset_x + _4323;
                            vec2 _4424 = vec2(cos(_4347), sin(_4347));
                            vec2 _4432 = _4424 * _4395;
                            vec2 _4435 = input_local_pos - (_4424 * _4339);
                            float _4352 = min(length(_4399 - (_4396 * clamp(dot(_4399, _4396) / max(dot(_4396, _4396), 9.9999999747524270787835121154785e-07), 0.0, 1.0))), length(_4435 - (_4432 * clamp(dot(_4435, _4432) / max(dot(_4432, _4432), 9.9999999747524270787835121154785e-07), 0.0, 1.0))));
                            float _4360 = atan(input_local_pos.y, input_local_pos.x) - instances_1._data[input_instance_id].shadow_offset_x;
                            _6632 = ((_4360 - (floor(_4360 * 0.15915493667125701904296875) * 6.283185482025146484375)) <= _4323) ? max(_4319, -_4352) : _4352;
                            break;
                        } while(false);
                        _6636 = _6632;
                    }
                    else
                    {
                        float _6637 = 0.0;
                        if (instances_1._data[input_instance_id].shape_type == 4u)
                        {
                            float _6631 = 0.0;
                            do
                            {
                                vec2 _4460 = max(input_size, vec2(0.001000000047497451305389404296875));
                                float _4465 = length(input_local_pos / _4460);
                                if (_4465 < 9.9999999747524270787835121154785e-07)
                                {
                                    _6631 = -min(_4460.x, _4460.y);
                                    break;
                                }
                                _6631 = (_4465 - 1.0) / max(length(input_local_pos / (_4460 * _4460)) / _4465, 9.9999999747524270787835121154785e-07);
                                break;
                            } while(false);
                            _6637 = _6631;
                        }
                        else
                        {
                            _6637 = 1.0;
                        }
                        _6636 = _6637;
                    }
                    _6635 = _6636;
                }
                _6634 = _6635;
            }
            _6633 = _6634;
        }
        float _4494 = dFdxFine(_6633);
        float _4496 = dFdyFine(_6633);
        float _3448 = max(length(vec2(_4494, _4496)) * 0.5, 0.5);
        float _4507 = -_3448;
        float _4509 = smoothstep(_3448, _4507, _6633);
        float _6646 = 0.0;
        do
        {
            if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
            {
                _6646 = 1.0;
                break;
            }
            vec2 _4587 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1774.uniforms.scale_factor)) - ((input_rect_clip.zw * _1774.uniforms.scale_factor) * 0.5);
            float _4600 = min(max(_4587.x, _4587.y), 0.0) + length(max(_4587, vec2(0.0)));
            float _4573 = max((abs(dFdxFine(_4600)) + abs(dFdyFine(_4600))) * 0.5, 0.5);
            _6646 = smoothstep(_4573, -_4573, _4600);
            break;
        } while(false);
        float _6686 = 0.0;
        do
        {
            if (_1774.uniforms.clip_shape_kind == 0u)
            {
                _6686 = 1.0;
                break;
            }
            vec2 _4660 = (_1774.uniforms.clip_rect.xy + (_1774.uniforms.clip_rect.zw * 0.5)) * _1774.uniforms.scale_factor;
            vec2 _4667 = (_1774.uniforms.clip_rect.zw * _1774.uniforms.scale_factor) * 0.5;
            float _6684 = 0.0;
            if (_1774.uniforms.clip_shape_kind == 1u)
            {
                float _4676 = _1774.uniforms.clip_radius * _1774.uniforms.scale_factor;
                vec2 _4833 = (abs(input_screen_pos - _4660) - _4667) + vec2(_4676);
                _6684 = (min(max(_4833.x, _4833.y), 0.0) + length(max(_4833, vec2(0.0)))) - _4676;
            }
            else
            {
                float _6685 = 0.0;
                if (_1774.uniforms.clip_shape_kind == 2u)
                {
                    _6685 = length((input_screen_pos - _4660) / max(_4667, vec2(0.001000000047497451305389404296875))) - 1.0;
                }
                else
                {
                    if (_1774.uniforms.clip_shape_kind == 3u)
                    {
                        uint _4700 = min(_1774.uniforms.clip_point_count, 32u);
                        uint _4703 = min(_1774.uniforms.clip_contour_count, 8u);
                        if ((_4700 < 3u) || (_4703 == 0u))
                        {
                            _6686 = 1.0;
                            break;
                        }
                        vec2 _4718 = input_screen_pos - (_1774.uniforms.clip_rect.xy * _1774.uniforms.scale_factor);
                        bool _6667 = false;
                        do
                        {
                            if (_1774.uniforms.clip_fill_rule == 0u)
                            {
                                bool _6666 = false;
                                _6666 = false;
                                uint _4896 = 0u;
                                bool _6788 = false;
                                for (uint _6665 = 0u, _6676 = 0u; _6665 < _4703; _6676 = _4896, _6666 = _6788, _6665++)
                                {
                                    _4896 = min(_1774.uniforms.clip_polygon_end_points[_6665 / 4u][_6665 % 4u], _4700);
                                    if (_4896 <= (_6676 + 1u))
                                    {
                                        _6788 = _6666;
                                        continue;
                                    }
                                    bool _6679 = false;
                                    _6679 = _6666;
                                    bool _6793 = false;
                                    for (uint _6677 = _6676; _6677 < _4896; _6679 = _6793, _6677++)
                                    {
                                        uint _4912 = _6677 + 1u;
                                        uint _4918 = (_4912 < _4896) ? _4912 : _6676;
                                        uint _5011 = _6677 / 2u;
                                        bvec2 _5021 = bvec2((_6677 % 2u) == 0u);
                                        vec2 _4924 = vec2(_5021.x ? _1774.uniforms.clip_polygon_points[_5011].xy.x : _1774.uniforms.clip_polygon_points[_5011].zw.x, _5021.y ? _1774.uniforms.clip_polygon_points[_5011].xy.y : _1774.uniforms.clip_polygon_points[_5011].zw.y) * _1774.uniforms.scale_factor;
                                        uint _5027 = _4918 / 2u;
                                        bvec2 _5037 = bvec2((_4918 % 2u) == 0u);
                                        vec2 _4930 = vec2(_5037.x ? _1774.uniforms.clip_polygon_points[_5027].xy.x : _1774.uniforms.clip_polygon_points[_5027].zw.x, _5037.y ? _1774.uniforms.clip_polygon_points[_5027].xy.y : _1774.uniforms.clip_polygon_points[_5027].zw.y) * _1774.uniforms.scale_factor;
                                        float _4932 = _4930.y;
                                        float _4934 = _4924.y;
                                        float _4935 = _4932 - _4934;
                                        float _4947 = _4718.y;
                                        float _4960 = _4924.x;
                                        if (((_4934 > _4947) != (_4932 > _4947)) && (_4718.x < ((((_4930.x - _4960) * (_4947 - _4934)) / ((abs(_4935) < 9.9999997473787516355514526367188e-05) ? ((_4935 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _4935)) + _4960)))
                                        {
                                            _6793 = !_6679;
                                        }
                                        else
                                        {
                                            _6793 = _6679;
                                        }
                                    }
                                    _6788 = _6679;
                                }
                                _6667 = _6666;
                                break;
                            }
                            int _6648 = 0;
                            _6648 = 0;
                            uint _5067 = 0u;
                            int _6776 = 0;
                            for (uint _6647 = 0u, _6649 = 0u; _6647 < _4703; _6649 = _5067, _6648 = _6776, _6647++)
                            {
                                _5067 = min(_1774.uniforms.clip_polygon_end_points[_6647 / 4u][_6647 % 4u], _4700);
                                if (_5067 <= (_6649 + 1u))
                                {
                                    _6776 = _6648;
                                    continue;
                                }
                                int _6652 = 0;
                                _6652 = _6648;
                                int _6783 = 0;
                                for (uint _6650 = _6649; _6650 < _5067; _6652 = _6783, _6650++)
                                {
                                    uint _5083 = _6650 + 1u;
                                    uint _5089 = (_5083 < _5067) ? _5083 : _6649;
                                    uint _5204 = _6650 / 2u;
                                    bvec2 _5214 = bvec2((_6650 % 2u) == 0u);
                                    vec2 _5095 = vec2(_5214.x ? _1774.uniforms.clip_polygon_points[_5204].xy.x : _1774.uniforms.clip_polygon_points[_5204].zw.x, _5214.y ? _1774.uniforms.clip_polygon_points[_5204].xy.y : _1774.uniforms.clip_polygon_points[_5204].zw.y) * _1774.uniforms.scale_factor;
                                    uint _5220 = _5089 / 2u;
                                    bvec2 _5230 = bvec2((_5089 % 2u) == 0u);
                                    vec2 _5101 = vec2(_5230.x ? _1774.uniforms.clip_polygon_points[_5220].xy.x : _1774.uniforms.clip_polygon_points[_5220].zw.x, _5230.y ? _1774.uniforms.clip_polygon_points[_5220].xy.y : _1774.uniforms.clip_polygon_points[_5220].zw.y) * _1774.uniforms.scale_factor;
                                    float _5103 = _5095.y;
                                    float _5105 = _4718.y;
                                    if (_5103 <= _5105)
                                    {
                                        float _5109 = _5101.y;
                                        int _6784 = 0;
                                        if (_5109 > _5105)
                                        {
                                            float _5117 = _5095.x;
                                            int _6785 = 0;
                                            if ((((_5101.x - _5117) * (_5105 - _5103)) - ((_4718.x - _5117) * (_5109 - _5103))) > 0.0)
                                            {
                                                _6785 = _6652 + 1;
                                            }
                                            else
                                            {
                                                _6785 = _6652;
                                            }
                                            _6784 = _6785;
                                        }
                                        else
                                        {
                                            _6784 = _6652;
                                        }
                                        _6783 = _6784;
                                    }
                                    else
                                    {
                                        float _5146 = _5101.y;
                                        int _6786 = 0;
                                        if (_5146 <= _5105)
                                        {
                                            float _5154 = _5095.x;
                                            int _6787 = 0;
                                            if ((((_5101.x - _5154) * (_5105 - _5103)) - ((_4718.x - _5154) * (_5146 - _5103))) < 0.0)
                                            {
                                                _6787 = _6652 - 1;
                                            }
                                            else
                                            {
                                                _6787 = _6652;
                                            }
                                            _6786 = _6787;
                                        }
                                        else
                                        {
                                            _6786 = _6652;
                                        }
                                        _6783 = _6786;
                                    }
                                }
                                _6776 = _6652;
                            }
                            _6667 = _6648 != 0;
                            break;
                        } while(false);
                        float _6669 = 0.0;
                        uint _6670 = 0u;
                        _6670 = 0u;
                        _6669 = uintBitsToFloat(0x7f800000u /* inf */);
                        uint _4735 = 0u;
                        float _6789 = 0.0;
                        for (uint _6668 = 0u; _6668 < _4703; _6670 = _4735, _6669 = _6789, _6668++)
                        {
                            _4735 = min(_1774.uniforms.clip_polygon_end_points[_6668 / 4u][_6668 % 4u], _4700);
                            if (_4735 <= (_6670 + 1u))
                            {
                                _6789 = _6669;
                                continue;
                            }
                            float _6673 = 0.0;
                            _6673 = _6669;
                            for (uint _6671 = _6670; _6671 < _4735; )
                            {
                                uint _4751 = _6671 + 1u;
                                uint _4757 = (_4751 < _4735) ? _4751 : _6670;
                                uint _5244 = _6671 / 2u;
                                bvec2 _5254 = bvec2((_6671 % 2u) == 0u);
                                vec2 _4763 = vec2(_5254.x ? _1774.uniforms.clip_polygon_points[_5244].xy.x : _1774.uniforms.clip_polygon_points[_5244].zw.x, _5254.y ? _1774.uniforms.clip_polygon_points[_5244].xy.y : _1774.uniforms.clip_polygon_points[_5244].zw.y) * _1774.uniforms.scale_factor;
                                uint _5260 = _4757 / 2u;
                                bvec2 _5270 = bvec2((_4757 % 2u) == 0u);
                                vec2 _5279 = (vec2(_5270.x ? _1774.uniforms.clip_polygon_points[_5260].xy.x : _1774.uniforms.clip_polygon_points[_5260].zw.x, _5270.y ? _1774.uniforms.clip_polygon_points[_5260].xy.y : _1774.uniforms.clip_polygon_points[_5260].zw.y) * _1774.uniforms.scale_factor) - _4763;
                                _6673 = min(_6673, length(_4718 - (_4763 + (_5279 * clamp(dot(_4718 - _4763, _5279) / max(dot(_5279, _5279), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                                _6671++;
                                continue;
                            }
                            _6789 = _6673;
                        }
                        float _4794 = max(length(vec2(dFdxFine(input_screen_pos.x), dFdyFine(input_screen_pos.y))) * 0.5, 0.75);
                        _6686 = smoothstep(_4794, -_4794, _6667 ? (-_6669) : _6669);
                        break;
                    }
                    _6685 = 1.0;
                }
                _6684 = _6685;
            }
            float _4816 = max((abs(dFdxFine(_6684)) + abs(dFdyFine(_6684))) * 0.5, 0.5);
            _6686 = smoothstep(_4816, -_4816, _6684);
            break;
        } while(false);
        float _4525 = _6646 * _6686;
        SPIRV_CROSS_BRANCH
        if ((((true && (instances_1._data[input_instance_id].packed_flags == 0u)) && (instances_1._data[input_instance_id].border_width == 0.0)) && all(equal(instances_1._data[input_instance_id].border_widths, vec4(0.0)))) && (instances_1._data[input_instance_id].shadow_color.w == 0.0))
        {
            float _3510 = instances_1._data[input_instance_id].fill_color.w * _4509;
            vec4 _3525 = vec4(instances_1._data[input_instance_id].fill_color.xyz * _3510, _3510) * _4525;
            if (_3525.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _6775 = _3525;
            break;
        }
        vec4 _3536 = instances_1._data[input_instance_id].border_widths * _1774.uniforms.scale_factor;
        float _3538 = _3536.x;
        float _3540 = _3536.y;
        float _3543 = _3536.z;
        float _3546 = _3536.w;
        bool _3564 = _4509 > 0.0;
        float _6727 = 0.0;
        if (true && (((((_3538 + _3540) + _3543) + _3546) > 0.0) && _3384))
        {
            vec4 _3633 = max(_3354 - vec4(max(_3538, _3546), max(_3538, _3540), max(_3543, _3540), max(_3543, _3546)), vec4(0.0));
            vec2 _3637 = input_local_pos - vec2((_3546 - _3540) * 0.5, (_3538 - _3543) * 0.5);
            bool _5309 = _3637.y < 0.0;
            float _5323 = (_3637.x < 0.0) ? (_5309 ? _3633.x : _3633.w) : (_5309 ? _3633.y : _3633.z);
            vec2 _5330 = (abs(_3637) - max(vec2(input_size.x - ((_3540 + _3546) * 0.5), input_size.y - ((_3538 + _3543) * 0.5)), vec2(0.0))) + vec2(_5323);
            _6727 = _4509 - smoothstep(_3448, _4507, (min(max(_5330.x, _5330.y), 0.0) + length(max(_5330, vec2(0.0)))) - _5323);
        }
        else
        {
            float _6728 = 0.0;
            if (true && (_3369 > 0.0))
            {
                _6728 = _4509 - smoothstep(_3448, _4507, _6633 + _3369);
            }
            else
            {
                _6728 = 0.0;
            }
            _6727 = _6728;
        }
        uint _3734 = instances_1._data[input_instance_id].packed_flags & 255u;
        uint _3738 = (instances_1._data[input_instance_id].packed_flags >> 8u) & 255u;
        uint _3742 = (instances_1._data[input_instance_id].packed_flags >> 16u) & 255u;
        bool _3746 = (instances_1._data[input_instance_id].packed_flags & 33554432u) != 0u;
        vec4 _7044 = vec4(0.0);
        _7044 = vec4(0.0);
        vec4 _7067 = vec4(0.0);
        SPIRV_CROSS_LOOP
        for (uint _6707 = 0u; _6707 < 2u; _7044 = _7067, _6707++)
        {
            bool _3754 = _6707 == 0u;
            if (true && (_3754 ? (_3373 > 0.0) : _3746))
            {
                vec2 _6750 = vec2(0.0);
                vec2 _6752 = vec2(0.0);
                vec4 _6755 = vec4(0.0);
                vec4 _6761 = vec4(0.0);
                float _6765 = 0.0;
                if (_3754)
                {
                    float _3780 = ((instances_1._data[input_instance_id].packed_flags & 268435456u) != 0u) ? (instances_1._data[input_instance_id].noise_scale * _1774.uniforms.scale_factor) : 0.0;
                    vec2 _6753 = vec2(0.0);
                    vec4 _6756 = vec4(0.0);
                    if (_3384)
                    {
                        _6756 = max(_3354 + vec4(_3780), vec4(0.0));
                        _6753 = max(input_size + vec2(_3780), vec2(0.0));
                    }
                    else
                    {
                        _6756 = _3354;
                        _6753 = input_size;
                    }
                    _6765 = _3373;
                    _6761 = instances_1._data[input_instance_id].shadow_color;
                    _6755 = _6756;
                    _6752 = _6753;
                    _6750 = _3380;
                }
                else
                {
                    _6765 = shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].blur * _1774.uniforms.scale_factor;
                    _6761 = shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].color;
                    _6755 = _3354;
                    _6752 = input_size;
                    _6750 = vec2(shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].offset_x, shadow_params_1._data[instances_1._data[input_instance_id].shadow2_index].offset_y) * _1774.uniforms.scale_factor;
                }
                vec2 _3845 = input_local_pos - _6750;
                float _6759 = 0.0;
                do
                {
                    if (_3384)
                    {
                        bool _5449 = _3845.y < 0.0;
                        float _5463 = (_3845.x < 0.0) ? (_5449 ? _6755.x : _6755.w) : (_5449 ? _6755.y : _6755.z);
                        vec2 _5470 = (abs(_3845) - _6752) + vec2(_5463);
                        _6759 = (min(max(_5470.x, _5470.y), 0.0) + length(max(_5470, vec2(0.0)))) - _5463;
                        break;
                    }
                    if (instances_1._data[input_instance_id].shape_type == 1u)
                    {
                        _6759 = length(_3845) - min(_6752.x, _6752.y);
                        break;
                    }
                    if (instances_1._data[input_instance_id].shape_type == 4u)
                    {
                        float _6758 = 0.0;
                        do
                        {
                            vec2 _5499 = max(_6752, vec2(0.001000000047497451305389404296875));
                            float _5504 = length(_3845 / _5499);
                            if (_5504 < 9.9999999747524270787835121154785e-07)
                            {
                                _6758 = -min(_5499.x, _5499.y);
                                break;
                            }
                            _6758 = (_5504 - 1.0) / max(length(_3845 / (_5499 * _5499)) / _5504, 9.9999999747524270787835121154785e-07);
                            break;
                        } while(false);
                        _6759 = _6758;
                        break;
                    }
                    _6759 = 1.0;
                    break;
                } while(false);
                float _3862 = _6761.w * (smoothstep(_6765, -_6765, _6759) * (1.0 - _4509));
                _7067 = _7044 + (vec4(_6761.xyz * _3862, _3862) * (1.0 - _7044.w));
            }
            else
            {
                _7067 = _7044;
            }
        }
        vec4 _7059 = vec4(0.0);
        if (true && _3564)
        {
            vec4 _7040 = vec4(0.0);
            if (_3734 > 0u)
            {
                float _6708 = 0.0;
                if (_3734 == 4u)
                {
                    vec2 _3903 = vec2(0.5 + instances_1._data[input_instance_id].shadow_offset_x, 0.5 + instances_1._data[input_instance_id].shadow_offset_y);
                    float _6709 = 0.0;
                    if ((instances_1._data[input_instance_id].packed_flags & 536870912u) != 0u)
                    {
                        _6709 = length((input_uv - _3903) / max(vec2(instances_1._data[input_instance_id].noise_scale, instances_1._data[input_instance_id].noise_intensity), vec2(9.9999997473787516355514526367188e-05)));
                    }
                    else
                    {
                        _6709 = length(input_uv - _3903) * 2.0;
                    }
                    _6708 = _6709;
                }
                else
                {
                    float _6710 = 0.0;
                    if (_3734 == 5u)
                    {
                        _6710 = fract(((atan(input_uv.y - 0.5, input_uv.x - 0.5) - uintBitsToFloat(instances_1._data[input_instance_id]._ext_reserved)) * 0.15915493667125701904296875) + 0.5);
                    }
                    else
                    {
                        float _3965 = (instances_1._data[input_instance_id].shape_type == 3u) ? 0.0 : (((instances_1._data[input_instance_id].shadow_blur * 2.0) + abs(instances_1._data[input_instance_id].shadow_offset_x)) + abs(instances_1._data[input_instance_id].shadow_offset_y));
                        vec2 _3985 = clamp(((input_uv * (instances_1._data[input_instance_id].rect.zw + vec2(_3965 * 2.0))) - vec2(_3965)) / max(instances_1._data[input_instance_id].rect.zw, vec2(0.001000000047497451305389404296875)), vec2(0.0), vec2(1.0));
                        float _6711 = 0.0;
                        if (_3734 == 1u)
                        {
                            _6711 = _3985.y;
                        }
                        else
                        {
                            float _6712 = 0.0;
                            if (_3734 == 2u)
                            {
                                _6712 = _3985.x;
                            }
                            else
                            {
                                _6712 = (_3985.x + _3985.y) * 0.5;
                            }
                            _6711 = _6712;
                        }
                        _6710 = _6711;
                    }
                    _6708 = _6710;
                }
                uint _4011 = (instances_1._data[input_instance_id].packed_flags >> 26u) & 3u;
                float _6713 = 0.0;
                if (_4011 == 1u)
                {
                    _6713 = fract(_6708);
                }
                else
                {
                    float _6714 = 0.0;
                    if (_4011 == 2u)
                    {
                        float _4023 = mod(abs(_6708), 2.0);
                        _6714 = (_4023 > 1.0) ? (2.0 - _4023) : _4023;
                    }
                    else
                    {
                        _6714 = clamp(_6708, 0.0, 1.0);
                    }
                    _6713 = _6714;
                }
                vec4 _7037 = vec4(0.0);
                if (instances_1._data[input_instance_id].gradient_stop_count > 0u)
                {
                    vec4 _6719 = vec4(0.0);
                    do
                    {
                        if (instances_1._data[input_instance_id].gradient_stop_count == 0u)
                        {
                            _6719 = vec4(0.0);
                            break;
                        }
                        if (instances_1._data[input_instance_id].gradient_stop_count > 16u)
                        {
                            _6719 = vec4(1.0, 0.0, 1.0, 1.0);
                            break;
                        }
                        if (instances_1._data[input_instance_id].gradient_stop_count == 1u)
                        {
                            _6719 = grad_stops_1._data[instances_1._data[input_instance_id].gradient_stop_offset].color;
                            break;
                        }
                        uint _5577 = (instances_1._data[input_instance_id].gradient_stop_offset + instances_1._data[input_instance_id].gradient_stop_count) - 1u;
                        float _5583 = clamp(_6713, grad_stops_1._data[instances_1._data[input_instance_id].gradient_stop_offset].position, grad_stops_1._data[_5577].position);
                        vec4 _6716 = vec4(0.0);
                        _6716 = grad_stops_1._data[_5577].color;
                        bool _7076 = false;
                        vec4 _6794 = vec4(0.0);
                        uint _6715 = 0u;
                        bool _6717 = false;
                        for (; _6715 < (instances_1._data[input_instance_id].gradient_stop_count - 1u); _6717 = _7076, _6716 = _6794, _6715++)
                        {
                            uint _5599 = instances_1._data[input_instance_id].gradient_stop_offset + _6715;
                            uint _5615 = _5599 + 1u;
                            bool _5639 = ((!_6717) && (_5583 >= grad_stops_1._data[_5599].position)) && (_5583 <= grad_stops_1._data[_5615].position);
                            if (_5639)
                            {
                                float _5645 = grad_stops_1._data[_5615].position - grad_stops_1._data[_5599].position;
                                vec4 _5663 = mix(vec4(grad_stops_1._data[_5599].color.xyz * grad_stops_1._data[_5599].color.w, grad_stops_1._data[_5599].color.w), vec4(grad_stops_1._data[_5615].color.xyz * grad_stops_1._data[_5615].color.w, grad_stops_1._data[_5615].color.w), vec4((_5645 > 9.9999999747524270787835121154785e-07) ? ((_5583 - grad_stops_1._data[_5599].position) / _5645) : 0.0));
                                float _5702 = _5663.w;
                                vec4 _5715 = vec4(_5663.xyz / vec3(_5702), _5702);
                                bvec4 _5716 = bvec4(_5702 > 9.9999999747524270787835121154785e-07);
                                _6794 = vec4(_5716.x ? _5715.x : vec4(0.0).x, _5716.y ? _5715.y : vec4(0.0).y, _5716.z ? _5715.z : vec4(0.0).z, _5716.w ? _5715.w : vec4(0.0).w);
                            }
                            else
                            {
                                _6794 = _6716;
                            }
                            _7076 = _5639 ? true : _6717;
                        }
                        _6719 = _6716;
                        break;
                    } while(false);
                    _7037 = _6719;
                }
                else
                {
                    vec4 _4056 = mix(vec4(instances_1._data[input_instance_id].fill_color.xyz * instances_1._data[input_instance_id].fill_color.w, instances_1._data[input_instance_id].fill_color.w), vec4(instances_1._data[input_instance_id].gradient_to_color.xyz * instances_1._data[input_instance_id].gradient_to_color.w, instances_1._data[input_instance_id].gradient_to_color.w), vec4(_6713));
                    float _5747 = _4056.w;
                    vec4 _5760 = vec4(_4056.xyz / vec3(_5747), _5747);
                    bvec4 _5761 = bvec4(_5747 > 9.9999999747524270787835121154785e-07);
                    _7037 = vec4(_5761.x ? _5760.x : vec4(0.0).x, _5761.y ? _5760.y : vec4(0.0).y, _5761.z ? _5760.z : vec4(0.0).z, _5761.w ? _5760.w : vec4(0.0).w);
                }
                vec3 _4069 = clamp(_7037.xyz + vec3((float(_642[((uint(input_screen_pos.y) & 15u) * 16u) + (uint(input_screen_pos.x) & 15u)]) - 127.5) * 1.5378700481960549950599670410156e-05), vec3(0.0), vec3(1.0));
                vec4 _6974 = _7037;
                _6974.x = _4069.x;
                _6974.y = _4069.y;
                _6974.z = _4069.z;
                _7040 = _6974;
            }
            else
            {
                _7040 = instances_1._data[input_instance_id].fill_color;
            }
            vec4 _7041 = vec4(0.0);
            if ((_3738 > 0u) && (instances_1._data[input_instance_id].noise_scale > 0.0))
            {
                float _6720 = 0.0;
                if (_3738 == 1u)
                {
                    float _5805 = float(_3742);
                    vec2 _5811 = ((input_local_pos / vec2(_1774.uniforms.scale_factor)) / vec2(max(instances_1._data[input_instance_id].noise_scale, 0.001000000047497451305389404296875))) + vec2(_5805 * 17.299999237060546875, _5805 * 31.700000762939453125);
                    vec2 _5813 = floor(_5811);
                    vec2 _5815 = fract(_5811);
                    vec2 _5823 = (_5815 * _5815) * (vec2(3.0) - (_5815 * 2.0));
                    uint _5866 = uint(abs(_5813.y) * 1000.0) * 2654435761u;
                    uint _5878 = (_5866 ^ 61u) ^ (_5866 >> 16u);
                    uint _5882 = _5878 + (_5878 << 3u);
                    uint _5888 = (_5882 ^ (_5882 >> 4u)) * 668265261u;
                    uint _5868 = uint(abs(_5813.x) * 1000.0) ^ (_5888 ^ (_5888 >> 15u));
                    uint _5900 = (_5868 ^ 61u) ^ (_5868 >> 16u);
                    uint _5904 = _5900 + (_5900 << 3u);
                    uint _5910 = (_5904 ^ (_5904 >> 4u)) * 668265261u;
                    vec2 _5827 = _5813 + vec2(1.0, 0.0);
                    uint _5934 = uint(abs(_5827.y) * 1000.0) * 2654435761u;
                    uint _5946 = (_5934 ^ 61u) ^ (_5934 >> 16u);
                    uint _5950 = _5946 + (_5946 << 3u);
                    uint _5956 = (_5950 ^ (_5950 >> 4u)) * 668265261u;
                    uint _5936 = uint(abs(_5827.x) * 1000.0) ^ (_5956 ^ (_5956 >> 15u));
                    uint _5968 = (_5936 ^ 61u) ^ (_5936 >> 16u);
                    uint _5972 = _5968 + (_5968 << 3u);
                    uint _5978 = (_5972 ^ (_5972 >> 4u)) * 668265261u;
                    vec2 _5830 = _5813 + vec2(0.0, 1.0);
                    uint _6002 = uint(abs(_5830.y) * 1000.0) * 2654435761u;
                    uint _6014 = (_6002 ^ 61u) ^ (_6002 >> 16u);
                    uint _6018 = _6014 + (_6014 << 3u);
                    uint _6024 = (_6018 ^ (_6018 >> 4u)) * 668265261u;
                    uint _6004 = uint(abs(_5830.x) * 1000.0) ^ (_6024 ^ (_6024 >> 15u));
                    uint _6036 = (_6004 ^ 61u) ^ (_6004 >> 16u);
                    uint _6040 = _6036 + (_6036 << 3u);
                    uint _6046 = (_6040 ^ (_6040 >> 4u)) * 668265261u;
                    vec2 _5833 = _5813 + vec2(1.0);
                    uint _6070 = uint(abs(_5833.y) * 1000.0) * 2654435761u;
                    uint _6082 = (_6070 ^ 61u) ^ (_6070 >> 16u);
                    uint _6086 = _6082 + (_6082 << 3u);
                    uint _6092 = (_6086 ^ (_6086 >> 4u)) * 668265261u;
                    uint _6072 = uint(abs(_5833.x) * 1000.0) ^ (_6092 ^ (_6092 >> 15u));
                    uint _6104 = (_6072 ^ 61u) ^ (_6072 >> 16u);
                    uint _6108 = _6104 + (_6104 << 3u);
                    uint _6114 = (_6108 ^ (_6108 >> 4u)) * 668265261u;
                    float _5838 = _5823.x;
                    _6720 = mix(mix(float(_5910 ^ (_5910 >> 15u)) * 2.3283064365386962890625e-10, float(_5978 ^ (_5978 >> 15u)) * 2.3283064365386962890625e-10, _5838), mix(float(_6046 ^ (_6046 >> 15u)) * 2.3283064365386962890625e-10, float(_6114 ^ (_6114 >> 15u)) * 2.3283064365386962890625e-10, _5838), _5823.y) - 0.5;
                }
                else
                {
                    float _6721 = 0.0;
                    if (_3738 == 2u)
                    {
                        uint _4110 = _3742 ^ (_1774.uniforms.frame_seed & 255u);
                        vec2 _6135 = floor(input_screen_pos) + vec2(float(_4110 & 255u) * 3.7000000476837158203125, float((_4110 >> 8u) & 255u) * 5.099999904632568359375);
                        uint _6156 = uint(abs(_6135.y) * 1000.0) * 2654435761u;
                        uint _6168 = (_6156 ^ 61u) ^ (_6156 >> 16u);
                        uint _6172 = _6168 + (_6168 << 3u);
                        uint _6178 = (_6172 ^ (_6172 >> 4u)) * 668265261u;
                        uint _6158 = uint(abs(_6135.x) * 1000.0) ^ (_6178 ^ (_6178 >> 15u));
                        uint _6190 = (_6158 ^ 61u) ^ (_6158 >> 16u);
                        uint _6194 = _6190 + (_6190 << 3u);
                        uint _6200 = (_6194 ^ (_6194 >> 4u)) * 668265261u;
                        _6721 = (float(_6200 ^ (_6200 >> 15u)) * 2.3283064365386962890625e-10) - 0.5;
                    }
                    else
                    {
                        _6721 = 0.0;
                    }
                    _6720 = _6721;
                }
                float _4121 = _6720 * instances_1._data[input_instance_id].noise_intensity;
                _7041 = clamp(_7040 + vec4(_4121, _4121, _4121, 0.0), vec4(0.0), vec4(1.0));
            }
            else
            {
                _7041 = _7040;
            }
            float _4135 = _7041.w * _4509;
            _7059 = _7044 + (vec4(_7041.xyz * _4135, _4135) * (1.0 - _7044.w));
        }
        else
        {
            _7059 = _7044;
        }
        vec4 _7061 = vec4(0.0);
        if ((true && ((instances_1._data[input_instance_id].packed_flags & 16777216u) != 0u)) && _3564)
        {
            vec2 _4158 = input_local_pos - _3380;
            float _6723 = 0.0;
            do
            {
                if (_3384)
                {
                    bool _6264 = _4158.y < 0.0;
                    float _6278 = (_4158.x < 0.0) ? (_6264 ? _3354.x : _3354.w) : (_6264 ? _3354.y : _3354.z);
                    vec2 _6285 = (abs(_4158) - input_size) + vec2(_6278);
                    _6723 = (min(max(_6285.x, _6285.y), 0.0) + length(max(_6285, vec2(0.0)))) - _6278;
                    break;
                }
                if (instances_1._data[input_instance_id].shape_type == 1u)
                {
                    _6723 = length(_4158) - min(input_size.x, input_size.y);
                    break;
                }
                if (instances_1._data[input_instance_id].shape_type == 4u)
                {
                    float _6722 = 0.0;
                    do
                    {
                        vec2 _6314 = max(input_size, vec2(0.001000000047497451305389404296875));
                        float _6319 = length(_4158 / _6314);
                        if (_6319 < 9.9999999747524270787835121154785e-07)
                        {
                            _6722 = -min(_6314.x, _6314.y);
                            break;
                        }
                        _6722 = (_6319 - 1.0) / max(length(_4158 / (_6314 * _6314)) / _6319, 9.9999999747524270787835121154785e-07);
                        break;
                    } while(false);
                    _6723 = _6722;
                    break;
                }
                _6723 = -1.0;
                break;
            } while(false);
            float _4179 = instances_1._data[input_instance_id].shadow_color.w * (_4509 * smoothstep(-max(_3373, 1.0), 0.0, _6723));
            _7061 = _7059 + (vec4(instances_1._data[input_instance_id].shadow_color.xyz * _4179, _4179) * (1.0 - _7059.w));
        }
        else
        {
            _7061 = _7059;
        }
        vec4 _7062 = vec4(0.0);
        if (true && (_6727 > 0.0))
        {
            float _4207 = instances_1._data[input_instance_id].border_color.w * _6727;
            _7062 = _7061 + (vec4(instances_1._data[input_instance_id].border_color.xyz * _4207, _4207) * (1.0 - _7061.w));
        }
        else
        {
            _7062 = _7061;
        }
        vec4 _4227 = _7062 * _4525;
        if (_4227.w < 0.001000000047497451305389404296875)
        {
            discard;
        }
        _6775 = _4227;
        break;
    } while(false);
    _entryPointOutput = _6775;
}

