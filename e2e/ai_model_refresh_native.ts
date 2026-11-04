/** Isolated native acceptance: opening refreshes only automatic model catalogs. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,open,realpath,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';

const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);
await mkdir(out,{recursive:true});
const base=await realpath(await mkdtemp('/tmp/zw-model-refresh-')),data=join(base,'data'),rpc=join(base,'rpc');
await mkdir(data);await mkdir(rpc);await writeFile(join(data,'hosts.toml'),'');
const model=(id:string)=>({id,context_window:64000,reasoning:false,vision:false});
let models=[model('old-model')],hold=false,fail=false,release:(()=>void)|undefined;
const requests={automatic:0,configured:0};
const server=createServer(async(req,res)=>{
 if(req.url?.startsWith('/configured/')){
  requests.configured++;res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({data:[model('manual-model')]}));return;
 }
 requests.automatic++;
 if(hold)await new Promise<void>(r=>{release=r;});
 res.writeHead(fail?503:200,{'content-type':'application/json'});res.end(JSON.stringify({data:models}));
});
await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
const port=(server.address() as any).port;
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ai]\ndefault_provider="automatic"\n[[ai.providers]]\nid="automatic"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/automatic/v1"\nenabled=true\n[[ai.providers]]\nid="configured"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${port}/configured/v1"\nenabled=true\n[[ai.providers.models]]\nname="manual-model"\ncontext_window=8192\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n&&n.visible!==false&&!n.hidden&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>n?[n,...(n.children??[]).flatMap(flat)]:[];
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id);};
const row=async(id:string)=>(await h.query('ai.model.option')).find(n=>shown(n)&&flat(n).some(c=>c.text===id));
const report:any={status:'running',checks:[]};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1440,900);
 await click('workspace.empty.local');await visible('terminal.surface');await click('ai.strip');
 await h.waitFor(()=>requests.automatic>=1&&requests.configured===1||null,15000);
 await click('ai.composer.model');await visible('ai.model.menu');
 await h.waitFor(async()=>await row('old-model')||null,15000);
 await h.key('escape');
 const before=requests.automatic;hold=true;
 await click('ai.composer.model');
 await h.waitFor(()=>requests.automatic>before&&release||null,15000);
 await visible('ai.model.menu');assert(await row('old-model'));assert(await row('manual-model'));
 assert.equal(requests.configured,1);
 assert((await h.screenshot(join(out,'01-pending-refresh.png'))).ok);
 report.checks.push('Opening starts an asynchronous catalog request; existing models and the popup stay available while the response is held.');
 models=[model('new-model')];hold=false;release?.();release=undefined;
 await h.waitFor(async()=>await row('new-model')||null,15000);
 await visible('ai.model.menu');assert(!(await row('old-model')));assert(await row('manual-model'));
 assert.equal(requests.configured,1);
 assert((await h.screenshot(join(out,'02-updated-open-popup.png'))).ok);
 report.checks.push('The open popup adds the current model and removes the withdrawn model; the configured provider receives no additional GET.');
 await h.key('escape');fail=true;const failureBefore=requests.automatic;
 await click('ai.composer.model');await h.waitFor(()=>requests.automatic>failureBefore||null,15000);
 await visible('ai.model.menu');assert(await row('new-model'));
 report.checks.push('An upstream failure leaves the last published catalog available.');
 await h.key('escape');fail=false;models=[];const emptyBefore=requests.automatic;
 await click('ai.composer.model');await h.waitFor(()=>requests.automatic>emptyBefore||null,15000);
 await h.waitFor(async()=>!(await row('new-model'))&&await row('manual-model')||null,15000);
 await visible('ai.model.menu');assert.equal(requests.configured,1);
 assert((await h.screenshot(join(out,'03-empty-automatic-list.png'))).ok);
 report.checks.push('A successful empty automatic catalog removes its models while preserving the configured model and the open popup.');
 report.status='passed';
}catch(e){report.status='failed';report.error=String((e as Error).stack??e);throw e;}
finally{
 release?.();app.kill('SIGTERM');await ended;server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));await log.close();
 await writeFile(join(out,'report.json'),JSON.stringify({...report,requests},null,2));
}
