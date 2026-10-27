#!/usr/bin/env python3
"""Check actual native pixels of all indexed-color swatches (16..255).
The UI query supplies logical glyph bounds; no source/image data is changed.
"""
import argparse,json,re
from pathlib import Path
from PIL import Image
p=argparse.ArgumentParser();p.add_argument('screenshot');p.add_argument('rows');p.add_argument('--width',type=int,default=1440);a=p.parse_args()
im=Image.open(a.screenshot).convert('RGB');scale=im.width/a.width
found={}
rows=json.loads(Path(a.rows).read_text())
for row in rows:
 for glyph in row['glyphs']:
  value=glyph.get('text','')
  if not re.fullmatch(r'\s*\d{1,3} ',value):continue
  i=int(value.strip())
  if not 16<=i<=255:continue
  if i<232:
   v=i-16; levels=[0,95,135,175,215,255];expected=(levels[v//36],levels[v//6%6],levels[v%6])
  else:expected=(8+(i-232)*10,)*3
  r=glyph['rect'];x=round((r['x']+r['w']*.92)*scale);y=round((r['y']+r['h']*.45)*scale)
  actual=im.getpixel((x,y));assert max(abs(actual[c]-expected[c]) for c in range(3))<=2,(i,actual,expected,(x,y))
  found[i]=actual
assert len(found)==240,('missing swatches',sorted(set(range(16,256))-found.keys()))
hidden=next((row,glyph) for row in rows for glyph in row['glyphs'] if glyph.get('text')=='HIDDEN')
row,glyph=hidden;r=glyph['rect'];background=im.getpixel((round((row['rect']['x']+row['rect']['w']-10)*scale),round((r['y']+r['h']*.5)*scale)))
import math
for x in range(math.ceil(r['x']*scale)+1,math.floor((r['x']+r['w'])*scale)-1):
 for y in range(math.ceil(r['y']*scale)+1,math.floor((r['y']+r['h'])*scale)-1):
  assert max(abs(im.getpixel((x,y))[c]-background[c]) for c in range(3))<=1,('SGR8 hidden glyph painted ink',(x,y),background,im.getpixel((x,y)))
strike=next(glyph for row in rows for glyph in row['glyphs'] if glyph.get('text')=='STRIKE')
r=strike['rect'];xs=range(math.ceil(r['x']*scale)+1,math.floor((r['x']+r['w'])*scale)-1)
coverage=max(sum(min(im.getpixel((x,y)))>140 for x in xs)/len(xs) for y in range(math.floor((r['y']+r['h']*.4)*scale),math.ceil((r['y']+r['h']*.6)*scale)))
assert coverage>.95,('SGR9 missing continuous strikethrough',coverage)
print(json.dumps({'strikethrough_has_line':True,'status':'passed','indexed_swatches':len(found),'hidden_has_no_ink':True,'scale':scale}))
