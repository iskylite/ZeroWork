"""Measure reviewed SVG in Chrome and check layout/function-preservation boundaries."""
from pathlib import Path
import subprocess,tempfile,re,json,html,xml.etree.ElementTree as ET
REPO=Path(__file__).resolve().parents[2]
BASE=REPO/"docs/UI_V4"
CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
JS='''document.fonts.ready.then(()=>{
 const rect=e=>{if(!e)return null;const b=e.getBoundingClientRect();return {x:b.x,y:b.y,w:b.width,h:b.height,right:b.right,bottom:b.bottom}};
 const get=id=>document.getElementById(id);
 const measure=id=>rect(get(id));
 const groups=['toolbar.tabs','toolbar.connections-transfer','toolbar.history-notifications','toolbar.assistance-preferences'];
 const tools=groups.slice(1).filter(id=>get(id)).map(id=>({id,bounds:measure(id+'.surface'),buttons:[...get(id).querySelectorAll('[data-role="hit-area"]')].map(e=>({id:e.id,...rect(e)}))}));
 const rows=[...document.querySelectorAll('g[id^="host."]')].map(g=>({id:g.id,name:rect(g.querySelector('text[id$=".name"]')),route:g.querySelector('text[id$=".hops"]')?rect(g.querySelector('text[id$=".hops"]')):null}));
 const tabs=[...document.querySelectorAll('g[id^="tab."]')].map(g=>({id:g.id,bounds:rect(g.querySelector('[data-role="hit-area"]')),name:rect(g.querySelector('text')),close:g.querySelector('rect[id$=".close.hit"]')?rect(g.querySelector('rect[id$=".close.hit"]')):null}));
 const content=[...get('terminal.content').querySelectorAll('text')].map(e=>({text:e.textContent,...rect(e)}));
 const prompt=get('terminal.current-prompt');
 const report={size:[Number(document.documentElement.getAttribute('width')),Number(document.documentElement.getAttribute('height'))],sidebar:measure('sidebar.surface'),tabs:measure('toolbar.tabs.surface'),compactToggle:measure('toolbar.compact-toggle.surface'),tools,rows,tabItems:tabs,footer:measure('sidebar.footer.surface'),footerContent:measure('sidebar.footer.content'),headerSearch:measure('sidebar.search.toggle.hit'),headerNew:measure('sidebar.new.hit'),sidebarCollapse:measure('sidebar.collapse.hit'),terminalViewport:measure('terminal.viewport'),terminalText:measure('terminal.text.bounds'),firstLine:measure('terminal.first-line'),lastPrompt:measure('terminal.current-prompt'),promptAdvance:prompt.getComputedTextLength(),cursor:measure('terminal.cursor'),ai:measure('ai.status-strip.surface'),aiHit:measure('ai.status-strip.hit'),terminalLines:content};
 document.documentElement.setAttribute('data-layout-audit',JSON.stringify(report));
});'''

def near(a,b,t=.1):assert abs(a-b)<=t,(a,b)
def inside(a,b,margin=0):
 assert a['x']>=b['x']+margin-.5 and a['y']>=b['y']+margin-.5 and a['right']<=b['right']-margin+.5 and a['bottom']<=b['bottom']-margin+.5,(a,b,margin)

