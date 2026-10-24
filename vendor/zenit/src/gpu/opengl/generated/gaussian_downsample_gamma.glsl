#version 430

layout(binding = 0, std140) uniform GaussianAreaUniforms
{
    vec2 area_source_size;
    vec2 area_output_size;
    float area_input_gamma;
    float area_padding0;
    float area_padding1;
    float area_padding2;
} _39;

layout(binding = 0) uniform sampler2D SPIRV_Cross_Combinedsource_texturesource_sampler;

layout(location = 0) in vec2 input_uv;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec2 _193 = _39.area_source_size / _39.area_output_size;
    vec2 _201 = floor(input_uv * _39.area_output_size) * _193;
    vec2 _204 = _201 + _193;
    ivec2 _207 = ivec2(floor(_201));
    vec4 _287 = vec4(0.0);
    _287 = vec4(0.0);
    vec4 _290 = vec4(0.0);
    for (int _286 = 0; _286 < 4; _287 = _290, _286++)
    {
        _290 = _287;
        vec4 _293 = vec4(0.0);
        for (int _288 = 0; _288 < 4; _290 = _293, _288++)
        {
            vec2 _223 = vec2(_207 + ivec2(_288, _286));
            vec2 _233 = max(min(_223 + vec2(1.0), _204) - max(_223, _201), vec2(0.0));
            float _238 = _233.x * _233.y;
            if (_238 > 0.0)
            {
                _293 = _290 + (textureLod(SPIRV_Cross_Combinedsource_texturesource_sampler, (_223 + vec2(0.5)) / _39.area_source_size, 0.0) * _238);
            }
            else
            {
                _293 = _290;
            }
        }
    }
    _entryPointOutput = _287 / vec4(_193.x * _193.y);
}

