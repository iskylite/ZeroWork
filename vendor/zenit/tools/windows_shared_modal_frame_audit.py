#!/usr/bin/env python3
"""Audit all archived D3D12 submitted frames of the three-cycle Modal fixture.
This is rendered-surface evidence, not desktop/compositor or pacing evidence.
"""
import json
import math
from pathlib import Path
import re
import zipfile
from windows_modal_frame_audit import bitmap

LINEAR = tuple(v / 3294.6 if v <= 10 else ((v / 255 + .055) / 1.055) ** 2.4 for v in range(256))

def srgb(v):
    v = max(0., min(1., v))
    return 255 * (12.92 * v if v <= .0031308 else 1.055 * v ** (1 / 2.4) - .055)

def fade(bg, ref, ref_bg, alpha):
    """A pixel of the Modal group at opacity `alpha`, from the settled open
    frame (`ref` over `ref_bg`) composited over today's backdrop `bg`.

    The shared renderer blends in encoded sRGB space and a group-opacity fade
    is a linear interpolation of encoded values, so the expectation is encoded
    too. Interpolating in linear light deviated by up to 5 levels in the
    darkest shadow band under the dialog's edge at alpha ~.7 (real Win10 at
    100% DPI; the 175% VM stayed inside the tolerance by chance), failing
    roughly every other run with 16-368 "stale" pixels in one frame."""
    return max(0., min(255., bg + (ref - ref_bg) * alpha))


def find(node, test_id):
    if not isinstance(node, dict):
        return None
    if node.get('test_id') == test_id:
        return node
    for child in node.get('children', []):
        found = find(child, test_id)
        if found is not None:
            return found
    return None

def validate_viewport(meta, tree):
    viewport = tree.get('rect')
    if not viewport or (round(viewport['w']*meta['scale']) != meta['width'] or
                        round(viewport['h']*meta['scale']) != meta['height']):
        raise ValueError('layout viewport/drawable mismatch')
    geometry = meta.get('frame_work_area')
    if geometry is None:
        raise ValueError('missing native frame/work area')
    if geometry is not None:
        if len(geometry) != 10 or not all(math.isfinite(v) for v in geometry):
            raise ValueError('invalid native frame/work area')
        x,y,w,h,_,_,wx,wy,ww,wh = geometry
        if min(w,h,ww,wh) <= 0 or x < wx or y < wy or x+w > wx+ww or y+h > wy+wh:
            raise ValueError('window frame outside monitor work area')


