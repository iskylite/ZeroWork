#version 430

const vec2 _25[3] = vec2[](vec2(-1.0, -3.0), vec2(3.0, 1.0), vec2(-1.0, 1.0));

void main()
{
    vec4 _64 = vec4(_25[uint(gl_VertexID)], 0.0, 1.0);
    _64.y = -_25[uint(gl_VertexID)].y;
    gl_Position = _64;
    gl_Position.z = 2.0 * gl_Position.z - gl_Position.w;
}

