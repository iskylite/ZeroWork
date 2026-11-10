#!/usr/bin/env python3
"""Isolated native regression for AI group sending, live effort and Shift+Return.

zig build -Dtest-mode=true --prefix /private/tmp/zw-ai-session-fixes
python3 e2e/ai_session_controls_native.py --prefix /private/tmp/zw-ai-session-fixes --out /private/tmp/zw-ai-session-evidence

Uses a loopback provider and an isolated Local session. No saved user data,
remote connection, real model account or shell business command is used.
"""
import argparse, http.server, json, os, pathlib, shutil, subprocess, tempfile, threading, time, uuid
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--prefix',required=True,help='Output prefix of the explicit test-mode build')
parser.add_argument('--out',required=True,help='Evidence directory')
args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parent.parent
prefix=pathlib.Path(args.prefix).resolve()
iso=pathlib.Path(tempfile.mkdtemp(prefix='zerowork-ai-session-check-')).resolve()
out=pathlib.Path(args.out).resolve();out.mkdir(parents=True,exist_ok=True)
rpc_dir=iso/'rpc';data=iso/'data';zdot=iso/'zdot'
for d in [rpc_dir,data,zdot]:d.mkdir()
(zdot/'.zshrc').write_text("bindkey -e\nPS1='session-check%# '\n")
requests=[];allow_tool=threading.Event();group_started=threading.Event();failures=[]
class Provider(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  self.send_response(200);self.end_headers();self.wfile.write(b'{"data":[{"id":"session-check"}]}')
 def do_POST(self):
  try:
   body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
   self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
   def emit(delta):self.wfile.write(('data: '+json.dumps({'choices':[{'index':0,'delta':delta}]})+'\n\n').encode());self.wfile.flush()
   if not body.get('tools'):emit({'content':'会话测试'})
   else:
    requests.append(body)
    users=[m.get('content','') for m in body['messages'] if m['role']=='user']
    is_group=any(isinstance(t,str) and 'GROUP_REASONING_TEST' in t for t in users)
    results=[m for m in body['messages'] if m['role']=='tool' and m.get('tool_call_id')=='reasoning-probe']
    if is_group and not results:
     emit({'content':'RUNNING_CHECK'});group_started.set()
     if not allow_tool.wait(30):raise RuntimeError('reasoning UI action timed out')
     emit({'tool_calls':[{'index':0,'id':'reasoning-probe','type':'function','function':{'name':'host__get_ucurrent_ucontext','arguments':'{}'}}]})
    else:emit({'content':'GROUP_REASONING_DONE' if is_group else 'MULTILINE_DONE'})
   self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
  except Exception as e:failures.append(repr(e))
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Provider);threading.Thread(target=server.serve_forever,daemon=True).start()
(data/'config.toml').write_text(f'''[meta]
config_revision=1
[updates]
auto_check=false
[ui]
theme="dark"
[ai]
default_provider="session-check"
permission_mode="confirm"
[[ai.providers]]
id="session-check"
kind="openai_compat"
endpoint="http://127.0.0.1:{server.server_port}/v1/chat/completions"
enabled=true
[[ai.providers.models]]
name="session-check"
context_window=200000
default=true
reasoning=true
efforts=["low","medium","high"]
''')
log=(iso/'app.log').open('w+')
app=subprocess.Popen([str(prefix/'bin/zerowork')],cwd=root,env={**os.environ,'ZENIT_E2E_FILE_RPC_DIR':str(rpc_dir),'ZENIT_E2E_BACKGROUND':'1','ZENIT_E2E_ISOLATE_POINTER':'1','ZEROWORK_DATA_DIR':str(data),'ZEROWORK_AUTOCONNECT':'0','ZDOTDIR':str(zdot)},stdout=log,stderr=log)
def rpc(path,body=None,method='POST',timeout=15):
 rid=str(uuid.uuid4());req=rpc_dir/f'req-{rid}.json';tmp=req.with_suffix('.tmp');tmp.write_text(json.dumps({'method':method,'path':path,'body_json':json.dumps(body,ensure_ascii=False) if body else ''},ensure_ascii=False));tmp.rename(req);res=rpc_dir/f'res-{rid}.json';deadline=time.monotonic()+timeout
 while time.monotonic()<deadline:
  if res.exists():
   result=json.loads(res.read_text());req.unlink(missing_ok=True);res.unlink()
   if isinstance(result,dict) and result.get('error'):raise RuntimeError((path,result))
   return result
  if app.poll() is not None:raise RuntimeError(('app exited',app.returncode))
  time.sleep(.03)
 raise TimeoutError(path)
def query(id):return rpc('/query',{'test_id':id})
def shown(n):return n.get('visible',True) and not n.get('hidden',False) and n.get('effective_opacity',1)>0 and n['rect']['w']>0 and n['rect']['h']>0
def visible(id,timeout=15):
 deadline=time.monotonic()+timeout
 while time.monotonic()<deadline:
  nodes=[n for n in query(id) if shown(n)]
  if nodes:return nodes[0]
  time.sleep(.08)
 raise TimeoutError(id)
