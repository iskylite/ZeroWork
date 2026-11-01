"""Check terminal default and highlighted prompt ink over native wallpaper captures."""
import collections,json,pathlib,sys
from PIL import Image
ROOT=pathlib.Path(__file__).resolve().parents[1];BASE=pathlib.Path(sys.argv[1]);OUT=pathlib.Path(sys.argv[2])if len(sys.argv)>2 else BASE/'terminal-default-report.json';D=json.loads((ROOT/'docs/UI_V3/theme-presets.json').read_text())['terminalPalettes']
def rgb(s):return tuple(int(s[i:i+2],16)for i in(1,3,5))
def lum(c):return sum((v/255/12.92 if v/255<=.04045 else((v/255+.055)/1.055)**2.4)*w for v,w in zip(c,(.2126,.7152,.0722)))
def cr(a,b):x,y=sorted((lum(a),lum(b)));return(y+.05)/(x+.05)
def walk(n):
 yield n
 for c in n.get('children',[]):yield from walk(c)
report=[]
for theme,palette in D.items():
 item={'theme':theme,'samples':[]}
 for f in sorted(BASE.glob(theme+'-*-chrome.json')):
  if any(f.stem.startswith(other+'-')for other in D if other.startswith(theme+'-')):continue
  raw=json.loads(f.read_text());roots=sum((v for v in raw.values()if isinstance(v,list)),[]);nodes={n.get('id'):n for r in roots for n in walk(r)if n.get('text','').strip()in('DEFAULT_BOUNDARY','wallpaper%')and n.get('rect',{}).get('w',0)>0}
  im=Image.open(f.with_suffix('.png')).convert('RGB');scale=im.width/1440
  for n in nodes.values():
   r=n['rect'];box=tuple(round(v*scale)for v in(r['x'],r['y'],r['x']+r['w'],r['y']+r['h']));crop=im.crop(box);counts=collections.Counter(crop.getdata());edge=[crop.getpixel((x,y))for y in(0,crop.height-1)for x in range(crop.width)];bg=collections.Counter(edge).most_common(1)[0][0];ink=rgb(palette['foreground']);value=cr(ink,bg);item['samples'].append({'state':f.stem[len(theme)+1:],'kind':'highlighted-prompt'if n.get('text','').strip()=='wallpaper%'else'default-output','foreground':ink,'core_pixels':counts[ink],'background':bg,'contrast':round(value,5),'pass':counts[ink]>=3 and value>=4.5,'rect':r})
 report.append(item)
OUT.write_text(json.dumps(report,indent=2))
if not any(item['samples']for item in report):sys.exit('No terminal default or highlighted prompt samples found')
for item in report:
 if item['samples']:print(item['theme'],[(s['state'],s['contrast'],s['core_pixels'],s['pass'])for s in item['samples']])
if any(not s['pass']for i in report for s in i['samples']):sys.exit(1)
