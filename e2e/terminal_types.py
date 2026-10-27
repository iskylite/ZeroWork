#!/usr/bin/env python3
"""Installed terminfo contract for built-in TERM declarations, via a real PTY.
Absent capabilities are reported, never substituted with xterm escape sequences.
"""
import argparse,curses,json,os,re,select,sys,termios,time,tty
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--out',required=True);p.add_argument('--term',required=True,choices=['xterm-256color','xterm','vt100']);a=p.parse_args()
out=Path(a.out);out.mkdir(parents=True,exist_ok=True)
assert os.environ['TERM']==a.term,(os.environ.get('TERM'),a.term)
curses.setupterm(a.term);fd=sys.stdin.fileno();saved=termios.tcgetattr(fd)
control=os.open('/dev/tty',os.O_RDWR);os.close(control);assert os.tcgetpgrp(fd)==os.getpgrp()
names='clear cup home cub1 cud1 cuf1 cuu1 cub cud cuf cuu ed el el1 sc rc csr ind ri ht hts tbc smam rmam enacs smacs rmacs sgr0 bold blink rev smul rmul smso rmso civis cnorm cvvis smkx rmkx dch dch1 ich ech il il1 dl dl1 hpa vpa cbt rep smir rmir indn rin smcup rmcup setaf setab initc oc op is2 rs1 rs2 kcuu1 kcud1 kcub1 kcuf1 khome kend kdch1 kich1 kpp knp kcbt kbs kDC kEND kHOM kIC kLFT kNXT kPRV kRIT kind kri'.split()+['kf'+str(i)for i in range(64)]
raw={name:curses.tigetstr(name)for name in names}
report={'term':a.term,'colors':curses.tigetnum('colors'),'controlling_tty':True,'checks':[],'inputs':[],'terminfo_capabilities':[],'capability_matrix':{n:{'declared':v is not None,'sequence_hex':v.hex() if v else None,'status':'pending' if v else 'not_advertised'}for n,v in raw.items()},'extensions':[]}
assert report['colors']=={'xterm-256color':256,'xterm':8,'vt100':-1}[a.term],report['colors']
def emit(v):os.write(1,v.encode()if isinstance(v,str)else v)
def cap(n,*params):
 v=raw[n];assert v is not None,n
 if n not in report['terminfo_capabilities']:report['terminfo_capabilities'].append(n)
 report['capability_matrix'][n]['status']='exercised'
 return re.sub(rb'\$<[^>]*>',b'',curses.tparm(v,*params)if params else v)
