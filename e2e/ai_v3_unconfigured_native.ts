/** Real unconfigured production assistant and its existing settings entry points. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-v3-ai-prefix',h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-v3-ai-unconfigured');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-ai-v3-unconfigured-')),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w'),app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const capture=async(name:string)=>{await h.sleep(160);await h.screenshot(join(out,name+'.png'));await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.panel'),null,2))};
const report:any={status:'running',checks:[],isolatedData:iso};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(860,480);await click('workspace.empty.local');await visible('terminal.surface');await click('ai.strip');await visible('ai.empty.unconfigured');await visible('ai.empty.title');await capture('01-unconfigured-compact');assert.equal((await visible('ai.prompt')).rect.w,570);assert.equal((await visible('ai.send')).effective_opacity,.45);
 await click('ai.empty.settings');await visible('settings.close');await click('settings.close');await visible('ai.empty.unconfigured');await click('ai.empty.ollama');await visible('settings.close');await capture('02-local-model-settings');await click('settings.close');report.checks.push('Unconfigured V3 setup is visible; real general AI and local model settings entry points both open');
 await h.resizeWindow(1440,900);await capture('03-unconfigured-wide');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});process.exitCode=1;}
finally{app.kill('SIGTERM');if(app.exitCode===null&&app.signalCode===null)await new Promise(r=>app.once('close',r));await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2))}
console.log(JSON.stringify(report));
