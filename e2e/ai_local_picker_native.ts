/** Real system text-file chooser; run with a serialized foreground CUA lease. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,realpath,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-ai-v3-prefix',h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-ai-local-picker');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-ai-local-picker-')),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
const fixture=join(iso,'selected.txt');await writeFile(fixture,'Native system chooser selected this owned UTF-8 file.\n');
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');const app=spawn(process.env.ZW_AI_BINARY??join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'0',ZENIT_E2E_ISOLATE_POINTER:'0'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
const report:any={status:'running',pid:app.pid,rpc,fixture,checks:[]};await writeFile(join(out,'live.json'),JSON.stringify(report));
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const click=async(id:string)=>{report.lastAction=id;await h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);assert((await h.clickTestId(id)).ok)};
try{await h.waitForServerReady();await h.resizeWindow(1100,760);await click('workspace.empty.local');await click('toolbar.ai');await click('ai.composer.attachment');await click('ai.attachment.local_text').catch(e=>{if(!String(e).includes('request timeout'))throw e});await h.waitFor(async()=>(await h.query('ai.attachment.local_text')).some(shown)||null,180000);await h.screenshot(join(out,'01-local-selected.png'));await click('ai.attachment.open');await h.waitFor(async()=>(await h.query('ai.attachment.preview')).some(shown)||null,10000);await h.screenshot(join(out,'02-local-preview.png'));report.checks.push('Actual macOS open-file panel selects owned UTF-8 file and native preview renders its captured bytes');report.status='passed'}catch(e){report.status='failed';report.error=String(e);process.exitCode=1}finally{app.kill('SIGTERM');await ended;await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report))}
