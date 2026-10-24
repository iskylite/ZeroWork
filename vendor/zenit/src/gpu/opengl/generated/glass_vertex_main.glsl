#version 430

layout(location = 0) out vec2 _entryPointOutput_uv;

void main()
{
    float _220 = (uint(gl_VertexID) == 1u) ? 3.0 : (-1.0);
    float _224 = (uint(gl_VertexID) == 2u) ? 3.0 : (-1.0);
    vec4 _229 = vec4(_220, _224, 0.0, 1.0);
    _229.y = -_224;
    gl_Position = _229;
    _entryPointOutput_uv = vec2((_220 + 1.0) * 0.5, (1.0 - _224) * 0.5);
    gl_Position.z = 2.0 * gl_Position.z - gl_Position.w;
}

