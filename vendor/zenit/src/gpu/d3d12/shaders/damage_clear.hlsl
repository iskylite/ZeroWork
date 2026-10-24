// Windows counterpart of src/render/shaders/damage_clear.metal.
// zenit-entry: vertex damage_clear_vertex_main
// zenit-entry: fragment damage_clear_fragment_main
float4 damage_clear_vertex_main(uint id : SV_VertexID) : SV_Position {
    const float2 positions[3] = { float2(-1,-3), float2(3,1), float2(-1,1) };
    return float4(positions[id], 0, 1);
}
float4 damage_clear_fragment_main() : SV_Target { return float4(0,0,0,0); }
