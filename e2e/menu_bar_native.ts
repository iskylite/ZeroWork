/** Isolated product check. Native left/right clicks and activation are verified
 * with CUA while this runner keeps its own bundle/data/RPC alive. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,copyFile,writeFile,readFile,open,access,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'/tmp/zerowork-menu-bar-check'); await mkdir(out,{recursive:true});
const base=await realpath(await mkdtemp('/tmp/zw-menu-bar-')),rpc=join(base,'rpc'),data=join(base,'data'),bundle=join(base,'ZeroWork Menu Bar Check.app'),contents=join(bundle,'Contents'),mac=join(contents,'MacOS');
await Promise.all([rpc,data,mac].map(p=>mkdir(p,{recursive:true})));
const binary=join(mac,'zerowork');await copyFile(resolve(process.argv[3]??'zig-out/bin/zerowork'),binary);
await writeFile(join(contents,'Info.plist'),`<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.zerowork.menu-bar-check</string><key>CFBundleName</key><string>ZeroWork Menu Bar Check</string><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
const identity=execFileSync('python3',['scripts/macos_signing.py','identity'],{encoding:'utf8'}).trim();
execFileSync('/usr/bin/codesign',['--force','--deep','--sign',identity,'--identifier','com.zerowork.menu-bar-check',bundle],{stdio:'pipe'});
const log=await open(join(out,'app.log'),'w');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});
const closed=new Promise(r=>app.once('close',(code,signal)=>{console.log(JSON.stringify({exit_code:code,signal}));r(code);}));
async function count(){const text=await readFile(join(out,'app.log'),'utf8');const rows=[...text.matchAll(/MENU_BAR_BADGE (\{[^\n]+\})/g)];return rows.length?JSON.parse(rows.at(-1)![1]).count:null;}
async function click(id:string){await h.waitFor(async()=>(await h.query(id)).some(n=>n.visible!==false&&n.rect.w>0)||null);assert((await h.clickTestId(id)).ok,id);}
const flat=(nodes:any[]):any[]=>nodes.flatMap(n=>[n,...flat(n.children??[])]);
const tabs=async()=>flat(await h.query('tabs.strip')).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id??'')&&n.rect.w>0).sort((a,b)=>a.rect.x-b.rect.x);
const title=(tab:any)=>flat([tab]).find(n=>n.test_id==='tabs.title')?.text;
const native=async()=>h.request('GET','/zerowork/menu-bar') as Promise<any>;
async function parity(){return h.waitFor(async()=>{const ts=await tabs(),menu=await native();if(menu.rows?.length!==ts.length)return null;const titles=ts.map(title);if(JSON.stringify(menu.rows.map((r:any)=>r.title))!==JSON.stringify(titles))return null;for(const r of menu.rows){assert(r.has_icon);assert.equal(r.icon_width,14);assert(r.status.length>0);}return menu;});}
async function rename(tab:any,name:string){await h.clickAt(tab.rect.x+tab.rect.w/2,tab.rect.y+16,2);await click('tabs.rename.input');await h.key('a',{cmd:true});await h.type_(name);await click('tabs.rename.save');}
const checks:string[]=[];
try{
 await h.waitForServerReady();await h.resizeWindow(1000,700);
 await h.waitFor(async()=>(await count())===0||null);
 await click('workspace.empty.local');
 await h.waitFor(async()=>(await count())===1||null);checks.push('one real local session counts once');
 await h.type_("printf 'MENU_BADGE_REPEAT\\n'");await h.key('return');await h.sleep(500);
 assert.equal(await count(),1);checks.push('further output and command completion do not increase one-session count');
 await h.key('t',{cmd:true});await click('session.menu.local');
 await h.waitFor(async()=>(await count())===2||null);checks.push('two real local sessions count twice');
 let ts=await tabs();await rename(ts[0],'Menu Alpha');await parity();
 ts=await tabs();await rename(ts[1],'Menu Beta');let menu=await parity();
 assert.deepEqual(menu.rows.map((r:any)=>r.title),['Menu Alpha','Menu Beta']);
 assert.equal(menu.rows.filter((r:any)=>r.current).length,1);checks.push('native menu uses actual Tab names, 14pt icons, status and current item; rename refreshes');
 ts=await tabs();const a=ts[0].rect,b=ts[1].rect,x=a.x+a.w/2,y=a.y+16,tx=b.x+b.w-3;
 await h.mouseDown(x,y);await h.mouseMove(x+9,y);await h.mouseMove(tx,y);await h.sleep(100);await h.mouseUp(tx,y);
 await h.waitFor(async()=>title((await tabs())[0])==='Menu Beta'||null);menu=await parity();
 assert.deepEqual(menu.rows.map((r:any)=>r.title),['Menu Beta','Menu Alpha']);checks.push('native menu follows actual Tab drag reorder');
 ts=await tabs();await h.clickAt(ts[0].rect.x+ts[0].rect.w/2,ts[0].rect.y+16);
 await h.type_('exit');await h.key('return');
 menu=await h.waitFor(async()=>{const m=await native();return m.rows?.find((r:any)=>r.title==='Menu Beta')?.status==='离线'?m:null;});
 checks.push('real Local process exit refreshes native menu status');
 await writeFile(join(out,'native-menu.json'),JSON.stringify(menu,null,2));
 await h.screenshot(join(out,'native-window.png'));
 await writeFile(join(out,'state.json'),JSON.stringify({bundle,binary,pid:app.pid,rpc,data,checks},null,2));
 console.log(JSON.stringify({status:process.env.ZEROWORK_E2E_NATIVE_HOLD==='1'?'ready_for_native_clicks':'automated_checks_passed',bundle,pid:app.pid,output:out}));
 // CUA controls the real status item, then creates stop through the test caller.
 const deadline=Date.now()+600000;
 while(process.env.ZEROWORK_E2E_NATIVE_HOLD==='1'&&app.exitCode===null&&Date.now()<deadline){try{await access(join(out,'stop'));break;}catch{}await h.sleep(500);}
 await writeFile(join(out,'report.json'),JSON.stringify({checks,last_count:await count(),exit_code:app.exitCode,bundle,native_clicks:'requires CUA or manual acceptance'},null,2));
}finally{if(app.exitCode===null)app.kill('SIGTERM');await closed;await log.close();}
