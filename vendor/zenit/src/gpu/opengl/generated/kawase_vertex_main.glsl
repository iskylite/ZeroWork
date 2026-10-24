#version 430

layout(location = 0) out vec2 _entryPointOutput_uv;

void main()
{
    float _105 = (uint(gl_VertexID) == 1u) ? 3.0 : (-1.0);
    float _108 = (uint(gl_VertexID) == 2u) ? 3.0 : (-1.0);
    vec4 _113 = vec4(_105, _108, 0.0, 1.0);
    _113.y = -_108;
    gl_Position = _113;
    _entryPointOutput_uv = vec2((_105 + 1.0) * 0.5, (1.0 - _108) * 0.5);
    gl_Position.z = 2.0 * gl_Position.z - gl_Position.w;
}

