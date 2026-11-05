"""Reject the formerly flat opaque AI shell in real Metal captures."""
import collections
import json
import pathlib
import sys
from PIL import Image, ImageChops, ImageStat

base = pathlib.Path(sys.argv[1])
report = json.loads((base / 'report.json').read_text())
checks = []
patches = {}
draft_ink = []
def find_draft(node):
    if node.get('text') == '分层回归草稿':
        return node
    return next((found for child in node.get('children', []) if (found := find_draft(child))), None)
for capture in report['captures']:
    if capture['id'] != 'ai.panel':
        continue
    image = Image.open(base / (capture['name'] + '.png')).convert('RGB')
    # Captures use either 1440×900 or 860×480 logical points, Retina scale.
    width = 860 if capture['name'].endswith('compact') else 1440
    scale = image.width / width
    r = capture['rect']
    box = tuple(round(v * scale) for v in (r['x']+30, r['y']+56, r['x']+r['w']-30, r['y']+106))
    patch = image.crop(box)
    colors = collections.Counter(patch.getdata())
    span = max(maximum-minimum for minimum, maximum in patch.getextrema())
    assert len(colors) >= 16 and span >= 8, (capture['name'], len(colors), span)
    patches[capture['name']] = patch
    checks.append({'capture':capture['name'], 'colors':len(colors), 'channel_span':span})
    if capture['name'] == 'dark-after-hidden-theme':
        tree = json.loads((base / (capture['name'] + '.json')).read_text())
        row = find_draft(tree)
        assert row, 'missing native draft row'
        r = row['rect']
        row_box = tuple(round(v * scale) for v in (r['x'], r['y'], r['x']+100, r['y']+r['h']))
        # This text-only crop must contain bright ink after Light -> Dark.
        bright = sum(min(rgb) >= 180 for rgb in image.crop(row_box).getdata())
        assert bright >= 50, ('stale Light draft ink in Dark theme', bright)
        draft_ink.append({'capture':capture['name'], 'bright_ink_pixels':bright})
# Same state after repeated reopening must not accumulate material veils.
a, b = (patches[name] for name in ['light-after-hidden-theme','light-reopened'])
assert a.size == b.size
mean = ImageStat.Stat(ImageChops.difference(a,b)).mean
assert max(mean) < 2, ('reopen paint drift', mean)
(base / 'pixel-report.json').write_text(json.dumps({'status':'passed','checks':checks,'draft_ink':draft_ink,'reopen_mean_delta':mean},indent=2))
print('PASS: wallpaper transmission, stable reopening, Dark draft ink')