def save():(out/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
def stage(n,expected=None):save();(out/'stage.json').write_text(json.dumps({'name':n,'expected':expected}))
def wait(n):
 deadline=time.monotonic()+45
 while not(out/(n+'.release')).exists():
  if time.monotonic()>deadline:raise TimeoutError(n)
  time.sleep(.025)
def read_until(pred):
 value=b'';deadline=time.monotonic()+15
 while time.monotonic()<deadline:
  if select.select([fd],[],[],.1)[0]:
   value+=os.read(fd,65536)
   if pred(value):return value
 raise AssertionError(('input timeout',value.hex()))
def exact(n,mode,want):
 emit(mode);termios.tcflush(fd,termios.TCIFLUSH);stage(n,want.hex());value=read_until(lambda b:len(b)>=len(want));assert value==want,(n,value,want)
 report['inputs'].append({'name':n,'hex':value.hex()});report['checks'].append(n)
def at(r,c=0):emit(cap('cup',r,c))
def clear():emit(cap('sgr0'));emit(cap('clear'))
def editing(n,expected):stage('editing-'+n,expected);wait('editing-'+n);report['checks'].append(n)
try:
 tty.setraw(fd);clear();emit('TERM '+a.term+'\r\n')
 for n,title in [('bold','BOLD'),('smul','UNDERLINE'),('rev','REVERSE'),('smso','STANDOUT'),('blink','BLINK')]:emit(cap(n));emit(title);emit(cap('rmul' if n=='smul' else 'rmso' if n=='smso' else 'sgr0'));emit(' / ')
 emit('\r\nACS: ')
 if raw['enacs']:emit(cap('enacs'))
 emit(cap('smacs'));emit('lqqqk x mqqqj');emit(cap('rmacs'));emit(' ASCII_OK\r\n')
 # Indexed colors use only the selected entry's advertised range.
 for i in range(max(0,report['colors'])):
  emit(cap('setaf',0 if i>7 else 7));emit(cap('setab',i));emit(f'{i:3d} ')
  if i%16==15:emit(cap('sgr0'));emit('\r\n')
 emit(cap('sgr0'));emit('\r\nVISUAL_DONE');stage('visual');wait('visual');report['checks'].append('declared-SGR-ACS-color-range')
 clear();at(2);emit('BADRIGHT');at(2,2);emit(cap('el1'));at(3);emit('LEFTTRASH');at(3,4);emit(cap('el'))
 at(4);emit('SAVE');emit(cap('sc'));at(5);emit('OTHER');emit(cap('rc'));emit('D')
 at(6,4);emit(cap('cub',2));emit('L');emit(cap('cuf',3));emit('R');emit(cap('cud',1));emit(cap('cub1'));emit('B');emit(cap('cuu',1));emit(cap('cuf1'));emit('C');emit(cap('cuu1'));emit(cap('cud1'));emit('N')
 at(8);emit(cap('tbc'));at(8,4);emit(cap('hts'));at(8);emit('T');emit(cap('ht'));emit('TAB')
 at(9);emit('HIDDEN_AFTER_ED');at(9);emit(cap('ed'))
 at(11);emit('REGION_TOP');at(12);emit('REGION_MID');at(13);emit('REGION_BOTTOM');emit(cap('csr',11,13));at(13);emit(cap('ind'));emit('SCROLLED');emit(cap('csr',0,os.get_terminal_size().lines-1))
 at(15);emit('REVERSE_INDEX');emit(cap('csr',15,17));at(15);emit(cap('ri'));emit(cap('csr',0,os.get_terminal_size().lines-1))
 at(20);emit('NOWRAP');emit(cap('rmam'));at(20,os.get_terminal_size().columns-3);emit('ABCDEF');emit(cap('smam'))
 at(23);emit('EDIT_DONE');editing('base',{'2':'   RIGHT','3':'LEFT','4':'SAVED','5':'OTHER','6':'  L   R CN','7':'      B','8':'T   TAB','9':'','11':'REGION_MID','12':'REGION_BOTTOM','13':'SCROLLED','15':'','16':'REVERSE_INDEX','20':'NOWRAP'+' '*(os.get_terminal_size().columns-9)+'ABF'})
 emit(cap('tbc'))
 for col in range(8,os.get_terminal_size().columns,8):at(8,col);emit(cap('hts'))
 # Named optional capabilities are never silently skipped: absence is in the matrix.
 if raw['dch1']:
  clear();at(2);emit('ABCDE');at(2,2);emit(cap('dch1'));emit(cap('ich',1));emit('X');at(3);emit('123456');at(3,2);emit(cap('ech',2));at(4);emit(cap('smir'));emit('INSERT');emit(cap('rmir'))
  at(6);emit('LINE_A');at(7);emit('LINE_B');at(6);emit(cap('il1'));emit('NEW');at(7);emit(cap('dl1'))
  at(9);emit('A');emit(cap('hpa',8));emit('HPA');emit(cap('vpa',10));emit('VPA');at(11);emit('T');emit(cap('ht'));emit('TAB');emit(cap('cbt'));emit('X');at(12);emit('R');emit(cap('rep',ord('Z'),4))
  at(14);emit('ABCDE');at(14,2);emit(cap('dch',2));at(16);emit('OLD');at(17);emit('NEXT');at(16);emit(cap('il',1));emit('NEW');at(17);emit(cap('dl',1))
  at(19);emit('SCROLL_UP');at(20);emit('SCROLL_DOWN');emit(cap('csr',19,21));at(21);emit(cap('indn',1));emit(cap('rin',1));emit(cap('csr',0,os.get_terminal_size().lines-1))
  at(23);emit('EDIT_DONE');editing('extended',{'2':'ABXDE','3':'12  56','4':'INSERT','6':'NEW','7':'LINE_B','9':'A       HPA','10':'           VPA','11':'T       XAB','12':'RZZZZ','14':'ABE','16':'NEW','17':'NEXT','19':'','20':'SCROLL_DOWN'})
  clear();emit('PRIMARY_RESTORED');emit(cap('smcup'));emit(cap('clear'));emit('ALTERNATE_ACTIVE');stage('alternate');wait('alternate');emit(cap('rmcup'));stage('primary');wait('primary');report['checks'].append('advertised-alternate-screen')
 clear();emit(cap('home'));at(4,9);emit('\x1b[6n');v=read_until(lambda b:b.endswith(b'R'));assert v==b'\x1b[5;10R',v
 emit('\x1b[c');v=read_until(lambda b:b.endswith(b'c'));assert v.startswith(b'\x1b[?'),v;report['checks'].append('DSR-primary-DA')
 if raw['initc']:
  emit(cap('initc',20,1000,0,0));emit('\x1b]4;20;?\x07');v=read_until(lambda b:b.endswith(b'\x1b\\') or b.endswith(b'\x07'));assert b'rgb:ffff/0000/0000'in v.lower(),v;emit(cap('oc'));report['checks'].append('advertised-palette-change-query-reset')
 if raw['op']:emit(cap('op'))
 for n in ['civis','cnorm','cvvis']:
  if raw[n]:emit(cap(n));stage('cursor-'+n);wait('cursor-'+n)
 for name,seq in [('up','A'),('down','B'),('right','C'),('left','D')]:exact('key-'+name+'-normal',cap('rmkx'),b'\x1b['+seq.encode())
 for name,n in [('up','kcuu1'),('down','kcud1'),('left','kcub1'),('right','kcuf1')]:exact('key-'+name+'-application',cap('smkx'),cap(n))
 for name,n in [('home','khome'),('end','kend'),('delete','kdch1'),('insert','kich1'),('pageup','kpp'),('pagedown','knp'),('backtab','kcbt')]:
  if raw[n]:exact('key-'+name,b'',cap(n))
 for i in range(1,64):
  if raw['kf'+str(i)]:exact('key-f'+str(i),b'',cap('kf'+str(i)))
 for name,n in [('delete','kDC'),('end','kEND'),('home','kHOM'),('insert','kIC'),('left','kLFT'),('pagedown','kNXT'),('pageup','kPRV'),('right','kRIT'),('down','kind'),('up','kri')]:
  if raw[n]:exact('key-shift-'+name,b'',cap(n))
 exact('key-backspace-bs','\x1b[?67h',cap('kbs'));exact('key-backspace-del','\x1b[?67l',b'\x7f')
 # Reset sequences must restore normal cursor/keypad behavior, not merely print nothing.
 for n in ['is2','rs1','rs2']:
  if raw[n]:exact('key-up-after-'+n,cap('smkx')+cap(n),cap('kcuu1') if a.term=='vt100' and n=='rs2' else b'\x1b[A')
 emit(cap('rmkx'));clear();
 for item in report['capability_matrix'].values():
  if item['status']=='pending':item['status']='declared_not_exercised'
 report['status']='passed';save();emit('COMPATIBILITY_DONE\r\n');stage('done')
except BaseException as e:report['status']='failed';report['error']=repr(e);save();raise
finally:emit(cap('sgr0'));emit(cap('rmkx'));termios.tcsetattr(fd,termios.TCSANOW,saved)
