/** All settings pages: compact hierarchy, contextual help and protected notices. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,realpath,open,readFile,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);await mkdir(out,{recursive:true});
const pages:any={appearance:['settings.appearance.app_icon.header','settings.appearance.themes.header','settings.materials.header','settings.appearance.font.header','settings.appearance.aids.header'],keys:['settings.keys.tabs.header','settings.keys.terminal.header'],ssh:['settings.ssh.connection.header','settings.ssh.reconnect.header','settings.ssh.socks.header','settings.ssh.authentication.header'],transfer:['settings.transfer.connection.header','settings.transfer.engine.header','settings.transfer.defaults.header'],ai:['settings.ai.permissions.header','settings.ai.context.header','settings.ai.attachments.header','settings.ai.behavior.header'],plugins:['已内置','协议扩展'],notifications:['settings.notifications.events.header','settings.notifications.attention.header'],data:['settings.data.location.header','settings.data.history.header','settings.data.actions.header']};
const markers:any={appearance:'settings.appearance.help.cursor_style',keys:'settings.key.fixed.accept_completion',ssh:'settings.help.keepalive_sec',transfer:'settings.help.shared_pacing_kbps',ai:'settings.help.error_hint',notifications:'settings.notifications.permission.info',data:'settings.path.配置文件'};
const flat=(n:any):any[]=>[n,...(n.children??[]).flatMap(flat)],text=(n:any)=>flat(n).map(n=>n.text??'').join(' '),shown=(n:any)=>!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const report:any={status:'running',runs:[],limits:['Temporary isolated config; no real credentials, permission requests or destructive actions.','No physical IME or VoiceOver verification.']};
for(const theme of ['dark','light']){
 const base=await realpath(await mkdtemp('/private/tmp/zw-hierarchy-')),data=join(base,'data'),rpc=join(base,'rpc');await mkdir(data);await mkdir(rpc);await writeFile(join(data,'hosts.toml'),'');
 const initial=`[ui]\ntheme="${theme}"\n[ai]\ndefault_provider="Fixture"\n[[ai.providers]]\nid="Fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:9/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="model"\ndefault=true\ncontext_window=128000\n`;
 await writeFile(join(data,'config.toml'),initial);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,theme+'.log'),'w'),app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
 const current=async(id:string)=>(await h.query(id)).find(shown)??null,node=(id:string)=>h.waitFor(()=>current(id));
 async function reveal(id:string){for(let i=0;i<30;i++){const n=await node(id),v=await node('settings.viewport');if(n.rect.y>=v.rect.y&&n.rect.y+n.rect.h<=v.rect.y+v.rect.h)return n;await h.scrollAt(v.rect.x+v.rect.w/2,v.rect.y+v.rect.h/2,0,n.rect.y<v.rect.y?180:-180);await h.sleep(50);}throw Error('Cannot reveal '+id);}
 async function click(id:string,scroll=false){if(scroll)await reveal(id);await node(id);assert((await h.clickTestId(id)).ok,id);await h.sleep(90);}
 async function top(){const v=await node('settings.viewport');await h.scrollAt(v.rect.x+v.rect.w/2,v.rect.y+30,0,4000);await h.sleep(70);}
 async function capture(name:string){assert((await h.screenshot(join(out,name+'.png'))).ok);}
 const run:any={theme,pages:[],hints:[]};report.runs.push(run);
 try{
  await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(1440,900);await click('toolbar.settings');
  for(const [page,headers] of Object.entries(pages) as any){
   await click('settings.nav.'+page);
   for(const id of headers){const n=await node(id),summary=flat(n).find(n=>n.test_id?.endsWith('.summary'));if(summary&&!summary.hidden)await click(id,true);}
   await top();await capture(theme+'-'+page+'-top');
   for(const id of headers){const n=await node(id),summary=flat(n).find(n=>n.test_id?.endsWith('.summary'));if(summary)assert(summary.hidden,'expanded summary '+id);}
   if(page==='ai'){const m=await reveal('settings.ai.provider.0.keychain');await h.mouseMove(m.rect.x+m.rect.w/2,m.rect.y+m.rect.h/2);assert(text(await node('settings.ai.provider.0.keychain.tooltip')).includes('钥匙串'));await h.mouseMove(10,10);run.hints.push('settings.ai.provider.0.keychain');}
   const marker=markers[page];if(marker){const m=await reveal(marker);assert(m.rect.h<=32);await h.mouseMove(m.rect.x+m.rect.w/2,m.rect.y+m.rect.h/2);assert(text(await node(marker+'.tooltip')).trim().length>0);await capture(theme+'-'+page+'-hint');await click(marker);await h.key('escape');await node('settings.panel');await h.mouseMove(10,10);run.hints.push(marker);}
   if(page==='ssh')for(const key of ['buffer_input','socks_bind']){const n=await node('settings.help.content.'+key);assert(text(n).trim().length>0);}
   if(page==='ai'){const n=await node('settings.help.content.redact_ip');assert(text(n).includes('终端正文与附件'));}
   if(page==='plugins')assert(!text(await node('settings.content')).includes('内置协议随应用管理。'));
   const v=await node('settings.viewport');await h.scrollAt(v.rect.x+v.rect.w/2,v.rect.y+v.rect.h/2,0,-4000);await h.sleep(100);await capture(theme+'-'+page+'-bottom');
   await h.resizeWindow(860,480);await top();const footer=(await node('settings.footer')).rect;await capture(theme+'-'+page+'-compact-top');
   await h.scrollAt((await node('settings.viewport')).rect.x+100,300,0,-4000);await h.sleep(100);assert.deepEqual((await node('settings.footer')).rect,footer);await capture(theme+'-'+page+'-compact-bottom');
   if(page==='appearance'){await reveal('settings.field.cursor_style');await capture(theme+'-appearance-cursor-compact');const group=await node('settings.field.cursor_style');assert.equal(group.rect.w,210);const opts=await Promise.all(['block','bar','underline'].map(x=>node('settings.option.cursor_style.'+x)));for(const n of opts)assert(n.rect.x>=group.rect.x&&n.rect.x+n.rect.w<=group.rect.x+group.rect.w+.5);}
   run.pages.push(page);await h.resizeWindow(1440,900);
  }
  await click('settings.nav.ssh');await top();await click('settings.ssh.connection.header',true);const summary=await node('settings.ssh.connection.summary');assert(text(summary).length>0);await click('settings.ssh.connection.header',true);await node('settings.help.keepalive_sec');
  assert.equal(await readFile(join(data,'config.toml'),'utf8'),initial);run.status='passed';
 }catch(e){run.status='failed';run.error=String(e);report.status='failed';await capture(theme+'-failure').catch(()=>{});throw e;}
 finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));if(app.exitCode===null)app.kill('SIGTERM');await ended;await log.close();}
}
report.status='passed';await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
