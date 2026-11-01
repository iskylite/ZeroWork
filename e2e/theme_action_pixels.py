"""Check filled action and translucent bubble ink against native gradient pixels."""
import collections,json,pathlib,sys
from PIL import Image
BASE=pathlib.Path(sys.argv[1]);OUT=pathlib.Path(sys.argv[2])if len(sys.argv)>2 else BASE/'action-pixel-report.json'
D=json.loads((pathlib.Path(__file__).resolve().parents[1]/'docs/UI_V3/theme-presets.json').read_text())['themes']
def lum(c):return sum((v/255/12.92 if v/255<=.04045 else ((v/255+.055)/1.055)**2.4)*w for v,w in zip(c,(.2126,.7152,.0722)))
def cr(a,b):x,y=sorted((lum(a),lum(b)));return(y+.05)/(x+.05)
def walk(n):
 yield n
 for child in n.get('children',[]):yield from walk(child)
report=[]
for theme in D:
 row={'theme':theme,'states':[]}
 for state in ['save-enabled','save-hover','save-pressed','t0-ai','t50-ai','t100-ai']:
  f=BASE/f'{theme}-{state}.json'
  if not f.exists() or not f.with_suffix('.png').exists():continue
  raw=json.loads(f.read_text());roots=raw if isinstance(raw,list)else sum((v for v in raw.values()if isinstance(v,list)),[]);tid='settings.save'if state.startswith('save')else'ai.message.user.bubble'
  action=next((node for root in roots for node in walk(root)if node.get('test_id')==tid),None)
  if action is None:continue
  nodes=[n for n in walk(action)if n.get('tag')=='text'and n.get('text','').strip()]
  if not nodes:continue
  img=Image.open(f.with_suffix('.png')).convert('RGB');scale=img.width/1440;br=action['rect'];counts=collections.Counter();points=[]
  for node in nodes:
   r=node['rect'];b=tuple(round(v*scale)for v in(r['x'],r['y'],r['x']+r['w'],r['y']+r['h']));crop=img.crop(b);counts.update(crop.getdata());points.append((b,crop))
  ink=max([(255,255,255),(0,0,0)],key=lambda color:counts[color]);xs=set()
  for b,crop in points:
   for x in range(crop.width):
    if any(crop.getpixel((x,y))==ink for y in range(crop.height)):xs.add(b[0]+x)
  # Sample actual paint above and below the text, at each occupied glyph x.
  # Both rows are inside the rounded fill and outside the text's AA fringe.
  clip=next((n['rect']for root in roots for n in walk(root)if n.get('test_id')=='ai.conversation.viewport'),None)if not state.startswith('save')else None
  top=max(br['y']+4,clip['y']+.5)if clip else br['y']+4
  bottom=min(br['y']+br['h']-4,clip['y']+clip['h']-.5)if clip else br['y']+br['h']-4
  ys=[round(top*scale),round(bottom*scale)]
  values=[cr(ink,img.getpixel((x,y)))for x in xs for y in ys]
  item={'state':state,'foreground':ink,'core_pixels':counts[ink],'reference_rgb':img.getpixel((round((br['x']+br['w']/2)*scale),round((br['y']+4)*scale))),'minimum_contrast':round(min(values),3)if values else 0,'pass':bool(values)and min(values)>=4.5};row['states'].append(item)
 save=[s for s in row['states']if s['state'].startswith('save-')]
 if len(save)==3:
  row['save_feedback_distinct']=len({tuple(s['reference_rgb'])for s in save})==3
  if not row['save_feedback_distinct']:
   for state in save:state['pass']=False
 report.append(row)
OUT.write_text(json.dumps(report,indent=2))
if not any(row['states']for row in report):sys.exit('No filled action or bubble text samples found')
for row in report:
 if row['states']:print(row['theme'],[(s['state'],s['minimum_contrast'],s['pass'])for s in row['states']])
if any(not s['pass']for r in report for s in r['states']):sys.exit(1)
