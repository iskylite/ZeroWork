/** SSH, transfer, notification and data settings transactions in real native windows. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,realpath,open} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep,scrollAt,request,inputState} from '../vendor/zenit/e2e/client.ts';
const [argBinary,argOutput]=process.argv.slice(2); assert(argBinary&&argOutput);
const hostOnly=process.argv[4]==='host';
const binary=resolve(argBinary), output=resolve(argOutput);await mkdir(output,{recursive:true});
const report:any={status:'running',runs:[]};
const shown=(n:any)=>n.visible!==false&&n.rect.w>0&&n.rect.h>0&&(n.effective_opacity??1)>0;
const text=(n:any)=>typeof n.text==='string'?n.text:n.text?.content??'';
const near=(a:number,b:number)=>assert(Math.abs(a-b)<.6,`${a} != ${b}`);
for(const theme of ['dark','light']){
 const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-settings-v3-'))),rpc=join(iso,'rpc'),data=join(iso,'data');await mkdir(rpc);await mkdir(data);
 await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n`,{mode:0o600});process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(output,theme+'.log'),'w');const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});const ended=new Promise<void>(done=>app.once('close',()=>done()));
 const rec:any={theme,pages:[],checks:[],captures:[]};report.runs.push(rec);
 const node=async(id:string):Promise<any>=>waitFor(async()=> (await query(id)).find(shown)??null,12000);
 const reveal=async(id:string)=>{for(let i=0;i<12;i++){const n=await node(id),v=await node('settings.viewport');if(n.rect.y>=v.rect.y&&n.rect.y+n.rect.h<=v.rect.y+v.rect.h)return;await scrollAt(v.rect.x+v.rect.w/2,v.rect.y+v.rect.h/2,0,n.rect.y<v.rect.y?180:-180);await sleep(100);}};
 const click=async(id:string)=>{if(/settings\.(appearance\.|materials\.|field\.|toggle\.)/.test(id))await reveal(id);const n=await node(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await sleep(180);};
 const capture=async(name:string)=>{await sleep(180);const path=join(output,theme+'-'+name+'.png');assert((await screenshot(path)).ok);rec.captures.push(path);};
 const edit=async(id:string,value:string)=>{await click(id);await key('a',{cmd:true});await key('backspace');await type_(value);await sleep(100);};
 try{
  await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
  await resizeWindow(1440,900);await click('toolbar.settings');await click('settings.nav.ssh');
  const header=await node('settings.ssh.connection.header'), row=await node('settings.row.keepalive_sec'), field=await node('settings.field.keepalive_sec'),card=await node('settings.ssh.connection');
  rec.geometry={header:header.rect,row:row.rect,field:field.rect,card:card.rect};near(header.rect.h,62);near(row.rect.h,53);near(field.rect.w,220);near(field.rect.h,32);near(field.rect.x+field.rect.w,card.rect.x+card.rect.w-16);
  assert.equal(text(await node('settings.ssh.connection.summary')),'连接保活、超时与终端类型');await capture('ssh-standard');rec.checks.push('standard card/header/field contract');
  if(hostOnly){near(card.rect.w,830);await resizeWindow(860,480);await sleep(250);rec.compact=(await node('settings.ssh.connection')).rect;near(rec.compact.w,608);await capture('host-compact');rec.status='passed_pending_pixel_review';continue;}
  await click('settings.ssh.connection.header');await node('settings.ssh.connection.summary');await capture('ssh-collapsed');await click('settings.ssh.connection.header');
  await edit('settings.field.keepalive_sec','70000');assert.equal((await inputState('settings.field.keepalive_sec')).buffer,'70000');await node('settings.error.keepalive_sec');await key('escape');assert.equal((await inputState('settings.field.keepalive_sec')).buffer,'30');rec.checks.push('invalid raw retained and Escape restores valid draft');
  await edit('settings.field.keepalive_sec','44');await click('settings.revert');await sleep(300);assert.equal((await inputState('settings.field.keepalive_sec')).buffer,'30');rec.checks.push('outer revert');
  await edit('settings.field.keepalive_sec','44');await click('settings.save');await waitFor(async()=> (await readFile(join(data,'config.toml'),'utf8')).includes('keepalive_sec = 44')?true:null,10000);await click('settings.close');await click('toolbar.settings');await click('settings.nav.ssh');assert.equal((await inputState('settings.field.keepalive_sec')).buffer,'44');rec.checks.push('save and reopen actual config');
  await reveal('settings.ssh.reconnect.header');await click('settings.ssh.reconnect.header');
  await reveal('settings.field.reconnect_backoff');await edit('settings.field.reconnect_backoff','1, 3, 5, 8, 13');
  await click('settings.save');await waitFor(async()=> (await readFile(join(data,'config.toml'),'utf8')).includes('reconnect_backoff = [1,3,5,8,13]')?true:null,10000);
  await capture('ssh-backoff-comma-list');rec.checks.push('prototype comma-list backoff edits and persists legacy TOML array');
  for(const [page,section,field,value] of [
   ['transfer','settings.transfer.connection.header','shared_pacing_kbps','4096'],
   ['notifications','settings.notifications.attention.header','quiet_hours','23:00-07:00'],
   ['data','settings.data.history.header','retention_days','21']]){
   await click('settings.nav.'+page);await capture(page+'-standard');
   await reveal(section);if(page!=='transfer')await click(section);await reveal('settings.field.'+field);
   const initial=(await inputState('settings.field.'+field)).buffer;
   await edit('settings.field.'+field,value);await capture(page+'-edited');
   await click('settings.revert');await reveal('settings.field.'+field);
   assert.equal((await inputState('settings.field.'+field)).buffer,initial);
   await edit('settings.field.'+field,value);await click('settings.save');
   await waitFor(async()=> (await readFile(join(data,'config.toml'),'utf8')).includes(field+' = '+(field==='quiet_hours'?'"'+value+'"':value))?true:null,10000);
   await resizeWindow(860,480);await sleep(250);await capture(page+'-compact');
   const viewport=(await node('settings.viewport')).rect,footerY=(await node('settings.footer')).rect.y;
   await scrollAt(viewport.x+viewport.w/2,viewport.y+viewport.h/2,0,-900);await sleep(200);near((await node('settings.footer')).rect.y,footerY);await capture(page+'-compact-scrolled');
   await resizeWindow(1440,900);await sleep(250);rec.checks.push(page+' edit/revert/save/compact scroll');
  }
  await click('settings.nav.keys');await capture('keys-standard');await resizeWindow(860,480);await capture('keys-compact');await resizeWindow(1440,900);
  await click('settings.nav.plugins');await capture('plugins-standard');await resizeWindow(860,480);await capture('plugins-compact');await resizeWindow(1440,900);
  await click('settings.nav.ssh');await resizeWindow(860,480);await sleep(300);const compact=await node('settings.field.keepalive_sec');near(compact.rect.w,210);near(compact.rect.h,32);const footer=(await node('settings.footer')).rect;await capture('ssh-compact');const v=await node('settings.viewport');await scrollAt(v.rect.x+v.rect.w/2,v.rect.y+v.rect.h/2,0,-650);await sleep(250);near((await node('settings.footer')).rect.y,footer.y);await capture('ssh-compact-scrolled');rec.checks.push('compact field210, content scroll and fixed footer');
  await resizeWindow(1440,900);await sleep(250);await click('settings.nav.ssh');near((await node('settings.field.keepalive_sec')).rect.w,220);rec.checks.push('resize restores standard field width');
  rec.status='passed_pending_pixel_review';
 }catch(e){rec.status='failed';rec.error=String(e);await capture('failure').catch(()=>{});throw e;}finally{await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));if(app.exitCode===null)app.kill('SIGTERM');await ended;await log.close();}
}
report.status='passed_pending_pixel_review';await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
