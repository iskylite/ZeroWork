#!/usr/bin/env python3
"""Real-PTY xterm-256color contract. UI drives keys/mouse/paste between stages.
Uses the endpoint's installed terminfo, never feeds the app through test routes.
"""
import argparse, curses, json, os, re, select, sys, termios, time, tty
from pathlib import Path
p=argparse.ArgumentParser(); p.add_argument('--out',required=True); args=p.parse_args()
out=Path(args.out); out.mkdir(parents=True,exist_ok=True)
curses.setupterm(term=os.environ.get('TERM'))
report={'term':os.environ.get('TERM'),'colors':curses.tigetnum('colors'),'checks':[],'inputs':[],'terminfo_capabilities':[]}
assert report['term']=='xterm-256color' and report['colors']==256, report
control=os.open('/dev/tty',os.O_RDWR);os.close(control)
report['controlling_tty']=True
assert os.tcgetpgrp(sys.stdin.fileno())==os.getpgrp(), 'fixture process must own the PTY foreground group'
fd=sys.stdin.fileno(); saved=termios.tcgetattr(fd)
def emit(value):
    os.write(1,value.encode() if isinstance(value,str) else value)
def cap(name,*params):
    value=curses.tigetstr(name); assert value is not None,name
    if name not in report['terminfo_capabilities']: report['terminfo_capabilities'].append(name)
    return re.sub(rb'\$<[^>]*>',b'',curses.tparm(value,*params) if params else value)
