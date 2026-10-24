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

const uint _634[256] = uint[](0u, 128u, 32u, 160u, 8u, 136u, 40u, 168u, 2u, 130u, 34u, 162u, 10u, 138u, 42u, 170u, 192u, 64u, 224u, 96u, 200u, 72u, 232u, 104u, 194u, 66u, 226u, 98u, 202u, 74u, 234u, 106u, 48u, 176u, 16u, 144u, 56u, 184u, 24u, 152u, 50u, 178u, 18u, 146u, 58u, 186u, 26u, 154u, 240u, 112u, 208u, 80u, 248u, 120u, 216u, 88u, 242u, 114u, 210u, 82u, 250u, 122u, 218u, 90u, 12u, 140u, 44u, 172u, 4u, 132u, 36u, 164u, 14u, 142u, 46u, 174u, 6u, 134u, 38u, 166u, 204u, 76u, 236u, 108u, 196u, 68u, 228u, 100u, 206u, 78u, 238u, 110u, 198u, 70u, 230u, 102u, 60u, 188u, 28u, 156u, 52u, 180u, 20u, 148u, 62u, 190u, 30u, 158u, 54u, 182u, 22u, 150u, 252u, 124u, 220u, 92u, 244u, 116u, 212u, 84u, 254u, 126u, 222u, 94u, 246u, 118u, 214u, 86u, 3u, 131u, 35u, 163u, 11u, 139u, 43u, 171u, 1u, 129u, 33u, 161u, 9u, 137u, 41u, 169u, 195u, 67u, 227u, 99u, 203u, 75u, 235u, 107u, 193u, 65u, 225u, 97u, 201u, 73u, 233u, 105u, 51u, 179u, 19u, 147u, 59u, 187u, 27u, 155u, 49u, 177u, 17u, 145u, 57u, 185u, 25u, 153u, 243u, 115u, 211u, 83u, 251u, 123u, 219u, 91u, 241u, 113u, 209u, 81u, 249u, 121u, 217u, 89u, 15u, 143u, 47u, 175u, 7u, 135u, 39u, 167u, 13u, 141u, 45u, 173u, 5u, 133u, 37u, 165u, 207u, 79u, 239u, 111u, 199u, 71u, 231u, 103u, 205u, 77u, 237u, 109u, 197u, 69u, 229u, 101u, 63u, 191u, 31u, 159u, 55u, 183u, 23u, 151u, 61u, 189u, 29u, 157u, 53u, 181u, 21u, 149u, 255u, 127u, 223u, 95u, 247u, 119u, 215u, 87u, 253u, 125u, 221u, 93u, 245u, 117u, 213u, 85u);

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
    vec4 _6682 = vec4(0.0);
    do
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
        float _4473 = -_3414;
        float _4475 = smoothstep(_3414, _4473, _6540);
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
        float _4491 = _6553 * _6593;
        SPIRV_CROSS_BRANCH
        if ((((true && (instances_1._data[input_instance_id].packed_flags == 0u)) && (instances_1._data[input_instance_id].border_width == 0.0)) && all(equal(instances_1._data[input_instance_id].border_widths, vec4(0.0)))) && (instances_1._data[input_instance_id].shadow_color.w == 0.0))
        {
            float _3476 = instances_1._data[input_instance_id].fill_color.w * _4475;
            vec4 _3491 = vec4(instances_1._data[input_instance_id].fill_color.xyz * _3476, _3476) * _4491;
            if (_3491.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _6682 = _3491;
            break;
        }
        vec4 _3502 = instances_1._data[input_instance_id].border_widths * _1766.uniforms.scale_factor;
        float _3504 = _3502.x;
        float _3506 = _3502.y;
        float _3509 = _3502.z;
        float _3512 = _3502.w;
        bool _3537 = false || (true && (!((instances_1._data[input_instance_id].packed_flags & 16777216u) != 0u)));
        float _6634 = 0.0;
        if (_3537 && (((((_3504 + _3506) + _3509) + _3512) > 0.0) && _3350))
        {
            vec4 _3599 = max(_3320 - vec4(max(_3504, _3512), max(_3504, _3506), max(_3509, _3506), max(_3509, _3512)), vec4(0.0));
            vec2 _3603 = input_local_pos - vec2((_3512 - _3506) * 0.5, (_3504 - _3509) * 0.5);
            bool _5275 = _3603.y < 0.0;
            float _5289 = (_3603.x < 0.0) ? (_5275 ? _3599.x : _3599.w) : (_5275 ? _3599.y : _3599.z);
            vec2 _5296 = (abs(_3603) - max(vec2(input_size.x - ((_3506 + _3512) * 0.5), input_size.y - ((_3504 + _3509) * 0.5)), vec2(0.0))) + vec2(_5289);
            _6634 = _4475 - smoothstep(_3414, _4473, (min(max(_5296.x, _5296.y), 0.0) + length(max(_5296, vec2(0.0)))) - _5289);
        }
        else
        {
            float _6635 = 0.0;
            if (_3537 && (_3335 > 0.0))
            {
                _6635 = _4475 - smoothstep(_3414, _4473, _6540 + _3335);
            }
            else
            {
                _6635 = 0.0;
            }
            _6634 = _6635;
        }
        uint _3700 = instances_1._data[input_instance_id].packed_flags & 255u;
        uint _3704 = (instances_1._data[input_instance_id].packed_flags >> 8u) & 255u;
        uint _3708 = (instances_1._data[input_instance_id].packed_flags >> 16u) & 255u;
        vec4 _6918 = vec4(0.0);
        if (true && (_4475 > 0.0))
        {
            vec4 _6901 = vec4(0.0);
            if (_3700 > 0u)
            {
                float _6615 = 0.0;
                if (_3700 == 4u)
                {
                    vec2 _3869 = vec2(0.5 + instances_1._data[input_instance_id].shadow_offset_x, 0.5 + instances_1._data[input_instance_id].shadow_offset_y);
                    float _6616 = 0.0;
                    if ((instances_1._data[input_instance_id].packed_flags & 536870912u) != 0u)
                    {
                        _6616 = length((input_uv - _3869) / max(vec2(instances_1._data[input_instance_id].noise_scale, instances_1._data[input_instance_id].noise_intensity), vec2(9.9999997473787516355514526367188e-05)));
                    }
                    else
                    {
                        _6616 = length(input_uv - _3869) * 2.0;
                    }
                    _6615 = _6616;
                }
                else
                {
                    float _6617 = 0.0;
                    if (_3700 == 5u)
                    {
                        _6617 = fract(((atan(input_uv.y - 0.5, input_uv.x - 0.5) - uintBitsToFloat(instances_1._data[input_instance_id]._ext_reserved)) * 0.15915493667125701904296875) + 0.5);
                    }
                    else
                    {
                        float _3931 = (instances_1._data[input_instance_id].shape_type == 3u) ? 0.0 : (((instances_1._data[input_instance_id].shadow_blur * 2.0) + abs(instances_1._data[input_instance_id].shadow_offset_x)) + abs(instances_1._data[input_instance_id].shadow_offset_y));
                        vec2 _3951 = clamp(((input_uv * (instances_1._data[input_instance_id].rect.zw + vec2(_3931 * 2.0))) - vec2(_3931)) / max(instances_1._data[input_instance_id].rect.zw, vec2(0.001000000047497451305389404296875)), vec2(0.0), vec2(1.0));
                        float _6618 = 0.0;
                        if (_3700 == 1u)
                        {
                            _6618 = _3951.y;
                        }
                        else
                        {
                            float _6619 = 0.0;
                            if (_3700 == 2u)
                            {
                                _6619 = _3951.x;
                            }
                            else
                            {
                                _6619 = (_3951.x + _3951.y) * 0.5;
                            }
                            _6618 = _6619;
                        }
                        _6617 = _6618;
                    }
                    _6615 = _6617;
                }
                uint _3977 = (instances_1._data[input_instance_id].packed_flags >> 26u) & 3u;
                float _6620 = 0.0;
                if (_3977 == 1u)
                {
                    _6620 = fract(_6615);
                }
                else
                {
                    float _6621 = 0.0;
                    if (_3977 == 2u)
                    {
                        float _3989 = mod(abs(_6615), 2.0);
                        _6621 = (_3989 > 1.0) ? (2.0 - _3989) : _3989;
                    }
                    else
                    {
                        _6621 = clamp(_6615, 0.0, 1.0);
                    }
                    _6620 = _6621;
                }
                vec4 _6898 = vec4(0.0);
                if (instances_1._data[input_instance_id].gradient_stop_count > 0u)
                {
                    vec4 _6626 = vec4(0.0);
                    do
                    {
                        if (instances_1._data[input_instance_id].gradient_stop_count == 0u)
                        {
                            _6626 = vec4(0.0);
                            break;
                        }
                        if (instances_1._data[input_instance_id].gradient_stop_count > 16u)
                        {
                            _6626 = vec4(1.0, 0.0, 1.0, 1.0);
                            break;
                        }
                        if (instances_1._data[input_instance_id].gradient_stop_count == 1u)
                        {
                            _6626 = grad_stops_1._data[instances_1._data[input_instance_id].gradient_stop_offset].color;
                            break;
                        }
                        uint _5543 = (instances_1._data[input_instance_id].gradient_stop_offset + instances_1._data[input_instance_id].gradient_stop_count) - 1u;
                        float _5549 = clamp(_6620, grad_stops_1._data[instances_1._data[input_instance_id].gradient_stop_offset].position, grad_stops_1._data[_5543].position);
                        vec4 _6623 = vec4(0.0);
                        _6623 = grad_stops_1._data[_5543].color;
                        bool _6926 = false;
                        vec4 _6701 = vec4(0.0);
                        uint _6622 = 0u;
                        bool _6624 = false;
                        for (; _6622 < (instances_1._data[input_instance_id].gradient_stop_count - 1u); _6624 = _6926, _6623 = _6701, _6622++)
                        {
                            uint _5565 = instances_1._data[input_instance_id].gradient_stop_offset + _6622;
                            uint _5581 = _5565 + 1u;
                            bool _5605 = ((!_6624) && (_5549 >= grad_stops_1._data[_5565].position)) && (_5549 <= grad_stops_1._data[_5581].position);
                            if (_5605)
                            {
                                float _5611 = grad_stops_1._data[_5581].position - grad_stops_1._data[_5565].position;
                                vec4 _5629 = mix(vec4(grad_stops_1._data[_5565].color.xyz * grad_stops_1._data[_5565].color.w, grad_stops_1._data[_5565].color.w), vec4(grad_stops_1._data[_5581].color.xyz * grad_stops_1._data[_5581].color.w, grad_stops_1._data[_5581].color.w), vec4((_5611 > 9.9999999747524270787835121154785e-07) ? ((_5549 - grad_stops_1._data[_5565].position) / _5611) : 0.0));
                                float _5668 = _5629.w;
                                vec4 _5681 = vec4(_5629.xyz / vec3(_5668), _5668);
                                bvec4 _5682 = bvec4(_5668 > 9.9999999747524270787835121154785e-07);
                                _6701 = vec4(_5682.x ? _5681.x : vec4(0.0).x, _5682.y ? _5681.y : vec4(0.0).y, _5682.z ? _5681.z : vec4(0.0).z, _5682.w ? _5681.w : vec4(0.0).w);
                            }
                            else
                            {
                                _6701 = _6623;
                            }
                            _6926 = _5605 ? true : _6624;
                        }
                        _6626 = _6623;
                        break;
                    } while(false);
                    _6898 = _6626;
                }
                else
                {
                    vec4 _4022 = mix(vec4(instances_1._data[input_instance_id].fill_color.xyz * instances_1._data[input_instance_id].fill_color.w, instances_1._data[input_instance_id].fill_color.w), vec4(instances_1._data[input_instance_id].gradient_to_color.xyz * instances_1._data[input_instance_id].gradient_to_color.w, instances_1._data[input_instance_id].gradient_to_color.w), vec4(_6620));
                    float _5713 = _4022.w;
                    vec4 _5726 = vec4(_4022.xyz / vec3(_5713), _5713);
                    bvec4 _5727 = bvec4(_5713 > 9.9999999747524270787835121154785e-07);
                    _6898 = vec4(_5727.x ? _5726.x : vec4(0.0).x, _5727.y ? _5726.y : vec4(0.0).y, _5727.z ? _5726.z : vec4(0.0).z, _5727.w ? _5726.w : vec4(0.0).w);
                }
                vec3 _4035 = clamp(_6898.xyz + vec3((float(_634[((uint(input_screen_pos.y) & 15u) * 16u) + (uint(input_screen_pos.x) & 15u)]) - 127.5) * 1.5378700481960549950599670410156e-05), vec3(0.0), vec3(1.0));
                vec4 _6857 = _6898;
                _6857.x = _4035.x;
                _6857.y = _4035.y;
                _6857.z = _4035.z;
                _6901 = _6857;
            }
            else
            {
                _6901 = instances_1._data[input_instance_id].fill_color;
            }
            vec4 _6902 = vec4(0.0);
            if ((_3704 > 0u) && (instances_1._data[input_instance_id].noise_scale > 0.0))
            {
                float _6627 = 0.0;
                if (_3704 == 1u)
                {
                    float _5771 = float(_3708);
                    vec2 _5777 = ((input_local_pos / vec2(_1766.uniforms.scale_factor)) / vec2(max(instances_1._data[input_instance_id].noise_scale, 0.001000000047497451305389404296875))) + vec2(_5771 * 17.299999237060546875, _5771 * 31.700000762939453125);
                    vec2 _5779 = floor(_5777);
                    vec2 _5781 = fract(_5777);
                    vec2 _5789 = (_5781 * _5781) * (vec2(3.0) - (_5781 * 2.0));
                    uint _5832 = uint(abs(_5779.y) * 1000.0) * 2654435761u;
                    uint _5844 = (_5832 ^ 61u) ^ (_5832 >> 16u);
                    uint _5848 = _5844 + (_5844 << 3u);
                    uint _5854 = (_5848 ^ (_5848 >> 4u)) * 668265261u;
                    uint _5834 = uint(abs(_5779.x) * 1000.0) ^ (_5854 ^ (_5854 >> 15u));
                    uint _5866 = (_5834 ^ 61u) ^ (_5834 >> 16u);
                    uint _5870 = _5866 + (_5866 << 3u);
                    uint _5876 = (_5870 ^ (_5870 >> 4u)) * 668265261u;
                    vec2 _5793 = _5779 + vec2(1.0, 0.0);
                    uint _5900 = uint(abs(_5793.y) * 1000.0) * 2654435761u;
                    uint _5912 = (_5900 ^ 61u) ^ (_5900 >> 16u);
                    uint _5916 = _5912 + (_5912 << 3u);
                    uint _5922 = (_5916 ^ (_5916 >> 4u)) * 668265261u;
                    uint _5902 = uint(abs(_5793.x) * 1000.0) ^ (_5922 ^ (_5922 >> 15u));
                    uint _5934 = (_5902 ^ 61u) ^ (_5902 >> 16u);
                    uint _5938 = _5934 + (_5934 << 3u);
                    uint _5944 = (_5938 ^ (_5938 >> 4u)) * 668265261u;
                    vec2 _5796 = _5779 + vec2(0.0, 1.0);
                    uint _5968 = uint(abs(_5796.y) * 1000.0) * 2654435761u;
                    uint _5980 = (_5968 ^ 61u) ^ (_5968 >> 16u);
                    uint _5984 = _5980 + (_5980 << 3u);
                    uint _5990 = (_5984 ^ (_5984 >> 4u)) * 668265261u;
                    uint _5970 = uint(abs(_5796.x) * 1000.0) ^ (_5990 ^ (_5990 >> 15u));
                    uint _6002 = (_5970 ^ 61u) ^ (_5970 >> 16u);
                    uint _6006 = _6002 + (_6002 << 3u);
                    uint _6012 = (_6006 ^ (_6006 >> 4u)) * 668265261u;
                    vec2 _5799 = _5779 + vec2(1.0);
                    uint _6036 = uint(abs(_5799.y) * 1000.0) * 2654435761u;
                    uint _6048 = (_6036 ^ 61u) ^ (_6036 >> 16u);
                    uint _6052 = _6048 + (_6048 << 3u);
                    uint _6058 = (_6052 ^ (_6052 >> 4u)) * 668265261u;
                    uint _6038 = uint(abs(_5799.x) * 1000.0) ^ (_6058 ^ (_6058 >> 15u));
                    uint _6070 = (_6038 ^ 61u) ^ (_6038 >> 16u);
                    uint _6074 = _6070 + (_6070 << 3u);
                    uint _6080 = (_6074 ^ (_6074 >> 4u)) * 668265261u;
                    float _5804 = _5789.x;
                    _6627 = mix(mix(float(_5876 ^ (_5876 >> 15u)) * 2.3283064365386962890625e-10, float(_5944 ^ (_5944 >> 15u)) * 2.3283064365386962890625e-10, _5804), mix(float(_6012 ^ (_6012 >> 15u)) * 2.3283064365386962890625e-10, float(_6080 ^ (_6080 >> 15u)) * 2.3283064365386962890625e-10, _5804), _5789.y) - 0.5;
                }
                else
                {
                    float _6628 = 0.0;
                    if (_3704 == 2u)
                    {
                        uint _4076 = _3708 ^ (_1766.uniforms.frame_seed & 255u);
                        vec2 _6101 = floor(input_screen_pos) + vec2(float(_4076 & 255u) * 3.7000000476837158203125, float((_4076 >> 8u) & 255u) * 5.099999904632568359375);
                        uint _6122 = uint(abs(_6101.y) * 1000.0) * 2654435761u;
                        uint _6134 = (_6122 ^ 61u) ^ (_6122 >> 16u);
                        uint _6138 = _6134 + (_6134 << 3u);
                        uint _6144 = (_6138 ^ (_6138 >> 4u)) * 668265261u;
                        uint _6124 = uint(abs(_6101.x) * 1000.0) ^ (_6144 ^ (_6144 >> 15u));
                        uint _6156 = (_6124 ^ 61u) ^ (_6124 >> 16u);
                        uint _6160 = _6156 + (_6156 << 3u);
                        uint _6166 = (_6160 ^ (_6160 >> 4u)) * 668265261u;
                        _6628 = (float(_6166 ^ (_6166 >> 15u)) * 2.3283064365386962890625e-10) - 0.5;
                    }
                    else
                    {
                        _6628 = 0.0;
                    }
                    _6627 = _6628;
                }
                float _4087 = _6627 * instances_1._data[input_instance_id].noise_intensity;
                _6902 = clamp(_6901 + vec4(_4087, _4087, _4087, 0.0), vec4(0.0), vec4(1.0));
            }
            else
            {
                _6902 = _6901;
            }
            float _4101 = _6902.w * _4475;
            _6918 = vec4(_6902.xyz * _4101, _4101) * 1.0;
        }
        else
        {
            _6918 = vec4(0.0);
        }
        vec4 _6919 = vec4(0.0);
        if (_3537 && (_6634 > 0.0))
        {
            float _4173 = instances_1._data[input_instance_id].border_color.w * _6634;
            _6919 = _6918 + (vec4(instances_1._data[input_instance_id].border_color.xyz * _4173, _4173) * (1.0 - _6918.w));
        }
        else
        {
            _6919 = _6918;
        }
        vec4 _4193 = _6919 * _4491;
        if (_4193.w < 0.001000000047497451305389404296875)
        {
            discard;
        }
        _6682 = _4193;
        break;
    } while(false);
    _entryPointOutput = _6682;
}

