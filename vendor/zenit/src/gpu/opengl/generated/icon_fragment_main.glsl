#version 430
#extension GL_ARB_derivative_control : require

struct IconInstanceData
{
    vec4 rect;
    vec4 tint_color;
    vec4 rect_clip;
    float corner_radius;
    float opacity;
    float rotate;
    float _padding2;
};

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
};

layout(binding = 1, std430) readonly buffer instances
{
    IconInstanceData _data[];
} instances_1;

layout(binding = 0, std140) uniform Params
{
    Uniforms uniforms;
} _800;

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combinedmask_texatlas_sampler;

layout(location = 0) in vec2 input_uv;
layout(location = 1) in vec2 input_local_pos;
layout(location = 2) in vec2 input_size;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 5) flat in uint input_instance_id;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    float _1042 = instances_1._data[input_instance_id].corner_radius * _800.uniforms.scale_factor;
    vec4 _1048 = texture(SPIRV_Cross_Combinedmask_texatlas_sampler, input_uv);
    float _1049 = _1048.x;
    float _2154 = 0.0;
    if (_1042 > 0.0)
    {
        vec2 _1177 = (abs(input_local_pos) - input_size) + vec2(_1042);
        float _1189 = (min(max(_1177.x, _1177.y), 0.0) + length(max(_1177, vec2(0.0)))) - _1042;
        float _1065 = abs(dFdxFine(_1189)) + abs(dFdyFine(_1189));
        _2154 = _1049 * smoothstep(_1065 * 0.5, _1065 * (-0.5), _1189);
    }
    else
    {
        _2154 = _1049;
    }
    float _2111 = 0.0;
    do
    {
        if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
        {
            _2111 = 1.0;
            break;
        }
        vec2 _1267 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _800.uniforms.scale_factor)) - ((input_rect_clip.zw * _800.uniforms.scale_factor) * 0.5);
        float _1280 = min(max(_1267.x, _1267.y), 0.0) + length(max(_1267, vec2(0.0)));
        float _1253 = max((abs(dFdxFine(_1280)) + abs(dFdyFine(_1280))) * 0.5, 0.5);
        _2111 = smoothstep(_1253, -_1253, _1280);
        break;
    } while(false);
    float _2151 = 0.0;
    do
    {
        if (_800.uniforms.clip_shape_kind == 0u)
        {
            _2151 = 1.0;
            break;
        }
        vec2 _1340 = (_800.uniforms.clip_rect.xy + (_800.uniforms.clip_rect.zw * 0.5)) * _800.uniforms.scale_factor;
        vec2 _1347 = (_800.uniforms.clip_rect.zw * _800.uniforms.scale_factor) * 0.5;
        float _2149 = 0.0;
        if (_800.uniforms.clip_shape_kind == 1u)
        {
            float _1356 = _800.uniforms.clip_radius * _800.uniforms.scale_factor;
            vec2 _1513 = (abs(input_screen_pos - _1340) - _1347) + vec2(_1356);
            _2149 = (min(max(_1513.x, _1513.y), 0.0) + length(max(_1513, vec2(0.0)))) - _1356;
        }
        else
        {
            float _2150 = 0.0;
            if (_800.uniforms.clip_shape_kind == 2u)
            {
                _2150 = length((input_screen_pos - _1340) / max(_1347, vec2(0.001000000047497451305389404296875))) - 1.0;
            }
            else
            {
                if (_800.uniforms.clip_shape_kind == 3u)
                {
                    uint _1380 = min(_800.uniforms.clip_point_count, 32u);
                    uint _1383 = min(_800.uniforms.clip_contour_count, 8u);
                    if ((_1380 < 3u) || (_1383 == 0u))
                    {
                        _2151 = 1.0;
                        break;
                    }
                    vec2 _1398 = input_screen_pos - (_800.uniforms.clip_rect.xy * _800.uniforms.scale_factor);
                    bool _2132 = false;
                    do
                    {
                        if (_800.uniforms.clip_fill_rule == 0u)
                        {
                            bool _2131 = false;
                            _2131 = false;
                            uint _1588 = 0u;
                            bool _2185 = false;
                            for (uint _2130 = 0u, _2141 = 0u; _2130 < _1383; _2141 = _1588, _2131 = _2185, _2130++)
                            {
                                _1588 = min(_800.uniforms.clip_polygon_end_points[_2130 / 4u][_2130 % 4u], _1380);
                                if (_1588 <= (_2141 + 1u))
                                {
                                    _2185 = _2131;
                                    continue;
                                }
                                bool _2144 = false;
                                _2144 = _2131;
                                bool _2190 = false;
                                for (uint _2142 = _2141; _2142 < _1588; _2144 = _2190, _2142++)
                                {
                                    uint _1604 = _2142 + 1u;
                                    uint _1610 = (_1604 < _1588) ? _1604 : _2141;
                                    uint _1833 = _2142 / 2u;
                                    bvec2 _1843 = bvec2((_2142 % 2u) == 0u);
                                    vec2 _1616 = vec2(_1843.x ? _800.uniforms.clip_polygon_points[_1833].xy.x : _800.uniforms.clip_polygon_points[_1833].zw.x, _1843.y ? _800.uniforms.clip_polygon_points[_1833].xy.y : _800.uniforms.clip_polygon_points[_1833].zw.y) * _800.uniforms.scale_factor;
                                    uint _1849 = _1610 / 2u;
                                    bvec2 _1859 = bvec2((_1610 % 2u) == 0u);
                                    vec2 _1622 = vec2(_1859.x ? _800.uniforms.clip_polygon_points[_1849].xy.x : _800.uniforms.clip_polygon_points[_1849].zw.x, _1859.y ? _800.uniforms.clip_polygon_points[_1849].xy.y : _800.uniforms.clip_polygon_points[_1849].zw.y) * _800.uniforms.scale_factor;
                                    float _1624 = _1622.y;
                                    float _1626 = _1616.y;
                                    float _1627 = _1624 - _1626;
                                    float _1639 = _1398.y;
                                    float _1652 = _1616.x;
                                    if (((_1626 > _1639) != (_1624 > _1639)) && (_1398.x < ((((_1622.x - _1652) * (_1639 - _1626)) / ((abs(_1627) < 9.9999997473787516355514526367188e-05) ? ((_1627 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _1627)) + _1652)))
                                    {
                                        _2190 = !_2144;
                                    }
                                    else
                                    {
                                        _2190 = _2144;
                                    }
                                }
                                _2185 = _2144;
                            }
                            _2132 = _2131;
                            break;
                        }
                        int _2113 = 0;
                        _2113 = 0;
                        uint _1693 = 0u;
                        int _2173 = 0;
                        for (uint _2112 = 0u, _2114 = 0u; _2112 < _1383; _2114 = _1693, _2113 = _2173, _2112++)
                        {
                            _1693 = min(_800.uniforms.clip_polygon_end_points[_2112 / 4u][_2112 % 4u], _1380);
                            if (_1693 <= (_2114 + 1u))
                            {
                                _2173 = _2113;
                                continue;
                            }
                            int _2117 = 0;
                            _2117 = _2113;
                            int _2180 = 0;
                            for (uint _2115 = _2114; _2115 < _1693; _2117 = _2180, _2115++)
                            {
                                uint _1709 = _2115 + 1u;
                                uint _1715 = (_1709 < _1693) ? _1709 : _2114;
                                uint _1873 = _2115 / 2u;
                                bvec2 _1883 = bvec2((_2115 % 2u) == 0u);
                                vec2 _1721 = vec2(_1883.x ? _800.uniforms.clip_polygon_points[_1873].xy.x : _800.uniforms.clip_polygon_points[_1873].zw.x, _1883.y ? _800.uniforms.clip_polygon_points[_1873].xy.y : _800.uniforms.clip_polygon_points[_1873].zw.y) * _800.uniforms.scale_factor;
                                uint _1889 = _1715 / 2u;
                                bvec2 _1899 = bvec2((_1715 % 2u) == 0u);
                                vec2 _1727 = vec2(_1899.x ? _800.uniforms.clip_polygon_points[_1889].xy.x : _800.uniforms.clip_polygon_points[_1889].zw.x, _1899.y ? _800.uniforms.clip_polygon_points[_1889].xy.y : _800.uniforms.clip_polygon_points[_1889].zw.y) * _800.uniforms.scale_factor;
                                float _1729 = _1721.y;
                                float _1731 = _1398.y;
                                if (_1729 <= _1731)
                                {
                                    float _1735 = _1727.y;
                                    int _2181 = 0;
                                    if (_1735 > _1731)
                                    {
                                        float _1743 = _1721.x;
                                        int _2182 = 0;
                                        if ((((_1727.x - _1743) * (_1731 - _1729)) - ((_1398.x - _1743) * (_1735 - _1729))) > 0.0)
                                        {
                                            _2182 = _2117 + 1;
                                        }
                                        else
                                        {
                                            _2182 = _2117;
                                        }
                                        _2181 = _2182;
                                    }
                                    else
                                    {
                                        _2181 = _2117;
                                    }
                                    _2180 = _2181;
                                }
                                else
                                {
                                    float _1772 = _1727.y;
                                    int _2183 = 0;
                                    if (_1772 <= _1731)
                                    {
                                        float _1780 = _1721.x;
                                        int _2184 = 0;
                                        if ((((_1727.x - _1780) * (_1731 - _1729)) - ((_1398.x - _1780) * (_1772 - _1729))) < 0.0)
                                        {
                                            _2184 = _2117 - 1;
                                        }
                                        else
                                        {
                                            _2184 = _2117;
                                        }
                                        _2183 = _2184;
                                    }
                                    else
                                    {
                                        _2183 = _2117;
                                    }
                                    _2180 = _2183;
                                }
                            }
                            _2173 = _2117;
                        }
                        _2132 = _2113 != 0;
                        break;
                    } while(false);
                    float _2134 = 0.0;
                    uint _2135 = 0u;
                    _2135 = 0u;
                    _2134 = uintBitsToFloat(0x7f800000u /* inf */);
                    uint _1415 = 0u;
                    float _2186 = 0.0;
                    for (uint _2133 = 0u; _2133 < _1383; _2135 = _1415, _2134 = _2186, _2133++)
                    {
                        _1415 = min(_800.uniforms.clip_polygon_end_points[_2133 / 4u][_2133 % 4u], _1380);
                        if (_1415 <= (_2135 + 1u))
                        {
                            _2186 = _2134;
                            continue;
                        }
                        float _2138 = 0.0;
                        _2138 = _2134;
                        for (uint _2136 = _2135; _2136 < _1415; )
                        {
                            uint _1431 = _2136 + 1u;
                            uint _1437 = (_1431 < _1415) ? _1431 : _2135;
                            uint _1913 = _2136 / 2u;
                            bvec2 _1923 = bvec2((_2136 % 2u) == 0u);
                            vec2 _1443 = vec2(_1923.x ? _800.uniforms.clip_polygon_points[_1913].xy.x : _800.uniforms.clip_polygon_points[_1913].zw.x, _1923.y ? _800.uniforms.clip_polygon_points[_1913].xy.y : _800.uniforms.clip_polygon_points[_1913].zw.y) * _800.uniforms.scale_factor;
                            uint _1929 = _1437 / 2u;
                            bvec2 _1939 = bvec2((_1437 % 2u) == 0u);
                            vec2 _1948 = (vec2(_1939.x ? _800.uniforms.clip_polygon_points[_1929].xy.x : _800.uniforms.clip_polygon_points[_1929].zw.x, _1939.y ? _800.uniforms.clip_polygon_points[_1929].xy.y : _800.uniforms.clip_polygon_points[_1929].zw.y) * _800.uniforms.scale_factor) - _1443;
                            _2138 = min(_2138, length(_1398 - (_1443 + (_1948 * clamp(dot(_1398 - _1443, _1948) / max(dot(_1948, _1948), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                            _2136++;
                            continue;
                        }
                        _2186 = _2138;
                    }
                    float _1474 = max(length(vec2(dFdxFine(input_screen_pos.x), dFdyFine(input_screen_pos.y))) * 0.5, 0.75);
                    _2151 = smoothstep(_1474, -_1474, _2132 ? (-_2134) : _2134);
                    break;
                }
                _2150 = 1.0;
            }
            _2149 = _2150;
        }
        float _1496 = max((abs(dFdxFine(_2149)) + abs(dFdyFine(_2149))) * 0.5, 0.5);
        _2151 = smoothstep(_1496, -_1496, _2149);
        break;
    } while(false);
    float _1148 = instances_1._data[input_instance_id].tint_color.w * ((_2154 * (_2111 * _2151)) * instances_1._data[input_instance_id].opacity);
    if (_1148 < 0.001000000047497451305389404296875)
    {
        discard;
    }
    _entryPointOutput = vec4(instances_1._data[input_instance_id].tint_color.xyz * _1148, _1148);
}

