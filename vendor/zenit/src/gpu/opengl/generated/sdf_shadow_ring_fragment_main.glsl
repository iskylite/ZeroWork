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

layout(binding = 0, std140) uniform Params
{
    Uniforms uniforms;
} _1774;

layout(binding = 3, std430) readonly buffer shadow_params
{
    ShadowParam _data[];
} shadow_params_1;

layout(location = 0) in vec2 input_local_pos;
layout(location = 1) in vec2 input_size;
layout(location = 2) in vec2 input_uv;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 6) flat in vec4 input_solid_fill;
layout(location = 7) flat in vec4 input_solid_border;
layout(location = 8) flat in vec4 input_solid_radii;
layout(location = 10) flat in vec3 input_solid_metrics;
layout(location = 11) flat in uint input_solid_shape;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    uint _3080 = input_solid_shape & 268435456u;
    vec4 _3314 = input_solid_radii * _1774.uniforms.scale_factor;
    float _3333 = input_solid_border.x * _1774.uniforms.scale_factor;
    vec2 _3340 = vec2(input_solid_metrics.y, input_solid_metrics.z) * _1774.uniforms.scale_factor;
    bool _4206 = input_local_pos.y < 0.0;
    float _4208 = _3314.x;
    float _4210 = _3314.w;
    float _4216 = _3314.y;
    float _4218 = _3314.z;
    float _4220 = (input_local_pos.x < 0.0) ? (_4206 ? _4208 : _4210) : (_4206 ? _4216 : _4218);
    vec2 _4227 = (abs(input_local_pos) - input_size) + vec2(_4220);
    float _4239 = (min(max(_4227.x, _4227.y), 0.0) + length(max(_4227, vec2(0.0)))) - _4220;
    float _4454 = dFdxFine(_4239);
    float _4456 = dFdyFine(_4239);
    float _3408 = max(length(vec2(_4454, _4456)) * 0.5, 0.5);
    float _4469 = smoothstep(_3408, -_3408, _4239);
    float _6635 = 0.0;
    do
    {
        if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
        {
            _6635 = 1.0;
            break;
        }
        vec2 _4547 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1774.uniforms.scale_factor)) - ((input_rect_clip.zw * _1774.uniforms.scale_factor) * 0.5);
        float _4560 = min(max(_4547.x, _4547.y), 0.0) + length(max(_4547, vec2(0.0)));
        float _4533 = max((abs(dFdxFine(_4560)) + abs(dFdyFine(_4560))) * 0.5, 0.5);
        _6635 = smoothstep(_4533, -_4533, _4560);
        break;
    } while(false);
    float _6675 = 0.0;
    do
    {
        if (_1774.uniforms.clip_shape_kind == 0u)
        {
            _6675 = 1.0;
            break;
        }
        vec2 _4620 = (_1774.uniforms.clip_rect.xy + (_1774.uniforms.clip_rect.zw * 0.5)) * _1774.uniforms.scale_factor;
        vec2 _4627 = (_1774.uniforms.clip_rect.zw * _1774.uniforms.scale_factor) * 0.5;
        float _6673 = 0.0;
        if (_1774.uniforms.clip_shape_kind == 1u)
        {
            float _4636 = _1774.uniforms.clip_radius * _1774.uniforms.scale_factor;
            vec2 _4793 = (abs(input_screen_pos - _4620) - _4627) + vec2(_4636);
            _6673 = (min(max(_4793.x, _4793.y), 0.0) + length(max(_4793, vec2(0.0)))) - _4636;
        }
        else
        {
            float _6674 = 0.0;
            if (_1774.uniforms.clip_shape_kind == 2u)
            {
                _6674 = length((input_screen_pos - _4620) / max(_4627, vec2(0.001000000047497451305389404296875))) - 1.0;
            }
            else
            {
                if (_1774.uniforms.clip_shape_kind == 3u)
                {
                    uint _4660 = min(_1774.uniforms.clip_point_count, 32u);
                    uint _4663 = min(_1774.uniforms.clip_contour_count, 8u);
                    if ((_4660 < 3u) || (_4663 == 0u))
                    {
                        _6675 = 1.0;
                        break;
                    }
                    vec2 _4678 = input_screen_pos - (_1774.uniforms.clip_rect.xy * _1774.uniforms.scale_factor);
                    bool _6656 = false;
                    do
                    {
                        if (_1774.uniforms.clip_fill_rule == 0u)
                        {
                            bool _6655 = false;
                            _6655 = false;
                            uint _4856 = 0u;
                            bool _6777 = false;
                            for (uint _6654 = 0u, _6665 = 0u; _6654 < _4663; _6665 = _4856, _6655 = _6777, _6654++)
                            {
                                _4856 = min(_1774.uniforms.clip_polygon_end_points[_6654 / 4u][_6654 % 4u], _4660);
                                if (_4856 <= (_6665 + 1u))
                                {
                                    _6777 = _6655;
                                    continue;
                                }
                                bool _6668 = false;
                                _6668 = _6655;
                                bool _6782 = false;
                                for (uint _6666 = _6665; _6666 < _4856; _6668 = _6782, _6666++)
                                {
                                    uint _4872 = _6666 + 1u;
                                    uint _4878 = (_4872 < _4856) ? _4872 : _6665;
                                    uint _4971 = _6666 / 2u;
                                    bvec2 _4981 = bvec2((_6666 % 2u) == 0u);
                                    vec2 _4884 = vec2(_4981.x ? _1774.uniforms.clip_polygon_points[_4971].xy.x : _1774.uniforms.clip_polygon_points[_4971].zw.x, _4981.y ? _1774.uniforms.clip_polygon_points[_4971].xy.y : _1774.uniforms.clip_polygon_points[_4971].zw.y) * _1774.uniforms.scale_factor;
                                    uint _4987 = _4878 / 2u;
                                    bvec2 _4997 = bvec2((_4878 % 2u) == 0u);
                                    vec2 _4890 = vec2(_4997.x ? _1774.uniforms.clip_polygon_points[_4987].xy.x : _1774.uniforms.clip_polygon_points[_4987].zw.x, _4997.y ? _1774.uniforms.clip_polygon_points[_4987].xy.y : _1774.uniforms.clip_polygon_points[_4987].zw.y) * _1774.uniforms.scale_factor;
                                    float _4892 = _4890.y;
                                    float _4894 = _4884.y;
                                    float _4895 = _4892 - _4894;
                                    float _4907 = _4678.y;
                                    float _4920 = _4884.x;
                                    if (((_4894 > _4907) != (_4892 > _4907)) && (_4678.x < ((((_4890.x - _4920) * (_4907 - _4894)) / ((abs(_4895) < 9.9999997473787516355514526367188e-05) ? ((_4895 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _4895)) + _4920)))
                                    {
                                        _6782 = !_6668;
                                    }
                                    else
                                    {
                                        _6782 = _6668;
                                    }
                                }
                                _6777 = _6668;
                            }
                            _6656 = _6655;
                            break;
                        }
                        int _6637 = 0;
                        _6637 = 0;
                        uint _5027 = 0u;
                        int _6765 = 0;
                        for (uint _6636 = 0u, _6638 = 0u; _6636 < _4663; _6638 = _5027, _6637 = _6765, _6636++)
                        {
                            _5027 = min(_1774.uniforms.clip_polygon_end_points[_6636 / 4u][_6636 % 4u], _4660);
                            if (_5027 <= (_6638 + 1u))
                            {
                                _6765 = _6637;
                                continue;
                            }
                            int _6641 = 0;
                            _6641 = _6637;
                            int _6772 = 0;
                            for (uint _6639 = _6638; _6639 < _5027; _6641 = _6772, _6639++)
                            {
                                uint _5043 = _6639 + 1u;
                                uint _5049 = (_5043 < _5027) ? _5043 : _6638;
                                uint _5164 = _6639 / 2u;
                                bvec2 _5174 = bvec2((_6639 % 2u) == 0u);
                                vec2 _5055 = vec2(_5174.x ? _1774.uniforms.clip_polygon_points[_5164].xy.x : _1774.uniforms.clip_polygon_points[_5164].zw.x, _5174.y ? _1774.uniforms.clip_polygon_points[_5164].xy.y : _1774.uniforms.clip_polygon_points[_5164].zw.y) * _1774.uniforms.scale_factor;
                                uint _5180 = _5049 / 2u;
                                bvec2 _5190 = bvec2((_5049 % 2u) == 0u);
                                vec2 _5061 = vec2(_5190.x ? _1774.uniforms.clip_polygon_points[_5180].xy.x : _1774.uniforms.clip_polygon_points[_5180].zw.x, _5190.y ? _1774.uniforms.clip_polygon_points[_5180].xy.y : _1774.uniforms.clip_polygon_points[_5180].zw.y) * _1774.uniforms.scale_factor;
                                float _5063 = _5055.y;
                                float _5065 = _4678.y;
                                if (_5063 <= _5065)
                                {
                                    float _5069 = _5061.y;
                                    int _6773 = 0;
                                    if (_5069 > _5065)
                                    {
                                        float _5077 = _5055.x;
                                        int _6774 = 0;
                                        if ((((_5061.x - _5077) * (_5065 - _5063)) - ((_4678.x - _5077) * (_5069 - _5063))) > 0.0)
                                        {
                                            _6774 = _6641 + 1;
                                        }
                                        else
                                        {
                                            _6774 = _6641;
                                        }
                                        _6773 = _6774;
                                    }
                                    else
                                    {
                                        _6773 = _6641;
                                    }
                                    _6772 = _6773;
                                }
                                else
                                {
                                    float _5106 = _5061.y;
                                    int _6775 = 0;
                                    if (_5106 <= _5065)
                                    {
                                        float _5114 = _5055.x;
                                        int _6776 = 0;
                                        if ((((_5061.x - _5114) * (_5065 - _5063)) - ((_4678.x - _5114) * (_5106 - _5063))) < 0.0)
                                        {
                                            _6776 = _6641 - 1;
                                        }
                                        else
                                        {
                                            _6776 = _6641;
                                        }
                                        _6775 = _6776;
                                    }
                                    else
                                    {
                                        _6775 = _6641;
                                    }
                                    _6772 = _6775;
                                }
                            }
                            _6765 = _6641;
                        }
                        _6656 = _6637 != 0;
                        break;
                    } while(false);
                    float _6658 = 0.0;
                    uint _6659 = 0u;
                    _6659 = 0u;
                    _6658 = uintBitsToFloat(0x7f800000u /* inf */);
                    uint _4695 = 0u;
                    float _6778 = 0.0;
                    for (uint _6657 = 0u; _6657 < _4663; _6659 = _4695, _6658 = _6778, _6657++)
                    {
                        _4695 = min(_1774.uniforms.clip_polygon_end_points[_6657 / 4u][_6657 % 4u], _4660);
                        if (_4695 <= (_6659 + 1u))
                        {
                            _6778 = _6658;
                            continue;
                        }
                        float _6662 = 0.0;
                        _6662 = _6658;
                        for (uint _6660 = _6659; _6660 < _4695; )
                        {
                            uint _4711 = _6660 + 1u;
                            uint _4717 = (_4711 < _4695) ? _4711 : _6659;
                            uint _5204 = _6660 / 2u;
                            bvec2 _5214 = bvec2((_6660 % 2u) == 0u);
                            vec2 _4723 = vec2(_5214.x ? _1774.uniforms.clip_polygon_points[_5204].xy.x : _1774.uniforms.clip_polygon_points[_5204].zw.x, _5214.y ? _1774.uniforms.clip_polygon_points[_5204].xy.y : _1774.uniforms.clip_polygon_points[_5204].zw.y) * _1774.uniforms.scale_factor;
                            uint _5220 = _4717 / 2u;
                            bvec2 _5230 = bvec2((_4717 % 2u) == 0u);
                            vec2 _5239 = (vec2(_5230.x ? _1774.uniforms.clip_polygon_points[_5220].xy.x : _1774.uniforms.clip_polygon_points[_5220].zw.x, _5230.y ? _1774.uniforms.clip_polygon_points[_5220].xy.y : _1774.uniforms.clip_polygon_points[_5220].zw.y) * _1774.uniforms.scale_factor) - _4723;
                            _6662 = min(_6662, length(_4678 - (_4723 + (_5239 * clamp(dot(_4678 - _4723, _5239) / max(dot(_5239, _5239), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                            _6660++;
                            continue;
                        }
                        _6778 = _6662;
                    }
                    float _4754 = max(length(vec2(dFdxFine(input_screen_pos.x), dFdyFine(input_screen_pos.y))) * 0.5, 0.75);
                    _6675 = smoothstep(_4754, -_4754, _6656 ? (-_6658) : _6658);
                    break;
                }
                _6674 = 1.0;
            }
            _6673 = _6674;
        }
        float _4776 = max((abs(dFdxFine(_6673)) + abs(dFdyFine(_6673))) * 0.5, 0.5);
        _6675 = smoothstep(_4776, -_4776, _6673);
        break;
    } while(false);
    SPIRV_CROSS_BRANCH
    if ((((true && (_3080 == 0u)) && true) && all(bvec4(true))) && (input_solid_fill.w == 0.0))
    {
        discard;
    }
    bool _3524 = _4469 > 0.0;
    uint _3694 = _3080 & 255u;
    bool _3706 = (_3080 & 33554432u) != 0u;
    vec4 _7002 = vec4(0.0);
    _7002 = vec4(0.0);
    vec4 _7014 = vec4(0.0);
    SPIRV_CROSS_LOOP
    for (uint _6696 = 0u; _6696 < 2u; _7002 = _7014, _6696++)
    {
        bool _3714 = _6696 == 0u;
        if (true && (_3714 ? (_3333 > 0.0) : _3706))
        {
            vec2 _6739 = vec2(0.0);
            vec2 _6741 = vec2(0.0);
            vec4 _6744 = vec4(0.0);
            vec4 _6750 = vec4(0.0);
            float _6754 = 0.0;
            if (_3714)
            {
                float _3740 = ((_3080 & 268435456u) != 0u) ? (input_solid_border.y * _1774.uniforms.scale_factor) : 0.0;
                _6754 = _3333;
                _6750 = input_solid_fill;
                _6744 = max(_3314 + vec4(_3740), vec4(0.0));
                _6741 = max(input_size + vec2(_3740), vec2(0.0));
                _6739 = _3340;
            }
            else
            {
                _6754 = shadow_params_1._data[0u].blur * _1774.uniforms.scale_factor;
                _6750 = shadow_params_1._data[0u].color;
                _6744 = _3314;
                _6741 = input_size;
                _6739 = vec2(shadow_params_1._data[0u].offset_x, shadow_params_1._data[0u].offset_y) * _1774.uniforms.scale_factor;
            }
            vec2 _3805 = input_local_pos - _6739;
            bool _5409 = _3805.y < 0.0;
            float _5423 = (_3805.x < 0.0) ? (_5409 ? _6744.x : _6744.w) : (_5409 ? _6744.y : _6744.z);
            vec2 _5430 = (abs(_3805) - _6741) + vec2(_5423);
            float _3822 = _6750.w * (smoothstep(_6754, -_6754, (min(max(_5430.x, _5430.y), 0.0) + length(max(_5430, vec2(0.0)))) - _5423) * (1.0 - _4469));
            _7014 = _7002 + (vec4(_6750.xyz * _3822, _3822) * (1.0 - _7002.w));
        }
        else
        {
            _7014 = _7002;
        }
    }
    vec4 _7010 = vec4(0.0);
    if (true && _3524)
    {
        vec4 _6998 = vec4(0.0);
        if (_3694 > 0u)
        {
            float _6697 = 0.0;
            if (_3694 == 4u)
            {
                vec2 _3863 = vec2(0.5 + input_solid_metrics.y, 0.5 + input_solid_metrics.z);
                float _6698 = 0.0;
                if ((_3080 & 536870912u) != 0u)
                {
                    _6698 = length((input_uv - _3863) / max(vec2(input_solid_border.y, 0.0), vec2(9.9999997473787516355514526367188e-05)));
                }
                else
                {
                    _6698 = length(input_uv - _3863) * 2.0;
                }
                _6697 = _6698;
            }
            else
            {
                float _6699 = 0.0;
                if (_3694 == 5u)
                {
                    _6699 = fract((atan(input_uv.y - 0.5, input_uv.x - 0.5) * 0.15915493667125701904296875) + 0.5);
                }
                else
                {
                    float _3924 = ((input_solid_border.x * 2.0) + abs(input_solid_metrics.y)) + abs(input_solid_metrics.z);
                    vec2 _3945 = clamp(((input_uv * vec2(_3924 * 2.0)) - vec2(_3924)) * vec2(999.99993896484375), vec2(0.0), vec2(1.0));
                    float _6700 = 0.0;
                    if (_3694 == 1u)
                    {
                        _6700 = _3945.y;
                    }
                    else
                    {
                        float _6701 = 0.0;
                        if (_3694 == 2u)
                        {
                            _6701 = _3945.x;
                        }
                        else
                        {
                            _6701 = (_3945.x + _3945.y) * 0.5;
                        }
                        _6700 = _6701;
                    }
                    _6699 = _6700;
                }
                _6697 = _6699;
            }
            uint _3971 = (_3080 >> 26u) & 3u;
            float _6702 = 0.0;
            if (_3971 == 1u)
            {
                _6702 = fract(_6697);
            }
            else
            {
                float _6703 = 0.0;
                if (_3971 == 2u)
                {
                    float _3983 = mod(abs(_6697), 2.0);
                    _6703 = (_3983 > 1.0) ? (2.0 - _3983) : _3983;
                }
                else
                {
                    _6703 = clamp(_6697, 0.0, 1.0);
                }
                _6702 = _6703;
            }
            vec4 _4016 = mix(vec4(0.0), vec4(0.0), vec4(_6702));
            float _5707 = _4016.w;
            vec4 _5720 = vec4(_4016.xyz / vec3(_5707), _5707);
            bvec4 _5721 = bvec4(_5707 > 9.9999999747524270787835121154785e-07);
            vec4 _5722 = vec4(_5721.x ? _5720.x : vec4(0.0).x, _5721.y ? _5720.y : vec4(0.0).y, _5721.z ? _5720.z : vec4(0.0).z, _5721.w ? _5720.w : vec4(0.0).w);
            vec3 _4029 = clamp(_5722.xyz + vec3((float(_642[((uint(input_screen_pos.y) & 15u) * 16u) + (uint(input_screen_pos.x) & 15u)]) - 127.5) * 1.5378700481960549950599670410156e-05), vec3(0.0), vec3(1.0));
            vec4 _6950 = _5722;
            _6950.x = _4029.x;
            _6950.y = _4029.y;
            _6950.z = _4029.z;
            _6998 = _6950;
        }
        else
        {
            _6998 = vec4(0.0);
        }
        vec4 _6999 = vec4(0.0);
        if ((((_3080 >> 8u) & 255u) > 0u) && (input_solid_border.y > 0.0))
        {
            _6999 = clamp(_6998, vec4(0.0), vec4(1.0));
        }
        else
        {
            _6999 = _6998;
        }
        float _4095 = _6999.w * _4469;
        _7010 = _7002 + (vec4(_6999.xyz * _4095, _4095) * (1.0 - _7002.w));
    }
    else
    {
        _7010 = _7002;
    }
    vec4 _7011 = vec4(0.0);
    if ((true && ((_3080 & 16777216u) != 0u)) && _3524)
    {
        vec2 _4118 = input_local_pos - _3340;
        bool _6224 = _4118.y < 0.0;
        float _6238 = (_4118.x < 0.0) ? (_6224 ? _4208 : _4210) : (_6224 ? _4216 : _4218);
        vec2 _6245 = (abs(_4118) - input_size) + vec2(_6238);
        float _4139 = input_solid_fill.w * (_4469 * smoothstep(-max(_3333, 1.0), 0.0, (min(max(_6245.x, _6245.y), 0.0) + length(max(_6245, vec2(0.0)))) - _6238));
        _7011 = _7010 + (vec4(input_solid_fill.xyz * _4139, _4139) * (1.0 - _7010.w));
    }
    else
    {
        _7011 = _7010;
    }
    vec4 _4187 = _7011 * (_6635 * _6675);
    if (_4187.w < 0.001000000047497451305389404296875)
    {
        discard;
    }
    _entryPointOutput = _4187;
}

