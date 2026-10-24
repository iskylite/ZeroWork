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
};

layout(binding = 0, std140) uniform ImageParams
{
    Uniforms uniforms;
} _777;

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combinedimage_textureimage_sampler;

layout(location = 0) in vec2 input_uv;
layout(location = 1) in vec2 input_local_pos;
layout(location = 2) in vec2 input_size;
layout(location = 3) in vec2 input_screen_pos;
layout(location = 4) in vec4 input_rect_clip;
layout(location = 5) flat in vec4 input_tint_color;
layout(location = 6) flat in vec3 input_material;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    float _1102 = input_material.x * _777.uniforms.scale_factor;
    vec4 _1108 = texture(SPIRV_Cross_Combinedimage_textureimage_sampler, input_uv);
    vec4 _1112 = _1108 * input_tint_color;
    float _2172 = 0.0;
    if (_1102 > 0.0)
    {
        vec2 _1191 = (abs(input_local_pos) - input_size) + vec2(_1102);
        float _1203 = (min(max(_1191.x, _1191.y), 0.0) + length(max(_1191, vec2(0.0)))) - _1102;
        float _1128 = abs(dFdxFine(_1203)) + abs(dFdyFine(_1203));
        _2172 = smoothstep(_1128 * 0.5, _1128 * (-0.5), _1203);
    }
    else
    {
        _2172 = 1.0;
    }
    float _2129 = 0.0;
    do
    {
        if ((input_rect_clip.z < 0.0) || (input_rect_clip.w < 0.0))
        {
            _2129 = 1.0;
            break;
        }
        vec2 _1281 = abs(input_screen_pos - ((input_rect_clip.xy + (input_rect_clip.zw * 0.5)) * _777.uniforms.scale_factor)) - ((input_rect_clip.zw * _777.uniforms.scale_factor) * 0.5);
        float _1294 = min(max(_1281.x, _1281.y), 0.0) + length(max(_1281, vec2(0.0)));
        float _1267 = max((abs(dFdxFine(_1294)) + abs(dFdyFine(_1294))) * 0.5, 0.5);
        _2129 = smoothstep(_1267, -_1267, _1294);
        break;
    } while(false);
    float _2169 = 0.0;
    do
    {
        if (_777.uniforms.clip_shape_kind == 0u)
        {
            _2169 = 1.0;
            break;
        }
        vec2 _1354 = (_777.uniforms.clip_rect.xy + (_777.uniforms.clip_rect.zw * 0.5)) * _777.uniforms.scale_factor;
        vec2 _1361 = (_777.uniforms.clip_rect.zw * _777.uniforms.scale_factor) * 0.5;
        float _2167 = 0.0;
        if (_777.uniforms.clip_shape_kind == 1u)
        {
            float _1370 = _777.uniforms.clip_radius * _777.uniforms.scale_factor;
            vec2 _1527 = (abs(input_screen_pos - _1354) - _1361) + vec2(_1370);
            _2167 = (min(max(_1527.x, _1527.y), 0.0) + length(max(_1527, vec2(0.0)))) - _1370;
        }
        else
        {
            float _2168 = 0.0;
            if (_777.uniforms.clip_shape_kind == 2u)
            {
                _2168 = length((input_screen_pos - _1354) / max(_1361, vec2(0.001000000047497451305389404296875))) - 1.0;
            }
            else
            {
                if (_777.uniforms.clip_shape_kind == 3u)
                {
                    uint _1394 = min(_777.uniforms.clip_point_count, 32u);
                    uint _1397 = min(_777.uniforms.clip_contour_count, 8u);
                    if ((_1394 < 3u) || (_1397 == 0u))
                    {
                        _2169 = 1.0;
                        break;
                    }
                    vec2 _1412 = input_screen_pos - (_777.uniforms.clip_rect.xy * _777.uniforms.scale_factor);
                    bool _2150 = false;
                    do
                    {
                        if (_777.uniforms.clip_fill_rule == 0u)
                        {
                            bool _2149 = false;
                            _2149 = false;
                            uint _1602 = 0u;
                            bool _2203 = false;
                            for (uint _2148 = 0u, _2159 = 0u; _2148 < _1397; _2159 = _1602, _2149 = _2203, _2148++)
                            {
                                _1602 = min(_777.uniforms.clip_polygon_end_points[_2148 / 4u][_2148 % 4u], _1394);
                                if (_1602 <= (_2159 + 1u))
                                {
                                    _2203 = _2149;
                                    continue;
                                }
                                bool _2162 = false;
                                _2162 = _2149;
                                bool _2208 = false;
                                for (uint _2160 = _2159; _2160 < _1602; _2162 = _2208, _2160++)
                                {
                                    uint _1618 = _2160 + 1u;
                                    uint _1624 = (_1618 < _1602) ? _1618 : _2159;
                                    uint _1847 = _2160 / 2u;
                                    bvec2 _1857 = bvec2((_2160 % 2u) == 0u);
                                    vec2 _1630 = vec2(_1857.x ? _777.uniforms.clip_polygon_points[_1847].xy.x : _777.uniforms.clip_polygon_points[_1847].zw.x, _1857.y ? _777.uniforms.clip_polygon_points[_1847].xy.y : _777.uniforms.clip_polygon_points[_1847].zw.y) * _777.uniforms.scale_factor;
                                    uint _1863 = _1624 / 2u;
                                    bvec2 _1873 = bvec2((_1624 % 2u) == 0u);
                                    vec2 _1636 = vec2(_1873.x ? _777.uniforms.clip_polygon_points[_1863].xy.x : _777.uniforms.clip_polygon_points[_1863].zw.x, _1873.y ? _777.uniforms.clip_polygon_points[_1863].xy.y : _777.uniforms.clip_polygon_points[_1863].zw.y) * _777.uniforms.scale_factor;
                                    float _1638 = _1636.y;
                                    float _1640 = _1630.y;
                                    float _1641 = _1638 - _1640;
                                    float _1653 = _1412.y;
                                    float _1666 = _1630.x;
                                    if (((_1640 > _1653) != (_1638 > _1653)) && (_1412.x < ((((_1636.x - _1666) * (_1653 - _1640)) / ((abs(_1641) < 9.9999997473787516355514526367188e-05) ? ((_1641 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _1641)) + _1666)))
                                    {
                                        _2208 = !_2162;
                                    }
                                    else
                                    {
                                        _2208 = _2162;
                                    }
                                }
                                _2203 = _2162;
                            }
                            _2150 = _2149;
                            break;
                        }
                        int _2131 = 0;
                        _2131 = 0;
                        uint _1707 = 0u;
                        int _2191 = 0;
                        for (uint _2130 = 0u, _2132 = 0u; _2130 < _1397; _2132 = _1707, _2131 = _2191, _2130++)
                        {
                            _1707 = min(_777.uniforms.clip_polygon_end_points[_2130 / 4u][_2130 % 4u], _1394);
                            if (_1707 <= (_2132 + 1u))
                            {
                                _2191 = _2131;
                                continue;
                            }
                            int _2135 = 0;
                            _2135 = _2131;
                            int _2198 = 0;
                            for (uint _2133 = _2132; _2133 < _1707; _2135 = _2198, _2133++)
                            {
                                uint _1723 = _2133 + 1u;
                                uint _1729 = (_1723 < _1707) ? _1723 : _2132;
                                uint _1887 = _2133 / 2u;
                                bvec2 _1897 = bvec2((_2133 % 2u) == 0u);
                                vec2 _1735 = vec2(_1897.x ? _777.uniforms.clip_polygon_points[_1887].xy.x : _777.uniforms.clip_polygon_points[_1887].zw.x, _1897.y ? _777.uniforms.clip_polygon_points[_1887].xy.y : _777.uniforms.clip_polygon_points[_1887].zw.y) * _777.uniforms.scale_factor;
                                uint _1903 = _1729 / 2u;
                                bvec2 _1913 = bvec2((_1729 % 2u) == 0u);
                                vec2 _1741 = vec2(_1913.x ? _777.uniforms.clip_polygon_points[_1903].xy.x : _777.uniforms.clip_polygon_points[_1903].zw.x, _1913.y ? _777.uniforms.clip_polygon_points[_1903].xy.y : _777.uniforms.clip_polygon_points[_1903].zw.y) * _777.uniforms.scale_factor;
                                float _1743 = _1735.y;
                                float _1745 = _1412.y;
                                if (_1743 <= _1745)
                                {
                                    float _1749 = _1741.y;
                                    int _2199 = 0;
                                    if (_1749 > _1745)
                                    {
                                        float _1757 = _1735.x;
                                        int _2200 = 0;
                                        if ((((_1741.x - _1757) * (_1745 - _1743)) - ((_1412.x - _1757) * (_1749 - _1743))) > 0.0)
                                        {
                                            _2200 = _2135 + 1;
                                        }
                                        else
                                        {
                                            _2200 = _2135;
                                        }
                                        _2199 = _2200;
                                    }
                                    else
                                    {
                                        _2199 = _2135;
                                    }
                                    _2198 = _2199;
                                }
                                else
                                {
                                    float _1786 = _1741.y;
                                    int _2201 = 0;
                                    if (_1786 <= _1745)
                                    {
                                        float _1794 = _1735.x;
                                        int _2202 = 0;
                                        if ((((_1741.x - _1794) * (_1745 - _1743)) - ((_1412.x - _1794) * (_1786 - _1743))) < 0.0)
                                        {
                                            _2202 = _2135 - 1;
                                        }
                                        else
                                        {
                                            _2202 = _2135;
                                        }
                                        _2201 = _2202;
                                    }
                                    else
                                    {
                                        _2201 = _2135;
                                    }
                                    _2198 = _2201;
                                }
                            }
                            _2191 = _2135;
                        }
                        _2150 = _2131 != 0;
                        break;
                    } while(false);
                    float _2152 = 0.0;
                    uint _2153 = 0u;
                    _2153 = 0u;
                    _2152 = uintBitsToFloat(0x7f800000u /* inf */);
                    uint _1429 = 0u;
                    float _2204 = 0.0;
                    for (uint _2151 = 0u; _2151 < _1397; _2153 = _1429, _2152 = _2204, _2151++)
                    {
                        _1429 = min(_777.uniforms.clip_polygon_end_points[_2151 / 4u][_2151 % 4u], _1394);
                        if (_1429 <= (_2153 + 1u))
                        {
                            _2204 = _2152;
                            continue;
                        }
                        float _2156 = 0.0;
                        _2156 = _2152;
                        for (uint _2154 = _2153; _2154 < _1429; )
                        {
                            uint _1445 = _2154 + 1u;
                            uint _1451 = (_1445 < _1429) ? _1445 : _2153;
                            uint _1927 = _2154 / 2u;
                            bvec2 _1937 = bvec2((_2154 % 2u) == 0u);
                            vec2 _1457 = vec2(_1937.x ? _777.uniforms.clip_polygon_points[_1927].xy.x : _777.uniforms.clip_polygon_points[_1927].zw.x, _1937.y ? _777.uniforms.clip_polygon_points[_1927].xy.y : _777.uniforms.clip_polygon_points[_1927].zw.y) * _777.uniforms.scale_factor;
                            uint _1943 = _1451 / 2u;
                            bvec2 _1953 = bvec2((_1451 % 2u) == 0u);
                            vec2 _1962 = (vec2(_1953.x ? _777.uniforms.clip_polygon_points[_1943].xy.x : _777.uniforms.clip_polygon_points[_1943].zw.x, _1953.y ? _777.uniforms.clip_polygon_points[_1943].xy.y : _777.uniforms.clip_polygon_points[_1943].zw.y) * _777.uniforms.scale_factor) - _1457;
                            _2156 = min(_2156, length(_1412 - (_1457 + (_1962 * clamp(dot(_1412 - _1457, _1962) / max(dot(_1962, _1962), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                            _2154++;
                            continue;
                        }
                        _2204 = _2156;
                    }
                    float _1488 = max(length(vec2(dFdxFine(input_screen_pos.x), dFdyFine(input_screen_pos.y))) * 0.5, 0.75);
                    _2169 = smoothstep(_1488, -_1488, _2150 ? (-_2152) : _2152);
                    break;
                }
                _2168 = 1.0;
            }
            _2167 = _2168;
        }
        float _1510 = max((abs(dFdxFine(_2167)) + abs(dFdyFine(_2167))) * 0.5, 0.5);
        _2169 = smoothstep(_1510, -_1510, _2167);
        break;
    } while(false);
    float _1149 = (_2172 * (_2129 * _2169)) * input_material.y;
    vec4 _2301 = vec4(0.0);
    if (input_material.z > 0.5)
    {
        _2301 = _1112 * _1149;
    }
    else
    {
        float _1161 = _1112.w * _1149;
        _2301 = vec4(_1112.xyz * _1161, _1161);
    }
    if (_2301.w < 0.001000000047497451305389404296875)
    {
        discard;
    }
    _entryPointOutput = _2301;
}

