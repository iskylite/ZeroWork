#version 430

layout(binding = 0, std140) uniform KawaseUniforms
{
    vec2 kawase_texel_size;
    float kawase_offset_scale;
    float kawase_padding;
    vec4 kawase_valid_uv;
} _42;

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combinedsource_texturesource_sampler;

layout(location = 0) in vec2 input_uv;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    _entryPointOutput = textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(input_uv, _42.kawase_valid_uv.xy, _42.kawase_valid_uv.zw), 0.0);
}