def at(row,col=0): emit(cap('cup',row,col))
def reset(): emit('\x1b[0m\x1b[?1049l\x1b[?1000l\x1b[?1002l\x1b[?1006l\x1b[?1004l\x1b[?2004l\x1b[?1l\x1b>\x1b[r\x1b[3J\x1b[2J\x1b[H')
def save(): (out/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
def stage(name,expected=None):
    save(); (out/'stage.json').write_text(json.dumps({'name':name,'expected':expected}))
def wait_release(name):
    deadline=time.monotonic()+45
    while not (out/(name+'.release')).exists():
        if time.monotonic()>deadline: raise TimeoutError(name)
        time.sleep(.03)
def read_until(predicate,timeout=15):
    value=b''; deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if select.select([fd],[],[],.1)[0]:
            value+=os.read(fd,65536)
            if predicate(value): return value
    raise AssertionError(('input timeout',value.hex()))
def exact(name,mode,expected):
    emit(mode); termios.tcflush(fd,termios.TCIFLUSH); stage(name,expected.hex())
    value=read_until(lambda b:len(b)>=len(expected)); assert value==expected,(name,value,expected)
    report['inputs'].append({'name':name,'hex':value.hex()}); report['checks'].append(name)
try:
    tty.setraw(fd)
    reset(); emit('XTERM VISUAL CONTRACT\r\n')
    emit('\x1b[1mBOLD\x1b[0m / \x1b[2mDIM\x1b[0m / \x1b[3mITALIC\x1b[0m / \x1b[4mUNDERLINE\x1b[0m\r\n')
    emit('\x1b[7mREVERSE\x1b[0m / \x1b[9mSTRIKE\x1b[0m / \x1b[53mOVERLINE\x1b[0m / \x1b[5mBLINK\x1b[0m / [\x1b[8mHIDDEN\x1b[0m]\r\n')
    emit('\x1b[4:2mDOUBLE\x1b[0m / \x1b[4:3mWAVY\x1b[0m / \x1b[4:4mDOTTED\x1b[0m / \x1b[4:5mDASHED\x1b[0m\r\n')
    emit('RGB '+ '\x1b[38;2;0;0;0;48;2;255;255;255mBLACK\x1b[0m '+ '\x1b[38;2;255;255;255;48;2;0;0;0mWHITE\x1b[0m\r\n')
    emit('Unicode: A界e\u0301🧪👩‍💻Z / ACS: '); emit(cap('smacs')); emit('lqqqk x mqqqj'); emit(cap('rmacs'));emit('\r\n')
    for row in range(16):
        for col in range(16):
            i=row*16+col; emit(cap('setaf',0 if i>7 else 15)); emit(cap('setab',i)); emit(f'{i:3d} ')
        emit(cap('sgr0')); emit('\r\n')
    emit('VISUAL_DONE'); stage('visual'); wait_release('visual'); report['checks'].append('ANSI16/indexed256/RGB/SGR/ACS/graphemes')
    for name,sequence in [('cursor-bar',6),('cursor-underline',4),('cursor-block',2),('cursor-default',0)]:
        reset();emit('CURSOR_SHAPE');emit(f'\x1b[{sequence} q');stage(name);wait_release(name)
    report['checks'].append('DECSCUSR cursor shape/default/blink')
    reset();emit('EDIT_CAPABILITIES')
    at(2);emit('ABCDE');at(2,2);emit(cap('dch1'));emit(cap('ich',1));emit('X')
    at(3);emit('123456');at(3,2);emit(cap('ech',2))
    at(4);emit('LEFTTRASH');at(4,4);emit(cap('el'))
    at(5);emit('BADRIGHT');at(5,2);emit(cap('el1'))
    at(6);emit('A');emit(cap('hpa',8));emit('HPA');emit(cap('vpa',7));emit('VPA')
    at(8);emit('SAVE');emit(cap('sc'));at(9);emit('OTHER');emit(cap('rc'));emit('D')
    at(10);emit(cap('smir'));emit('INSERT');emit(cap('rmir'))
    at(12);emit('LINE_A');at(13);emit('LINE_B');at(12);emit(cap('il1'));at(12);emit('NEW');at(13);emit(cap('dl1'))
    at(11);emit(cap('tbc'));at(11,4);emit(cap('hts'));at(11);emit('T');emit(cap('ht'));emit('TAB');emit(cap('cbt'));emit('X')
    emit(cap('tbc'))
    for col in range(8,os.get_terminal_size().columns,8):at(11,col);emit(cap('hts'))
    at(15);emit('R');emit(cap('rep',ord('Z'),4))
    at(20);emit('NOWRAP ');emit(cap('rmam'));at(20,os.get_terminal_size().columns-3);emit('ABCDEF');emit(cap('smam'))
    at(17);emit('REGION_TOP');at(18);emit('REGION_MID');at(19);emit('REGION_BOTTOM');emit(cap('csr',17,19));at(19);emit(cap('ind'));emit('SCROLLED');emit(cap('csr',0,os.get_terminal_size().lines-1))
    at(22);emit('BCE ');emit(cap('setab',4));emit(cap('el'));emit(cap('sgr0'))
    at(23);emit('EDIT_DONE')
    expected={'2':'ABXDE','3':'12  56','4':'LEFT','5':'   RIGHT','6':'A       HPA','7':'           VPA','8':'SAVED','9':'OTHER','10':'INSERT','12':'NEW','13':'LINE_B','17':'REGION_MID','18':'REGION_BOTTOM','19':'SCROLLED'}
    expected.update({'11':'T   XAB','15':'RZZZZ','20':'NOWRAP '+' '*(os.get_terminal_size().columns-10)+'ABF'})
    stage('editing',expected);wait_release('editing');report['checks'].append('cursor/edit/erase/insert/delete/scroll-region/BCE/save-restore')
    reset();emit('PRIMARY_RESTORED');emit(cap('smcup'));emit(cap('clear'));emit('ALTERNATE_ACTIVE');stage('alternate');wait_release('alternate');emit(cap('rmcup'));stage('primary');wait_release('primary');report['checks'].append('smcup/rmcup primary preservation')
    reset();at(4,9);emit('\x1b[6n');value=read_until(lambda b:b.endswith(b'R'));assert value==b'\x1b[5;10R',value
    emit('\x1b[c');value=read_until(lambda b:b.endswith(b'c'));assert value.startswith(b'\x1b[?'),value
    emit('\x1b[>c');value=read_until(lambda b:b.endswith(b'c'));assert value.startswith(b'\x1b[>'),value
    emit(cap('initc',20,1000,0,0));emit('\x1b]4;20;?\x07');value=read_until(lambda b:b.endswith(b'\x1b\\') or b.endswith(b'\x07'))
    assert b'rgb:ffff/0000/0000' in value.lower(),value
    emit(cap('oc'));emit(cap('op'))
    report['checks'].append('initc/OSC4 palette query/oc/op actual PTY replies')
    report['checks'].append('DSR/primary DA/secondary DA actual PTY replies')
    keys=[('key-up-normal','\x1b[?1l',b'\x1b[A'),('key-up-application','\x1b[?1h',cap('kcuu1')),('key-home','',cap('khome')),('key-end','',cap('kend')),('key-delete','',cap('kdch1')),('key-insert','',cap('kich1')),('key-pageup','',cap('kpp')),('key-pagedown','',cap('knp')),('key-backtab','',cap('kcbt'))]
    keys += [(f'key-f{i}','',cap(f'kf{i}')) for i in range(1,13)]
    keys += [(f'key-f{i}','',cap(f'kf{i}')) for i in range(13,64)]
    keys += [('key-ctrl-up','',b'\x1b[1;5A'),('key-alt-a','',b'\x1ba')]
    keys += [('key-shift-'+name,'',cap(capability)) for name,capability in [('delete','kDC'),('end','kEND'),('home','kHOM'),('insert','kIC'),('left','kLFT'),('pagedown','kNXT'),('pageup','kPRV'),('right','kRIT'),('down','kind'),('up','kri')]]
    keys += [('key-backspace','\x1b[?67h',cap('kbs'))]

    for name,mode,want in keys: exact(name,mode,want)
    exact('paste','\x1b[?2004h',b'\x1b[200~paste-\xe7\x95\x8c\xf0\x9f\xa7\xaa\x1b[201~');emit('\x1b[?2004l')
    for button,code in [('left',0),('middle',1),('right',2)]:
        emit('\x1b[?1000h\x1b[?1006h');termios.tcflush(fd,termios.TCIFLUSH);stage('mouse-'+button)
        value=read_until(lambda b:b.endswith(b'm'))
        pattern=rb'\x1b\[<'+str(code).encode()+rb';(\d+);(\d+)M\x1b\[<'+str(code).encode()+rb';\1;\2m'
        assert re.fullmatch(pattern,value),(button,value);report['inputs'].append({'name':'mouse-'+button,'hex':value.hex()})
    termios.tcflush(fd,termios.TCIFLUSH);stage('wheel');value=read_until(lambda b:b.endswith(b'M'));assert re.fullmatch(rb'(\x1b\[<64;\d+;\d+M)+',value),value
    emit('\x1b[?1000l\x1b[?1006l');report['checks'].append('primary-screen SGR left/middle/right/release/wheel')
    termios.tcflush(fd,termios.TCIFLUSH);emit('\x1b[?1004h');stage('focus');value=read_until(lambda b:b'\x1b[O' in b and b.endswith(b'\x1b[I'));emit('\x1b[?1004l');report['checks'].append('focus-out/focus-in actual PTY bytes')
    reset();emit('RESIZE_READY');stage('resize');wait_release('resize');report['resized']=list(os.get_terminal_size());report['checks'].append('SIGWINCH/actual PTY geometry')
    reset()
    for i in range(180):emit(f'SCROLL_{i:03d}\r\n')
    stage('scroll');wait_release('scroll')
    for i in range(20):emit(f'NEW_{i:03d}\r\n')
    stage('scroll-new');wait_release('scroll-new');report['checks'].append('scrollback retention with incoming output')
    reset();report['status']='passed';save()
except BaseException as error:
    report['status']='failed';report['error']=repr(error);save();raise
finally:
    emit('\x1b[0m\x1b[?1000l\x1b[?1002l\x1b[?1006l\x1b[?1004l\x1b[?2004l\x1b[?1l\x1b>\x1b[r\x1b[?1049l');termios.tcsetattr(fd,termios.TCSANOW,saved)
    if report.get('status')=='passed': emit('\r\nCOMPATIBILITY_DONE\r\n');stage('done')
