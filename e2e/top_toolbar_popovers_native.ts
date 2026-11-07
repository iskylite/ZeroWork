/** Top toolbar click-only popovers, tab context arbitration and forwarding body.
 * Disposable configuration and owned loopback SSH; no saved hosts are used. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,realpath,readFile,writeFile,open,rm} from 'node:fs/promises';
import {resolve,join,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);
const h=await import(pathToFileURL(resolve(dirname(binary),'../share/zenit/harness/client.ts')).href);
const iso=await realpath(await mkdtemp('/tmp/zw-toolbar-popovers-')),data=join(iso,'data'),rpc=join(iso,'rpc');
for(const dir of [out,data,rpc])await mkdir(dir,{recursive:true});
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w'),peerLog=await open(join(out,'peer.log'),'w');
const peer=spawn(process.env.ZW_TEST_PYTHON??'python3',['e2e/builtin_records_ssh_peer.py','--out',join(out,'peer')],{stdio:['ignore',peerLog.fd,peerLog.fd]});
const peerEnded=new Promise(r=>peer.once('close',r));
let app:any,ended:Promise<any>;
const report:any={binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[],captures:[],geometry:[],limits:["This UI fixture uses in-memory credentials; no Keychain access or credential acceptance is tested."]};
const shown=(n:any)=>n&&n.rect?.w>0&&n.rect.h>0&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0.01;
const flat=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(x=>x.text??'').join(' ');
const nodes=async(id:string)=>(await h.query(id)).filter(shown);
const visible=(id:string)=>h.waitFor(async()=>(await nodes(id))[0]??null,12000);
const hidden=(id:string)=>h.waitFor(async()=>!(await nodes(id)).length||null,6000);
async function click(id:string){const n=await visible(id);await h.mouseMove(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await h.sleep(150);}
async function capture(name:string){assert((await h.screenshot(join(out,name+'.png'))).ok);report.captures.push(name);}
async function expand(){if((await nodes('toolbar.expand')).length)await click('toolbar.expand');}
const panels=['connection.details','socks.info','status.theme'];
async function assertNone(){for(const id of panels)assert.equal((await nodes(id)).length,0,id+' remains closed');}
try{
 const ready=await h.waitFor(async()=>{assert(peer.exitCode===null,'SSH peer stays alive');try{return JSON.parse(await readFile(join(out,'peer/ready.json'),'utf8'))}catch{return null}},15000);
 await writeFile(join(data,'known_hosts'),ready.known_host);
 await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="light"\n');
 await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Toolbar SSH"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\nsocks_enabled=true\nsocks_port=1081\nsocks_bind="127.0.0.1"\nsocks_auto_start=false\n`);
 app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});ended=new Promise(r=>app.once('close',r));
 await Promise.race([h.waitForServerReady(60000),ended!.then(()=>{throw new Error('Native App exited before readiness');})]);await h.resizeWindow(1440,900);
 const host=await visible('sidebar.host');await h.mouseMove(host.rect.x+100,host.rect.y+host.rect.h/2);await click('sidebar.host.connect');
 await h.waitFor(async()=>{
  const secret=(await nodes('plugin.challenge.secret'))[0];
  if(secret){await click('plugin.challenge.secret');await h.type_(ready.password);await click('plugin.challenge.submit');}
  return text((await nodes('workspace.pane'))[0]).includes('sshrecords')||null;
 },30000);
 await h.mouseMove(700,300);await h.sleep(400);
 // Use the tab title, away from the overlaid session-identity icon and close.
 const tab=flat(await visible('tabs.strip')).find(n=>/^tabs\.tab\.\d+$/.test(n.test_id??''));assert(tab);
 if(!process.argv.includes("--session-only")){
 const point={x:tab.rect.x+tab.rect.w/2,y:tab.rect.y+tab.rect.h/2};
 await h.mouseMove(point.x,point.y);await visible('tabs.tooltip');
 for(const route of ['/mouse_down','/mouse_up'])assert((await h.request('POST',route,{...point,button:'right'})).ok);
 await visible('context.menu');await hidden('tabs.tooltip');await capture('tab-context-no-hover');
 await h.key('escape');await hidden('context.menu');await h.sleep(650);await hidden('tabs.tooltip');
 await h.mouseMove(700,300);await h.mouseMove(point.x,point.y);await visible('tabs.tooltip');await h.mouseMove(700,300);await hidden('tabs.tooltip');
 // Right-click before the hover delay expires must also cancel the pending hint.
 await h.mouseMove(point.x,point.y);
 for(const route of ['/mouse_down','/mouse_up'])await h.request('POST',route,{...point,button:'right'});
 await visible('context.menu');await h.sleep(650);await hidden('tabs.tooltip');await h.key('escape');await h.mouseMove(700,300);
 report.checks.push('Tab right-click closes visible and pending hints; Escape does not revive a stationary hint; leave/re-enter restores hover.');
 for(const [width,height]of [[1440,900],[860,480]]){
  await h.resizeWindow(width,height);await h.mouseMove(500,300);await h.sleep(180);await expand();
  // All nine controls use clicks for actions; pointer movement opens no panel.
  for(const groupId of ['connection','history','application']){
   await expand();const group=await visible('toolbar.group.'+groupId);
   for(const button of (group.children??[]).filter(shown)){await h.mouseMove(button.rect.x+button.rect.w/2,button.rect.y+button.rect.h/2);await h.sleep(500);await assertNone();}
  }
  report.checks.push(`${width}×${height}: hovering all nine right-toolbar controls opens no functional panel.`);
  for(const [triggerId,panelId]of [['status.connection.chain','connection.details'],['status.connection.forward','socks.info'],['status.connection.theme','status.theme']]){
   await expand();await click(triggerId);await h.sleep(300);const panel=await visible(panelId),trigger=await visible(triggerId),r=panel.rect;
   assert(Math.abs(r.y-(trigger.rect.y+trigger.rect.h+6))<=1,panelId+' is below full trigger');
   assert(r.x>=7.9&&r.x+r.w<=width-7.9&&r.y+r.h<=height-7.9,panelId+' stays inside viewport');
   for(const other of panels)if(other!==panelId)assert.equal((await nodes(other)).length,0,'switch closes '+other);
   if(panelId==='socks.info'){
    const address=await visible('socks.info.address');
    assert(text(panel).includes('127.0.0.1:1081'));assert(text(panel).includes('下载'));assert(text(panel).includes('活跃连接'));
    assert(address.rect.y>r.y+35&&address.rect.y+address.rect.h<r.y+r.h-45,'forwarding details are between header and actions');
   }
   await capture(panelId.replaceAll('.','-')+'-'+width);report.geometry.push({width,height,triggerId,trigger:trigger.rect,panelId,panel:r});
  }
  // Clicking the same trigger closes; moving away leaves a clicked panel open.
  await click('status.connection.theme');await hidden('status.theme');await expand();await click('status.connection.forward');await visible('socks.info');await h.mouseMove(500,300);await h.sleep(300);await visible('socks.info');await click('socks.info.close');await hidden('socks.info');
  report.checks.push(`${width}×${height}: chain → forwarding → theme are exclusive, below triggers and bounded; forwarding body retained; repeat click and X close.`);
 }
 }
 for(const [width,height]of [[1440,900],[860,480]]){
  await h.resizeWindow(width,height);await h.mouseMove(500,300);await h.sleep(200);
  const trigger=await visible('status.connection.identity');
  await h.mouseMove(trigger.rect.x+trigger.rect.w/2,trigger.rect.y+trigger.rect.h/2);await h.sleep(250);
  const panel=await visible('status.connection'),r=panel.rect;
  assert.equal(r.w,380);assert.equal(r.h,300);
  assert(Math.abs(r.y-trigger.rect.y-trigger.rect.h-6)<=1);
  const card=(await nodes(tab.test_id))[0];assert(card);
  const expectedX=card.rect.x+r.w<=width-8?card.rect.x:card.rect.x+card.rect.w-r.w;
  assert(Math.abs(r.x-Math.max(8,Math.min(expectedX,width-r.w-8)))<=1,'identity aligns with tab edge');
  assert.equal((await nodes('status.connection.reconnect')).length,0);
  assert.equal((await nodes('status.connection.footer')).length,0);
  const name=await visible('status.connection.name'),health=await visible('status.connection.health'),address=await visible('status.connection.address'),copy=await visible('status.connection.copy'),logs=await visible('status.connection.logs');
  assert(health.rect.x>=name.rect.x+name.rect.w&&Math.abs(health.rect.y-name.rect.y)<1,'health is beside name');
  assert(copy.rect.x>=address.rect.x+address.rect.w&&logs.rect.x>copy.rect.x,'actions are beside endpoint');
  assert(Math.abs(copy.rect.y+copy.rect.h/2-address.rect.y-address.rect.h/2)<1);

  assert(r.x>=8&&r.x+r.w<=width-8&&r.y+r.h<=height-8);
  await capture('session-identity-'+width);report.geometry.push({width,height,panelId:'status.connection',panel:r});
  await h.mouseMove(700,300);await hidden('status.connection');
 }
 await h.resizeWindow(1440,900);const identity=await visible('status.connection.identity');
 await h.mouseMove(identity.rect.x+identity.rect.w/2,identity.rect.y+identity.rect.h/2);await visible('status.connection');
 await click('status.connection.identity');
 const copy=await visible('status.connection.copy');await h.mouseMove(copy.rect.x+14,copy.rect.y+14);await h.sleep(650);await capture('session-copy-tooltip');await click('status.connection.copy');await capture('session-copied');
 const logs=await visible('status.connection.logs');await h.mouseMove(logs.rect.x+14,logs.rect.y+14);await h.sleep(650);await capture('session-logs-tooltip');await click('status.connection.logs');await hidden('status.connection');await visible('connection.logs');await capture('session-connection-logs');
 report.checks.push('Session identity aligns with tab card, has inline health and endpoint actions, no footer or reconnect; copy and logs activated.');report.status='passed';
}catch(error){report.status='failed';report.error=String(error);if(app)await capture('failure').catch(()=>{});process.exitCode=1;}
finally{
 if(app&&app.exitCode===null&&app.signalCode===null){try{await h.request('POST','/zerowork/windows',{action:'quit'});await Promise.race([ended!,h.sleep(8000)]);}catch{}if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await ended!;report.forced_shutdown=true;}else report.exit_code=app.exitCode;}
 peer.kill('SIGTERM');await Promise.race([peerEnded,h.sleep(3500)]);await peerLog.close();await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));await rm(iso,{recursive:true,force:true});
}
console.log(JSON.stringify(report,null,2));
