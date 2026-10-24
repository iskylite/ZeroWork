#!/usr/bin/env python3
"""Check real-time Sheet submitted frames, independently of host RPC latency.

The fixture is a right Sheet in the actual Storybook viewport. A
content-free row at half its height tests the moving panel edge and closed-state
residue. This is surface correctness, not compositor or frame-rate acceptance.
"""
import argparse
import json
import math
from pathlib import Path
import re
import zipfile
from windows_modal_frame_audit import bitmap
from windows_shared_modal_frame_audit import find, validate_viewport


def check_row(width, pixel, scale, expected_x, alpha, height, panel_width=320):
    logical_width = width / scale
    y = round(height / 2)
    lum = lambda x: sum(pixel(x, y)) / 3
    panel = sum(lum(x) for x in range(width - 16, width - 4)) / 12
    x0, x1 = round((logical_width-panel_width-120) * scale), round((logical_width-panel_width-65) * scale)
    background = sum(lum(x) for x in range(x0, x1)) / (x1 - x0)
    contrast = panel - background
    edge = None
    if contrast >= 2:
        threshold = (panel + background) / 2
        edge = next(((x + 1) / scale for x in range(width - 1, round((logical_width-panel_width-40) * scale), -1)
                     if lum(x) < threshold), None)
    if alpha == 0:
        residue = max(abs(lum(x) - background) for x in range(round((logical_width-panel_width-40) * scale), width - 2))
        passed = residue <= 2 and edge is None
    else:
        residue = None
        passed = edge is not None and abs(edge - expected_x) <= 2
    # Very low alpha may quantize to the background; record rather than infer
    # a missing edge there. Such frames never count as intermediate evidence.
    deferred = 0 < alpha < .1 and contrast < 2
    return dict(expected_x=expected_x, pixel_x=edge, alpha=alpha, contrast=contrast,
                closed_residue=residue, deferred=deferred, passed=passed or deferred)


def audit(folder):
    log = (folder / 'windows-e2e-stderr.log').read_text()
    finish = log.find('[test_harness] frame capture finished')
    if finish < 0 or '[windows-shared-capture]' in log[finish:] or '[windows-shared-capture-error]' in log:
        raise ValueError('capture not cleanly finished')
    expected = {tuple(map(int, m)) for m in re.findall(r'\[windows-shared-capture\] window=(\d+) index=(\d+) serial=(\d+)', log)}
    records, seen, committed, windows = [], set(), set(), {}
    with zipfile.ZipFile(folder / 'windows-presented-frames.zip') as archive:
        names = archive.namelist()
        if len(set(names)) != len(names):
            raise ValueError('duplicate archive artifacts')
        for name in names:
            if not re.fullmatch(r'shared-\d+-frame-\d+\.json', name):
                continue
            meta = json.loads(archive.read(name))
            key = (meta['window_id'], meta['index'], meta['frame_serial'])
            if key in seen or meta['backend'] not in ('d3d11', 'd3d12') or meta['animation_clock_step_ms'] is not None:
                raise ValueError('duplicate frame, wrong backend or controlled clock')
            seen.add(key)
            stem = name[:-5]
            if meta['image'] != stem + '.bmp' or meta['tree'] != stem + '.tree.json':
                raise ValueError('artifact identity mismatch')
            committed.update((name, meta['image'], meta['tree']))
            width, height, pixel = bitmap(archive.read(meta['image']))
            scale = meta['scale']
            if not math.isfinite(scale) or scale <= 0 or (width, height) != (meta['width'], meta['height']):
                raise ValueError('invalid drawable')
            windows.setdefault(meta['window_id'], []).append(meta)
            tree = json.loads(archive.read(meta['tree']))
            validate_viewport(meta, tree)
            viewport = tree['rect']
            if abs(viewport['w'] - width/scale) > 1/scale or abs(viewport['h'] - height/scale) > 1/scale:
                raise ValueError('layout viewport/drawable mismatch')
            node = find(tree, 'story.sheet.panel')
            if node is None:
                continue
            alpha = node.get('effective_opacity')
            if not isinstance(alpha, (int, float)) or not math.isfinite(alpha) or not 0 <= alpha <= 1:
                raise ValueError('invalid effective opacity')
            rect = node['rect']
            if alpha > 0 and (abs(rect['w'] - 320) > .1 or abs(rect['h'] - viewport['h']) > .1 or abs(rect['y']) > .1 or not viewport['w']-rect['w']-2 <= rect['x'] <= viewport['w']+2):
                raise ValueError('unexpected Sheet panel geometry')
            cursor = meta['cursor']
            if cursor['visible'] and abs(cursor['y'] - viewport['h']/2) <= 32 and cursor['x'] >= viewport['w']-rect['w']-152:
                raise ValueError('cursor obscures audit row')
            row = check_row(width, pixel, scale, rect['x'], alpha, height, rect['w'])
            records.append(dict(index=meta['index'], window=meta['window_id'], frame_time_ms=meta['frame_time_ms'], viewport_width=viewport['w'], panel_width=rect['w'], **row))
        if not seen or seen != expected or committed != set(names):
            raise ValueError('orphan, missing or unlogged frame artifacts')
        for frames in windows.values():
            frames.sort(key=lambda m: m['index'])
            if [m['index'] for m in frames] != list(range(len(frames))) or [m['frame_serial'] for m in frames] != list(range(1, len(frames) + 1)):
                raise ValueError('frame index/serial gap')
    if len({r['window'] for r in records}) != 1:
        raise ValueError('missing or ambiguous Sheet window')
    records.sort(key=lambda r: r['index'])
    prior_alpha, prior_x = 0, records[0]['viewport_width']
    starts = closes = entries = exits = settled = 0
    cycles = []
    for row in records:
        alpha, x = row['alpha'], row['expected_x']
        right = row['viewport_width']
        left = right-row['panel_width']
        if prior_alpha == 0 and alpha > 0:
            cycles.append(dict(entries=0, exits=0, settled=False, closed=False))
        starts += prior_alpha == 0 and alpha > 0
        closes += prior_alpha > 0 and alpha == 0
        is_settled = alpha >= .999 and abs(x - left) <= 1 and row['passed']
        settled += is_settled
        if cycles:
            cycles[-1]['settled'] |= is_settled
            cycles[-1]['closed'] |= prior_alpha > 0 and alpha == 0
        if row['passed'] and not row['deferred'] and left+8 < x < right-2 and alpha > 0:
            entering = x < prior_x
            exiting = x > prior_x and prior_alpha > 0
            entries += entering
            exits += exiting
            cycles[-1]['entries'] += entering
            cycles[-1]['exits'] += exiting
        prior_alpha, prior_x = alpha, x if alpha > 0 else right
    return dict(passed=starts == closes == 3 and all(c['entries'] and c['exits'] and c['settled'] and c['closed'] for c in cycles) and all(r['passed'] for r in records),
                capture_source='Direct3D retained submitted surface', animation_clock='real time',
                archive_frames=len(seen), checked_frames=len(records), starts=starts, closes=closes,
                entry_intermediates=entries, exit_intermediates=exits, settled_frames=settled, cycles=cycles, frames=records)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    folder = parser.parse_args().folder
    result = audit(folder)
    (folder / 'sheet-frame-audit.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'frames'}, indent=2))
    raise SystemExit(0 if result['passed'] else 1)
