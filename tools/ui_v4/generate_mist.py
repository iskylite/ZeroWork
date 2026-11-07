"""Generate the final editable UI SVG; specifications never render on the canvas."""
from pathlib import Path
from html import escape
import re, math, json

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "docs/UI_V4"
# Reuse the reviewed icon/font resources. Strip obsolete clips and replace shadows.
DEFS = (BASE/'mist-workspace.svg').read_text().split('<defs>',1)[1].split('</defs>',1)[0]
DEFS = re.sub(r'<clipPath.*?</clipPath>', '', DEFS, flags=re.S)
DEFS = re.sub(r'<filter id="(?:raised|sidebar-shadow|mist-raised|mist-sidebar-shadow)".*?</filter>', '', DEFS, flags=re.S)
DEFS += '''<filter id="mist-raised" x="-50%" y="-60%" width="200%" height="240%"><feDropShadow dx="0" dy="3" stdDeviation="4" flood-color="#18181B" flood-opacity=".07"/></filter><filter id="mist-sidebar-shadow" x="-12%" y="-3%" width="130%" height="108%"><feDropShadow dx="1" dy="2" stdDeviation="5" flood-color="#18181B" flood-opacity=".055"/></filter>'''
P = {'app': '#FFFFFF', 'sidebar': '#F6F6F7', 'surface': '#FFFFFF', 'well': '#EFEFEF', 'selected': '#EAEDFD', 'fg': '#18181B', 'fg2': '#5B5B65', 'fg3': '#676771', 'accent': '#4F5ED9', 'accent_ink': '#4352C7', 'ok': '#15B8A6', 'ok_ink': '#146D58', 'warn': '#D98A00'}

