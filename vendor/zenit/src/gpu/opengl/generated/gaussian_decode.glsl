#version 430

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combinedsource_texturesource_sampler;

layout(location = 0) in vec2 input_uv;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    _entryPointOutput = textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, input_uv, 0.0);
}

