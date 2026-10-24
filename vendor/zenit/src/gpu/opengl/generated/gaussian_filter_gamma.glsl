#version 430

layout(binding = 0, std140) uniform GaussianUniforms
{
    vec2 gaussian_texel_size;
    vec2 gaussian_direction;
    vec4 gaussian_valid_uv;
    vec4 gaussian_packed[97];
} _34;

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combinedsource_texturesource_sampler;

layout(location = 0) in vec2 input_uv;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec2 _215 = _34.gaussian_direction * _34.gaussian_texel_size;
    uint _289 = floatBitsToUint(_34.gaussian_packed[96].y);
    vec4 _344 = vec4(0.0);
    _344 = textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(input_uv, _34.gaussian_valid_uv.xy, _34.gaussian_valid_uv.zw), 0.0) * _34.gaussian_packed[0u].x;
    for (uint _343 = 1u; _343 <= min(_289, 384u); )
    {
        uint _244 = _343 + 1u;
        float _246 = (_343 < _289) ? _34.gaussian_packed[_244 >> uint(2)][_244 & 3u] : 0.0;
        float _249 = _34.gaussian_packed[_343 >> uint(2)][_343 & 3u] + _246;
        vec2 _258 = _215 * (float(_343) + (_246 / max(_249, 9.9999996826552253889678874634872e-21)));
        _344 += ((textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(input_uv + _258, _34.gaussian_valid_uv.xy, _34.gaussian_valid_uv.zw), 0.0) + textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(input_uv - _258, _34.gaussian_valid_uv.xy, _34.gaussian_valid_uv.zw), 0.0)) * _249);
        _343 += 2u;
        continue;
    }
    _entryPointOutput = _344;
}