def audit(name):
 raw=(BASE/(name+'.svg')).read_text();root=ET.fromstring(raw);ns={'s':'http://www.w3.org/2000/svg'}
 ids=[e.get('id') for e in root.iter() if e.get('id')];assert len(ids)==len(set(ids)), 'duplicate IDs'
 contract=json.loads(root.find('s:metadata[@id="design.contract"]',ns).text)
 assert contract['status']=='final_design' and contract['visible_annotations'] is False
 assert contract['canvas']==[int(root.get('width')),int(root.get('height'))]
 assert contract['ai_strip']['flow']=='absolute_overlay_no_reserved_row'
 assert not root.findall('.//s:script',ns) and not root.findall('.//s:foreignObject',ns) and not root.findall('.//s:image',ns)
 strip=next(e for e in root.iter() if e.get('id')=='ai.status-strip')
 assert len(strip.findall('s:circle',ns))==3 and not strip.findall('s:text',ns) and not strip.findall('s:use',ns)
 required=['sidebar.search.toggle','sidebar.new','sidebar.footer.new']
 if contract['toolbar']['compact_state']!='collapsed':
  required+=['session.command-history','global.logs','global.notifications','global.transfer','global.theme','assistant.open','global.settings','session.route','session.forward']
 required+=['tabs.new']
 if contract['toolbar']['compact_state']=='collapsed':required+=['toolbar.compact-toggle.button']
 for i in required:assert i in ids,i
 with tempfile.TemporaryDirectory(prefix='zerowork-mist-audit-') as d:
  f=Path(d)/'audit.svg';f.write_text(raw.replace('</svg>','<script><![CDATA['+JS+']]></script></svg>'))
  out=subprocess.run([CHROME,'--headless','--no-sandbox','--disable-gpu','--no-first-run','--allow-file-access-from-files','--user-data-dir='+d+'/profile','--virtual-time-budget=2000','--dump-dom',f.as_uri()],capture_output=True,text=True,timeout=20)
  m=re.search(r'data-layout-audit="([^"]+)"',out.stdout);assert m,'No browser measurements'
  r=json.loads(html.unescape(m.group(1)))
 w,h=r['size'];near(r['sidebar']['x'],12);near(r['sidebar']['y'],12);near(h-r['sidebar']['bottom'],12)
 caps=([r['tabs']] if r['tabs'] else [])+[g['bounds'] for g in r['tools']]+([r['compactToggle']] if r['compactToggle'] else [])
 for c in caps:near(c['y'],12);near(c['h'],36)
 near(w-caps[-1]['right'],12)
 if r['tabs']:
  assert caps[1]['x']-caps[0]['right'] >= 16-.1
  near(r['tabs']['right']-r['tabItems'][-1]['bounds']['right'],36)
 other_caps=caps[1:] if r['tabs'] else caps
 for a,b in zip(other_caps,other_caps[1:]):near(b['x']-a['right'],8)
 if contract['toolbar']['compact_state']=='collapsed':
  assert len(r['tools'])==0;near(r['compactToggle']['w'],36)
 if contract['toolbar']['compact_state']=='expanded_left':
  assert r['tabs'] is not None and len(r['tools'])==3 and r['compactToggle'] is not None
  assert 'toolbar.expanded.hover-region' in ids
  assert 'toolbar.compact-toggle.button' in ids
  assert sum(len(g['buttons']) for g in r['tools'])==9
 for group in r['tools']:
  buttons=group['buttons']
  for b in buttons:near(b['w'],28);near(b['h'],28);inside(b,group['bounds'],4)
  for a,b in zip(buttons,buttons[1:]):near(b['x']-a['x'],32)
 near(r['terminalViewport']['x']-r['sidebar']['right'],24)
 near(w-r['terminalViewport']['right'],12);near(h-r['terminalViewport']['bottom'],12)
 for name in ['x','y']:near(r['terminalText'][name]-r['terminalViewport'][name],16)
 near(r['terminalViewport']['right']-r['terminalText']['right'],16);near(r['terminalViewport']['bottom']-r['terminalText']['bottom'],16)
 near(r['firstLine']['x'],r['terminalText']['x']);near(r['firstLine']['y'],r['terminalText']['y'])
 for line in r['terminalLines']:inside(line,r['terminalText'])
 inside(r['cursor'],r['terminalText'])
 near(r['cursor']['x']-r['lastPrompt']['x'],r['promptAdvance'],.6)
 for tab in r['tabItems']:
  inside(tab['name'],tab['bounds']);inside(tab['bounds'],r['tabs'])
  assert tab['close'] is not None, 'Every tab must show its close button'
  assert tab['name']['right']+4 <= tab['close']['x']
 for row in r['rows']:
  if row['route']:assert row['name']['right']+8<=row['route']['x'],row
 inside(r['footerContent'],r['footer'])
 near(r['footerContent']['x']+r['footerContent']['w']/2,r['footer']['x']+r['footer']['w']/2,1)
 near(r['footerContent']['y']+r['footerContent']['h']/2,r['footer']['y']+r['footer']['h']/2,1)
 near(r['footer']['x']-.75,22);near(r['footer']['right']+.75,r['sidebar']['right']-10)
 near(r['ai']['w'],120);near(r['ai']['h'],6);near(r['aiHit']['w'],120);near(r['aiHit']['h'],6)
 near(r['ai']['x']+60,(r['terminalViewport']['x']+r['terminalViewport']['right'])/2)
 near(r['ai']['y']+r['ai']['h']/2,(caps[0]['bottom']+r['firstLine']['y'])/2)
 assert r['ai']['bottom'] < r['terminalText']['y']
 near(r['terminalViewport']['y']-caps[0]['bottom'],12)
 for id in ['headerNew','sidebarCollapse']:near(r[id]['right'],r['footer']['right']+.75)
 near(r['headerNew']['x']-r['headerSearch']['right'],4)
 assert not any(t.text in ['SSH','SFTP','KVM'] for t in root.findall('.//s:text',ns))
 assert not any(re.search(r'设计说明|尺寸标注|逻辑像素|最终定稿', ''.join(t.itertext())) for t in root.findall('.//s:text',ns))
 return r

if __name__=='__main__':
 forbidden=[p for p in BASE.rglob('*') if p.is_file() and p.suffix.lower() not in {'.svg','.md'}]
 assert not forbidden, 'UI_V4 only accepts SVG and Markdown: '+str(forbidden)
 report={}
 for n in ['mist-workspace','mist-workspace-compact','mist-workspace-compact-expanded']:
  report[n]=audit(n);print(n+': complete layout/functional-entry/AI-strip audit passed')
 for key in ['sidebar','terminalViewport','terminalText','firstLine','ai','aiHit']:
  assert report['mist-workspace-compact'][key]==report['mist-workspace-compact-expanded'][key],key+' moved when opening compact tools'
 output=REPO/'artifacts/ui-v4';output.mkdir(parents=True,exist_ok=True)
 (output/'spacing-measurements.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
