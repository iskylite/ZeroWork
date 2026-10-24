#!/usr/bin/env python3
"""Check actual presented Storybook Modal frames, without requesting a redraw.

Run after windows_vm_http.py e2e --app storybook --capture-frames --trace-frames
--suite e2e/windows-storybook-render.test.ts --filter 'Windows Modal'.
The blank content region surrounding this fixture must contain no old dialog
pixels outside its current animated bounds. Diagnostic readback affects pacing.
"""
import argparse
import json
import math
from pathlib import Path
import re
import struct
import zipfile


def bitmap(data):
    offset = struct.unpack_from('<I', data, 10)[0]
    width, height = struct.unpack_from('<ii', data, 18)
    bits, compression = struct.unpack_from('<HI', data, 28)
    if bits != 32 or compression or width <= 0 or height >= 0:
        raise ValueError('expected top-down uncompressed 32-bit BMP')
    height = -height
    if len(data) < offset + width * height * 4:
        raise ValueError('truncated BMP')
    def pixel(x, y):
        if not 0 <= x < width or not 0 <= y < height:
            raise ValueError('sample outside image')
        i = offset + (y * width + x) * 4
        return tuple(data[i:i+3])
    return width, height, pixel


def modal_layers(line):
    # The automation cursor emits sibling 24px opacity groups after the modal.
    # Only the fixture's large barrier/dialog layers participate in its alpha.
    layers = [tuple(map(float, v.split(','))) for v in re.findall(r'layer=\(([^)]+)\)', line)]
    dialog = [v for v in layers if v[2] > 128 and v[3] > 128]
    cursor = [v[:4] for v in layers if 0 < v[2] <= 32 and 0 < v[3] <= 32]
    return ((*dialog[-1], math.prod(v[4] for v in dialog)) if dialog else None), cursor


def recover_panel(pixel, width, height, scale, layer, bg):
    # The settled layer center is inside the fixture's solid panel. Fixed
    # y=430 only worked for the old 879px viewport.
    center_x, center_y = layer[0]+layer[2]/2, layer[1]+layer[3]/2
    xs = [x for x in range(max(0, round(layer[0]*scale)), min(width, round((layer[0]+layer[2])*scale)))
          if min(pixel(x, round(center_y*scale))) > (bg+255)/2]
    ys = [y for y in range(max(0, round(layer[1]*scale)), min(height, round((layer[1]+layer[3])*scale)))
          if min(pixel(round(center_x*scale), y)) > (bg+255)/2]
    if not xs or not ys:
        raise ValueError('settled dialog absent from capture: desktop rendering/capture gate failed; do not count submitted-surface assertions as desktop verification')
    return min(xs)/scale, min(ys)/scale, (max(xs)+1)/scale, (max(ys)+1)/scale


