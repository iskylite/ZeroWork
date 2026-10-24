#!/usr/bin/env python3
"""Translate validated UI SPIR-V offline to GL 4.3, retaining ABI reflection.
The GL backend uses an explicit first-instance uniform: gl_InstanceID excludes
baseInstance even when glDrawArraysInstancedBaseInstance is available.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--spirv-cross', required=True)
    ap.add_argument('--input', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    entries = json.loads((a.input / 'manifest.json').read_text())
    a.out.mkdir(parents=True, exist_ok=True)
    records, excluded = [], []
    names = set()
    for entry in entries:
        name = entry['name']
        if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', name) or name in names:
            raise ValueError('invalid/duplicate entry name')
        names.add(name)
        if name == 'sdf_region_vertex_main':
            excluded.append(dict(name=name, reason='Windows-only viewport-index optimization; OpenGL uses normal SDF/scissor pipelines'))
            (a.out / (name + '.glsl')).unlink(missing_ok=True)
            continue
        if entry['stage'] not in ('vertex', 'fragment'):
            raise ValueError('unsupported UI shader stage')
        src, dst = a.input / (name + '.spv'), a.out / (name + '.glsl')
        subprocess.run([a.spirv_cross, str(src), '--version', '430', '--no-es', '--fixup-clipspace', '--force-zero-initialized-variables', '--combined-samplers-inherit-bindings', '--output', str(dst)], check=True)
        code = dst.read_text()
        block = '#ifdef GL_ARB_shader_draw_parameters\n#define SPIRV_Cross_BaseInstance gl_BaseInstanceARB\n#else\nuniform int SPIRV_Cross_BaseInstance;\n#endif'
        if 'SPIRV_Cross_BaseInstance' in code:
            if code.count(block) != 1 or entry['stage'] != 'vertex':
                raise ValueError('unrecognized SPIRV-Cross base-instance contract: ' + name)
            code = code.replace(block, 'uniform int zenit_first_instance;').replace('SPIRV_Cross_BaseInstance', 'zenit_first_instance')
        if 'gl_BaseInstance' in code:
            raise ValueError('extension-dependent base instance remained: ' + name)
        reflected_path = a.out / (name + '.reflection.json')
        subprocess.run([a.spirv_cross, str(src), '--reflect', '--output', str(reflected_path)], check=True)
        reflected = json.loads(reflected_path.read_text())
        reflected_path.unlink()
        images = reflected.get('separate_images', [])
        samplers = reflected.get('separate_samplers', [])
        texture_units = []
        sampler_pattern = r'layout\(binding = (\d+)\) uniform sampler2D (SPIRV_Cross_Combined\w+);'
        declarations = list(re.finditer(sampler_pattern, code))
        for declaration in declarations:
            uniform = declaration[2]
            matches = [(image, sampler) for image in images for sampler in samplers + [None]
                       if uniform == 'SPIRV_Cross_Combined' + image['name'] + (sampler['name'] if sampler else 'SPIRV_Cross_DummySampler')]
            if len(matches) != 1:
                raise ValueError('unmapped combined texture/sampler: ' + uniform)
            image, sampler = matches[0]
            texture_units.append(dict(unit=len(texture_units), uniform=uniform,
                                      texture_group=image['set'], texture_binding=image['binding'],
                                      sampler_group=sampler['set'] if sampler else None,
                                      sampler_binding=sampler['binding'] if sampler else None))
        unit_by_uniform = {m['uniform']: m['unit'] for m in texture_units}
        code = re.sub(sampler_pattern, lambda m: 'layout(binding = %d) uniform sampler2D %s;' % (unit_by_uniform[m[2]], m[2]), code)
        if len(re.findall(r'\buniform\s+\w*sampler\w*\s+', code)) != len(texture_units):
            raise ValueError('unsupported sampler type/declaration: ' + name)
        dst.write_text(code)
        records.append(dict(entry, source=name + '.glsl', spirv_sha256=hashlib.sha256(src.read_bytes()).hexdigest(), glsl_sha256=hashlib.sha256(code.encode()).hexdigest(), first_instance_uniform='zenit_first_instance' if 'zenit_first_instance' in code else None, texture_units=texture_units, gl_resources={k: reflected.get(k, []) for k in ('ubos', 'ssbos')}))
    aliases = {'blur': 'kawase', 'composite': 'blend', 'sdf_primitives': 'sdf'}
    pairs = [[aliases.get(e['program'], e['program']) + '_vertex_main', e['name']] for e in entries if e['stage'] == 'fragment']
    pairs += [['sdf_tiled_rect_vertex_main', 'sdf_rect_fragment_main'], ['sdf_shadow_ring_vertex_main', 'sdf_shadow_ring_fragment_main'], ['sdf_dual_shadow_vertex_main', 'sdf_dual_shadow_fragment_main']]
    if any(v not in names or f not in names for v, f in pairs):
        raise ValueError('UI pipeline entry missing')
    manifest = dict(schema=1, glsl_version=430, clip_z_fixup=True, zero_initialized_variables=True, first_instance='explicit-uniform', entries=records, pipelines=pairs, excluded_entries=excluded)
    zig = ['// Generated by compile_opengl_ui_shaders.py; do not edit.',
           'pub const Stage = enum { vertex, fragment };',
           'pub const Binding = struct { group: u32, binding: u32, kind: u32, min_size: u32, stride: u32 };',
           'pub const TextureUnit = struct { unit: u32, uniform: [:0]const u8, texture_group: u32, texture_binding: u32, sampler_group: ?u32, sampler_binding: ?u32 };',
           'pub const Entry = struct { program: []const u8, name: [:0]const u8, stage: Stage, code: [:0]const u8, bindings: []const Binding, texture_units: []const TextureUnit, first_instance_uniform: ?[:0]const u8 };',
           'pub const Pipeline = struct { vertex: []const u8, fragment: []const u8 };',
           'pub const entries = [_]Entry{']
    def fields(values):
        return '.{ ' + ', '.join('.%s = %s' % (k, json.dumps(v)) for k, v in values.items()) + ' }'
    for record in records:
        # zig fmt spelling: `&.{}` empty, `&.{.{ ... }}` for one element, `&.{ a, b }` otherwise.
        def items(values):
            if not values:
                return '&.{}'
            if len(values) == 1:
                return '&.{' + values[0] + '}'
            return '&.{ ' + ', '.join(values) + ' }'
        bindings = items([fields(b) for b in record['bindings']])
        textures = items([fields(t) for t in record['texture_units']])
        zig.append('    .{ .program = %s, .name = %s, .stage = .%s, .code = @embedFile(%s), .bindings = %s, .texture_units = %s, .first_instance_uniform = %s },' %
                   (json.dumps(record['program']), json.dumps(record['name']), record['stage'], json.dumps(record['source']), bindings, textures, json.dumps(record['first_instance_uniform'])))
    zig.append('};')
    zig.append('pub const pipelines = [_]Pipeline{')
    for vertex, fragment in pairs:
        zig.append('    .{ .vertex = %s, .fragment = %s },' % (json.dumps(vertex), json.dumps(fragment)))
    zig.append('};')
    zig += ['comptime {', '    @setEvalBranchQuota(100000);', '    for (entries) |entry| {', '        if (entry.code.len == 0 or entry.name.len == 0) @compileError("empty OpenGL shader entry");', '        for (entry.texture_units, 0..) |unit, index| {', '            if (unit.unit != index or unit.uniform.len == 0) @compileError("invalid OpenGL texture unit mapping");', '        }', '    }', '}']
    (a.out / 'shaders.zig').write_text('\n'.join(zig) + '\n')
    (a.out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'compiled_entries': len(records), 'pipelines': len(pairs), 'excluded_entries': excluded}))

if __name__ == '__main__':
    main()
