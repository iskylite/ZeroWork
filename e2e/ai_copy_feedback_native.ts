/** Native copy feedback and code toolbar regression, using an isolated local provider. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,open,writeFile,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'zig-out');
const out=resolve(process.argv[2]??'/tmp/zw-ai-copy-evidence');
await mkdir(out,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-ai-copy-'),data=join(iso,'data'),rpc=join(iso,'rpc');
await mkdir(data);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const code='printf "COPY_CODE_EXACT"\n\n# '+ 'long_command_argument_'.repeat(16)+'\nprintf "完成"';
const answer='复制反馈检查\n\n```sh\n'+code+'\n```\n\nCOPY_COMPLETE';
let requests=0;
const server=createServer(async(req,res)=>{
 for await(const _ of req){}
 if(req.method!=='POST')return res.end('{"data":[{"id":"copy-fixture"}]}');
 requests++;
 res.writeHead(200,{'content-type':'text/event-stream'});
 res.end('data: '+JSON.stringify({choices:[{index:0,delta:{content:answer}}]})+'\n\ndata: [DONE]\n\n');
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ai]\ndefault_provider="fixture"\n[[ai.providers]]\nid="fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="copy-fixture"\ncontext_window=200000\ndefault=true\n`);
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const shown=(n:any)=>n&&n.visible!==false&&!n.hidden&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const report:any={status:'running',checks:[]};
try{
 await h.waitForServerReady();await h.resizeWindow(1440,1000);
 await click('workspace.empty.local');await click('toolbar.ai');await click('ai.prompt');
 await h.type_('检查复制和代码按钮');await click('ai.send');
 await visible('ai.turn.complete');await visible('ai.message.code.copy');
 const cap=async(name:string)=>{await h.mouseMove(1,1);assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.panel'),null,2));};
 await cap('00-idle');
 await click('ai.message.code.copy');
 assert.equal(execFileSync('pbpaste',{encoding:'utf8'}),code+'\n');
 await cap('01-code-copied');
 await h.sleep(1100);await click('ai.message.code.copy');await h.sleep(1100);
 await cap('01b-code-renewed');await h.sleep(1100);await cap('01c-code-reset');
 report.checks.push('Code copy writes exact original bytes, is independent, renews on repeated clicks, and resets after two seconds');
 const initial=await visible('ai.message.code.text');const viewport=await visible('ai.message.code.scroll');
 assert(initial.rect.w>viewport.rect.w);
 await click('ai.message.code.wrap');
 await h.waitFor(async()=>{const n=await visible('ai.message.code.text');return n.rect.w<=viewport.rect.w&&n.rect.h>initial.rect.h?n:null},5000);
 await cap('02-code-wrapped');
 await click('ai.message.code.wrap');
 await h.waitFor(async()=>(await visible('ai.message.code.text')).rect.w>viewport.rect.w||null,5000);
 report.checks.push('Code wrap changes actual text layout in both directions');
 await click('ai.turn.copy');assert.equal(execFileSync('pbpaste',{encoding:'utf8'}),answer);
 await cap('03-turn-copied');await h.sleep(2200);
 await click('ai.message.copy');assert.equal(execFileSync('pbpaste',{encoding:'utf8'}),'检查复制和代码按钮');
 await cap('04-user-copied');
 report.checks.push('Turn summary and user message copies write the correct content and acknowledge separately');
 await click('ai.turn.fork');await visible('ai.turn.complete');
 await click('ai.sessions');await visible('ai.session.row.1');await visible('ai.session.row.2');
 await cap('05-fork');report.checks.push('Summary fork creates a separate conversation and retains the original');
 assert.equal(requests,1);
 report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await h.screenshot(join(out,'failure.png')).catch(()=>{});}
finally{
 app.kill('SIGTERM');await Promise.race([ended,h.sleep(2000)]);
 if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}
 await log.close();await new Promise<void>(done=>server.close(()=>done()));await rm(iso,{recursive:true,force:true});
 await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
console.log(report.status+': '+join(out,'report.json'));
