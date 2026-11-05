/** Native session tags, second-line icon actions and compact geometry.
 * Uses an isolated Local session and a loopback model; no external services.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,writeFile,open} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-session-tags-build');
const out=resolve(process.argv[2]??'/tmp/zw-session-tags-native');await mkdir(out,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-conversation-ui-'),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');for(const dir of [data,rpc,zdot])await mkdir(dir);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='conversation-ui%# '\n");
const frame=(content:string)=>'data: '+JSON.stringify({choices:[{index:0,delta:{content}}]})+'\n\n';
const requests:any[]=[];let held:any=null,holdFirst=true;
const server=createServer(async(req,res)=>{if(req.method!=='POST'){res.end('{"data":[{"id":"conversation-fixture"}]}');return}let raw='';for await(const bytes of req)raw+=bytes;const body=JSON.parse(raw);requests.push(body);res.writeHead(200,{'content-type':'text/event-stream'});
 if(!body.tools?.length){res.end(frame('本地测试会话')+'data: [DONE]\n\n');return}
 const users=body.messages.filter((m:any)=>m.role==='user').map((m:any)=>String(m.content));
 if(holdFirst&&users.some((s:string)=>s.includes('FIRST_TASK'))){holdFirst=false;held=res;res.write(frame('正在处理第一个请求。'));return}
 res.end(frame('ANSWER_FINISHED')+'data: [DONE]\n\n');
});await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n[ai]\ndefault_provider="conversation-fixture"\npermission_mode="confirm"\nfollow_up_mode="queue"\n[[ai.providers]]\nid="conversation-fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="conversation-fixture"\ncontext_window=200000\ndefault=true\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const h=await import(join(prefix,'share/zenit/harness/client.ts'));const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZDOTDIR:zdot,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));const alive=()=>app.exitCode===null&&app.signalCode===null;
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(n=>n.text??'').join(' ');
const visible=(id:string)=>h.waitFor(async()=>{assert(alive(),'native App must remain alive');return(await h.query(id)).find(shown)??null},20000);
const click=async(id:string)=>{report.last_action=id;await visible(id);assert((await h.clickTestId(id)).ok,id)};
const absent=(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,15000);
const input=async(value:string)=>{await click('ai.prompt');await h.key('a',{cmd:true});await h.type_(value)};
const send=async(value:string)=>{await input(value);await click('ai.send')};
const report:any={status:'running',isolation:{directory:iso,data,rpc},checks:[],screenshots:[],geometry:{}};
async function capture(name:string,keepPointer=false){if(!keepPointer)await h.mouseMove(1,1);const ids=['ai.sessions.menu','ai.session.first_line','ai.session.second_line','ai.session.phase_tag','ai.session.bound','ai.session.unbound','ai.history'];const geometry:any={};for(const id of ids){const node=(await h.query(id)).find(shown);if(node)geometry[id]=node.rect}report.geometry[name]=geometry;await writeFile(join(out,name+'.json'),JSON.stringify(geometry,null,2));assert((await h.screenshot(join(out,name+'.png'))).ok);report.screenshots.push(join(out,name+'.png'))}

try{
 await h.waitForServerReady(60000);await h.resizeWindow(1200,900);await click('workspace.empty.local');await visible('terminal.surface');await click('toolbar.ai');await send('FIRST_TASK 检查当前服务器的运行状态');await h.waitFor(()=>held||null,15000);
 const inspect=async()=>{
  const rows=(await h.query('ai.sessions.menu')).flatMap(flat).filter((n:any)=>/^ai.session.row.\d+$/.test(n.test_id??'')&&shown(n));
  assert(rows.length>0);
  for(const row of rows){const nodes=flat(row),first=nodes.find(n=>n.test_id==='ai.session.first_line'),second=nodes.find(n=>n.test_id==='ai.session.second_line'),tag=nodes.find(n=>n.test_id==='ai.session.phase_tag'),binding=nodes.find(n=>n.test_id==='ai.session.bound'||n.test_id==='ai.session.unbound');
   assert.equal(row.rect.h,56);assert(first.rect.y+first.rect.h<=second.rect.y);assert(Math.abs(tag.rect.x+tag.rect.w-first.rect.x-first.rect.w)<1);assert.equal(binding.rect.x,second.rect.x);
   for(const action of nodes.filter(n=>/^ai.session.(jump|locate|restore|copy_use|delete).\d+$/.test(n.test_id??'')&&shown(n))){assert.equal(action.rect.w,24);assert.equal(action.rect.h,24);assert(action.rect.y>=second.rect.y&&action.rect.y+action.rect.h<=second.rect.y+second.rect.h+.6);assert(action.rect.x+action.rect.w<=second.rect.x+second.rect.w+.6);assert(!flat(action).some(n=>n.text?.trim()),'actions have icons without text')}
  }
  await writeFile(join(out,'session-tree.json'),JSON.stringify(rows,null,2));
 };
 await click('ai.close');await visible('ai.close.confirmation');await click('ai.close.confirmation.cancel');await absent('ai.close.confirmation');await visible('ai.stop');
 await click('ai.sessions');await visible('ai.session.status.running');assert(text(await visible('ai.session.phase_tag')).includes('运行中'));await inspect();await capture('01-running-bound');
 const locate=await visible('ai.session.locate.1');await h.mouseMove(locate.rect.x+12,locate.rect.y+12);await h.sleep(700);await capture('02-locate-tooltip',true);
 await click('ai.sessions.close');await click('ai.stop');await absent('ai.stop');await click('ai.sessions');await visible('ai.session.status.stopped');assert(text(await visible('ai.session.phase_tag')).includes('已暂停'));await inspect();await capture('03-paused');
 await click('ai.sessions.close');await send('COMPLETE_TASK 完成状态检查');await absent('ai.stop');await click('ai.sessions');await visible('ai.session.status.done');await inspect();await capture('03b-completed');await click('ai.sessions.close');await click('ai.session.new');await visible('ai.session.close.accept');await click('ai.session.close.accept');await absent('ai.session.close.confirmation');await click('ai.sessions');await visible('ai.session.row.2');await visible('ai.session.unbound');await inspect();await capture('04-two-rows');
 await h.resizeWindow(860,480);await inspect();const menu=await visible('ai.sessions.menu');assert(menu.rect.x>=8&&menu.rect.x+menu.rect.w<=852&&menu.rect.y+menu.rect.h<=472);await capture('05-compact');
 await click('ai.session.jump.1');await visible('ai.history');await click('ai.history.close');
 await click('ai.sessions');await click('ai.session.copy_use.1');await absent('ai.sessions.menu');await click('ai.sessions');await visible('ai.session.row.3');await inspect();await capture('06-copy-used');
 report.checks.push('Two-line geometry and icon-only controls at normal and compact sizes; bound/unbound tags; running-to-paused phase updates; read-only view and copy-use clicks');report.status='passed';
}catch(error){report.error=String(error);report.status='failed';process.exitCode=1;await capture('failure').catch(()=>{});}
finally{
 if(held){held.destroy();held=null}try{if(alive()){await Promise.race([h.request('POST','/quit'),ended]);const start=performance.now();while(alive()&&performance.now()-start<15000){for(const id of ['settings.close.discard','groups.close.accept','local.close.accept','session.close.accept'])try{if(!alive())break;if((await h.query(id)).some(shown))await h.clickTestId(id)}catch{}await Promise.race([ended,h.sleep(80)])}}}catch(e){report.quit_error=String(e)}
 if(alive()){report.forced=true;app.kill('SIGTERM');await ended}report.exit_code=app.exitCode;report.signal=app.signalCode;if(report.forced||app.exitCode!==0){report.status='failed';process.exitCode=1}server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,out}));
}
