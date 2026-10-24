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
    vec2 _201 = _34.gaussian_direction * _34.gaussian_texel_size;
    uint _203 = min(floatBitsToUint(_34.gaussian_packed[96].y), 384u);
    vec4 _300 = vec4(0.0);
    _300 = textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(input_uv, _34.gaussian_valid_uv.xy, _34.gaussian_valid_uv.zw), 0.0) * _34.gaussian_packed[0u].x;
    for (uint _299 = 1u; _299 <= _203; )
    {
        vec2 _220 = _201 * float(_299);
        _300 += ((textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(input_uv + _220, _34.gaussian_valid_uv.xy, _34.gaussian_valid_uv.zw), 0.0) + textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(input_uv - _220, _34.gaussian_valid_uv.xy, _34.gaussian_valid_uv.zw), 0.0)) * _34.gaussian_packed[_299 >> uint(2)][_299 & 3u]);
        _299++;
        continue;
    }
    _entryPointOutput = _300;
}

