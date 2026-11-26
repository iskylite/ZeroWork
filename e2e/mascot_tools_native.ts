/** A real, isolated app window: the pointer moves through trigger, gap and panel. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, open, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
const root = await realpath(await mkdtemp('/tmp/zw-native-mascot-'));
const data = join(root, 'data'), rpc = join(root, 'rpc');
await mkdir(data); await mkdir(rpc);
await writeFile(join(root,'.zshrc'),"bindkey -e\nPS1='workspace%# '\n");
const left = process.argv.includes('--light');
const [w,hgt] = left ? [860,480] : [1440,900];
await writeFile(join(data,'config.toml'), `[meta]\nconfig_revision=1\n[ui]\ntheme="${left?'reference-light':'dark'}"\nmascot_anchor_x=${left?'0.0':'1.0'}\nmascot_anchor_y=${left?'0.0':'1.0'}\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(root, 'app.log'),'w');
const app = spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env, ZDOTDIR:root, ZEROWORK_DATA_DIR:data, OPENAI_API_KEY:'', ANTHROPIC_API_KEY:'', ZEROWORK_AUTOCONNECT:'0', ZENIT_E2E_BACKGROUND:'1', ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const exited = once(app,'close');
const shown = (n:any) => n && !n.hidden && n.visible !== false && (n.effective_opacity ?? n.opacity ?? 1) > 0.01 && n.rect.w > 0 && n.rect.h > 0;
const nodes = async (id:string) => (await h.query(id)).filter(shown);
let step = '';
const visible = async (id:string) => h.waitFor(async()=> (await nodes(id))[0] ?? null,3500);
const hidden = async (id:string) => h.waitFor(async()=> !(await nodes(id)).length || null,3500);
const rect = async (id:string) => (await visible(id)).rect;
const center = (r:any):[number,number] => [r.x+r.w/2,r.y+r.h/2];
const hover = async (id:string) => { const [x,y] = center(await rect(id)); assert((await h.mouseMove(x,y)).ok); };
const pause = (ms:number) => h.sleep(ms);
const expectAnchor = async (r:any) => { const items = await nodes('workspace.mascot.body'); assert.equal(items.length,1); for(const k of ['x','y','w','h']) assert(Math.abs(items[0].rect[k]-r[k])<1,'mascot anchor: '+k); };
const outside = async () => h.mouseMove(left?w-18:12,left?hgt-22:14);
const list = (n:any):any[] => [n,...(n.children??[]).flatMap(list)];
const inside = (r:any,b:any) => r.x>=b.x-1 && r.y>=b.y-1 && r.x+r.w<=b.x+b.w+1 && r.y+r.h<=b.y+b.h+1;
try {
  await h.waitForServerReady(30000); await h.resizeWindow(w,hgt);
  assert((await h.clickTestId('workspace.empty.local')).ok);
  await visible('terminal.surface'); await outside();
  step='idle'; await hidden('workspace.mascot.tools');
  const badge = await rect('workspace.mascot.body');
  const canvas = {x:0,y:0,w,h:hgt}; // Floating panels belong to the whole native window, including sidebar gutters.
  step='expand'; await hover('workspace.mascot.body'); await visible('workspace.mascot.history'); await pause(320);
  const slots = await Promise.all(['transfer','forward','history'].map(s=>rect('workspace.mascot.'+s)));
  for(let i=0;i<slots.length;i++){const [x,y]=center(slots[i]); assert(Math.abs(y-center(badge)[1])<1,'slots must align on one axis');assert(left?x>center(badge)[0]:x<center(badge)[0],'strip points into workspace');if(i>0)assert(Math.abs(x-center(slots[i-1])[0])>=28,'slots never overlap');}
  await expectAnchor(badge);
  step='transfer hover'; await hover('workspace.mascot.transfer');
  const panel=await rect('transfer.manager');
  assert(inside(panel,canvas),JSON.stringify({panel,canvas})); assert(left? panel.y>=slots[0].y+slots[0].h : panel.y+panel.h<=slots[0].y,'transfer contents must not cover the trigger');
  assert((await nodes('transfer.header.title')).some((n:any)=>n.text==='传输任务'));
  const [manager]=await nodes('transfer.manager');
  assert(list(manager).some(n=>n.test_id==='transfer.header'),'real manager hierarchy'); assert(!list(manager).some(n=>n.rect.w===32&&n.rect.h===3),'non-draggable panel must not show a handle');
  step='panel hover bridge'; const px=center(slots[0])[0], near=left?panel.y:panel.y+panel.h;
  assert((await h.mouseMove(px,near+(left?-2:2))).ok);
  await pause(75); assert((await h.mouseMove(Math.min(panel.x+panel.w-10,Math.max(panel.x+10,px)),near+(left?12:-12))).ok);
  await pause(380); await visible('transfer.manager');
  if(process.env.ZW_MASCOT_CAPTURE) await h.screenshot(process.env.ZW_MASCOT_CAPTURE);
  step='hover leave'; await outside(); await hidden('transfer.manager'); await hidden('workspace.mascot.tools'); await expectAnchor(badge);
  step='forward hover'; await hover('workspace.mascot.body'); await visible('workspace.mascot.forward'); await pause(280); await hover('workspace.mascot.forward');
  const fm=await rect('workspace.mascot.forward.menu');assert(inside(fm,{x:0,y:0,w,h:hgt}),'forward preview within window');
  step='forward dismissal'; await outside();await hidden('workspace.mascot.forward.menu');await hidden('workspace.mascot.tools');
  step='history hover'; await hover('workspace.mascot.body');await visible('workspace.mascot.history');await pause(280);await hover('workspace.mascot.history');const hp=await rect('terminal.command-history');assert(inside(hp,canvas),'history preview within workspace');
  await outside();await hidden('terminal.command-history');await hidden('workspace.mascot.tools');
  step='click pin'; await hover('workspace.mascot.body'); await visible('workspace.mascot.transfer');await pause(280);await hover('workspace.mascot.transfer');await visible('transfer.manager');
  const [tx,ty]=center(await rect('workspace.mascot.transfer'));assert((await h.clickAt(tx,ty)).ok);await outside();await pause(450);await visible('transfer.manager');
  assert((await h.clickTestId('transfer.window.close')).ok);await hidden('transfer.manager');await outside();await hidden('workspace.mascot.tools');await expectAnchor(badge);
  step='badge click open / close at the same anchor';
  const [bx,by] = center(badge);
  await h.clickAt(bx,by); await visible('workspace.mascot.tools'); await outside(); await pause(450); await visible('workspace.mascot.tools');
  await h.clickAt(bx,by); await hidden('workspace.mascot.tools'); await expectAnchor(badge);
  if (process.argv.includes('--group')) {
    // Use the public trusted @grp action, not a direct dispatcher/DB mutation.
    await outside(); step='create local group';
    const [ex,ey]=center(await rect('terminal.surface')); await h.clickAt(ex,ey);
    await pause(1100); await h.type_('@');await visible('terminal.commands'); await h.type_('grp MascotFixture');await h.key('right');await hidden('terminal.commands');await h.key('return'); await visible('groups.workspace');
    await hover('workspace.mascot.body');await visible('workspace.mascot.broadcast');await pause(280);await hover('workspace.mascot.broadcast');
    step='group hover is read-only';const summary=await visible('workspace.mascot.preview');const labels=list(summary).map(n=>n.text??'').join(' ');
    assert(labels.includes('MascotFixture') && labels.includes('广播未开启'),labels);await hidden('group.broadcast.card');
    await outside();await hidden('workspace.mascot.preview');await hidden('group.broadcast.card');
    console.log('native group broadcast hover: real group name and state; no approval requested and no broadcast started');
  }
  if (process.argv.includes('--web')) {
    // A local document, no real BMC/remote service or stored account.
    const http=createServer((_,r)=>{r.writeHead(200,{'Content-Type':'text/html'});r.end('<title>Loopback</title><p>Workspace test</p>');});
    await new Promise<void>(done=>http.listen(0,'127.0.0.1',done));
    try {
      const fill=async(id:string,text:string)=>{assert((await h.clickTestId(id)).ok);await h.key('a',{cmd:true});await h.type_(text);};
      const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok);};
      step='create loopback Web tab';await click('toolbar.new_session');await click('session.menu.new_web');await visible('web.editor.name');await fill('web.editor.name','Loopback');
      await click('web.editor.mode.preset');await fill('web.editor.url','http://127.0.0.1:'+http.address().port+'/');await click('web.editor.next');await visible('wizard.access.direct');await click('web.editor.next');await visible('web.editor.review');await click('web.editor.open');await visible('web.document');
      step='Web hover read-only';await outside();await hover('workspace.mascot.body');await visible('workspace.mascot.chain');await pause(280);await hover('workspace.mascot.chain');
      const summary=await visible('workspace.mascot.preview');const labels=list(summary).map(n=>n.text??'').join(' ');assert(labels.includes('通信链路')&&labels.includes('Loopback'),labels);
      const gr=summary.rect;assert(inside(gr,canvas),'link summary is fully visible');await h.mouseMove(...center(gr));await pause(400);await visible('workspace.mascot.preview');
      await outside();await hidden('workspace.mascot.preview');await hidden('workspace.mascot.tools');
      step='Web direct forwarding from current owner, without opening details first';
      await hover('workspace.mascot.body');await visible('workspace.mascot.forward');await pause(280);await hover('workspace.mascot.forward');await visible('workspace.mascot.forward.menu');
      const direct=await visible('workspace.mascot.forward.session');assert(list(direct).some(n=>n.text==='直接连接'),'current renderer, not old SSH popup');
      await click('workspace.mascot.forward.session');const info=await visible('socks.info');assert(list(info).some(n=>n.text==='直接连接'));await click('socks.info.close');
      console.log('native embedded Web: live connection status, readable above the native web view, auto-close');
    } finally { await new Promise<void>(done=>{http.close(()=>done());http.closeAllConnections();}); }
  }
  console.log(`native mascot OK: ${left?'light / top-left':'dark / bottom-right'} ${w}×${hgt}; stationary strip, real transfer/forward/history, hover bridge, auto-close, click pin, no fake handle`);
} catch (err) {
  console.error('mascot native failed at '+step,await readFile(join(root,'app.log'),'utf8').then(s=>s.slice(-1300)));
  for(const id of ['workspace.mascot.body','workspace.mascot.tools','workspace.mascot.transfer','transfer.manager','workspace.mascot.forward.menu']) try { console.error(id,(await nodes(id)).map((n:any)=>n.rect)); } catch {}
  throw err;
} finally {
  app.kill('SIGTERM');await exited.catch(()=>{});await log.close();await rm(root,{recursive:true,force:true});
}