def audit(folder, desktop=False):
    log = (folder / 'windows-e2e-stderr.log').read_text()
    desktop_records = {}
    for m in re.finditer(r'\[windows-desktop-visible\] index=(\d+) rect=\(([^)]+)\).*frame_serial=(\d+)', log):
        index = int(m[1])
        if index in desktop_records:
            raise ValueError('duplicate desktop capture index')
        desktop_records[index] = (tuple(map(int, m[2].split(','))), int(m[3]))
    finish = log.find('[test_harness] frame capture finished')
    if finish >= 0 and '[windows-shared-capture]' in log[finish:]:
        raise ValueError('frame archive continued after finish acknowledgement')
    if '[windows-shared-capture-error]' in log:
        raise ValueError('native frame archive failed or exceeded its bound')
    expected = {tuple(map(int, m)) for m in re.findall(r'\[windows-shared-capture\] window=(\d+) index=(\d+) serial=(\d+)', log)}
    with zipfile.ZipFile(folder / 'windows-presented-frames.zip') as archive:
        names = archive.namelist()
        if len(set(names)) != len(names):
            raise ValueError('duplicate archive names')
        records, seen, windows = [], set(), {}
        committed = set()
        for name in names:
            if not re.fullmatch(r'shared-\d+-frame-\d+\.json', name):
                continue
            meta = json.loads(archive.read(name))
            if meta['backend'] not in ('d3d11', 'd3d12'):
                raise ValueError('unexpected frame backend')
            key = (meta['window_id'], meta['index'], meta['frame_serial'])
            if key in seen:
                raise ValueError('duplicate frame record')
            seen.add(key)
            stem = name[:-5]
            if meta['image'] != stem + '.bmp' or meta['tree'] != stem + '.tree.json':
                raise ValueError('frame artifact identity mismatch')
            committed.update((name, meta['image'], meta['tree']))
            if meta.get('desktop'):
                desktop_name = f"desktop-{meta['index']:04d}.bmp"
                committed.add(desktop_name)
                dw, dh, _ = bitmap(archive.read(desktop_name))
                entry = desktop_records.get(meta['index'])
                if (dw, dh) != (meta['width'], meta['height']) or entry is None or entry[1] != meta['frame_serial']:
                    raise ValueError('desktop dimensions or displayed serial mismatch')
            elif desktop:
                raise ValueError('desktop frame missing; submitted surfaces cannot satisfy the desktop gate')
            tree = json.loads(archive.read(meta['tree']))
            width, height, _ = bitmap(archive.read(meta['image']))
            if (width, height) != (meta['width'], meta['height']) or not math.isfinite(meta['scale']) or meta['scale'] <= 0:
                raise ValueError('invalid frame dimensions/scale')
            validate_viewport(meta, tree)
            windows.setdefault(meta['window_id'], []).append(meta)
            node = find(tree, 'story.modal.dialog')
            if node is not None:
                alpha = node.get('effective_opacity')
                if not isinstance(alpha, (int, float)) or not math.isfinite(alpha) or not 0 <= alpha <= 1:
                    raise ValueError('missing effective opacity on archived dialog')
                records.append((meta, node))
        if not seen or seen != expected or committed != set(names):
            raise ValueError('incomplete/orphan frame artifacts or log/metadata mismatch')
        for frames in windows.values():
            frames.sort(key=lambda m: m['index'])
            if [m['index'] for m in frames] != list(range(len(frames))):
                raise ValueError('frame index gap')
            if [m['frame_serial'] for m in frames] != list(range(1, len(frames) + 1)):
                raise ValueError('submitted frame serial gap')
        if len({m['window_id'] for m, _ in records}) != 1:
            raise ValueError('missing or ambiguous Modal window')
        records.sort(key=lambda r: r[0]['index'])
        settled = next((r for r in records if r[1]['effective_opacity'] >= .999), None)
        if settled is None or records[0][1]['effective_opacity'] != 0:
            raise ValueError('missing initial closed baseline or settled reference')
        sm, sn = settled
        scale = sm['scale']
        rw, rh, reference = bitmap(archive.read(sm['image']))
        _, _, baseline = bitmap(archive.read(records[0][0]['image']))
        rect = sn['rect']
        left, top, right, bottom = rect['x'], rect['y'], rect['x'] + rect['w'], rect['y'] + rect['h']
        bx = round((right+(rw/scale-right)/2)*scale)
        by = round((bottom+(rh/scale-bottom)/2)*scale)
        if not (0 <= bx < rw and 0 <= by < rh) or min(bx/scale-right, by/scale-bottom) < 64:
            raise ValueError('no clear backdrop sample outside dialog shadow')
        ref_bg = reference(bx, by)
        bounds = (max(0, math.ceil((left - 64) * scale)), max(0, math.ceil((top - 64) * scale)),
                  min(rw, math.floor((right + 64) * scale)), min(rh, math.floor((bottom + 64) * scale)))
        results = []
        prior = 0
        starts = closes = entering = exiting = 0
        for meta, node in records:
            width, height, pixel = bitmap(archive.read(meta['image']))
            if (width, height, meta['scale']) != (rw, rh, scale):
                raise ValueError('fixture drawable changed during frame audit')
            target_pixel = pixel
            visible = (0, 0, width, height)
            if desktop:
                _, _, pixel = bitmap(archive.read(f"desktop-{meta['index']:04d}.bmp"))
                visible = desktop_records[meta['index']][0]
                vx, vy, vw, vh = visible
                if not (vx <= bounds[0] and vy <= bounds[1] and vx + vw >= bounds[2] and vy + vh >= bounds[3]
                        and vx <= bx < vx + vw and vy <= by < vy + vh):
                    raise ValueError('desktop visible region does not cover the Modal audit')
            alpha = node['effective_opacity']
            if 0 < alpha < .999:
                entering += alpha > prior
                exiting += alpha < prior
            starts += prior == 0 and alpha > 0
            closes += prior > 0 and alpha == 0
            prior = alpha
            current = node['rect']
            # The fixture uses fade only. Fail rather than compare an unmodeled transform.
            if alpha > 0 and any(abs(current[k] - rect[k]) > .02 for k in ('x', 'y', 'w', 'h')):
                raise ValueError('Modal moved/scaled; this fixture audit requires stable geometry')
            bg = pixel(bx, by)
            if min(bg) < 90:
                raise ValueError('Modal backdrop became black')
            interior_error = 0.
            if alpha > 0:
                for y in range(round((bottom - 30) * scale), round((bottom - 20) * scale)):
                    for x in range(round((right - 120) * scale), round((right - 70) * scale)):
                        expected_pixel = [fade(b, r, rb, alpha) for b, r, rb in zip(bg, reference(x, y), ref_bg)]
                        interior_error = max(interior_error, max(abs(a - e) for a, e in zip(pixel(x, y), expected_pixel)))
            cursor = meta['cursor']
            stale = checked = desktop_mismatch = 0
            stale_box = None
            for y in range(bounds[1], bounds[3]):
                for x in range(bounds[0], bounds[2]):
                    if cursor['visible'] and abs(x / scale - cursor['x']) <= 32 and abs(y / scale - cursor['y']) <= 32:
                        continue
                    if desktop:
                        desktop_mismatch += max(abs(a - b) for a, b in zip(pixel(x, y), target_pixel(x, y))) > 3
                    if alpha > 0 and left - 2 <= x / scale <= right + 2 and top - 2 <= y / scale <= bottom + 2:
                        continue
                    checked += 1
                    expected_pixel = baseline(x, y) if alpha == 0 else [
                        fade(b, r, rb, alpha) for b, r, rb in zip(bg, reference(x, y), ref_bg)]
                    tolerance = 3 if alpha == 0 else 4
                    if max(abs(a - e) for a, e in zip(pixel(x, y), expected_pixel)) > tolerance:
                        stale += 1
                        stale_box = [x, y, x, y] if stale_box is None else [min(stale_box[0], x), min(stale_box[1], y), max(stale_box[2], x), max(stale_box[3], y)]
            results.append({'index': meta['index'], 'serial': meta['frame_serial'], 'effective_opacity': alpha,
                            'checked_exterior_or_closed_pixels': checked, 'stale_pixels': stale, 'stale_bbox': stale_box, 'desktop_target_mismatch_pixels': desktop_mismatch,
                            'max_interior_error': interior_error})
        passed = (starts >= 3 and closes >= 3 and entering >= 3 and exiting >= 3 and prior == 0
                  and all(r['stale_pixels'] <= 10 and r['max_interior_error'] <= 3 and r['desktop_target_mismatch_pixels'] <= 10 for r in results))
        report = {'passed': passed, 'capture_source': 'DXGI desktop duplication of Direct3D after DwmFlush with verified frame serial' if desktop else 'Direct3D retained submitted surface',
                  'archive_frames': len(seen), 'modal_frames': len(records), 'starts': starts, 'closes': closes,
                  'entry_intermediates': entering, 'exit_intermediates': exiting, 'complete_frame_archive': True,
                  'max_desktop_target_mismatch_pixels': max(r['desktop_target_mismatch_pixels'] for r in results),
                  'max_stale_pixels': max(r['stale_pixels'] for r in results),
                  'max_interior_error': max(r['max_interior_error'] for r in results),
                  'excluded_pointer': 'recorded virtual pointer position +/-32 logical pixels', 'frames': results}
        (folder / ('modal-desktop-audit.json' if desktop else 'modal-frame-audit.json')).write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({k: v for k, v in report.items() if k != 'frames'}))
        return passed
