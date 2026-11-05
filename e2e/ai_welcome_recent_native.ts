/** Welcome/history row parity with an isolated local provider and app data. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,writeFile,open} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-recent-aligned-build');
const out=resolve(process.argv[2]??'/tmp/zw-welcome-recent-native');await mkdir(out,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-welcome-recent-'),data=join(iso,'data'),rpc=join(iso,'rpc');for(const dir of [data,rpc])await mkdir(dir);
const frame=(content:string)=>'data: '+JSON.stringify({choices:[{index:0,delta:{content}}]})+'\n\n';
const server=createServer(async(req,res)=>{if(req.method!=='POST'){res.end('{"data":[{"id":"recent-fixture"}]}');return}for await(const _ of req){}res.writeHead(200,{'content-type':'text/event-stream'});res.end(frame('RECENT_ANSWER_FINISHED')+'data: [DONE]\n\n')});
await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n[ai]\ndefault_provider="recent-fixture"\n[[ai.providers]]\nid="recent-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="recent-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const h=await import(join(prefix,'share/zenit/harness/client.ts')),log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r)),alive=()=>app.exitCode===null&&app.signalCode===null;
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join(' ');
const visible=(id:string)=>h.waitFor(async()=>{assert(alive(),'app exited');return(await h.query(id)).find(shown)??null},15000);
const click=async(id:string)=>{report.last_action=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,10000);
const report:any={status:'running',checks:[],screenshots:[]};
const capture=async(name:string)=>{await h.mouseMove(1,1);await h.sleep(160);const path=join(out,name+'.png');assert((await h.screenshot(path)).ok);report.screenshots.push(path);await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.panel'),null,2))};
const newConversation=async()=>{await click('ai.session.new');await click('ai.session.close.accept');await absent('ai.session.close.confirmation');await visible('ai.empty.recent')};
const rowFacts=(row:any)=>{const nodes=flat(row);return{phase:text(nodes.find(n=>n.test_id==='ai.session.phase_tag')).trim(),bound:!!nodes.find(n=>n.test_id==='ai.session.bound'),actions:nodes.filter(n=>/^ai.session.(jump|locate|restore|copy_use|delete).1$/.test(n.test_id??'')&&shown(n)).map(n=>n.test_id).sort()}};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1200,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await click('ai.prompt');await h.type_('CHECK_TERMINAL_STATUS');await click('ai.send');await h.waitFor(async()=>text(await visible('ai.panel')).includes('RECENT_ANSWER_FINISHED')||null,15000);await absent('ai.stop');await newConversation();
 const recent=await visible('ai.empty.recent'),row=flat(recent).find(n=>n.test_id==='ai.session.row.1');assert(row&&shown(row));const facts=rowFacts(row);assert.equal(facts.phase,'已结束');assert(!facts.bound);assert.deepEqual(facts.actions,['ai.session.copy_use.1','ai.session.delete.1','ai.session.jump.1','ai.session.restore.1']);
 assert.equal(row.rect.h,56);await capture('01-welcome-history-actions');
 await click('ai.sessions');const menu=await visible('ai.sessions.menu'),historyRow=flat(menu).find(n=>n.test_id==='ai.session.row.1');assert.deepEqual(rowFacts(historyRow),facts);await click('ai.sessions.close');report.checks.push('Welcome and history list share phase, binding and available actions');
 await click('ai.session.jump.1');await visible('ai.history');assert(text(await visible('ai.history.body')).includes('RECENT_ANSWER_FINISHED'));await click('ai.history.close');await visible('ai.empty.recent');report.checks.push('Welcome View opens read-only history and preserves the current welcome page');
 await click('ai.session.restore.1');await absent('ai.empty.configured');await h.waitFor(async()=>text(await visible('ai.panel')).includes('RECENT_ANSWER_FINISHED')||null,15000);report.checks.push('Welcome Restore activates the original conversation');
 await newConversation();await click('ai.session.copy_use.1');await absent('ai.empty.configured');await h.waitFor(async()=>text(await visible('ai.panel')).includes('RECENT_ANSWER_FINISHED')||null,15000);report.checks.push('Welcome Copy and use activates a copy with the original history');
 await newConversation();await h.resizeWindow(860,480);await visible('ai.empty.recent');await capture('02-compact-welcome');for(const row of flat(await visible('ai.empty.recent')).filter(n=>/^ai.session.row.\d+$/.test(n.test_id??'')&&shown(n))){const second=flat(row).find(n=>n.test_id==='ai.session.second_line');for(const button of flat(row).filter(n=>/^ai.session.(jump|restore|copy_use|delete).\d+$/.test(n.test_id??'')&&shown(n))){assert.equal(button.rect.w,24);assert(button.rect.x+button.rect.w<=second.rect.x+second.rect.w+.6)}}
 await h.resizeWindow(1200,900);await click('ai.session.delete.1');await visible('ai.session.close.confirmation');await capture('03-delete-confirmation');await click('ai.session.close.accept');await h.waitFor(async()=>!flat(await visible('ai.empty.recent')).some(n=>n.test_id==='ai.session.row.1')||null,10000);report.checks.push('Compact rows keep actions within bounds; Delete confirms and immediately removes the recent row');report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await capture('failure').catch(()=>{})}
finally{
 try{if(alive()){await Promise.race([h.request('POST','/quit'),ended]);const start=performance.now();while(alive()&&performance.now()-start<15000){for(const id of ['groups.close.accept','local.close.accept','session.close.accept'])try{if((await h.query(id)).some(shown))await h.clickTestId(id)}catch{}await Promise.race([ended,h.sleep(80)])}}}catch(e){report.quit_error=String(e)}
 if(alive()){report.forced=true;app.kill('SIGTERM');await ended}report.exit_code=app.exitCode;report.signal=app.signalCode;if(report.forced||app.exitCode!==0){report.status='failed';process.exitCode=1}server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}));
}
