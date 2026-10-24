#version 430
#extension GL_ARB_derivative_control : require

struct PathUniforms
{
    vec2 viewport_size;
    float scale_factor;
    uint draw_mode;
    vec4 color;
    vec4 rect;
    uint fill_rule;
    uint point_count;
    uint contour_count;
    uint pad0;
    uvec4 contour_end_points[2];
    vec4 polygon_points[16];
    vec4 clip_rect;
    float clip_radius;
    uint clip_shape_kind;
    uint pad1;
    uint pad2;
    uint grad_dir;
    uint grad_stop_count;
    vec2 grad_center;
    float grad_angle;
    uint pad3;
    uint pad4;
    uint pad5;
    vec4 grad_colors[16];
    vec4 grad_positions[4];
};

layout(binding = 1, std140) uniform PathParams
{
    PathUniforms u;
} _96;

layout(location = 0) in vec4 input_fill_color;
layout(location = 1) in vec2 input_local_pos;
layout(location = 0) out vec4 _entryPointOutput;

void main()
{
    vec4 _3790 = vec4(0.0);
    do
    {
        float _3746 = 0.0;
        do
        {
            if (_96.u.clip_shape_kind == 0u)
            {
                _3746 = 1.0;
                break;
            }
            vec2 _2461 = (_96.u.clip_rect.xy + (_96.u.clip_rect.zw * 0.5)) * _96.u.scale_factor;
            vec2 _2468 = (_96.u.clip_rect.zw * _96.u.scale_factor) * 0.5;
            float _3744 = 0.0;
            if (_96.u.clip_shape_kind == 1u)
            {
                float _2480 = _96.u.clip_radius * _96.u.scale_factor;
                vec2 _2520 = (abs(gl_FragCoord.xy - _2461) - _2468) + vec2(_2480);
                _3744 = (length(max(_2520, vec2(0.0))) + min(max(_2520.x, _2520.y), 0.0)) - _2480;
            }
            else
            {
                float _3745 = 0.0;
                if (_96.u.clip_shape_kind == 2u)
                {
                    vec2 _2539 = max(_2468, vec2(9.9999997473787516355514526367188e-05));
                    _3745 = (length((gl_FragCoord.xy - _2461) / _2539) - 1.0) * min(_2539.x, _2539.y);
                }
                else
                {
                    _3745 = -1.0;
                }
                _3744 = _3745;
            }
            float _2503 = max((abs(dFdxFine(_3744)) + abs(dFdyFine(_3744))) * 0.5, 0.5);
            _3746 = smoothstep(_2503, -_2503, _3744);
            break;
        } while(false);
        if (_96.u.draw_mode == 1u)
        {
            uint _1777 = min(_96.u.point_count, 32u);
            uint _1780 = min(_96.u.contour_count, 8u);
            if ((_1777 < 3u) || (_1780 == 0u))
            {
                _3790 = vec4(0.0);
                break;
            }
            bool _3773 = false;
            do
            {
                if (_96.u.fill_rule == 0u)
                {
                    bool _3772 = false;
                    _3772 = false;
                    uint _2607 = 0u;
                    bool _3805 = false;
                    for (uint _3771 = 0u, _3782 = 0u; _3771 < _96.u.contour_count; _3782 = _2607, _3772 = _3805, _3771++)
                    {
                        _2607 = min(_96.u.contour_end_points[_3771 / 4u][_3771 % 4u], _96.u.point_count);
                        if (_2607 <= (_3782 + 1u))
                        {
                            _3805 = _3772;
                            continue;
                        }
                        bool _3785 = false;
                        _3785 = _3772;
                        bool _3810 = false;
                        for (uint _3783 = _3782; _3783 < _2607; _3785 = _3810, _3783++)
                        {
                            uint _2623 = _3783 + 1u;
                            uint _2629 = (_2623 < _2607) ? _2623 : _3782;
                            uint _2842 = _3783 / 2u;
                            bvec2 _2852 = bvec2((_3783 % 2u) == 0u);
                            vec2 _2853 = vec2(_2852.x ? _96.u.polygon_points[_2842].xy.x : _96.u.polygon_points[_2842].zw.x, _2852.y ? _96.u.polygon_points[_2842].xy.y : _96.u.polygon_points[_2842].zw.y);
                            uint _2858 = _2629 / 2u;
                            bvec2 _2868 = bvec2((_2629 % 2u) == 0u);
                            vec2 _2869 = vec2(_2868.x ? _96.u.polygon_points[_2858].xy.x : _96.u.polygon_points[_2858].zw.x, _2868.y ? _96.u.polygon_points[_2858].xy.y : _96.u.polygon_points[_2858].zw.y);
                            float _2637 = _2869.y;
                            float _2639 = _2853.y;
                            float _2640 = _2637 - _2639;
                            float _2665 = _2853.x;
                            if (((_2639 > input_local_pos.y) != (_2637 > input_local_pos.y)) && (input_local_pos.x < ((((_2869.x - _2665) * (input_local_pos.y - _2639)) / ((abs(_2640) < 9.9999997473787516355514526367188e-05) ? ((_2640 < 0.0) ? (-9.9999997473787516355514526367188e-05) : 9.9999997473787516355514526367188e-05) : _2640)) + _2665)))
                            {
                                _3810 = !_3785;
                            }
                            else
                            {
                                _3810 = _3785;
                            }
                        }
                        _3805 = _3785;
                    }
                    _3773 = _3772;
                    break;
                }
                int _3754 = 0;
                _3754 = 0;
                uint _2708 = 0u;
                int _3793 = 0;
                for (uint _3753 = 0u, _3755 = 0u; _3753 < _96.u.contour_count; _3755 = _2708, _3754 = _3793, _3753++)
                {
                    _2708 = min(_96.u.contour_end_points[_3753 / 4u][_3753 % 4u], _96.u.point_count);
                    if (_2708 <= (_3755 + 1u))
                    {
                        _3793 = _3754;
                        continue;
                    }
                    int _3758 = 0;
                    _3758 = _3754;
                    int _3800 = 0;
                    for (uint _3756 = _3755; _3756 < _2708; _3758 = _3800, _3756++)
                    {
                        uint _2724 = _3756 + 1u;
                        uint _2730 = (_2724 < _2708) ? _2724 : _3755;
                        uint _2882 = _3756 / 2u;
                        bvec2 _2892 = bvec2((_3756 % 2u) == 0u);
                        vec2 _2893 = vec2(_2892.x ? _96.u.polygon_points[_2882].xy.x : _96.u.polygon_points[_2882].zw.x, _2892.y ? _96.u.polygon_points[_2882].xy.y : _96.u.polygon_points[_2882].zw.y);
                        uint _2898 = _2730 / 2u;
                        bvec2 _2908 = bvec2((_2730 % 2u) == 0u);
                        vec2 _2909 = vec2(_2908.x ? _96.u.polygon_points[_2898].xy.x : _96.u.polygon_points[_2898].zw.x, _2908.y ? _96.u.polygon_points[_2898].xy.y : _96.u.polygon_points[_2898].zw.y);
                        float _2738 = _2893.y;
                        if (_2738 <= input_local_pos.y)
                        {
                            float _2744 = _2909.y;
                            int _3801 = 0;
                            if (_2744 > input_local_pos.y)
                            {
                                float _2752 = _2893.x;
                                int _3802 = 0;
                                if ((((_2909.x - _2752) * (input_local_pos.y - _2738)) - ((input_local_pos.x - _2752) * (_2744 - _2738))) > 0.0)
                                {
                                    _3802 = _3758 + 1;
                                }
                                else
                                {
                                    _3802 = _3758;
                                }
                                _3801 = _3802;
                            }
                            else
                            {
                                _3801 = _3758;
                            }
                            _3800 = _3801;
                        }
                        else
                        {
                            float _2781 = _2909.y;
                            int _3803 = 0;
                            if (_2781 <= input_local_pos.y)
                            {
                                float _2789 = _2893.x;
                                int _3804 = 0;
                                if ((((_2909.x - _2789) * (input_local_pos.y - _2738)) - ((input_local_pos.x - _2789) * (_2781 - _2738))) < 0.0)
                                {
                                    _3804 = _3758 - 1;
                                }
                                else
                                {
                                    _3804 = _3758;
                                }
                                _3803 = _3804;
                            }
                            else
                            {
                                _3803 = _3758;
                            }
                            _3800 = _3803;
                        }
                    }
                    _3793 = _3758;
                }
                _3773 = _3754 != 0;
                break;
            } while(false);
            float _3775 = 0.0;
            uint _3776 = 0u;
            _3776 = 0u;
            _3775 = uintBitsToFloat(0x7f800000u /* inf */);
            uint _2058 = 0u;
            uvec4 _3335[2] = uvec4[](uvec4(0u), uvec4(0u));
            vec4 _3362[16] = vec4[](vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0));
            vec4 _3388[16] = vec4[](vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0));
            float _3806 = 0.0;
            for (uint _3774 = 0u; _3774 < _1780; _3776 = _2058, _3775 = _3806, _3774++)
            {
                _3335[0] = _96.u.contour_end_points[0];
                _3335[1] = _96.u.contour_end_points[1];
                _2058 = min(_3335[_3774 / 4u][_3774 % 4u], _1777);
                if (_2058 <= (_3776 + 1u))
                {
                    _3806 = _3775;
                    continue;
                }
                float _3779 = 0.0;
                _3779 = _3775;
                for (uint _3777 = _3776; _3777 < _2058; )
                {
                    uint _2074 = _3777 + 1u;
                    uint _2080 = (_2074 < _2058) ? _2074 : _3776;
                    _3362[0] = _96.u.polygon_points[0];
                    _3362[1] = _96.u.polygon_points[1];
                    _3362[2] = _96.u.polygon_points[2];
                    _3362[3] = _96.u.polygon_points[3];
                    _3362[4] = _96.u.polygon_points[4];
                    _3362[5] = _96.u.polygon_points[5];
                    _3362[6] = _96.u.polygon_points[6];
                    _3362[7] = _96.u.polygon_points[7];
                    _3362[8] = _96.u.polygon_points[8];
                    _3362[9] = _96.u.polygon_points[9];
                    _3362[10] = _96.u.polygon_points[10];
                    _3362[11] = _96.u.polygon_points[11];
                    _3362[12] = _96.u.polygon_points[12];
                    _3362[13] = _96.u.polygon_points[13];
                    _3362[14] = _96.u.polygon_points[14];
                    _3362[15] = _96.u.polygon_points[15];
                    uint _2922 = _3777 / 2u;
                    bvec2 _2932 = bvec2((_3777 % 2u) == 0u);
                    vec2 _2933 = vec2(_2932.x ? _3362[_2922].xy.x : _3362[_2922].zw.x, _2932.y ? _3362[_2922].xy.y : _3362[_2922].zw.y);
                    _3388[0] = _96.u.polygon_points[0];
                    _3388[1] = _96.u.polygon_points[1];
                    _3388[2] = _96.u.polygon_points[2];
                    _3388[3] = _96.u.polygon_points[3];
                    _3388[4] = _96.u.polygon_points[4];
                    _3388[5] = _96.u.polygon_points[5];
                    _3388[6] = _96.u.polygon_points[6];
                    _3388[7] = _96.u.polygon_points[7];
                    _3388[8] = _96.u.polygon_points[8];
                    _3388[9] = _96.u.polygon_points[9];
                    _3388[10] = _96.u.polygon_points[10];
                    _3388[11] = _96.u.polygon_points[11];
                    _3388[12] = _96.u.polygon_points[12];
                    _3388[13] = _96.u.polygon_points[13];
                    _3388[14] = _96.u.polygon_points[14];
                    _3388[15] = _96.u.polygon_points[15];
                    uint _2938 = _2080 / 2u;
                    bvec2 _2948 = bvec2((_2080 % 2u) == 0u);
                    vec2 _2957 = vec2(_2948.x ? _3388[_2938].xy.x : _3388[_2938].zw.x, _2948.y ? _3388[_2938].xy.y : _3388[_2938].zw.y) - _2933;
                    _3779 = min(_3779, length(input_local_pos - (_2933 + (_2957 * clamp(dot(input_local_pos - _2933, _2957) / max(dot(_2957, _2957), 9.9999997473787516355514526367188e-05), 0.0, 1.0)))));
                    _3777++;
                    continue;
                }
                _3806 = _3779;
            }
            float _2369 = max(length(vec2(dFdxFine(input_local_pos.x), dFdyFine(input_local_pos.y))) * 0.5, 0.75 / max(_96.u.scale_factor, 1.0));
            float _2384 = (smoothstep(_2369, -_2369, _3773 ? (-_3775) : _3775) * _96.u.color.w) * _3746;
            _3790 = vec4(_96.u.color.xyz * _2384, _2384);
            break;
        }
        if (_96.u.draw_mode == 2u)
        {
            float _3747 = 0.0;
            do
            {
                vec2 _2988 = (input_local_pos / max(_96.u.rect.zw, vec2(9.9999999747524270787835121154785e-07))) - _96.u.grad_center;
                if (_96.u.grad_dir == 4u)
                {
                    _3747 = clamp(length(_2988) * 2.0, 0.0, 1.0);
                    break;
                }
                float _3005 = atan(_2988.y, _2988.x) - _96.u.grad_angle;
                _3747 = (_3005 - (6.283185482025146484375 * floor(_3005 * 0.15915493667125701904296875))) * 0.15915493667125701904296875;
                break;
            } while(false);
            vec4 _3752 = vec4(0.0);
            do
            {
                uint _3035 = min(_96.u.grad_stop_count, 16u);
                if (_3035 == 0u)
                {
                    _3752 = vec4(0.0);
                    break;
                }
                if (_3035 == 1u)
                {
                    _3752 = _96.u.grad_colors[0];
                    break;
                }
                float _3047 = clamp(_3747, 0.0, 1.0);
                if (_3047 <= _96.u.grad_positions[0u].x)
                {
                    _3752 = _96.u.grad_colors[0];
                    break;
                }
                vec4 _3749 = vec4(0.0);
                _3749 = _96.u.grad_colors[_3035 - 1u];
                bool _3891 = false;
                vec4 _3791 = vec4(0.0);
                uint _3748 = 1u;
                bool _3750 = false;
                for (; _3748 < _3035; _3750 = _3891, _3749 = _3791, _3748++)
                {
                    uint _3118 = _3748 / 4u;
                    uint _3120 = _3748 % 4u;
                    bool _3071 = (!_3750) && (_3047 <= _96.u.grad_positions[_3118][_3120]);
                    if (_3071)
                    {
                        uint _3076 = _3748 - 1u;
                        uint _3134 = _3076 / 4u;
                        uint _3136 = _3076 % 4u;
                        float _3078 = _96.u.grad_positions[_3118][_3120] - _96.u.grad_positions[_3134][_3136];
                        _3791 = mix(_96.u.grad_colors[_3076], _96.u.grad_colors[_3748], vec4((_3078 > 9.9999999747524270787835121154785e-07) ? ((_3047 - _96.u.grad_positions[_3134][_3136]) / _3078) : 0.0));
                    }
                    else
                    {
                        _3791 = _3749;
                    }
                    _3891 = _3071 ? true : _3750;
                }
                _3752 = _3749;
                break;
            } while(false);
            float _2415 = (_3752.w * input_fill_color.w) * _3746;
            _3790 = vec4(_3752.xyz * _2415, _2415);
            break;
        }
        _3790 = input_fill_color * _3746;
        break;
    } while(false);
    _entryPointOutput = _3790;
}

