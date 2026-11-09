"""Check native video bytes and video-local HUD composition, not just styles."""
import json
import pathlib
import sys
from PIL import Image

def contrast(a, b):
    def luminance(rgb):
        def linear(value):
            value /= 255
            return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4
        return sum(weight * linear(value) for weight, value in zip((0.2126, 0.7152, 0.0722), rgb))
    x, y = sorted((luminance(a), luminance(b)))
    return (y + 0.05) / (x + 0.05)

base = pathlib.Path(sys.argv[1])
report = json.loads((base / 'report.json').read_text())
checks = []
for capture in report['captures']:
    image = Image.open(base / (capture['name'] + '.png')).convert('RGB')
    scale = image.width / capture['width']
    for spec in capture['pixels']:
        node = capture['nodes'][spec['id']]
        r = node['bounds']
        if spec['kind'] == 'popup':
            # Empty left padding halfway down the popup, over the Metal video.
            x, y = r['x'] + 8, r['y'] + r['h'] / 2
            actual = image.getpixel((round(x * scale), round(y * scale)))
            for role in ('foreground', 'foreground_secondary'):
                ink = node[role]
                ratio = contrast([ink[key] for key in 'rgb'], actual)
                assert ratio >= 4.5, (capture['name'], role, ratio, ink, actual)
            checks.append({'capture':capture['name'],'kind':'popup','actual':actual})
            continue
        if spec['kind'] == 'video':
            # Original mode extends the texture beyond the viewport. Sample
            # the upper left visible part, clear of both HUDs.
            x, y = r['x'] + 100, r['y'] + 100
            expected = spec['rgb']
        else:
            # Sample the empty bottom padding away from text and controls.
            x, y = (r['x'] + r['w'] / 2, r['y'] + r['h'] - 12) if spec['kind'] == 'progress' else (r['x'] + 3, r['y'] + r['h'] / 2)
            bg = node['background']
            alpha = bg['a'] / 255
            if spec['kind'] == 'progress':
                assert bg['a'] == 255 and not node['current_target'], 'KVM progress must use an opaque local surface'
                viewport = capture['nodes'][spec['underNode']]['background']
                assert viewport == {'r': 0, 'g': 0, 'b': 0, 'a': 255}, viewport
                under = spec.get('staleFrame') or [0, 0, 0]
                bounds = capture['nodes'][spec['underNode']]['bounds']
                if spec.get('staleFrame') is None:
                    waiting_pixel = image.getpixel((round((bounds['x'] + 16) * scale), round((bounds['y'] + 16) * scale)))
                    assert max(waiting_pixel) <= 4, (capture['name'], 'waiting viewport', waiting_pixel)
                card_pixel = image.getpixel((round((r['x'] + r['w'] / 2) * scale), round((r['y'] + 10) * scale)))
                route = capture['nodes']['bmc.progress.route']
                route_bounds = route['bounds']
                route_pixel = image.getpixel((round((route_bounds['x'] + route_bounds['w'] / 2) * scale), round((route_bounds['y'] + 3) * scale)))
                for text_node, background in ((capture['nodes']['bmc.progress.stage'], card_pixel), (route, route_pixel), (capture['nodes']['bmc.progress.status'], route_pixel)):
                    ink = text_node['ink']
                    ratio = contrast([ink[key] for key in 'rgb'], background)
                    assert ratio >= 4.5, (capture['name'], 'progress contrast', ratio, ink, background)
            else:
                under = spec['under']
            expected = [round(bg[key] * alpha + value * (1-alpha)) for key, value in zip('rgb', under)]
        actual = image.getpixel((round(x*scale), round(y*scale)))
        assert max(abs(a-b) for a,b in zip(actual,expected)) <= 4, (capture['name'],spec,actual,expected)
        checks.append({'capture':capture['name'],'kind':spec['kind'],'actual':actual,'expected':expected})
(base / 'pixel-report.json').write_text(json.dumps({'status':'passed','checks':checks},indent=2))
print('PASS:',len(checks),'native video/HUD pixel checks')
