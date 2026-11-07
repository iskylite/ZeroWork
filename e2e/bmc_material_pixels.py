"""Check native video bytes and video-local HUD composition, not just styles."""
import json
import pathlib
import sys
from PIL import Image

base = pathlib.Path(sys.argv[1])
report = json.loads((base / 'report.json').read_text())
checks = []
for capture in report['captures']:
    image = Image.open(base / (capture['name'] + '.png')).convert('RGB')
    scale = image.width / capture['width']
    for spec in capture['pixels']:
        node = capture['nodes'][spec['id']]
        r = node['bounds']
        if spec['kind'] == 'video':
            # Original mode extends the texture beyond the viewport. Sample
            # the upper left visible part, clear of both HUDs.
            x, y = r['x'] + 100, r['y'] + 100
            expected = spec['rgb']
        else:
            # Progress glass has real blur: keep the sample in its empty bottom
            # padding, away from video letterbox edges and text.
            x, y = (r['x'] + r['w'] / 2, r['y'] + r['h'] - 12) if spec['kind'] == 'progress' else (r['x'] + 3, r['y'] + r['h'] / 2)
            bg = node['background']
            alpha = bg['a'] / 255
            if spec['kind'] == 'progress':
                assert node['current_target'], 'KVM glass must sample the video composite'
                viewport = capture['nodes'][spec['underNode']]['background']
                under = spec.get('staleFrame') or [viewport[key] * viewport['a'] / 255 for key in 'rgb']
            else:
                under = spec['under']
            expected = [round(bg[key] * alpha + value * (1-alpha)) for key, value in zip('rgb', under)]
        actual = image.getpixel((round(x*scale), round(y*scale)))
        assert max(abs(a-b) for a,b in zip(actual,expected)) <= 4, (capture['name'],spec,actual,expected)
        checks.append({'capture':capture['name'],'kind':spec['kind'],'actual':actual,'expected':expected})
(base / 'pixel-report.json').write_text(json.dumps({'status':'passed','checks':checks},indent=2))
print('PASS:',len(checks),'native video/HUD pixel checks')
