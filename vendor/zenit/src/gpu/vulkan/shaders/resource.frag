#version 450
layout(set=0, binding=0, std140) uniform Params { vec2 viewport; float scale; };
layout(set=0, binding=1, std430) readonly buffer Instances { float data[]; };
layout(location=0) out vec4 color;
void main() { color = vec4(viewport == vec2(64,48) ? 1 : 0, scale == 1 ? 1 : 0, data[30] == 32 ? 1 : 0, 1); }
