#version 430

layout(binding = 0, std140) uniform KawaseUniforms
{
    vec2 kawase_texel_size;
    float kawase_offset_scale;
    float kawase_padding;
    vec4 kawase_valid_uv;
} _39;

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combinedsource_texturesource_sampler;

layout(location = 0) in vec2 input_uv;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec2 _200 = _39.kawase_texel_size * 0.5;
    vec2 _209 = mix(_39.kawase_valid_uv.xy - _200, _39.kawase_valid_uv.zw + _200, input_uv);
    vec2 _215 = _39.kawase_texel_size * (0.75 * _39.kawase_offset_scale);
    float _224 = _215.x;
    float _225 = -_224;
    float _227 = _215.y;
    float _228 = -_227;
    _entryPointOutput = (((((textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(_209, _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0) * 4.0) + textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(_209 + vec2(_225, _228), _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0)) + textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(_209 + vec2(_224, _228), _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0)) + textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(_209 + vec2(_225, _227), _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0)) + textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(_209 + _215, _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0)) * vec4(0.125);
}

