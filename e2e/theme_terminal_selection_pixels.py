"""Measure exact default-ink cores on the actual opaque native selection.

Usage: python3 e2e/theme_terminal_selection_pixels.py EVIDENCE_DIR
"""
import collections,json,pathlib,sys
from PIL import Image
base=pathlib.Path(sys.argv[1]);rows=[]
def rgb(value):return tuple(int(value[i:i+2],16) for i in (1,3,5))
def luminance(color):return sum((v/255/12.92 if v/255<=.04045 else ((v/255+.055)/1.055)**2.4)*w for v,w in zip(color,(.2126,.7152,.0722)))
def contrast(a,b):lo,hi=sorted((luminance(a),luminance(b)));return(hi+.05)/(lo+.05)
for file in sorted(base.glob('*-selected.json')):
 data=json.loads(file.read_text());image=Image.open(file.with_suffix('.png')).convert('RGB');scale=image.width/1280;r=data['selection_rect'];bounds=tuple(round(v*scale) for v in(r['x'],r['y'],r['x']+r['w'],r['y']+r['h']));crop=image.crop(bounds);counts=collections.Counter(crop.getdata());fg=rgb(data['foreground']);source=rgb(data['selection']);bg=counts.most_common(1)[0][0]
 alpha=int(data['selection'][7:9],16) if len(data['selection'])==9 else 255
 before=Image.open(base/(data['theme']+'-unselected.png')).convert('RGB').crop(bounds);underlay=collections.Counter(before.getdata()).most_common(1)[0][0]
 expected=tuple((v*alpha+u*(255-alpha)+127)//255 for v,u in zip(source,underlay))
 assert all(abs(a-b)<=1 for a,b in zip(bg,expected)),(data['theme'],'selection paint differs',bg,expected)
 assert counts[fg]>=30,(data['theme'],'default foreground has no measured opaque cores',counts[fg])
 ratio=contrast(fg,bg);rows.append({'theme':data['theme'],'foreground':fg,'background':bg,'source_selection':data['selection'],'selection_alpha':alpha,'unselected_background':underlay,'core_pixels':counts[fg],'background_pixels':counts[bg],'contrast':ratio,'rect':r,'status':'passed' if ratio>=4.5 else 'failed'})
assert rows,'No actual selected frames found'
report={'status':'passed' if all(x['status']=='passed' for x in rows) else 'failed','themes':len(rows),'minimum_contrast':min(x['contrast'] for x in rows),'cases':rows}
(base/'selection-pixel-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
for row in rows:print(row['theme'],row['status'],round(row['contrast'],5),row['core_pixels'],'exact default-ink pixels')
if report['status']!='passed':sys.exit(1)