class Screen:
 def __init__(self,w,h,compact=False,tools_expanded=False):
  self.w,self.h,self.compact=w,h,compact
  self.tools_expanded=tools_expanded
  self.sidebar_width=220 if compact else 238
  self.work_x=12+self.sidebar_width+24
  self.work_right=w-12
  self.text_x=self.work_x+16
  self.text_y=76
  self.text_right=w-28
  self.text_bottom=h-28
  self.parts=[]
  self.add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" fill="none"><title>ZeroWork 工作区</title><desc>主机分组、活动终端、会话工具与三点 AI 状态浮条。</desc>')
  self.source_contract()
  self.add(f'<defs>{DEFS}<clipPath id="window.clip"><rect width="{w}" height="{h}" rx="18"/></clipPath><clipPath id="sidebar.list.clip"><rect x="22" y="118" width="{self.sidebar_width-20}" height="{h-186}"/></clipPath><clipPath id="terminal.text.clip"><rect x="{self.text_x}" y="{self.text_y}" width="{self.text_right-self.text_x}" height="{self.text_bottom-self.text_y}"/></clipPath></defs><g clip-path="url(#window.clip)">')
  self.rect(0,0,w,h,P['app'],id='window.background')
 def add(self,s):self.parts.append(s)
 def note(self,s):
  assert '--' not in s
  self.add('<!-- '+s+' -->')
 def source_contract(self):
  contract={
   'status':'final_design','units':'logical_px','canvas':[self.w,self.h],
   'preview_scale':2,'theme':'reference-light','specification':'mist-design.md','measurements':'../../artifacts/ui-v4/spacing-measurements.json','requirements':'DESIGN_REQUIREMENTS.md','style_guide':'STYLE_GUIDE.md',
   'native_implementation_changed':True,'visible_annotations':False,
   'window':{'outer_margin':12,'sidebar_width':self.sidebar_width,'sidebar_to_workspace':24},
   'toolbar':{'top':12,'height':36,'radius':18,'button_hit':[28,28],'icon':[16,16],
    'icon_feedback':{'idle':'transparent','hover':'theme_hover_circle','pressed':'theme_pressed_circle','click_end':'transparent_until_physical_leave_and_reenter','disabled':'no_feedback','keyboard_focus':'1px_accent_circle_outline_no_persistent_fill'},'button_shape':'circle','button_state_radius':14,'button_center_pitch':32,'group_gap':8,'tab_to_tools_min_gap':16,'empty_tabs':{'capsule':[36,36],'gap':0,'new_button_center':'capsule_center'},'tab_close':'always_visible','tab_width':'fit_actual_tabs_and_new_button_never_stretch',
    'compact_state':('expanded_left' if self.tools_expanded else 'collapsed') if self.compact else 'full',
    'compact_behavior':'default_show_all_tools; compact_width_or_tabs_exceed_available_width_collapses_to_ellipsis; hover_ellipsis_reveals_all_nine_buttons_left_over_220ms_and_retains_ellipsis; shrink_tab_budget_to_reserve_expanded_tools_and_16px_gap; pointer_leaves_whole_function_region_including_group_gaps_returns_to_ellipsis; opening_click_is_not_forwarded_to_new_buttons; terminal_and_ai_do_not_move',
    'groups':[['connection_route','port_forwarding','global_transfers'],['command_history','session_logs','notifications'],['global_theme','ai_entry','settings']]},
   'terminal':{'viewport':[self.work_x,60,self.work_right-self.work_x,self.h-72],
    'text_bounds':[self.text_x,self.text_y,self.text_right-self.text_x,self.text_bottom-self.text_y],
    'padding':[16,16,16,16],'toolbar_to_viewport_gap':12,'first_visible_glyph_top':76,
    'scroll':'existing_terminal_document','font_preferences':'preserve_existing_user_settings'},
   'ai_strip':{'visual_and_trigger':[120,6],'dot_diameter':3,'dot_gap':4,
    'center_x':(self.work_x+self.work_right)/2,'center_y':(48+self.text_y)/2,
    'placement':'center_between_visible_toolbar_bottom_and_first_terminal_glyph_top',
    'flow':'absolute_overlay_no_reserved_row','material':'existing_transparent_glass',
    'behavior':'preserve_existing_hover_preview_click_and_state_controller'},
   'sidebar':{'protocol_text_tags':False,'header_actions_right_inset':10,
    'host_row_height':36,'host_row_pitch':37,'footer_height':34,
    'operations':'preserve_existing_search_creation_grouping_and_connection_actions'},
   'fonts':{'interface':'system-ui / PingFang SC','terminal':'embedded JetBrains Mono Regular'},
  }
  self.note('设计契约仅存于源码 metadata 与注释，不渲染到产品画布。完整规范见 mist-design.md。')
  self.add('<metadata id="design.contract">'+escape(json.dumps(contract,ensure_ascii=False,indent=2),quote=False)+'</metadata>')
 def group(self,id,extra=''):self.add(f'<g id="{id}" {extra}>')
 def end(self):self.add('</g>')
 def title(self,s):self.add('<title>'+escape(s)+'</title>')
 def rect(self,x,y,w,h,fill,rx=0,id=None,extra=''):
  ident=f' id="{id}"' if id else ''
  self.add(f'<rect{ident} x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" {extra}/>')
 def text(self,x,y,s,size=13,col=None,weight=400,id=None,extra=''):
  ident=f' id="{id}"' if id else ''
  self.add(f'<text{ident} x="{x}" y="{y}" font-size="{size}" fill="{col or P["fg"]}" font-weight="{weight}" {extra}>{escape(s)}</text>')
 def icon(self,asset,x,y,size=18,col=None,id=None):
  ident=f' id="{id}"' if id else ''
  self.add(f'<use{ident} href="#{asset}" x="{x}" y="{y}" width="{size}" height="{size}" color="{col or P["fg3"]}"/>')
 def dot(self,x,y,r,fill,id=None,extra=''):
  ident=f' id="{id}"' if id else ''
  self.add(f'<circle{ident} cx="{x}" cy="{y}" r="{r}" fill="{fill}" {extra}/>')
 def hit(self,id,x,y,w,h):self.rect(x,y,w,h,'transparent',rx=14 if w==h==28 else 0,id=id,extra='data-role="hit-area"')
 def capsule(self,id,x,w):
  self.group(id)
  self.rect(x,12,w,36,P['surface'],18,id=id+'.surface',extra='filter="url(#mist-raised)"')
 def button(self,id,x,asset,label,active=False,badge=False):
  self.group(id);self.title(label);self.hit(id+'.hit',x,16,28,28)
  self.icon(asset,x+6,22,16,P['accent_ink'] if active else P['fg3'],id=id+'.icon')
  if badge:self.dot(x+22,20,2.5,P['accent'],id=id+'.badge')
  self.end()
 def transfer(self,x):
  self.group('global.transfer');self.title('打开全局传输列表 · 68%')
  self.hit('global.transfer.hit',x,16,28,28);cx=x+14;r=11;c=2*math.pi*r
  self.dot(cx,30,r,'none',id='global.transfer.track',extra='stroke="#E4E4E7" stroke-width="2"')
  self.dot(cx,30,r,'none',id='global.transfer.ring',extra=f'stroke="{P["accent"]}" stroke-width="2" stroke-linecap="round" stroke-dasharray="{c*.68} {c}" transform="rotate(-90 {cx} 30)"')
  self.text(cx,33,'68%',8,P['accent_ink'],550,extra='text-anchor="middle"')
  self.end()
 def sidebar(self):
  sw=self.sidebar_width
  self.note(f'workspace.sidebar：x12 y12 w{sw} h{self.h-24}；搜索/新建沿用已有行为，协议文字 Tag 不显示。')
  self.group('workspace.sidebar')
  self.rect(12,12,sw,self.h-24,P['sidebar'],16,id='sidebar.surface',extra='filter="url(#mist-sidebar-shadow)"')
  self.rect(12.5,12.5,sw-1,self.h-25,'none',15.5,extra='stroke="#FFFFFF" stroke-width="1"')
  self.group('window.native-controls')
  for x,col in [(40,'#FF5F57'),(60,'#FEBC2E'),(80,'#28C840')]:self.dot(x,30,6,col)
  self.end()
  self.group('sidebar.collapse');self.title('隐藏侧栏 ⌘B');self.hit('sidebar.collapse.hit',sw-22,18,24,24);self.icon('sidebar',sw-19.5,20.5,19);self.end()
  self.group('sidebar.header')
  self.icon('server',26,81,17,P['accent_ink']);self.text(49,95,'主机与连接',13,P['fg'],700)
  for asset,x,label,id in [('search',sw-50,'搜索主机','sidebar.search.toggle'),('plus',sw-22,'新建主机或分组','sidebar.new')]:
   self.group(id);self.title(label);self.hit(id+'.hit',x,78,24,24);self.icon(asset,x+4,82,16);self.end()
  self.end()
  self.group('sidebar.hosts',extra='clip-path="url(#sidebar.list.clip)"')
  def group_heading(top,name,count,col,collapsed=False):
   self.group('host-group.'+name)
   self.hit('host-group.'+name+'.hit',22,top,sw-20,28)
   self.icon('chevron' if collapsed else 'down',30,top+7,12)
   self.dot(51,top+13,2.5,col)
   self.text(62,top+17,name,11.5,P['fg2'],600)
   self.text(sw-3,top+17,str(count),10,P['fg3'],id='host-group.'+name+'.count',extra='text-anchor="end"')
   self.end()
  def host(top,name,proto='SSH',hops='0',os='ubuntu',selected=False,online=False):
   ident='host.'+name;self.group(ident)
   self.rect(22,top,sw-20,36,P['selected'] if selected else 'transparent',8,id=ident+'.hit',extra='data-role="hit-area"')
   self.icon('os-'+os if proto=='SSH' else ('folder' if proto=='SFTP' else 'monitor'),31,top+9,18)
   if online:self.dot(49,top+9,3,P['ok'],extra='stroke="#F6F6F7" stroke-width="1.2"')
   self.text(58,top+23,name,12,P['fg'],500,id=ident+'.name')
   if proto!='KVM':
    self.icon('route',sw-36,top+11,14);self.text(sw-3,top+22,hops,10,P['fg3'],id=ident+'.hops',extra='text-anchor="end"')
   self.end()
  group_heading(126,'生产环境',4,'#8C7CC5')
  host(162,'prod-web-01',selected=True,online=True);host(199,'prod-web-02');host(236,'prod-db-01',hops='1',os='debian');host(273,'prod-bastion',os='debian')
  group_heading(329,'开发环境',3,'#75A99A')
  host(365,'dev-api-01',os='fedora',online=True);host(402,'项目文件','SFTP');host(439,'dev-cache-01',os='debian')
  group_heading(495,'硬件管理',2,'#BEA06B',True)
  self.end()
  if self.compact:self.rect(sw,151,2,102,'#C4C4CC',1)
  self.group('sidebar.footer.new');fy=self.h-56;mid=12+sw/2
  self.rect(22.75,fy+.75,sw-21.5,32.5,'transparent',7.25,id='sidebar.footer.surface',extra='stroke="#D4D4D8" stroke-width="1.5" stroke-dasharray="4.5 4.5"')
  self.group('sidebar.footer.content',extra='transform="translate(-1.5,.5)"')
  self.icon('plus',mid-34,fy+10,14);self.text(mid-14,fy+21,'新建连接',12,P['fg2'],500)
  self.end();self.end();self.end()
 def tab(self,x,w,name,asset,active,color):
  self.group('tab.'+name)
  self.rect(x,16,w,28,P['selected'] if active else 'transparent',7,id='tab.'+name+'.hit',extra='data-role="hit-area"')
  self.rect(x+8,23,2.5,14,color,1.25)
  self.icon(asset,x+19,22,16,P['accent_ink'] if active else P['fg3'])
  if active:self.dot(x+33,22,3.7,P['ok'],extra='stroke="#FFFFFF" stroke-width="1.2"')
  self.text(x+43,34,name,12.5,P['fg'] if active else P['fg3'],550 if active else 400,id='tab.'+name+'.name')
  self.hit('tab.'+name+'.close.hit',x+w-28,20,20,20);self.icon('close',x+w-24,24,12)
  self.end()
 def full_tool_groups(self,conn,hist,pref):
  self.capsule('toolbar.connections-transfer',conn,100)
  self.button('session.route',conn+4,'network','当前会话连接链路')
  self.button('session.forward',conn+36,'plug','当前会话端口转发',True,True)
  self.transfer(conn+68)
  self.end()
  self.capsule('toolbar.history-notifications',hist,100)
  self.button('session.command-history',hist+4,'list-restart','当前终端的命令历史')
  self.button('global.logs',hist+36,'history','回看会话日志')
  self.button('global.notifications',hist+68,'bell','通知',badge=True)
  self.end()
  self.capsule('toolbar.assistance-preferences',pref,100)
  self.button('global.theme',pref+4,'palette','全局主题 · 晴霜')
  self.button('assistant.open',pref+36,'sparkles','AI 助手')
  self.button('global.settings',pref+68,'settings','偏好设置')
  self.end()
 def toolbar(self):
  self.note('workspace.toolbar：y12 h36；默认显示全部工具，窄窗或Tab过多收为三点，悬停220ms向左展开并保留三点，展开时Tab按实际剩余空间收缩并留16点间距，移出收回并恢复Tab宽度；不推移终端或AI条。')
  self.group('workspace.toolbar')
  if self.compact:
   toggle=self.w-12-36
   if self.tools_expanded:
    tw=204
    self.capsule('toolbar.tabs',self.work_x,tw)
    self.tab(self.work_x+4,164,'prod-web-01','terminal',True,P['accent'])
    self.button('tabs.new',self.work_x+tw-32,'plus','新建会话')
    self.end()
    pref=toggle-8-100;hist=pref-8-100;conn=hist-8-100
    self.group('toolbar.expanded.overlay')
    self.hit('toolbar.expanded.hover-region',conn,12,self.w-12-conn,36)
    self.full_tool_groups(conn,hist,pref)
    self.end()
   else:
    tw=204
    self.capsule('toolbar.tabs',self.work_x,tw)
    self.tab(self.work_x+4,164,'prod-web-01','terminal',True,P['accent'])
    self.button('tabs.new',self.work_x+tw-32,'plus','新建会话')
    self.end()
   self.capsule('toolbar.compact-toggle',toggle,36)
   self.button('toolbar.compact-toggle.button',toggle+4,'more','悬停向左展开全部功能按钮')
   self.end()
  else:
   pref=self.w-12-100;hist=pref-8-100;conn=hist-8-100
   tw=min(732,conn-16-self.work_x)
   self.capsule('toolbar.tabs',self.work_x,tw)
   cur=self.work_x+4
   for i,(width,name,asset,col) in enumerate([(164,'prod-web-01','terminal',P['accent']),(100,'本地','terminal','#98909F'),(128,'项目文件','folder','#5D9F8E'),(144,'BMC 控制台','monitor','#B0925D'),(140,'部署会话组','layers','#A586B6')]):
    self.tab(cur,width,name,asset,i==0,col);cur+=width+4
   self.button('tabs.new',self.work_x+tw-32,'plus','新建会话')
   self.end()
   self.full_tool_groups(conn,hist,pref)
  self.end()
 def ai_strip(self):
  self.note('ai.status-strip：绝对悬浮，不占布局；中心y=(组件真实下沿48+首行字形上沿76)/2=62，上沿59。三点及原交互不变。')
  self.group('ai.status-strip',extra='data-owner="active-ai-binding"')
  self.title('打开 AI 助手')
  mid=(self.work_x+self.work_right)/2;x=mid-60;top=(48+self.text_y)/2-3
  # Match the existing strip trigger footprint (120 × 6), not an invented larger trigger.
  self.hit('ai.status-strip.hit',x,top,120,6)
  self.rect(x,top,120,6,'url(#ai-strip-glass)',3,id='ai.status-strip.surface',extra='filter="url(#ai-strip-shadow)" stroke="#FFFFFF" stroke-opacity=".65" stroke-width=".6"')
  col=P['warn'] if self.compact else P['accent']
  for i in range(3):self.dot(mid-7+i*7,top+3,1.5,col,id=f'ai.status-strip.dot.{i}',extra='opacity=".37255"' if i!=1 else '')
  self.end()
 def terminal(self):
  self.note(f'workspace.terminal：视口x{self.work_x} y60；文字x{self.text_x} y76，四边内距16，窗口右/下留白12。浮条不参与间距计算。')
  self.group('workspace.terminal')
  self.rect(self.work_x,60,self.work_right-self.work_x,self.h-72,'transparent',id='terminal.viewport',extra='data-role="viewport-bounds"')
  self.rect(self.text_x,self.text_y,self.text_right-self.text_x,self.text_bottom-self.text_y,'transparent',id='terminal.text.bounds',extra='data-role="text-bounds"')
  self.group('terminal.content',extra='clip-path="url(#terminal.text.clip)"')
  def mono(row,s,col=None,id=None):self.text(self.text_x,89+20*row,s,13,col or P['fg2'],id=id,extra='class="mono"')
  def prompt(row,command='',id=None):
   ident=f' id="{id}"' if id else ''
   self.add(f'<text{ident} x="{self.text_x}" y="{89+20*row}" font-size="13" class="mono"><tspan fill="{P["ok_ink"]}">admin@prod-web-01</tspan><tspan fill="{P["fg3"]}">:</tspan><tspan fill="{P["accent_ink"]}">/srv/zerowork</tspan><tspan fill="{P["fg"]}">$ {escape(command)}</tspan></text>')
  if self.compact:
   mono(0,'Last login: Fri Nov  6 09:41:22 2026',P['fg3'],id='terminal.first-line')
   prompt(2,'nginx -t')
   mono(4,'nginx: the configuration file')
   mono(5,'/etc/nginx/nginx.conf syntax is ok')
   mono(6,'nginx: configuration test is successful',P['ok_ink'])
   prompt(9,'curl -I https://localhost')
   mono(11,'HTTP/2 200',P['ok_ink']);mono(12,'server: nginx/1.24.0');mono(13,'content-type: text/html')
   prompt(16,id='terminal.current-prompt');cy=89+20*16
  else:
   mono(0,'Last login: Fri Nov  6 09:41:22 2026 from 10.0.1.8',P['fg3'],id='terminal.first-line')
   prompt(2,'systemctl status nginx --no-pager')
   mono(3,'● nginx.service - A high performance web server',P['fg'])
   mono(4,'     Loaded: loaded (/usr/lib/systemd/system/nginx.service; enabled)')
   self.add(f'<text x="{self.text_x}" y="189" class="mono" font-size="13"><tspan fill="{P["fg2"]}">     Active: </tspan><tspan fill="{P["ok_ink"]}">active (running)</tspan><tspan fill="{P["fg2"]}"> since Fri 2026-11-06 09:12:04 CST</tspan></text>')
   for row,s in [(6,'       Docs: man:nginx(8)'),(7,'   Main PID: 1428 (nginx)'),(8,'      Tasks: 5 (limit: 9387)'),(9,'     Memory: 12.4M (peak: 14.8M)'),(10,'        CPU: 1.284s'),(11,'     CGroup: /system.slice/nginx.service'),(12,'             ├─1428 "nginx: master process /usr/sbin/nginx"'),(13,'             ├─1429 "nginx: worker process"'),(14,'             ├─1430 "nginx: worker process"'),(15,'             ├─1431 "nginx: worker process"'),(16,'             └─1432 "nginx: worker process"')]:mono(row,s,P['fg3'] if row>=12 else P['fg2'])
   mono(18,'Nov 06 09:12:04 prod-web-01 systemd[1]: Starting nginx.service...',P['fg3'])
   mono(19,'Nov 06 09:12:04 prod-web-01 systemd[1]: Started nginx.service.',P['fg3'])
   prompt(21,'nginx -t');mono(22,'nginx: the configuration file /etc/nginx/nginx.conf syntax is ok');mono(23,'nginx: configuration file /etc/nginx/nginx.conf test is successful',P['ok_ink'])
   prompt(25,'curl -I https://localhost');mono(26,'HTTP/2 200',P['ok_ink']);mono(27,'server: nginx/1.24.0');mono(28,'content-type: text/html');mono(29,'content-length: 1248')
   prompt(31,'tail -n 3 /var/log/nginx/access.log')
   for row,time in [(32,'10:02:11'),(33,'10:02:21'),(34,'10:02:31')]:mono(row,f'10.0.1.8 - - [06/Nov/2026:{time} +0800] "GET /health HTTP/1.1" 200 2',P['fg3'])
   prompt(37,id='terminal.current-prompt');cy=89+20*37
  self.rect(self.text_x+257.4,cy-13,7.8,18,P['accent'],1,id='terminal.cursor')
  self.end();self.end()
 def save(self,name):
  self.sidebar();self.toolbar();self.ai_strip();self.terminal();self.end()
  self.rect(.5,.5,self.w-1,self.h-1,'none',17.5,id='window.frame',extra='stroke="#D4D4D8" stroke-width="1"')
  self.add('</svg>');(BASE/name).write_text('\n'.join(self.parts));print(BASE/name)

if __name__=='__main__':
 Screen(1440,900).save('mist-workspace.svg')
 Screen(860,480,True).save('mist-workspace-compact.svg')
 Screen(860,480,True,tools_expanded=True).save('mist-workspace-compact-expanded.svg')
