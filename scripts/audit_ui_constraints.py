#!/usr/bin/env python3
"""Inventory production UI dimensions and interaction sites; no heuristic pass claim.

Run from the repository root. JSON retains every source location for review.
Comments and quoted text are masked before looking for declarations; mockups,
fixtures, preview runners and tests are excluded. Parameterized/dynamic dimensions
remain expressions, since source text cannot determine rendered sizes.
"""
import argparse
import collections
import json
from pathlib import Path
import re


def mask(source):
    return re.sub(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\])*"',
                  lambda m: ''.join('\n' if c == '\n' else ' ' for c in m[0]), source)


def balanced(source, start, opening='(', closing=')'):
    depth = 0
    for i in range(start, len(source)):
        if source[i] == opening:
            depth += 1
        elif source[i] == closing:
            depth -= 1
            if depth == 0:
                return i + 1
    raise ValueError(f'unbalanced expression at {start}')


def inventory(root):
    result = {'scope': 'production src; excludes tests/mockups/fixture/preview runners',
              'dimensions': [], 'buttons': [], 'custom_interactions': []}
    for path in sorted((root / 'src').rglob('*.zig')):
        rel = path.relative_to(root)
        if any(x in str(rel) for x in ('_tests.zig', '/mockups/', '/fixture_probe/', '_preview_runner.zig')):
            continue
        raw = path.read_text()
        clean = mask(raw)
        for block in reversed(list(re.finditer(r'\btest\s*\{', clean))):
            start = clean.index('{', block.start())
            end = balanced(clean, start, '{', '}')
            clean = clean[:block.start()] + ''.join('\n' if c == '\n' else ' ' for c in clean[block.start():end]) + clean[end:]
        functions = list(re.finditer(r'\bfn\s+(\w+)\s*\(', clean))
        def loc(at):
            owner = next((f[1] for f in reversed(functions) if f.start() < at), None)
            return {'file': str(rel), 'line': raw.count('\n', 0, at) + 1, 'function': owner}
        for m in re.finditer(r'\.(width|height|min_width|max_width|min_height|max_height)\s*=\s*', clean):
            start = m.end()
            if clean[start:start+2] == '.{':
                end = balanced(clean, start+1, '{', '}')
            else:
                end = start
                depth = 0
                while end < len(clean):
                    c = clean[end]
                    if depth == 0 and c in ',;\n':
                        break
                    if c in '({[': depth += 1
                    if c in ')}]':
                        if depth == 0: break
                        depth -= 1
                    end += 1
            expression = raw[start:end].strip()
            kind = ('fixed_or_parameterized' if re.search(r'\.px\s*=', expression)
                    else 'content' if '.fit' in expression
                    else 'available' if '.fill' in expression or '.grow' in expression
                    else 'bound' if m[1].startswith(('min_', 'max_'))
                    else 'expression')
            result['dimensions'].append({**loc(m.start()), 'axis': m[1], 'value': expression, 'kind': kind})
        for m in re.finditer(r'\bui\.widgets\.Button\s*\(', clean):
            end = balanced(clean, clean.index('(', m.start()))
            body, props = raw[m.start():end], clean[m.start():end]
            result['buttons'].append({**loc(m.start()), 'inline_click': '.on_click' in props,
                                      'event_handler': '.on_event' in props,
                                      'explicit_disabled': bool(re.search(r'\.disabled\s*=\s*true\b', props)),
                                      'source': body})
        for m in re.finditer(r'\bui\.clickable\s*\(|\.behavior\.events\.(?:on_click|on_event|on_mouse_down)\s*=', clean):
            line = raw.splitlines()[raw.count('\n', 0, m.start())]
            result['custom_interactions'].append({**loc(m.start()), 'source': line.strip()})
    result['counts'] = {k: len(result[k]) for k in ('buttons','dimensions','custom_interactions')}
    result['counts']['dimension_kinds'] = dict(collections.Counter(x['kind'] for x in result['dimensions']))
    result['counts']['dimension_files'] = len({x['file'] for x in result['dimensions']})
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    result = inventory(Path(__file__).resolve().parents[1])
    Path(args.out).write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result['counts'], ensure_ascii=False))
