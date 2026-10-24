/** Native main-app visual acceptance. Owned loopback HTTP only; no provider mock,
 * user configuration, real credentials, external network or remote commands. */
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,writeFile,copyFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {waitForServerReady,waitFor,query,clickTestId,key,type_,inputState,resizeWindow,screenshot,sleep} from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]??'artifacts/vanta-20261022-round4/native');
const themes=process.argv[3]?[process.argv[3]]:['dark','light','sauber'];
await mkdir(out,{recursive:true});
const binary=join(out,'zerowork-frozen');await copyFile(resolve('zig-out/bin/zerowork'),binary);
const sha=createHash('sha256').update(await readFile(binary)).digest('hex');
let mode='network';const requests:any[]=[];const sockets=new Set<any>();
const server=createServer(async(req,res)=>{
 let body='';for await(const c of req)body+=c;
 requests.push({mode,path:req.url,at:Date.now(),body:JSON.parse(body)});
 if(mode==='network'){req.socket.destroy();return;}
 if(mode==='429'){res.writeHead(429,{'Retry-After':'2','Content-Type':'application/json'});res.end('{"error":{"message":"rate limited"}}');return;}
 res.writeHead(200,{'Content-Type':'text/event-stream'});
 res.end('data: {"choices":[{"delta":{"content":"RECOVERY_OK"},"finish_reason":null}]}\n\ndata: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
});
server.on('connection',s=>{sockets.add(s);s.once('close',()=>sockets.delete(s));});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
const port=(server.address() as any).port;
const report:any={status:'running',binary_sha256:sha,runs:[],scope:'Production main app, native Metal, public synthetic Harness; actual loopback TCP loss and HTTP 429',external_requests:0};
function shown(n:any){return n&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;}
function flat(n:any):any[]{return !shown(n)?[]:[n,...(n.children??[]).flatMap(flat)];}
const visible=async(id:string,timeout=20000)=>waitFor(async()=>(await query(id)).find(shown)??null,timeout);
async function click(id:string){await visible(id);assert((await clickTestId(id)).ok,id);}
let failure:unknown;
try{for(const theme of themes){
 const dir=join(out,theme);await mkdir(dir,{recursive:true});const isolated=await mkdtemp(join(tmpdir(),'zw-vanta-errors-'));
 const rpc=join(isolated,'rpc'),data=join(isolated,'data');await mkdir(rpc);await mkdir(data);
 await writeFile(join(data,'hosts.toml'),'[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname="History empty"\nhost="192.0.2.1"\nport=22\nuser="tester"\n');
 await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n[ai]\ndefault_provider="visual-loopback"\nprovider_count=1\n[[ai.providers]]\nid="visual-loopback"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/v1/chat/completions"\napi_key="local-fixture-only"\nenabled=true\n[[ai.providers.models]]\nname="visual-fixture"\ncontext_window=8192\ndefault=true\n`);
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(dir,'app.log'),'w');
 const env={...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''};delete env.ZEROWORK_AI_MOCK;
 const app=spawn(binary,[],{env,stdio:['ignore',log.fd,log.fd]});const ended=new Promise<void>(done=>app.once('close',()=>done()));
 const run:any={theme,pid:app.pid,stages:[],checks:[]};report.runs.push(run);
 async function capture(name:string,ids:string[]){await sleep(200);const nodes=Object.fromEntries(await Promise.all(ids.map(async id=>[id,await query(id)])));await writeFile(join(dir,name+'.json'),JSON.stringify(nodes,null,2));assert((await screenshot(join(dir,name+'.png'))).ok);run.stages.push({name,nodes:ids});return nodes;}
 try{
  await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
  await resizeWindow(1440,900);await click('sidebar.host');await click('sidebar.host.more');await click('context.menu.history');
  await visible('history.empty');assert.equal((await visible('history.empty')).text,'还没有会话历史');
  await capture('history-empty-wide',['history.panel','history.empty']);
  await resizeWindow(860,480);await capture('history-empty-compact',['history.panel','history.empty']);await click('history.close');
  assert(!(await query('history.panel')).some(shown));run.checks.push('History empty opens from production host menu and closes without creating a connection.');
  await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await visible('ai.prompt');
  for(const state of ['network','429']){
   mode=state;await resizeWindow(1440,900);await click('ai.prompt');await key('a',{cmd:true});await type_('Visual recovery '+state);await click('ai.send');
   const reason=await visible('ai.recovery.reason',30000);assert(state==='429'?/受限/.test(reason.text):/中断/.test(reason.text),JSON.stringify(reason));
   const calls=requests.filter(x=>x.mode===state&&x.body.messages.some((m:any)=>String(m.content).includes('Visual recovery '+state)));
   assert(calls.length>=4,'Actual production retry exhaustion, not injected UI');
   const wide=await capture('ai-'+state+'-wide',['ai.panel','ai.recovery','ai.recovery.reason','ai.recovery.regenerate','ai.recovery.edit']);
   await resizeWindow(860,480);const compact=await capture('ai-'+state+'-compact',['ai.panel','ai.recovery','ai.recovery.reason','ai.recovery.regenerate','ai.recovery.edit']);
   for(const n of (compact['ai.recovery.reason'] as any[]).filter(shown))assert(n.rect.x>=0&&n.rect.x+n.rect.w<=860.5,'Reason within narrow window');
   run.checks.push({state,actual_requests:calls.length,reason:reason.text,wide:wide['ai.panel'][0]?.rect,compact:compact['ai.panel'][0]?.rect});
   await click('ai.recovery.edit');assert.equal((await inputState('ai.prompt')).buffer,'Visual recovery '+state,'Edit preserves original prompt');
  }
  mode='success';await waitFor(()=>Date.now()>(requests.filter(x=>x.mode==='429').at(-1)?.at??0)+2100?true:null,5000);await click('ai.send');await waitFor(async()=>{const p=await visible('ai.panel');return flat(p).some(n=>n.text==='RECOVERY_OK')&&!(await query('ai.stop')).some(shown)||null;},20000);
  await capture('ai-recovered-compact',['ai.panel','ai.prompt','ai.recovery']);run.checks.push('Real HTTP success after editing the failed request renders RECOVERY_OK.');run.status='passed';
 }catch(e){run.status='failed';run.error=String(e);await capture('failure',['ai.panel','history.panel','auth.challenge.modal']).catch(()=>{});throw e;}
 finally{app.kill('SIGTERM');await Promise.race([ended,sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}run.cleanup={exit_code:app.exitCode,signal:app.signalCode};await log.close();}
}report.status='passed';}catch(e){failure=e;report.status='failed';report.error=String(e);}
finally{for(const s of sockets)s.destroy();await new Promise<void>(done=>server.close(()=>done()));report.requests=requests;await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
console.log(report.status+': '+join(out,'report.json'));if(failure)throw failure;
