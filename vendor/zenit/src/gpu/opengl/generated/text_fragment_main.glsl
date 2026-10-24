#version 430
#extension GL_ARB_derivative_control : require

struct GlyphInstance
{
    vec2 position;
    vec2 size;
    vec4 uv_rect;
    vec4 color;
    vec4 rect_clip;
    float skew_x;
    float page_index;
    float is_color;
    float shader_snap;
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
    GlyphInstance _data[];
} instances_1;

layout(binding = 0, std140) uniform Params
{
    Uniforms uniforms;
} _802;

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combinedglyph_atlas_coloratlas_sampler;
layout(binding = 1) uniform sampler2D SPIRV_Cross_Combinedglyph_atlasatlas_sampler;

layout(location = 0) in vec2 input_uv;
layout(location = 1) in vec2 input_screen_pos;
layout(location = 2) in vec4 input_rect_clip;
layout(location = 3) flat in uint input_instance_id;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _2115 = vec4(0.0);
    do
    {
        float _2074 = 0.0;
        do
        {
            if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
            {
                _2074 = 1.0;
                break;
            }
            vec2 _1235 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _802.uniforms.scale_factor)) - ((input_rect_clip.zw * _802.uniforms.scale_factor) * 0.5);
            float _1248 = min(max(_1235.x, _1235.y), 0.0) + length(max(_1235, vec2(0.0)));
            float _1221 = max((abs(dFdxFine(_1248)) + abs(dFdyFine(_1248))) * 0.5, 0.5);
            _2074 = smoothstep(_1221, -_1221, _1248);
            break;
        } while(false);
        float _2114 = 0.0;
        do
        {
            if (_802.uniforms.clip_shape_kind == 0u)
            {
                _2114 = 1.0;
                break;
            }
            vec2 _1308 = (_802.uniforms.clip_rect.xy + (_802.uniforms.clip_rect.zw * 0.5)) * _802.uniforms.scale_factor;
            vec2 _1315 = (_802.uniforms.clip_rect.zw * _802.uniforms.scale_factor) * 0.5;
            float _2112 = 0.0;
            if (_802.uniforms.clip_shape_kind == 1u)
            {
                float _1324 = _802.uniforms.clip_radius * _802.uniforms.scale_factor;
                vec2 _1481 = (abs(input_screen_pos - _1308) - _1315) + vec2(_1324);
                _2112 = (min(max(_1481.x, _1481.y), 0.0) + length(max(_1481, vec2(0.0)))) - _1324;
            }
            else
            {
                float _2113 = 0.0;
                if (_802.uniforms.clip_shape_kind == 2u)
                {
                    _2113 = length((input_screen_pos - _1308) / max(_1315, vec2(0.001000000047497451305389404296875))) - 1.0;
                }
                else
                {
                    if (_802.uniforms.clip_shape_kind == 3u)
                    {
                        uint _1348 = min(_802.uniforms.clip_point_count, 32u);
                        uint _1351 = min(_802.uniforms.clip_contour_count, 8u);
                        if ((_1348 < 3u) || (_1351 == 0u))
                        {
                            _2114 = 1.0;
                            break;
                        }
                        vec2 _1366 = input_screen_pos - (_802.uniforms.clip_rect.xy * _802.uniforms.scale_factor);
                        bool _2095 = false;
                        do
                        {
                            if (_802.uniforms.clip_fill_rule == 0u)
                            {
                                bool _2094 = false;
                                _2094 = false;
                                uint _1556 = 0u;
                                bool _2128 = false;
                                for (uint _2093 = 0u, _2104 = 0u; _2093 < _1351; _2104 = _1556, _2094 = _2128, _2093++)
                                {
                                    _1556 = min(_802.uniforms.clip_polygon_end_points[_2093 / 4u][_2093 % 4u], _1348);
                                    if (_1556 <= (_2104 + 1u))
                                    {
                                        _2128 = _2094;
                                        continue;
                                    }
                                    bool _2107 = false;
                                    _2107 = _2094;
                                    bool _2133 = false;
                                    for (uint _2105 = _2104; _2105 < _1556; _2107 = _2133, _2105++)
                                    {
                                        uint _1572 = _2105 + 1u;
                                        uint _1578 = (_1572 < _1556) ? _1572 : _2104;
                                        uint _1801 = _2105 / 2u;
                                        bvec2 _1811 = bvec2((_2105 % 2u) == 0u);
                                        vec2 _1584 = vec2(_1811.x ? _802.uniforms.clip_polygon_points[_1801].xy.x : _802.uniforms.clip_polygon_points[_1801].zw.x, _1811.y ? _802.uniforms.clip_polygon_points[_1801].xy.y : _802.uniforms.clip_polygon_points[_1801].zw.y) * _802.uniforms.scale_factor;
                                        uint _1817 = _1578 / 2u;
                                        bvec2 _1827 = bvec2((_1578 % 2u) == 0u);
                                        vec2 _1590 = vec2(_1827.x ? _802.uniforms.clip_polygon_points[_1817].xy.x : _802.uniforms.clip_polygon_points[_1817].zw.x, _1827.y ? _802.uniforms.clip_polygon_points[_1817].xy.y : _802.uniforms.clip_polygon_points[_1817].zw.y) * _802.uniforms.scale_factor;
                                        float _1592 = _1590.y;
                                        float _1594 = _1584.y;
                                        float _1595 = _1592 - _1594;
                                        float _1607 = _1366.y;
                                        float _1620 = _1584.x;
                                        if (((_1594 > _1607) != (_1592 > _1607)) && (_1366.x < ((((_1590.x - _1620) * (_1607 - _1594)) / ((abs(_1595) < 9.9999997473787516355514526367188e-05) ? ((_1595 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _1595)) + _1620)))
                                        {
                                            _2133 = !_2107;
                                        }
                                        else
                                        {
                                            _2133 = _2107;
                                        }
                                    }
                                    _2128 = _2107;
                                }
                                _2095 = _2094;
                                break;
                            }
                            int _2076 = 0;
                            _2076 = 0;
                            uint _1661 = 0u;
                            int _2116 = 0;
                            for (uint _2075 = 0u, _2077 = 0u; _2075 < _1351; _2077 = _1661, _2076 = _2116, _2075++)
                            {
                                _1661 = min(_802.uniforms.clip_polygon_end_points[_2075 / 4u][_2075 % 4u], _1348);
                                if (_1661 <= (_2077 + 1u))
                                {
                                    _2116 = _2076;
                                    continue;
                                }
                                int _2080 = 0;
                                _2080 = _2076;
                                int _2123 = 0;
                                for (uint _2078 = _2077; _2078 < _1661; _2080 = _2123, _2078++)
                                {
                                    uint _1677 = _2078 + 1u;
                                    uint _1683 = (_1677 < _1661) ? _1677 : _2077;
                                    uint _1841 = _2078 / 2u;
                                    bvec2 _1851 = bvec2((_2078 % 2u) == 0u);
                                    vec2 _1689 = vec2(_1851.x ? _802.uniforms.clip_polygon_points[_1841].xy.x : _802.uniforms.clip_polygon_points[_1841].zw.x, _1851.y ? _802.uniforms.clip_polygon_points[_1841].xy.y : _802.uniforms.clip_polygon_points[_1841].zw.y) * _802.uniforms.scale_factor;
                                    uint _1857 = _1683 / 2u;
                                    bvec2 _1867 = bvec2((_1683 % 2u) == 0u);
                                    vec2 _1695 = vec2(_1867.x ? _802.uniforms.clip_polygon_points[_1857].xy.x : _802.uniforms.clip_polygon_points[_1857].zw.x, _1867.y ? _802.uniforms.clip_polygon_points[_1857].xy.y : _802.uniforms.clip_polygon_points[_1857].zw.y) * _802.uniforms.scale_factor;
                                    float _1697 = _1689.y;
                                    float _1699 = _1366.y;
                                    if (_1697 <= _1699)
                                    {
                                        float _1703 = _1695.y;
                                        int _2124 = 0;
                                        if (_1703 > _1699)
                                        {
                                            float _1711 = _1689.x;
                                            int _2125 = 0;
                                            if ((((_1695.x - _1711) * (_1699 - _1697)) - ((_1366.x - _1711) * (_1703 - _1697))) > 0.0)
                                            {
                                                _2125 = _2080 + 1;
                                            }
                                            else
                                            {
                                                _2125 = _2080;
                                            }
                                            _2124 = _2125;
                                        }
                                        else
                                        {
                                            _2124 = _2080;
                                        }
                                        _2123 = _2124;
                                    }
                                    else
                                    {
                                        float _1740 = _1695.y;
                                        int _2126 = 0;
                                        if (_1740 <= _1699)
                                        {
                                            float _1748 = _1689.x;
                                            int _2127 = 0;
                                            if ((((_1695.x - _1748) * (_1699 - _1697)) - ((_1366.x - _1748) * (_1740 - _1697))) < 0.0)
                                            {
                                                _2127 = _2080 - 1;
                                            }
                                            else
                                            {
                                                _2127 = _2080;
                                            }
                                            _2126 = _2127;
                                        }
                                        else
                                        {
                                            _2126 = _2080;
                                        }
                                        _2123 = _2126;
                                    }
                                }
                                _2116 = _2080;
                            }
                            _2095 = _2076 != 0;
                            break;
                        } while(false);
                        float _2097 = 0.0;
                        uint _2098 = 0u;
                        _2098 = 0u;
                        _2097 = uintBitsToFloat(0x7f800000u /* inf */);
                        uint _1383 = 0u;
                        float _2129 = 0.0;
                        for (uint _2096 = 0u; _2096 < _1351; _2098 = _1383, _2097 = _2129, _2096++)
                        {
                            _1383 = min(_802.uniforms.clip_polygon_end_points[_2096 / 4u][_2096 % 4u], _1348);
                            if (_1383 <= (_2098 + 1u))
                            {
                                _2129 = _2097;
                                continue;
                            }
                            float _2101 = 0.0;
                            _2101 = _2097;
                            for (uint _2099 = _2098; _2099 < _1383; )
                            {
                                uint _1399 = _2099 + 1u;
                                uint _1405 = (_1399 < _1383) ? _1399 : _2098;
                                uint _1881 = _2099 / 2u;
                                bvec2 _1891 = bvec2((_2099 % 2u) == 0u);
                                vec2 _1411 = vec2(_1891.x ? _802.uniforms.clip_polygon_points[_1881].xy.x : _802.uniforms.clip_polygon_points[_1881].zw.x, _1891.y ? _802.uniforms.clip_polygon_points[_1881].xy.y : _802.uniforms.clip_polygon_points[_1881].zw.y) * _802.uniforms.scale_factor;
                                uint _1897 = _1405 / 2u;
                                bvec2 _1907 = bvec2((_1405 % 2u) == 0u);
                                vec2 _1916 = (vec2(_1907.x ? _802.uniforms.clip_polygon_points[_1897].xy.x : _802.uniforms.clip_polygon_points[_1897].zw.x, _1907.y ? _802.uniforms.clip_polygon_points[_1897].xy.y : _802.uniforms.clip_polygon_points[_1897].zw.y) * _802.uniforms.scale_factor) - _1411;
                                _2101 = min(_2101, length(_1366 - (_1411 + (_1916 * clamp(dot(_1366 - _1411, _1916) / max(dot(_1916, _1916), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                                _2099++;
                                continue;
                            }
                            _2129 = _2101;
                        }
                        float _1442 = max(length(vec2(dFdxFine(input_screen_pos.x), dFdyFine(input_screen_pos.y))) * 0.5, 0.75);
                        _2114 = smoothstep(_1442, -_1442, _2095 ? (-_2097) : _2097);
                        break;
                    }
                    _2113 = 1.0;
                }
                _2112 = _2113;
            }
            float _1464 = max((abs(dFdxFine(_2112)) + abs(dFdyFine(_2112))) * 0.5, 0.5);
            _2114 = smoothstep(_1464, -_1464, _2112);
            break;
        } while(false);
        float _1173 = _2074 * _2114;
        if (instances_1._data[input_instance_id].is_color > 0.5)
        {
            vec4 _1107 = texture(SPIRV_Cross_Combinedglyph_atlas_coloratlas_sampler, input_uv);
            vec4 _1114 = _1107 * (_1173 * instances_1._data[input_instance_id].color.w);
            if (_1114.w < 0.001000000047497451305389404296875)
            {
                discard;
            }
            _2115 = _1114;
            break;
        }
        vec4 _1127 = texture(SPIRV_Cross_Combinedglyph_atlasatlas_sampler, input_uv);
        float _1136 = instances_1._data[input_instance_id].color.w * (_1127.x * _1173);
        if (_1136 < 0.001000000047497451305389404296875)
        {
            discard;
        }
        _2115 = vec4(instances_1._data[input_instance_id].color.xyz * _1136, _1136);
        break;
    } while(false);
    _entryPointOutput = _2115;
}

