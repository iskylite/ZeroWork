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
} _1774;

layout(location = 0) in vec2 input_local_pos;
layout(location = 1) in vec2 input_size;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 6) flat in vec4 input_solid_fill;
layout(location = 7) flat in vec4 input_solid_border;
layout(location = 8) flat in vec4 input_solid_radii;
layout(location = 9) flat in vec4 input_solid_widths;
layout(location = 10) flat in vec3 input_solid_metrics;
layout(location = 12) flat in vec3 input_second_shadow_metrics;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _2977 = input_solid_fill;
    vec4 _6755 = vec4(0.0);
    do
    {
        vec4 _3308 = input_solid_radii * _1774.uniforms.scale_factor;
        float _3327 = input_solid_metrics.x * _1774.uniforms.scale_factor;
        vec2 _3334 = vec2(input_solid_metrics.y, input_solid_metrics.z) * _1774.uniforms.scale_factor;
        bool _4200 = input_local_pos.y < 0.0;
        float _4214 = (input_local_pos.x < 0.0) ? (_4200 ? _3308.x : _3308.w) : (_4200 ? _3308.y : _3308.z);
        vec2 _4221 = (abs(input_local_pos) - input_size) + vec2(_4214);
        float _4233 = (min(max(_4221.x, _4221.y), 0.0) + length(max(_4221, vec2(0.0)))) - _4214;
        float _4448 = dFdxFine(_4233);
        float _4450 = dFdyFine(_4233);
        float _3402 = max(length(vec2(_4448, _4450)) * 0.5, 0.5);
        float _4463 = smoothstep(_3402, -_3402, _4233);
        float _6626 = 0.0;
        do
        {
            if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
            {
                _6626 = 1.0;
                break;
            }
            vec2 _4541 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _1774.uniforms.scale_factor)) - ((input_rect_clip.zw * _1774.uniforms.scale_factor) * 0.5);
            float _4554 = min(max(_4541.x, _4541.y), 0.0) + length(max(_4541, vec2(0.0)));
            float _4527 = max((abs(dFdxFine(_4554)) + abs(dFdyFine(_4554))) * 0.5, 0.5);
            _6626 = smoothstep(_4527, -_4527, _4554);
            break;
        } while(false);
        float _6666 = 0.0;
        do
        {
            if (_1774.uniforms.clip_shape_kind == 0u)
            {
                _6666 = 1.0;
                break;
            }
            vec2 _4614 = (_1774.uniforms.clip_rect.xy + (_1774.uniforms.clip_rect.zw * 0.5)) * _1774.uniforms.scale_factor;
            vec2 _4621 = (_1774.uniforms.clip_rect.zw * _1774.uniforms.scale_factor) * 0.5;
            float _6664 = 0.0;
            if (_1774.uniforms.clip_shape_kind == 1u)
            {
                float _4630 = _1774.uniforms.clip_radius * _1774.uniforms.scale_factor;
                vec2 _4787 = (abs(input_screen_pos - _4614) - _4621) + vec2(_4630);
                _6664 = (min(max(_4787.x, _4787.y), 0.0) + length(max(_4787, vec2(0.0)))) - _4630;
            }
            else
            {
                float _6665 = 0.0;
                if (_1774.uniforms.clip_shape_kind == 2u)
                {
                    _6665 = length((input_screen_pos - _4614) / max(_4621, vec2(0.001000000047497451305389404296875))) - 1.0;
                }
                else
                {
                    if (_1774.uniforms.clip_shape_kind == 3u)
                    {
                        uint _4654 = min(_1774.uniforms.clip_point_count, 32u);
                        uint _4657 = min(_1774.uniforms.clip_contour_count, 8u);
                        if ((_4654 < 3u) || (_4657 == 0u))
                        {
                            _6666 = 1.0;
                            break;
                        }
                        vec2 _4672 = input_screen_pos - (_1774.uniforms.clip_rect.xy * _1774.uniforms.scale_factor);
                        bool _6647 = false;
                        do
                        {
                            if (_1774.uniforms.clip_fill_rule == 0u)
                            {
                                bool _6646 = false;
                                _6646 = false;
                                uint _4850 = 0u;
                                bool _6768 = false;
                                for (uint _6645 = 0u, _6656 = 0u; _6645 < _4657; _6656 = _4850, _6646 = _6768, _6645++)
                                {
                                    _4850 = min(_1774.uniforms.clip_polygon_end_points[_6645 / 4u][_6645 % 4u], _4654);
                                    if (_4850 <= (_6656 + 1u))
                                    {
                                        _6768 = _6646;
                                        continue;
                                    }
                                    bool _6659 = false;
                                    _6659 = _6646;
                                    bool _6773 = false;
                                    for (uint _6657 = _6656; _6657 < _4850; _6659 = _6773, _6657++)
                                    {
                                        uint _4866 = _6657 + 1u;
                                        uint _4872 = (_4866 < _4850) ? _4866 : _6656;
                                        uint _4965 = _6657 / 2u;
                                        bvec2 _4975 = bvec2((_6657 % 2u) == 0u);
                                        vec2 _4878 = vec2(_4975.x ? _1774.uniforms.clip_polygon_points[_4965].xy.x : _1774.uniforms.clip_polygon_points[_4965].zw.x, _4975.y ? _1774.uniforms.clip_polygon_points[_4965].xy.y : _1774.uniforms.clip_polygon_points[_4965].zw.y) * _1774.uniforms.scale_factor;
                                        uint _4981 = _4872 / 2u;
                                        bvec2 _4991 = bvec2((_4872 % 2u) == 0u);
                                        vec2 _4884 = vec2(_4991.x ? _1774.uniforms.clip_polygon_points[_4981].xy.x : _1774.uniforms.clip_polygon_points[_4981].zw.x, _4991.y ? _1774.uniforms.clip_polygon_points[_4981].xy.y : _1774.uniforms.clip_polygon_points[_4981].zw.y) * _1774.uniforms.scale_factor;
                                        float _4886 = _4884.y;
                                        float _4888 = _4878.y;
                                        float _4889 = _4886 - _4888;
                                        float _4901 = _4672.y;
                                        float _4914 = _4878.x;
                                        if (((_4888 > _4901) != (_4886 > _4901)) && (_4672.x < ((((_4884.x - _4914) * (_4901 - _4888)) / ((abs(_4889) < 9.9999997473787516355514526367188e-05) ? ((_4889 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _4889)) + _4914)))
                                        {
                                            _6773 = !_6659;
                                        }
                                        else
                                        {
                                            _6773 = _6659;
                                        }
                                    }
                                    _6768 = _6659;
                                }
                                _6647 = _6646;
                                break;
                            }
                            int _6628 = 0;
                            _6628 = 0;
                            uint _5021 = 0u;
                            int _6756 = 0;
                            for (uint _6627 = 0u, _6629 = 0u; _6627 < _4657; _6629 = _5021, _6628 = _6756, _6627++)
                            {
                                _5021 = min(_1774.uniforms.clip_polygon_end_points[_6627 / 4u][_6627 % 4u], _4654);
                                if (_5021 <= (_6629 + 1u))
                                {
                                    _6756 = _6628;
                                    continue;
                                }
                                int _6632 = 0;
                                _6632 = _6628;
                                int _6763 = 0;
                                for (uint _6630 = _6629; _6630 < _5021; _6632 = _6763, _6630++)
                                {
                                    uint _5037 = _6630 + 1u;
                                    uint _5043 = (_5037 < _5021) ? _5037 : _6629;
                                    uint _5158 = _6630 / 2u;
                                    bvec2 _5168 = bvec2((_6630 % 2u) == 0u);
                                    vec2 _5049 = vec2(_5168.x ? _1774.uniforms.clip_polygon_points[_5158].xy.x : _1774.uniforms.clip_polygon_points[_5158].zw.x, _5168.y ? _1774.uniforms.clip_polygon_points[_5158].xy.y : _1774.uniforms.clip_polygon_points[_5158].zw.y) * _1774.uniforms.scale_factor;
                                    uint _5174 = _5043 / 2u;
                                    bvec2 _5184 = bvec2((_5043 % 2u) == 0u);
                                    vec2 _5055 = vec2(_5184.x ? _1774.uniforms.clip_polygon_points[_5174].xy.x : _1774.uniforms.clip_polygon_points[_5174].zw.x, _5184.y ? _1774.uniforms.clip_polygon_points[_5174].xy.y : _1774.uniforms.clip_polygon_points[_5174].zw.y) * _1774.uniforms.scale_factor;
                                    float _5057 = _5049.y;
                                    float _5059 = _4672.y;
                                    if (_5057 <= _5059)
                                    {
                                        float _5063 = _5055.y;
                                        int _6764 = 0;
                                        if (_5063 > _5059)
                                        {
                                            float _5071 = _5049.x;
                                            int _6765 = 0;
                                            if ((((_5055.x - _5071) * (_5059 - _5057)) - ((_4672.x - _5071) * (_5063 - _5057))) > 0.0)
                                            {
                                                _6765 = _6632 + 1;
                                            }
                                            else
                                            {
                                                _6765 = _6632;
                                            }
                                            _6764 = _6765;
                                        }
                                        else
                                        {
                                            _6764 = _6632;
                                        }
                                        _6763 = _6764;
                                    }
                                    else
                                    {
                                        float _5100 = _5055.y;
                                        int _6766 = 0;
                                        if (_5100 <= _5059)
                                        {
                                            float _5108 = _5049.x;
                                            int _6767 = 0;
                                            if ((((_5055.x - _5108) * (_5059 - _5057)) - ((_4672.x - _5108) * (_5100 - _5057))) < 0.0)
                                            {
                                                _6767 = _6632 - 1;
                                            }
                                            else
                                            {
                                                _6767 = _6632;
                                            }
                                            _6766 = _6767;
                                        }
                                        else
                                        {
                                            _6766 = _6632;
                                        }
                                        _6763 = _6766;
                                    }
                                }
                                _6756 = _6632;
                            }
                            _6647 = _6628 != 0;
                            break;
                        } while(false);
                        float _6649 = 0.0;
                        uint _6650 = 0u;
                        _6650 = 0u;
                        _6649 = uintBitsToFloat(0x7f800000u /* inf */);
                        uint _4689 = 0u;
                        float _6769 = 0.0;
                        for (uint _6648 = 0u; _6648 < _4657; _6650 = _4689, _6649 = _6769, _6648++)
                        {
                            _4689 = min(_1774.uniforms.clip_polygon_end_points[_6648 / 4u][_6648 % 4u], _4654);
                            if (_4689 <= (_6650 + 1u))
                            {
                                _6769 = _6649;
                                continue;
                            }
                            float _6653 = 0.0;
                            _6653 = _6649;
                            for (uint _6651 = _6650; _6651 < _4689; )
                            {
                                uint _4705 = _6651 + 1u;
                                uint _4711 = (_4705 < _4689) ? _4705 : _6650;
                                uint _5198 = _6651 / 2u;
                                bvec2 _5208 = bvec2((_6651 % 2u) == 0u);
                                vec2 _4717 = vec2(_5208.x ? _1774.uniforms.clip_polygon_points[_5198].xy.x : _1774.uniforms.clip_polygon_points[_5198].zw.x, _5208.y ? _1774.uniforms.clip_polygon_points[_5198].xy.y : _1774.uniforms.clip_polygon_points[_5198].zw.y) * _1774.uniforms.scale_factor;
                                uint _5214 = _4711 / 2u;
                                bvec2 _5224 = bvec2((_4711 % 2u) == 0u);
                                vec2 _5233 = (vec2(_5224.x ? _1774.uniforms.clip_polygon_points[_5214].xy.x : _1774.uniforms.clip_polygon_points[_5214].zw.x, _5224.y ? _1774.uniforms.clip_polygon_points[_5214].xy.y : _1774.uniforms.clip_polygon_points[_5214].zw.y) * _1774.uniforms.scale_factor) - _4717;
                                _6653 = min(_6653, length(_4672 - (_4717 + (_5233 * clamp(dot(_4672 - _4717, _5233) / max(dot(_5233, _5233), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                                _6651++;
                                continue;
                            }
                            _6769 = _6653;
                        }
                        float _4748 = max(length(vec2(dFdxFine(input_screen_pos.x), dFdyFine(input_screen_pos.y))) * 0.5, 0.75);
                        _6666 = smoothstep(_4748, -_4748, _6647 ? (-_6649) : _6649);
                        break;
                    }
                    _6665 = 1.0;
                }
                _6664 = _6665;
            }
            float _4770 = max((abs(dFdxFine(_6664)) + abs(dFdyFine(_6664))) * 0.5, 0.5);
            _6666 = smoothstep(_4770, -_4770, _6664);
            break;
        } while(false);
        float _4479 = _6626 * _6666;
        SPIRV_CROSS_BRANCH
        if (true && (_4463 == 1.0))
        {
            vec3 _3423 = _2977.xyz * _2977.w;
            vec4 _6877 = _2977;
            _6877.x = _3423.x;
            _6877.y = _3423.y;
            _6877.z = _3423.z;
            vec4 _3432 = _6877 * _4479;
            if (_3432.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _6755 = _3432;
            break;
        }
        vec4 _6955 = vec4(0.0);
        _6955 = vec4(0.0);
        vec4 _6959 = vec4(0.0);
        SPIRV_CROSS_LOOP
        for (uint _6687 = 0u; _6687 < 2u; _6955 = _6959, _6687++)
        {
            bool _3708 = _6687 == 0u;
            if (true && (_3708 ? (_3327 > 0.0) : true))
            {
                vec2 _6730 = vec2(0.0);
                vec2 _6732 = vec2(0.0);
                vec4 _6735 = vec4(0.0);
                float _6745 = 0.0;
                if (_3708)
                {
                    _6745 = _3327;
                    _6735 = max(_3308, vec4(0.0));
                    _6732 = max(input_size, vec2(0.0));
                    _6730 = _3334;
                }
                else
                {
                    _6745 = input_second_shadow_metrics.x * _1774.uniforms.scale_factor;
                    _6735 = _3308;
                    _6732 = input_size;
                    _6730 = vec2(input_second_shadow_metrics.y, input_second_shadow_metrics.z) * _1774.uniforms.scale_factor;
                }
                bvec4 _6966 = bvec4(_3708);
                vec4 _6967 = vec4(_6966.x ? input_solid_border.x : input_solid_widths.x, _6966.y ? input_solid_border.y : input_solid_widths.y, _6966.z ? input_solid_border.z : input_solid_widths.z, _6966.w ? input_solid_border.w : input_solid_widths.w);
                vec2 _3799 = input_local_pos - _6730;
                bool _5403 = _3799.y < 0.0;
                float _5417 = (_3799.x < 0.0) ? (_5403 ? _6735.x : _6735.w) : (_5403 ? _6735.y : _6735.z);
                vec2 _5424 = (abs(_3799) - _6732) + vec2(_5417);
                float _3816 = _6967.w * (smoothstep(_6745, -_6745, (min(max(_5424.x, _5424.y), 0.0) + length(max(_5424, vec2(0.0)))) - _5417) * (1.0 - _4463));
                _6959 = _6955 + (vec4(_6967.xyz * _3816, _3816) * (1.0 - _6955.w));
            }
            else
            {
                _6959 = _6955;
            }
        }
        vec4 _6956 = vec4(0.0);
        if (true && (_4463 > 0.0))
        {
            float _4089 = _2977.w * _4463;
            _6956 = _6955 + (vec4(_2977.xyz * _4089, _4089) * (1.0 - _6955.w));
        }
        else
        {
            _6956 = _6955;
        }
        vec4 _4181 = _6956 * _4479;
        if (_4181.w < 0.001000000047497451305389404296875)
        {
            discard;
        }
        _6755 = _4181;
        break;
    } while(false);
    _entryPointOutput = _6755;
}

