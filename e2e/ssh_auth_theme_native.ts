import {nativeThemeData} from './native_theme_data.mjs';
/** Actual authentication dialog paints for every theme at T0/T100.
 * node e2e/ssh_auth_theme_native.ts <evidence-dir> <owned-peer.json> <binary>
 * The peer must use an encrypted fixture key and remain alive for the run.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,realpath,rm,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import * as h from '../zig-out/share/zenit/harness/client.ts';

const out=resolve(process.argv[2]),fixture=JSON.parse(await readFile(resolve(process.argv[3]),'utf8')),binary=resolve(process.argv[4]);
assert.equal(fixture.host??'127.0.0.1','127.0.0.1','Only an owned loopback peer is allowed');
assert(Number.isInteger(fixture.port)&&fixture.port>0&&fixture.port<65536);
assert(fixture.key&&fixture.fingerprint,'Encrypted fixture path and expected fingerprint are required');
assert((await realpath(fixture.key)).startsWith('/private/tmp/'),'Only a generated temporary fixture key is allowed');
await mkdir(out,{recursive:true});
const themes=Object.keys(nativeThemeData.themes);
const report:any={status:'running',binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),cases:[],limits:['Owned loopback encrypted-key fixture; no external host or user key is accessed.','Synthetic input on real native windows; physical keyboard and IME are outside this run.']};
const shown=(n:any)=>n?.rect&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join(' ');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
async function click(id:string){const n=await visible(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok,id);}
async function capture(name:string){await h.mouseMove(3,3);await h.sleep(300);await h.screenshot(join(out,name+'.png'));await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('plugin.challenge.modal'),null,2));}
try{
 for(const theme of themes)for(const transparency of [0,100]){
  const iso=await realpath(await mkdtemp('/private/tmp/zw-auth-theme-')),data=join(iso,'data'),rpc=join(iso,'rpc');
  await mkdir(data);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
  await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\n[ui.materials.background]\nenabled=false\ntransparency=${transparency}\n`);
  await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="private_key"\nname="Encrypted key appearance"\nhost="127.0.0.1"\nport=${fixture.port}\nuser=${JSON.stringify(fixture.user??'fixture')}\nauth={key=${JSON.stringify(fixture.key)}}\n`);
  const name=theme+'-t'+transparency,log=await open(join(out,name+'.log'),'w'),app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]}),ended=new Promise(r=>app.once('close',r));
  try{
   await h.waitForServerReady();await h.resizeWindow(1280,720);
   const row=await visible('sidebar.host');assert((await h.clickAt(row.rect.x+45,row.rect.y+row.rect.h/2)).ok);
   await h.waitFor(async()=>text(await visible('plugin.challenge.title'))==='核对主机密钥'||null);
   assert(text(await visible('plugin.challenge.material')).includes(fixture.fingerprint),'owned peer identity matches');
   await capture(name+'-host-key');await click('plugin.challenge.choice.0');
   await h.waitFor(async()=>text(await visible('plugin.challenge.title'))==='解锁 SSH 私钥'||null);
   assert(!text(await visible('plugin.challenge.modal')).includes(fixture.fingerprint),'host-key material retires before secret input');
   const state:any=await h.request('POST','/zerowork/windows',{action:'snapshot'});
   assert.equal((state.sessions??[]).filter((s:any)=>s.plugin==='ssh').length,1,'One row activation starts one authentication flow');
   await click('plugin.challenge.answer.0');await h.type_('visual-fixture');
   await capture(name+'-private-key-focused');
   await click('plugin.challenge.submit');
   await h.waitFor(async()=>text(await visible('plugin.challenge.detail')).includes('密码短语不正确')||null,15000);
   assert(!text(await visible('plugin.challenge.modal')).includes(fixture.fingerprint),'host-key material remains absent after retry');
   await click('plugin.challenge.answer.0');await capture(name+'-private-key-error');
   await click('plugin.challenge.cancel');await h.waitFor(async()=>!(await h.query('plugin.challenge.modal')).some(shown)||null);
   report.cases.push({theme,transparency,status:'passed',states:['host-key','private-key-focused','private-key-error'],cancelled:true});
   await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(name+' passed');
  }catch(error){await capture(name+'-failure').catch(()=>{});await writeFile(join(out,name+'-failure-state.json'),JSON.stringify(await h.request('POST','/zerowork/windows',{action:'snapshot'}),null,2)).catch(()=>{});throw error;}
  finally{if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;await log.close();await rm(iso,{recursive:true,force:true});}
 }
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);console.error(e);}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
if(report.status!=='passed')process.exitCode=1;
