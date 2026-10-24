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
    vec2 _252 = _39.kawase_texel_size * 0.5;
    vec2 _261 = mix(_39.kawase_valid_uv.xy - _252, _39.kawase_valid_uv.zw + _252, input_uv);
    vec2 _267 = _39.kawase_texel_size * (0.64999997615814208984375 * _39.kawase_offset_scale);
    float _270 = _267.x;
    float _293 = _267.y;
    float _319 = -_270;
    float _322 = -_293;
    _entryPointOutput = (((((((textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(_261 + vec2(_270 * (-2.0), 0.0), _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0) + textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(_261 + vec2(_270 * 2.0, 0.0), _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0)) + textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(_261 + vec2(0.0, _293 * (-2.0)), _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0)) + textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(_261 + vec2(0.0, _293 * 2.0), _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0)) + (textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(_261 + vec2(_319, _322), _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0) * 2.0)) + (textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(_261 + vec2(_270, _322), _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0) * 2.0)) + (textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(_261 + vec2(_319, _293), _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0) * 2.0)) + (textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, clamp(_261 + _267, _39.kawase_valid_uv.xy, _39.kawase_valid_uv.zw), 0.0) * 2.0)) * vec4(0.083333335816860198974609375);
}

