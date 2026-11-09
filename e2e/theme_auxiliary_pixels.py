"""Measure actual native screenshot glyph cores, including small helper text.

Usage: python3 e2e/theme_auxiliary_pixels.py EVIDENCE_DIR [REPORT_JSON]
The screenshots and node bounds must originate from the same settled frame.
Real disabled actions are reported separately; explanatory/helper content never
receives a lower threshold merely because it uses a muted ink.
"""
import collections,json,pathlib,sys
from PIL import Image
from native_theme_data import load as load_native_theme_data
ROOT=pathlib.Path(__file__).resolve().parents[1]
BASE=pathlib.Path(sys.argv[1])
OUT=pathlib.Path(sys.argv[2]) if len(sys.argv)>2 else BASE/'pixel-report.json'
D=load_native_theme_data()['themes']
def rgb(s):return tuple(int(s[i:i+2],16) for i in (1,3,5))
def lum(c):return sum((v/255/12.92 if v/255<=.04045 else ((v/255+.055)/1.055)**2.4)*w for v,w in zip(c,(.2126,.7152,.0722)))
def contrast(a,b):x,y=sorted((lum(a),lum(b)));return(y+.05)/(x+.05)
def inside(r,c):return r['x']>=c['x']-.1 and r['y']>=c['y']-.1 and r['x']+r['w']<=c['x']+c['w']+.1 and r['y']+r['h']<=c['y']+c['h']+.1
CLIPS={'settings.viewport','terminal.commands.rows','ai.messages.scroll','ai.chat.scroll','ai.conversation.viewport','quick.results','quick.saved.list','files.rows','files.data_clip','connection.progress.body','connection.progress.logs'}
DISABLED_ACTIONS={'settings.save','settings.revert','settings.theme.remove.current','quick.submit','wizard.next.identity','local.close.accept','settings.ai.model.save','settings.keybinding.unbind','settings.keybinding.confirm','settings.notifications.test'}
report=[]
for theme,p in D.items():
 inks={rgb(p['--'+role]):role for role in ['fg-1','fg-2','fg-3','accent-ink','ok-ink','warn-ink','danger-ink']}
 item={'theme':theme,'states':[],'samples':[],'disabled_actions':[],'gradient_text':[],'failures':[],'unmeasured':[]}
 for file in sorted(BASE.rglob(theme+'-*.json')):
  if not file.with_suffix('.png').exists():continue
  state=str(file.relative_to(BASE).with_suffix(''))[len(theme)+1:]
  if any(file.stem.startswith(other+'-') for other in D if other.startswith(theme+'-')):continue
  raw=json.loads(file.read_text());roots=raw if isinstance(raw,list) else sum((v for v in raw.values() if isinstance(v,list)),[])
  img=Image.open(file.with_suffix('.png')).convert('RGB');scale=img.width/(1194 if 'files' in file.parts else 1440)
  seen=set()
  def walk(n,clip=None,visible=True,opacity=1,ancestors=()):
   visible=visible and not n.get('hidden',False) and n.get('visible',True);opacity=min(opacity*n.get('opacity',1),n.get('effective_opacity',1));r=n.get('rect');tid=n.get('test_id','');ancestors=ancestors+(tid,)
   if tid in CLIPS and r:clip=r
   if visible and n.get('tag')=='text' and n.get('text','').strip() and r and n.get('id') not in seen and r['w']>0 and r['h']>0 and(clip is None or inside(r,clip)):
    seen.add(n.get('id'));bounds=tuple(round(v*scale) for v in(r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
    if 0<=bounds[0]<bounds[2]<=img.width and 0<=bounds[1]<bounds[3]<=img.height:
     crop=img.crop(bounds);counts=collections.Counter(crop.getdata());edge=[crop.getpixel((x,y))for y in(0,crop.height-1)for x in range(crop.width)]+[crop.getpixel((x,y))for x in(0,crop.width-1)for y in range(crop.height)];bg=collections.Counter(edge).most_common(1)[0][0]
     filled=any(a in {'settings.save','ai.message.user.bubble','settings.keybinding.confirm','local.close.accept','quick.submit','connection.progress.retry','ai.empty.settings'}for a in ancestors)
     allowed_inks={**inks,**({(255,255,255):'white-action',(0,0,0):'black-action'}if filled else{})}
     matches=[(contrast(color,bg),count,color,allowed_inks.get(color,'rendered-ink'))for color,count in counts.most_common(64)if count>=3 and color!=bg and(filled or color not in {(255,255,255),(0,0,0)})]
     if matches:
      # A fully-covered core gives the maximum contrast within one text run;
      # antialias fringes are mixtures with the same background, never a new ink.
      cr,count,color,role=max(matches);sample={'state':state,'text':n['text'],'role':role,'pixels':count,'foreground':color,'background':bg,'contrast':round(cr,3),'rect':r,'opacity':opacity,'test_path':[a for a in ancestors if a]}
      if 'ai.message.user.bubble'in ancestors:item['gradient_text'].append({'state':state,'text':n['text'],'rect':r,'method':'per-glyph gradient rows in theme_action_pixels.py'})
      elif opacity<.999 and any(a in DISABLED_ACTIONS for a in ancestors):item['disabled_actions'].append(sample)
      else:
       candidates=[(contrast(ink,bg),counts[ink],ink,ink_role)for ink,ink_role in allowed_inks.items()if counts[ink]>=3 and ink!=bg]
       if not candidates:candidates=[(cr,count,color,role)]
       for ink_contrast,ink_count,ink,ink_role in candidates:
        actual={**sample,'contrast':round(ink_contrast,3),'foreground':ink,'pixels':ink_count,'role':ink_role}
        item['samples'].append(actual)
        if ink_contrast<4.5:item['failures'].append(actual)
     else:item['unmeasured'].append({'state':state,'text':n['text'],'rect':r})
   for child in n.get('children',[]):walk(child,clip,visible,opacity,ancestors)
  for node in roots:walk(node)
  item['states'].append(state)
 report.append(item)
OUT.write_text(json.dumps(report,ensure_ascii=False,indent=2))
if not any(item['samples']for item in report):sys.exit('No readable text samples found')
for item in report:
 print(item['theme'],len(item['states']),'states',len(item['samples']),'readable text runs',len(item['disabled_actions']),'disabled actions',len(item['failures']),'failures')
 for f in item['failures'][:12]:print(' ',f['state'],repr(f['text'][:40]),f['role'],f['contrast'],f['foreground'],f['background'])
print('Minimum measured readable contrast:',min((s['contrast'] for item in report for s in item['samples']),default=None))
if any(item['failures'] for item in report):sys.exit(1)
