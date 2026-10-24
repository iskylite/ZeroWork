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
    vec2 _173 = _39.kawase_texel_size * 0.5;
    float _176 = _173.x;
    float _177 = -_176;
    float _179 = _173.y;
    float _180 = -_179;
    _entryPointOutput = (((textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(input_uv + vec2(_177, _180), _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0) + textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(input_uv + vec2(_176, _180), _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0)) + textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(input_uv + vec2(_177, _179), _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0)) + textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(input_uv + _173, _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0)) * 0.25;
}

