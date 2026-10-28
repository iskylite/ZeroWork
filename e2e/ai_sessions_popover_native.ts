/** Session popover geometry, dismissal and session actions in the real native UI. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,open,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-v3-ai-prefix',h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-ai-sessions-popover');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-ai-v3-unconfigured-')),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w'),app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{report.lastAction=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
const capture=async(name:string)=>{await h.sleep(160);await h.screenshot(join(out,name+'.png'));await writeFile(join(out,name+'.json'),JSON.stringify(await h.query('ai.panel'),null,2))};
const report:any={status:'running',checks:[],isolatedData:iso};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1440,900);await click('workspace.empty.local');await visible('terminal.surface');await click('ai.strip');
 await h.sleep(300);const before=(await visible('ai.conversation.viewport')).rect;
 await click('ai.sessions');await visible('ai.sessions.menu');await h.sleep(220);
 assert.deepEqual((await visible('ai.conversation.viewport')).rect,before,'session popover must not resize transcript');
 const menu=await visible('ai.sessions.menu');assert.equal(menu.rect.w,440);await capture('01-session-popover');
 await h.key('escape');await h.waitFor(async()=>!(await h.query('ai.sessions.menu')).some(shown)||null,5000);
 await click('ai.sessions');await visible('ai.sessions.menu');await click('ai.prompt');await h.waitFor(async()=>!(await h.query('ai.sessions.menu')).some(shown)||null,5000);
 report.checks.push('Session list floats without moving transcript; Escape and outside click dismiss it');
 await click('ai.session.new');await click('ai.sessions');await visible('ai.sessions.menu');await click('ai.session.jump.1');await h.waitFor(async()=>!(await h.query('ai.sessions.menu')).some(shown)||null,5000);
 if(!(await h.query('ai.panel')).some(shown))await click('ai.strip');await click('ai.sessions');await visible('ai.sessions.menu');await click('ai.session.delete.1');await h.sleep(300);await h.waitFor(async()=>!(await h.query('ai.session.row.1')).some(shown)||null,5000);if(!(await h.query('ai.panel')).some(shown))await click('ai.strip');if((await h.query('ai.sessions.menu')).some(shown))await click('ai.sessions.close');
 report.checks.push('Switching sessions dismisses the popover; idle session deletion removes the selected row');
 await h.resizeWindow(860,480);await h.sleep(300);const compact=(await visible('ai.conversation.viewport')).rect;await click('ai.sessions');await visible('ai.sessions.menu');await h.sleep(220);const small=await visible('ai.sessions.menu');assert.deepEqual((await visible('ai.conversation.viewport')).rect,compact);assert(small.rect.x>=8&&small.rect.y>=8&&small.rect.x+small.rect.w<=852&&small.rect.y+small.rect.h<=472);await capture('02-session-popover-compact');report.checks.push('Compact window keeps popover within viewport and transcript unchanged');report.status='passed';

}catch(e){report.status='failed';report.error=String(e);await capture('failure').catch(()=>{});process.exitCode=1;}
finally{app.kill('SIGTERM');if(app.exitCode===null&&app.signalCode===null)await new Promise(r=>app.once('close',r));await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2))}
console.log(JSON.stringify(report));