def click(id):
 n=visible(id);r=n['rect'];assert rpc('/click',{'x':r['x']+r['w']/2,'y':r['y']+r['h']/2})['ok'];time.sleep(.1)
def key(name,**mods):assert rpc('/key_down',{'key':name,**mods})['ok']
def text(s):assert rpc('/text_input',{'text':s})['ok']
def wait(predicate,timeout=20):
 deadline=time.monotonic()+timeout
 while time.monotonic()<deadline:
  if predicate():return
  time.sleep(.08)
 raise TimeoutError('condition')
def idle():wait(lambda:not any(shown(n) for n in query('ai.stop')))
def shot(name):assert rpc('/screenshot',{'path':str(out/name)})['ok']
report={'status':'running'}
try:
 assert rpc('/health',method='GET',timeout=25)['status']=='ok'
 rpc('/resize',{'width':1440,'height':1000})
 print('phase: native app ready',flush=True)
 click('workspace.empty.local');visible('terminal.surface');time.sleep(1)
 click('toolbar.ai');click('ai.prompt');text('FIRST_LINE');key('return',shift=True);text('第二行')
 assert rpc('/input_state',{'test_id':'ai.prompt'})['buffer']=='FIRST_LINE\n第二行'
 assert len(requests)==0
 shot('multiline-composer.png');key('return')
 wait(lambda:len(requests)>=1);idle()
 assert requests[0]['messages'][-1]['content']=='FIRST_LINE\n第二行'
 print('phase: multiline submit passed',flush=True)
 report['multiline']='Shift+Return inserts one newline without submitting; Return sends both lines'
 click('ai.collapse');click('terminal.input');text('@');visible('terminal.commands');text('grp SessionFix');key('right');time.sleep(.1);key('return');visible('groups.workspace')
 click('toolbar.ai');click('ai.prompt');text('GROUP_REASONING_TEST');key('return')
 print('phase: group message submitted',flush=True)
 wait(group_started.is_set)
 click('ai.composer.model');click('ai.effort.slider.track');key('end')
 time.sleep(.3)
 effort=visible('ai.effort.value')
 report['effort_label']=effort.get('text');shot('group-reasoning-change.png')
 key('escape');allow_tool.set()
 wait(lambda:any(any(m.get('tool_call_id')=='reasoning-probe' for m in r['messages']) for r in requests))
 idle();assert app.poll() is None
 group=[r for r in requests if any(isinstance(m.get('content'),str) and 'GROUP_REASONING_TEST' in m['content'] for m in r['messages'])]
 assert len(group)==2,len(group)
 assert group[0].get('reasoning_effort')=='low',group[0].get('reasoning_effort')
 assert group[1].get('reasoning_effort')=='high',group[1].get('reasoning_effort')
 report['group']='Converted one Local session to a group and sent with Return; read-only tool round completed without a crash'
 report['live_reasoning']=[r.get('reasoning_effort') for r in group]
 report['tool_counts']=[len(r['tools']) for r in group]
 time.sleep(.4)
 shot('group-message-completed.png')
 assert not failures,failures
 report['status']='passed'
except Exception:
 report['status']='failed'
 try:shot('failure.png');(out/'failure-tree.json').write_text(json.dumps(rpc('/tree',method='GET'),ensure_ascii=False))
 except Exception:pass
 raise
finally:
 allow_tool.set()
 try:
  if app.poll() is None:
   report['normal_quit_requested']=rpc('/zerowork/windows',{'action':'quit'}).get('ok',False)
   deadline=time.monotonic()+15
   while app.poll() is None and time.monotonic()<deadline:
    for test_id in ['ai.close.confirmation.confirm','session.close.accept','groups.close.accept']:
     if app.poll() is not None:break
     nodes=[n for n in query(test_id) if shown(n)]
     if nodes:
      r=nodes[0]['rect'];rpc('/click',{'x':r['x']+r['w']/2,'y':r['y']+r['h']/2})
    time.sleep(.1)
  app.wait(timeout=1)
 except Exception as error:
  try:app.wait(timeout=15)
  except subprocess.TimeoutExpired:
   report['cleanup_error']=repr(error)
   app.terminate();app.wait(timeout=5)
 log.flush();log.seek(0);logs=log.read();log.close();(out/'app.log').write_text(logs)
 (out/'report.json').write_text(json.dumps({**report,'exit_code':app.returncode,'failures':failures},ensure_ascii=False,indent=2))
 server.shutdown();shutil.rmtree(iso)
 if app.returncode!=0:report['status']='failed'
 (out/'report.json').write_text(json.dumps({**report,'exit_code':app.returncode,'failures':failures},ensure_ascii=False,indent=2))

assert app.returncode==0, f'Native application did not quit normally: {app.returncode}'
print(json.dumps({**report,'exit_code':app.returncode},ensure_ascii=False),flush=True)
