#version 450
layout(set=0, binding=0, std140) uniform Params { vec2 viewport; float scale; };
layout(set=0, binding=1, std430) readonly buffer Instances { float data[]; };
layout(location=0) flat out vec4 diagnostic;
void main() {
    const vec2 positions[3] = vec2[3](vec2(-0.75,-0.75), vec2(0.75,-0.75), vec2(0,0.75));
    gl_Position = vec4(positions[gl_VertexIndex % 3], 0, 1);
    int offset = gl_InstanceIndex * 28;
    diagnostic = vec4(data[28] / 16.0, data[offset] / 16.0, float(data.length()) / 112.0, 1);
}