def audit(folder, allow_shadow_halo=False, desktop=False):
    if '[windows-shared-capture]' in (folder / 'windows-e2e-stderr.log').read_text():
        from windows_shared_modal_frame_audit import audit as audit_shared
        return audit_shared(folder, desktop=desktop)
    records = []
    visible = {}
    sources = {}
    present_status = {}
    desktop_times = {}
    desktop_serials = {}
    render_serials = {}
    animated_presents = set()
    cursor_bounds = {}
    for line in (folder / 'windows-e2e-stderr.log').read_text().splitlines():
        presented = re.search(r'\[windows-present\] frame=(\d+).*?opacity=([\d.]+)', line)
        if presented and float(presented[2]) < .999:
            animated_presents.add(int(presented[1]))
        status = re.search(r'\[windows-capture-present\] index=(\d+) hr=0x([0-9a-fA-F]+)', line)
        if status:
            present_status[int(status[1])] = int(status[2], 16)
        v = re.search(r'\[windows-desktop-visible\] index=(\d+) rect=\(([^)]+)\)', line)
        if v:
            visible[int(v[1])] = tuple(map(float, v[2].split(',')))
            sources[int(v[1])] = 'dxgi-duplication' if 'source=dxgi-duplication' in line else 'gdi'
            times = re.search(r'present_time=(\d+) present_not_before=(\d+)', line)
            if times:
                desktop_times[int(v[1])] = tuple(map(int, times.groups()))
            serial = re.search(r'frame_serial=(\d+)', line)
            if serial:
                desktop_serials[int(v[1])] = int(serial[1])
        m = re.search(r'\[windows-capture\] index=(\d+) scale=([\d.]+)', line)
        if m:
            serial = re.search(r'frame_serial=(\d+)', line)
            if serial:
                render_serials[int(m[1])] = int(serial[1])
            current, cursor_bounds[int(m[1])] = modal_layers(line)
            records.append((int(m[1]), float(m[2]), current))
    if not records:
        raise ValueError('no actual presented frame records')
    with zipfile.ZipFile(folder / 'windows-presented-frames.zip') as archive:
        names = {Path(n).name: n for n in archive.namelist()}
        if desktop:
            for index, scale, _ in records:
                if index == 0:
                    continue  # Initial frame precedes fixture navigation.
                if present_status.get(index) != 0:
                    raise ValueError(f'frame {index} was not accepted for normal Present (hr={present_status.get(index)}); desktop gate unverified')
                if index not in visible:
                    raise ValueError(f'no visible desktop bounds for frame {index}; desktop gate untested')
                if sources[index] != 'dxgi-duplication':
                    raise ValueError(f'frame {index} is GDI-only; GPU desktop gate unverified')
                times = desktop_times.get(index)
                if not times or times[0] < times[1] or times[1] <= 0:
                    raise ValueError(f'frame {index} has no desktop update after its Present began; desktop gate unverified')
                if not render_serials.get(index) or desktop_serials.get(index) != render_serials[index]:
                    raise ValueError(f'frame {index} has no matching visible presentation serial; desktop gate unverified')
                x, y, w, h = visible[index]
                # Includes all panel/shadow samples and the backdrop sample.
                dw, dh, _ = bitmap(archive.read(names[f'frame-{index:04d}.bmp']))
                if x > 0 or y > 0 or x+w < dw or y+h < dh:
                    raise ValueError(f'Modal audit samples outside visible desktop in frame {index}')
            missing = [r[0] for r in records if r[0] != 0 and f'desktop-{r[0]:04d}.bmp' not in names]
            if missing:
                raise ValueError(f'desktop capture unavailable for frames {missing}; see windows-desktop-unavailable log; this gate is untested')
        def read(index):
            return bitmap(archive.read(names[f'{"desktop" if desktop else "frame"}-{index:04d}.bmp']))
        if desktop:
            for index, _, _ in records:
                if index == 0:
                    continue
                for prefix in ('desktop', 'frame'):
                    marker = bitmap(archive.read(names[f'{prefix}-{index:04d}.bmp']))[2]
                    b,g,r = marker(2,2)
                    if r+(g<<8)+(b<<16) != render_serials[index] or marker(6,2) != (107,199,53):
                        raise ValueError(f'{prefix} frame {index} has an invalid pixel presentation serial')
        settled = next((r for r in records if r[2] and r[2][4] >= .9999), None)
        if not settled:
            raise ValueError('capture did not include settled dialog')
        _, scale, layer = settled
        reference_width, reference_height, reference_pixel = read(settled[0])
        pixel = reference_pixel
        reference_scale = scale
        bx = round((layer[0]+layer[2]+reference_width/scale)/2*scale)
        by = round((layer[1]+layer[3]+reference_height/scale)/2*scale)
        reference_bg = pixel(bx, by)
        bg = reference_bg[0]
        # Recover the fixture's actual solid panel rectangle from settled ink;
        # its layer bounds include shadow padding, so they are much larger.
        base = recover_panel(pixel, reference_width, reference_height, scale, layer, bg)
        results = []
        entering = exiting = closed = 0
        previous = None
        for index, scale, current in records:
            # First frame precedes navigation to the Modal fixture.
            if index == 0:
                continue
            _, _, pixel = read(index)
            target_pixel = bitmap(archive.read(names[f'frame-{index:04d}.bmp']))[2] if desktop else None
            bg = pixel(bx, by)
            if current:
                factor = current[2] / layer[2]
                cx, cy = (base[0]+base[2])/2, (base[1]+base[3])/2
                bounds = (cx+(base[0]-cx)*factor, cy+(base[1]-cy)*factor,
                          cx+(base[2]-cx)*factor, cy+(base[3]-cy)*factor)
                if previous is not None:
                    entering += current[4] > previous + .001
                    exiting += current[4] < previous - .001
                previous = current[4]
            else:
                bounds = None
                previous = None
                closed += 1
            stale = 0
            desktop_target_mismatch = 0
            interior_error = 0
            interior_samples = 0
            if current:
                # This fixture's lower-right body patch is solid background,
                # without text, buttons, rounded edges or shadow. Validate it
                # against the settled reference at the current nested opacity:
                # excluding the whole panel would miss old alpha accumulating
                # inside its still-visible bounds during entry/exit.
                for ry in range(round((base[3]-30)*reference_scale), round((base[3]-20)*reference_scale)):
                    for rx in range(round((base[2]-120)*reference_scale), round((base[2]-70)*reference_scale)):
                        x = round((cx+(rx/reference_scale-cx)*factor)*scale)
                        y = round((cy+(ry/reference_scale-cy)*factor)*scale)
                        expected = tuple(b + (s-rb)*current[5]/layer[5]
                                         for b,s,rb in zip(bg,reference_pixel(rx,ry),reference_bg))
                        interior_error = max(interior_error,
                            max(abs(a-e) for a,e in zip(pixel(x,y),expected)))
                        interior_samples += 1
            pointer_boxes = [(math.floor((cx-2)*scale), math.floor((cy-2)*scale),
                              math.ceil((cx+cw+2)*scale), math.ceil((cy+ch+2)*scale))
                             for cx,cy,cw,ch in cursor_bounds.get(index, [])]
            for y in range(max(0, math.ceil((base[1]-24)*scale)), min(reference_height, math.floor((base[3]+24)*scale))):
                pointer_spans = [(left,right) for left,top,right,bottom in pointer_boxes if top <= y <= bottom]
                for x in range(max(0, math.ceil((base[0]-30)*scale)), min(reference_width, math.floor((base[2]+30)*scale))):
                    # The shared harness paints its virtual mouse on top of
                    # the scene. Use its recorded bounds, since the cursor
                    # changes shape and location during this fixture.
                    if pointer_spans and any(left <= x <= right for left,right in pointer_spans):
                        continue
                    actual = pixel(x,y)
                    if target_pixel and max(abs(a-b) for a,b in zip(actual,target_pixel(x,y))) > 3:
                        desktop_target_mismatch += 1
                    if bounds and bounds[0]-2 <= x/scale <= bounds[2]+2 and bounds[1]-2 <= y/scale <= bounds[3]+2:
                        continue
                    # Transform the settled shadow into the current frame and
                    # composite its attenuation at current dialog opacity over
                    # the current backdrop. Dark trails must also fail: simply
                    # permitting every dark pixel hides stale shadow surfaces.
                    if bounds and allow_shadow_halo:
                        rx = round((cx + (x/scale-cx)/factor)*reference_scale)
                        ry = round((cy + (y/scale-cy)/factor)*reference_scale)
                        sample = reference_pixel(rx, ry) if 0 <= rx < reference_width and 0 <= ry < reference_height else reference_bg
                        expected = tuple(b*(1-current[5]/layer[5]*(1-s/max(1, rb)))
                                         for b,s,rb in zip(bg,sample,reference_bg))
                        # Allow raster resampling and 8-bit layer rounding.
                        differs = max(abs(a-e) for a,e in zip(actual,expected)) > 8
                    else:
                        differs = max(abs(a-b) for a,b in zip(actual,bg)) > 4
                    if differs:
                        stale += 1
            results.append({'frame': index, 'opacity': current[4] if current else 0, 'stale_pixels': stale,
                            'desktop_target_mismatch_pixels': desktop_target_mismatch,
                            'interior_samples': interior_samples,
                            'max_interior_channel_error': interior_error})
        report = {'passed': entering >= 3 and exiting >= 3 and closed >= 1 and all(r['stale_pixels'] <= 10 and r['desktop_target_mismatch_pixels'] <= 10 and r['max_interior_channel_error'] <= 3 for r in results),
                  'capture_source': 'DXGI desktop duplication after DwmFlush' if desktop else 'render target before Present', 'frames_checked': len(results), 'enter_steps': entering, 'exit_steps': exiting, 'closed_frames': closed,
                  'max_stale_pixels': max(r['stale_pixels'] for r in results),
                  'max_desktop_target_mismatch_pixels': max(r['desktop_target_mismatch_pixels'] for r in results),
                  'max_interior_channel_error': max(r['max_interior_channel_error'] for r in results),
                  'interior_samples': sum(r['interior_samples'] for r in results),
                  'compare_transformed_shadow': allow_shadow_halo, 'panel_bounds': base, 'excluded_virtual_pointer': 'per-frame recorded cursor icon bounds plus 2px', 'frames': results}
        missed = sorted(animated_presents - set(render_serials.values()))
        report.update(animated_presents=len(animated_presents), missed_animated_present_serials=missed,
                      all_animated_presents_captured=not missed if animated_presents else None)
        report['passed'] = report['passed'] and not missed
        (folder / ('modal-desktop-audit.json' if desktop else 'modal-frame-audit.json')).write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps({k:v for k,v in report.items() if k != 'frames'}))
        return report['passed']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('job_dir', type=Path)
    parser.add_argument('--allow-shadow-halo', action='store_true', help='Compare live shadow to transformed settled reference; closed frames compare all channels')
    parser.add_argument("--desktop", action="store_true", help="Audit post-DwmFlush visible client pixels; fails if desktop captures are missing")
    args = parser.parse_args()
    try:
        passed = audit(args.job_dir, args.allow_shadow_halo, args.desktop)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        report = {'passed': False, 'capture_source': 'desktop' if args.desktop else 'render target', 'error': str(error)}
        (args.job_dir / ('modal-desktop-audit.json' if args.desktop else 'modal-frame-audit.json')).write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report))
        passed = False
    raise SystemExit(0 if passed else 1)
