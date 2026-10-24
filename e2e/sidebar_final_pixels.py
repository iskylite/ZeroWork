"""Assert captured production sidebar tint/shape from native pixels; no editing."""
import json,sys,pathlib
from PIL import Image
root=pathlib.Path(sys.argv[1]);theme=sys.argv[2]
palette={'dark':('5b5b64','22c55e','a1a1aa'),'light':('a1a1aa','16a34a','52525b'),'sauber':('8aa396','10b981','46604f')}
off,on,fg=map(lambda h:tuple(bytes.fromhex(h)),palette[theme]);checks=[]
def flat(n):return[n]+sum([flat(c) for c in n.get('children',[])],[])
def mask(im,r,c):
 scale=im.width/1440;box=tuple(round(t*scale) for t in[r['x'],r['y'],r['x']+r['w'],r['y']+r['h']]);return[max(abs(v[i]-c[i])for i in range(3))<8 for v in im.crop(box).get_flattened_data()]
for name in ['01-expanded-offline','02-collapsed-offline','03-expanded-connected','04-collapsed-connected','04b-collapsed-connected-hover','05-expanded-disconnected','06-collapsed-disconnected','06b-collapsed-disconnected-hover']:
 d=json.loads((root/(name+'.json')).read_text());im=Image.open(root/(name+'.png')).convert('RGB');expanded='expanded' in name;connected=name.startswith(('03','04'));icons=d['sidebar.host.icon'] if expanded else [d['sidebar.rail.host.1'][0],d['sidebar.rail.host.2'][0]]
 for i,n in enumerate(icons):
  r=n['rect'];r=r if expanded else {'x':r['x']+8,'y':r['y']+8,'w':16,'h':16};color=on if connected and i==0 else off;m=mask(im,r,color);assert sum(m)>8,(theme,name,i,'missing expected tint',color,sum(m));opposite=off if color==on else on;assert sum(mask(im,r,opposite))==0,(theme,name,i,'stale state tint');checks.append({'frame':name,'host':i+1,'tint':color,'solid_pixels':sum(m)})
 if name=='03-expanded-connected':
  tab=next(x for n in d['tabs.strip'] for x in flat(n) if x.get('test_id')=='tabs.type_icon');a=mask(im,tab['rect'],fg);b=mask(im,icons[0]['rect'],on);difference=sum(x!=y for x,y in zip(a,b));assert difference<=8,(theme,'tab/sidebar glyph mismatch',difference);checks.append({'tab_sidebar_terminal_shape_difference_pixels':difference,'solid_tab_pixels':sum(a),'solid_sidebar_pixels':sum(b)})


for p in sorted(root.glob('07-hot-theme-*.json')):
 name=p.stem;next_theme=name.rsplit('-',1)[1];d=json.loads(p.read_text());im=Image.open(p.with_suffix('.png')).convert('RGB');off_next,on_next,_=map(lambda h:tuple(bytes.fromhex(h)),palette[next_theme]);r=d['sidebar.rail.host.1'][0]['rect'];icon={'x':r['x']+8,'y':r['y']+8,'w':16,'h':16};assert sum(mask(im,icon,on_next))>8,(name,'stale online tint');bg=tuple(bytes.fromhex({'dark':'6164ec','light':'4f46e5','sauber':'1345f6'}[next_theme]));scale=im.width/1440;point=(round((r['x']+4)*scale),round((r['y']+16)*scale));actual=im.getpixel(point);assert max(abs(actual[i]-bg[i])for i in range(3))<=1,(name,'stale selected surface',actual,bg);checks.append({'frame':name,'same_host_selected_background':actual,'online_tint':on_next})
for name in ['04-collapsed-connected','06-collapsed-disconnected']:
 d=json.loads((root/(name+'.json')).read_text());im=Image.open(root/(name+'.png')).convert('RGB');r=d['sidebar.rail.host.1'][0]['rect'];bg=tuple(bytes.fromhex({'dark':'6164ec','light':'4f46e5','sauber':'1345f6'}[theme]));scale=im.width/1440;actual=im.getpixel((round((r['x']+4)*scale),round((r['y']+16)*scale)));assert max(abs(actual[i]-bg[i])for i in range(3))<=1,(name,'selected surface differs from prototype',actual,bg);checks.append({'frame':name,'selected_solid_background':actual})
for p in sorted(root.glob('08-hot-hover-*.json')):
 name=p.stem;next_theme=name.rsplit('-',1)[1];d=json.loads(p.read_text());im=Image.open(p.with_suffix('.png')).convert('RGB');_,on_next,_=map(lambda h:tuple(bytes.fromhex(h)),palette[next_theme]);r=d['sidebar.rail.host.1'][0]['rect'];icon={'x':r['x']+8,'y':r['y']+8,'w':16,'h':16};assert sum(mask(im,icon,on_next))>8,(name,'hover lost online tint');bg=tuple(bytes.fromhex({'dark':'202026','light':'ececf1','sauber':'dbf0d6'}[next_theme]));scale=im.width/1440;actual=im.getpixel((round((r['x']+4)*scale),round((r['y']+16)*scale)));assert max(abs(actual[i]-bg[i])for i in range(3))<=1,(name,'stale hover surface',actual,bg);checks.append({'frame':name,'current_theme_hover_background':actual,'online_tint':on_next})
(root/'pixels.json').write_text(json.dumps({'status':'passed','theme':theme,'checks':checks},indent=2)+'\n');print(json.dumps({'status':'passed','checks':len(checks),'theme':theme}))
