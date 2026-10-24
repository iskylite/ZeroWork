#version 430

void main()
{
    float _75 = (uint(gl_VertexID) == 2u) ? 3.0 : (-1.0);
    vec4 _76 = vec4((uint(gl_VertexID) == 1u) ? 3.0 : (-1.0), _75, 0.0, 1.0);
    _76.y = -_75;
    gl_Position = _76;
    gl_Position.z = 2.0 * gl_Position.z - gl_Position.w;
}

