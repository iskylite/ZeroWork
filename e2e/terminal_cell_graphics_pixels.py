"""Measure uninterrupted ink across eight actual terminal rows, not node bounds."""
import json, math, sys
from PIL import Image
m=json.load(open(sys.argv[1])); im=Image.open(m['screenshot']).convert('RGB')
# Harness returns window logical geometry; native capture is the 1440x900 surface.
sx,sy=im.width/1440,im.height/900
results=[]
for index,char in enumerate(['▌','█','│','┃','║','▐']):
    ps=[p['rect'] for p in m['probes'] if p['text']==char]
    x0=min(p['x'] for p in ps);x1=max(p['x']+p['w'] for p in ps)
    y0=min(p['y'] for p in ps);y1=max(p['y']+p['h'] for p in ps)
    empty=[]
    for y in range(math.ceil(y0*sy)+1,math.floor(y1*sy)-1):
        # Neutral strokes and gold block both differ strongly from the dark background.
        if not any(max(im.getpixel((x,y)))>110 for x in range(math.ceil(x0*sx),math.floor(x1*sx))):empty.append(y)
    results.append({'character':char,'empty_pixel_rows':len(empty),'sample_pixel_rows':math.floor(y1*sy)-math.ceil(y0*sy)-2})
if m['baseline']:
    assert results[0]['empty_pixel_rows']>0 and results[1]['empty_pixel_rows']>0,results
else:
    assert all(r['empty_pixel_rows']==0 for r in results),results
# Horizontal strokes must have ink in every physical pixel column across all 40 cells.
horizontal=[]
for label in ['HORIZONTAL ','HEAVY      ','DOUBLE     ']:
    row=next(r for r in m['rows'] if ''.join(n.get('text','') for n in r.get('children',[])).startswith(label))
    cells=[n['rect'] for n in row['children'] if n.get('text') in ['─','━','═'] and not n.get('hidden')]
    assert len(cells)==40
    x0=min(r['x'] for r in cells);x1=max(r['x']+r['w'] for r in cells)
    y0=min(r['y'] for r in cells);y1=max(r['y']+r['h'] for r in cells)
    gaps=sum(not any(max(im.getpixel((x,y)))>110 for y in range(math.ceil(y0*sy),math.floor(y1*sy))) for x in range(math.ceil(x0*sx)+1,math.floor(x1*sx)-1))
    horizontal.append({'label':label.strip(),'empty_pixel_columns':gaps})
if not m['baseline']: assert all(r['empty_pixel_columns']==0 for r in horizontal),horizontal
print(json.dumps({'vertical':results,'horizontal':horizontal,'pixel_size':im.size}))
