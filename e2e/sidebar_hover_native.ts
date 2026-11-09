import {openSidebarHostMenu} from './sidebar_host_menu.ts';
/** Host hover exposes only connect: native hover, routes and keyboard dispatch.
 * node e2e/sidebar_hover_native.ts OUTPUT [BINARY]
 * Owned /private/tmp data and synthetic public Harness input only.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,writeFile,realpath,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
const out=resolve(process.argv[2]??'/tmp/zerowork-followup-sidebar/native'),binary=resolve(process.argv[3]??'zig-out/bin/zerowork');await mkdir(out,{recursive:true});
const base=await realpath(await mkdtemp('/private/tmp/zerowork-sidebar-hover-'));let data=join(base,'data');await mkdir(data);
const mode=process.argv[4]??'full';assert(['full','minimum','actions','double','status'].includes(mode));
const themes=process.env.ZW_SIDEBAR_THEMES?.split(',')??['dark','light','sauber'];
const names=['X40-AI01','production-data-platform-primary-区域-01','files'];
let hosts='[registry]\nschema_version=2\nrevision=1\nnext_connection_id=4\nnext_group_id=1\n';
for(let i=0;i<3;i++)hosts+=`[[hosts]]\nconnection_id=${i+1}\nrevision=1\nprotocol="${i===2?'sftp':'ssh'}"\nauth_mode="password"\nname="${names[i]}"\nhost="127.0.0.1"\nport=1\nuser="fixture"\nroute=${i===1?'[1]':i===2?'[1,2]':'[]'}\n`;
await writeFile(join(data,'hosts.toml'),hosts);
const report:any={status:'running',mode,binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),themes:[],checks:[],captures:[],limits:['Actual native Metal rendering; public synthetic keyboard/pointer only. Physical keyboard/IME and VoiceOver were not tested.','Connection click uses a runner-owned loopback target on closed port 1 to prove dispatch; SSH authentication is covered separately.']};
let child:any,ended:Promise<unknown>,log:any;
const shown=(n:any)=>n&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const flat=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flat)]:[];
const label=(n:any)=>flat(n).map(v=>v.text??'').join('');
const node=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const row=async(index:number)=>(await h.query('sidebar.host')).filter(shown).find(n=>label(n).includes(names[index]))!;
const part=(r:any,id:string):any=>{if(!shown(r))return;return r.test_id===id?r:(r.children??[]).map((n:any)=>part(n,id)).find(Boolean);};
async function clickNode(n:any){assert(shown(n));assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await h.sleep(90);}
async function click(id:string){await clickNode(await node(id));}
async function hover(index:number){const r=await row(index);assert(r);await h.mouseMove(r.rect.x+12,r.rect.y+r.rect.h/2);await h.sleep(100);return row(index);}
async function sessionCount(){return (await h.query('tabs.strip')).flatMap(flat).filter(n=>shown(n)&&/^tabs\.tab\.\d+$/.test(n.test_id??'')).length;}
async function keyboardAction(id:string){let focus=await h.focused();for(let i=0;i<40&&focus.test_id!==id;i++){await h.key('tab');await h.sleep(30);focus=await h.focused();}assert.equal(focus.test_id,id,'Tab reaches the actual shortcut before activation');}
async function clean(){assert(!(await h.query('connection.progress')).some(shown),'no connection overlay may cover a menu acceptance');assert(!(await h.query('plugin.challenge.modal')).some(shown),'no challenge may cover a menu acceptance');}
async function action(index:number,id:string){await clean();const r=await hover(index);await clickNode(part(r,'sidebar.host.'+id));}
async function cap(theme:string,state:string){const name=theme+'-'+state;await h.sleep(100);const ids=['workspace.sidebar','sidebar.host','sidebar.host.name','sidebar.host.hops','sidebar.host.connect','sidebar.host.copy','sidebar.host.edit','context.menu','wizard.name','connection.progress'];const snapshot=Object.fromEntries(await Promise.all(ids.map(async id=>[id,await h.query(id)])));await writeFile(join(out,name+'.json'),JSON.stringify(snapshot,null,2));assert((await h.screenshot(join(out,name+'.png'))).ok);report.captures.push(name);}
function identity(r:any){const n=part(r,'sidebar.host.name');assert(n);return n.rect;}
const near=(a:number,b:number,s:string)=>assert(Math.abs(a-b)<.25,`${s}: ${a} vs ${b}`);
async function stable(before:any[],state:string){const rows=await Promise.all(names.map((_,i)=>row(i)));for(let i=0;i<rows.length;i++){assert(rows[i],names[i]);const r=rows[i];near(r.rect.h,36,state+' row height');const n=identity(r);near(n.x,before[i].x,state+' name x');assert(n.w>0,'identity retains visible space');const route=part(r,'sidebar.host.hops');const connect=part(r,'sidebar.host.connect');assert(route,'route badge remains visible');assert.equal(route.text,String(i),'route count matches fixture');assert(!flat(r).some(n=>['sidebar.host.copy','sidebar.host.edit'].includes(n.test_id)),'copy and edit shortcuts are absent');if(connect){near(connect.rect.w,24,'connect hit width');assert(connect.rect.x>=n.x+n.w,'connect never overlaps identity');assert(connect.rect.x+24<=r.rect.x+r.rect.w-4.9,'connect remains within row');assert(route.rect.x+route.rect.w<=connect.rect.x,'route remains beside connect');}}}
async function launch(theme:string){data=join(base,'data-'+theme);await mkdir(data);await writeFile(join(data,'hosts.toml'),hosts);const rpc=join(base,'rpc-'+theme);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n`);log=await open(join(out,theme+'.log'),'w');child=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});ended=new Promise(r=>child.once('close',r));await h.waitForServerReady(20000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),child.pid);await h.resizeWindow(1280,720);await node('sidebar.host');}
async function stop(){if(child?.exitCode===null){child.kill('SIGTERM');await ended;}if(child)await cleanupOwnedBridgeDirectories(child.pid);await log?.close();}
try{
 for(const theme of themes){
  if(mode==='actions'&&!['dark','light','sauber'].includes(theme)||mode==='double'&&theme!=='dark')continue;
  await launch(theme);
  if(mode==='status'){
   const sessions=await sessionCount();
   await hover(0);
   for(const area of ['icon','count','gap']){
    const r=await row(0),route=part(r,'sidebar.host.route'),count=part(r,'sidebar.host.hops'),connect=part(r,'sidebar.host.connect');
    assert(route&&count&&connect);
    const x=area==='icon'?route.rect.x+4:area==='count'?count.rect.x+count.rect.w/2:(route.rect.x+route.rect.w+connect.rect.x)/2;
    await h.clickAt(x,route.rect.y+route.rect.h/2);await h.sleep(120);
    assert.equal(await sessionCount(),sessions,area+' status click must not create a session');
    await clean();
   }
   await cap(theme,'status-clicks-no-connection');
   await action(0,'connect');await h.waitFor(async()=>await sessionCount()===sessions+1||null);
   await h.sleep(200);assert.equal(await sessionCount(),sessions+1,'connect opens exactly one session');
   await cap(theme,'status-then-connect');
   report.checks.push(theme+': route icon, count and gap create no session; explicit connect creates exactly one');
   report.themes.push({theme});await stop();continue;
  }
  if(mode==='double'){const r=await row(0);await h.clickAt(r.rect.x+50,r.rect.y+r.rect.h/2,2);await h.sleep(400);assert.equal(await sessionCount(),1,'a native double click creates exactly one host session');await h.sleep(300);assert.equal(await sessionCount(),1);await cap(theme,'double-click-single-session');report.themes.push({theme,sessions:1});await stop();console.log('PASS double-click sidebar',theme);continue;}
  if(mode==='minimum'){const grip=await node('sidebar.resize');await h.mouseDown(grip.rect.x+grip.rect.w/2,grip.rect.y+60);await h.mouseMove(grip.rect.x-120,grip.rect.y+60);await h.mouseUp(grip.rect.x-120,grip.rect.y+60);await h.sleep(120);near((await node('workspace.sidebar')).rect.w,220,'minimum sidebar');}
  await h.mouseMove(700,400);await h.sleep(100);const before=await Promise.all(names.map(async(_,i)=>identity(await row(i))));assert.deepEqual(await Promise.all(names.map(async(_,i)=>part(await row(i),'sidebar.host.hops')?.text)),['0','1','2'],'all route badges visible at rest');if(mode!=='minimum')near((await node('workspace.sidebar')).rect.w,238,'sidebar width');await cap(theme,'idle');
  await hover(0);await stable(before,'short hover');await cap(theme,'short-hover');await hover(1);await stable(before,'long hover');await cap(theme,'long-hover');
  const long=await row(1),name=part(long,'sidebar.host.name');await h.mouseMove(name.rect.x+Math.min(30,name.rect.w/2),name.rect.y+name.rect.h/2);await h.sleep(650);await cap(theme,'identity-tooltip');
  await h.resizeWindow(860,480);await hover(1);await stable(before,'compact hover');await cap(theme,'compact-hover');
  if(['dark','light','sauber'].includes(theme)){
   const sessions=await sessionCount();await hover(0);await keyboardAction('sidebar.host.connect');
   await openSidebarHostMenu(await row(0));await node('context.menu.new_tab');await h.key('escape');await action(0,'connect');await h.waitFor(async()=>await sessionCount()===sessions+1||null);await cap(theme,'connect-dispatched');report.checks.push(theme+': independent connect shortcut creates exactly one target session');
  }
  report.themes.push({theme,nameWidths:before.map(r=>r.w),states:['idle','short-hover','long-hover','identity-tooltip','compact-hover']});await stop();console.log('PASS sidebar',theme);
 }
 report.status='passed';if(mode!=='status')report.checks.push('All route badges remain visible, copy/edit shortcuts are absent and the full identity tooltip is retained.');
}catch(error){report.status='failed';report.error=String(error);console.error(error);await h.screenshot(join(out,'failure.png')).catch(()=>{});}finally{await stop().catch(()=>{});await rm(base,{recursive:true,force:true});report.cleanup={isolated_removed:true};await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
if(report.status!=='passed')process.exitCode=1;
