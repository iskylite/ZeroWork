#version 430

layout(binding = 0, std140) uniform BlendUniforms
{
    vec2 target_size;
    vec2 rect_size;
    vec2 src_uv_scale;
    vec2 inv_offset;
    vec4 inv;
    vec4 params;
    vec4 clip_rect;
    vec4 clip_shape;
    vec4 clip_shape_rect;
    vec4 warp;
    vec4 src_uv_origin;
} _434;

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combineddestination_textureSPIRV_Cross_DummySampler;
layout(binding = 1) uniform sampler2D SPIRV_Cross_Combinedsource_texturetexture_sampler;

layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _1984 = vec4(0.0);
    do
    {
        vec4 _1103 = texelFetch(SPIRV_Cross_Combineddestination_textureSPIRV_Cross_DummySampler, ivec3(ivec2(gl_FragCoord.xy), 0).xy, 0);
        vec2 _1129 = vec2((_434.inv.x * gl_FragCoord.x) + (_434.inv.z * gl_FragCoord.y), (_434.inv.y * gl_FragCoord.x) + (_434.inv.w * gl_FragCoord.y)) + _434.inv_offset;
        float _1131 = _1129.x;
        float _1134 = _1129.y;
        if ((((_1131 < 0.0) || (_1134 < 0.0)) || (_1131 >= _434.rect_size.x)) || (_1134 >= _434.rect_size.y))
        {
            _1984 = _1103;
            break;
        }
        vec2 _1970 = vec2(0.0);
        if ((_434.warp.x != 0.0) || (_434.warp.y != 0.0))
        {
            vec2 _1163 = _434.rect_size * 0.5;
            vec2 _1169 = max(_1163 - vec2(_434.params.w), vec2(0.5));
            float _1177 = min(_434.params.z, min(_1169.x, _1169.y));
            vec2 _1180 = _1129 - _1163;
            vec2 _1187 = (abs(_1180) - _1169) + vec2(_1177);
            float _1192 = _1187.x;
            float _1194 = _1187.y;
            vec2 _1219 = normalize(_1187);
            bvec2 _1225 = bvec2(_1192 > _1194);
            vec2 _1226 = vec2(_1225.x ? vec2(1.0, 0.0).x : vec2(0.0, 1.0).x, _1225.y ? vec2(1.0, 0.0).y : vec2(0.0, 1.0).y);
            bvec2 _1227 = bvec2((_1192 > 0.0) && (_1194 > 0.0));
            vec2 _1231 = vec2(_1227.x ? _1219.x : _1226.x, _1227.y ? _1219.y : _1226.y) * vec2((_1180.x < 0.0) ? (-1.0) : 1.0, (_1180.y < 0.0) ? (-1.0) : 1.0);
            float _1233 = _1231.y;
            _1970 = clamp(_1129 - ((_1231 * mix(_434.warp.x, _434.warp.y, _1233 * _1233)) * (1.0 - smoothstep(_434.warp.z, _434.warp.z + max(_434.warp.w, 0.00999999977648258209228515625), max(-((length(max(_1187, vec2(0.0))) + min(max(_1192, _1194), 0.0)) - _1177), 0.0)))), vec2(0.0), _434.rect_size - vec2(1.0));
        }
        else
        {
            _1970 = _1129;
        }
        vec4 _1282 = texture(SPIRV_Cross_Combinedsource_texturetexture_sampler, _434.src_uv_origin.xy + ((_1970 / _434.rect_size) * _434.src_uv_scale));
        float _1971 = 0.0;
        do
        {
            if (_434.params.z <= 0.5)
            {
                _1971 = 1.0;
                break;
            }
            vec2 _1446 = (_434.rect_size - vec2(2.0 * _434.params.w)) * 0.5;
            vec2 _1455 = (abs((_1129 - vec2(_434.params.w)) - _1446) - _1446) + vec2(_434.params.z);
            _1971 = clamp(0.5 - ((length(max(_1455, vec2(0.0))) + min(max(_1455.x, _1455.y), 0.0)) - _434.params.z), 0.0, 1.0);
            break;
        } while(false);
        float _1974 = 0.0;
        if ((_434.clip_rect.z >= 0.0) && (_434.clip_rect.w >= 0.0))
        {
            vec2 _1497 = _434.clip_rect.zw * 0.5;
            vec2 _1507 = abs(gl_FragCoord.xy - (_434.clip_rect.xy + _1497)) - _1497;
            _1974 = clamp(0.5 - (length(max(_1507, vec2(0.0))) + min(max(_1507.x, _1507.y), 0.0)), 0.0, 1.0);
        }
        else
        {
            _1974 = 1.0;
        }
        uint _1526 = uint(_434.clip_shape.x);
        bool _1528 = _1526 == 1u;
        float _1975 = 0.0;
        if (_1528 || (_1526 == 2u))
        {
            vec2 _1536 = _434.clip_shape_rect.zw * 0.5;
            vec2 _1543 = gl_FragCoord.xy - (_434.clip_shape_rect.xy + _1536);
            float _1972 = 0.0;
            if (_1528)
            {
                float _1554 = min(_434.clip_shape.y, min(_1536.x, _1536.y));
                vec2 _1561 = (abs(_1543) - _1536) + vec2(_1554);
                _1972 = (length(max(_1561, vec2(0.0))) + min(max(_1561.x, _1561.y), 0.0)) - _1554;
            }
            else
            {
                vec2 _1576 = max(_1536, vec2(0.001000000047497451305389404296875));
                _1972 = (length(_1543 / _1576) - 1.0) * min(_1576.x, _1576.y);
            }
            _1975 = _1974 * clamp(0.5 - _1972, 0.0, 1.0);
        }
        else
        {
            _1975 = _1974;
        }
        vec4 _1302 = _1282 * (_1971 * _1975);
        vec4 _1980 = vec4(0.0);
        do
        {
            float _1602 = _1302.w;
            if (_1602 < 9.9999997473787516355514526367188e-05)
            {
                _1980 = vec4(0.0);
                break;
            }
            _1980 = vec4(_1302.xyz / vec3(_1602), _1602);
            break;
        } while(false);
        vec4 _1981 = vec4(0.0);
        do
        {
            float _1626 = _1103.w;
            if (_1626 < 9.9999997473787516355514526367188e-05)
            {
                _1981 = vec4(0.0);
                break;
            }
            _1981 = vec4(_1103.xyz / vec3(_1626), _1626);
            break;
        } while(false);
        vec3 _1982 = vec3(0.0);
        switch (uint(_434.params.y))
        {
            case 1u:
            {
                _1982 = _1980.xyz * _1981.xyz;
                break;
            }
            case 2u:
            {
                _1982 = (_1980.xyz + _1981.xyz) - (_1980.xyz * _1981.xyz);
                break;
            }
            case 3u:
            {
                vec3 _1672 = (_1981.xyz * 2.0) * _1980.xyz;
                vec3 _1682 = vec3(1.0) - (((vec3(1.0) - _1981.xyz) * 2.0) * (vec3(1.0) - _1980.xyz));
                _1982 = vec3((_1981.x <= 0.5) ? _1672.x : _1682.x, (_1981.y <= 0.5) ? _1672.y : _1682.y, (_1981.z <= 0.5) ? _1672.z : _1682.z);
                break;
            }
            case 4u:
            {
                _1982 = min(_1980.xyz, _1981.xyz);
                break;
            }
            case 5u:
            {
                _1982 = max(_1980.xyz, _1981.xyz);
                break;
            }
            case 6u:
            {
                _1982 = vec3((_1980.x >= 1.0) ? 1.0 : min(1.0, _1981.x / max(1.0 - _1980.x, 9.9999997473787516355514526367188e-05)), (_1980.y >= 1.0) ? 1.0 : min(1.0, _1981.y / max(1.0 - _1980.y, 9.9999997473787516355514526367188e-05)), (_1980.z >= 1.0) ? 1.0 : min(1.0, _1981.z / max(1.0 - _1980.z, 9.9999997473787516355514526367188e-05)));
                break;
            }
            case 7u:
            {
                _1982 = vec3((_1980.x <= 0.0) ? 0.0 : (1.0 - min(1.0, (1.0 - _1981.x) / max(_1980.x, 9.9999997473787516355514526367188e-05))), (_1980.y <= 0.0) ? 0.0 : (1.0 - min(1.0, (1.0 - _1981.y) / max(_1980.y, 9.9999997473787516355514526367188e-05))), (_1980.z <= 0.0) ? 0.0 : (1.0 - min(1.0, (1.0 - _1981.z) / max(_1980.z, 9.9999997473787516355514526367188e-05))));
                break;
            }
            case 8u:
            {
                vec3 _1806 = (_1980.xyz * 2.0) * _1981.xyz;
                vec3 _1816 = vec3(1.0) - (((vec3(1.0) - _1980.xyz) * 2.0) * (vec3(1.0) - _1981.xyz));
                _1982 = vec3((_1980.x <= 0.5) ? _1806.x : _1816.x, (_1980.y <= 0.5) ? _1806.y : _1816.y, (_1980.z <= 0.5) ? _1806.z : _1816.z);
                break;
            }
            case 9u:
            {
                vec3 _1904 = _1980.xyz * 2.0;
                vec3 _1913 = _1981.xyz - (((vec3(1.0) - _1904) * _1981.xyz) * (vec3(1.0) - _1981.xyz));
                vec3 _1923 = _1981.xyz + ((_1904 - vec3(1.0)) * (vec3((_1981.x <= 0.25) ? (((((16.0 * _1981.x) - 12.0) * _1981.x) + 4.0) * _1981.x) : sqrt(_1981.x), (_1981.y <= 0.25) ? (((((16.0 * _1981.y) - 12.0) * _1981.y) + 4.0) * _1981.y) : sqrt(_1981.y), (_1981.z <= 0.25) ? (((((16.0 * _1981.z) - 12.0) * _1981.z) + 4.0) * _1981.z) : sqrt(_1981.z)) - _1981.xyz));
                _1982 = vec3((_1980.x <= 0.5) ? _1913.x : _1923.x, (_1980.y <= 0.5) ? _1913.y : _1923.y, (_1980.z <= 0.5) ? _1913.z : _1923.z);
                break;
            }
            case 10u:
            {
                _1982 = abs(_1980.xyz - _1981.xyz);
                break;
            }
            case 11u:
            {
                _1982 = (_1980.xyz + _1981.xyz) - ((_1980.xyz * 2.0) * _1981.xyz);
                break;
            }
            default:
            {
                _1982 = _1980.xyz;
                break;
            }
        }
        float _1384 = _1980.w * _434.params.x;
        float _1389 = 1.0 - _1384;
        float _1391 = _1384 + (_1981.w * _1389);
        vec3 _1983 = vec3(0.0);
        if (_1391 >= 9.9999997473787516355514526367188e-05)
        {
            _1983 = (((_1981.xyz * (_1389 * _1981.w)) + (_1982 * (_1384 * _1981.w))) + (_1980.xyz * ((1.0 - _1981.w) * _1384))) / vec3(_1391);
        }
        else
        {
            _1983 = vec3(0.0);
        }
        _1984 = vec4(_1983 * _1391, _1391);
        break;
    } while(false);
    _entryPointOutput = _1984;
}

