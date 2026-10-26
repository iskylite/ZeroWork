/** Production button/layout audit. Read-only navigation plus isolated Local terminal.
 * Geometry candidates are reported separately from behavior assertions: truncation,
 * scroll viewports and intentionally clipped visuals require source/pixel review. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,realpath,open,readFile,writeFile,rm,readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {waitForServerReady,waitFor,query,clickTestId,key,type_,resizeWindow,screenshot,sleep,scrollAt,mouseMove} from '../zig-out/share/zenit/harness/client.ts';
assert(process.argv[2],'output directory required');const out=resolve(process.argv[2]);await mkdir(out,{recursive:true});assert.equal((await readdir(out)).length,0,'use a fresh evidence directory');
const binary=resolve('zig-out/bin/zerowork'),pathOnly=process.argv[3]==='path';
const longDirectory='/Users/fixture/Downloads/团队服务器归档与诊断输出/production-cluster-2026-10-26/very-long-download-destination';
const report:any={status:'running',sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),screens:[],checks:[],buttons:{},overflow_candidates:[],limits:['Synthetic Harness input; physical pointer/IME/OS picker not verified.','No external connections, destructive user-data actions or external AI calls.','Button rectangles cannot prove glyph ink fits: source metrics and pixel review are also required.']};
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-buttons-'))),rpc=join(iso,'rpc'),data=join(iso,'data');await mkdir(rpc);await mkdir(data);await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[transfer]\ndownload_dir="'+longDirectory+'"\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});const ended=new Promise<void>(done=>app.once('close',()=>done()));
const shown=(n:any)=>n?.rect&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const flat=(n:any):any[]=>shown(n)?[n,...(n.children??[]).flatMap(flat)]:[];
const visible=async(id:string)=>waitFor(async()=>{const q=await query(id);assert(Array.isArray(q),`oversized query ${id}`);return q.find(shown)??null},8000);
const click=async(id:string)=>{await visible(id);assert((await clickTestId(id)).ok,id);await sleep(100)};
const hidden=async(id:string)=>waitFor(async()=>!(await query(id)).some(shown)||null,8000);
const edit=async(id:string,value:string)=>{await click(id);await key('a',{cmd:true});await type_(value)};
const inside=(a:any,b:any)=>a.x>=b.x-0.6&&a.y>=b.y-0.6&&a.x+a.w<=b.x+b.w+0.6&&a.y+a.h<=b.y+b.h+0.6;
function scan(n:any,screen:string,path:string[]=[]){
 if(!shown(n))return;const name=n.test_id??n.component??n.tag,trail=[...path,name];
 if(n.component==='Button'){
  const text=flat(n).filter(v=>v.text).map(v=>v.text).join(' '),id=n.test_id??`node-${n.id}`;
  report.buttons[id]={text,rect:n.rect,screen};
  for(const leaf of flat(n).filter(v=>v.text))if(!inside(leaf.rect,n.rect))report.overflow_candidates.push({screen,kind:'button-text',id,text:leaf.text,button:n.rect,content:leaf.rect});
 }
 for(const c of n.children??[]){
  if(shown(c)&&c.text&&!inside(c.rect,n.rect))report.overflow_candidates.push({screen,kind:'text-parent',path:trail.join('/'),text:c.text,parent:n.rect,content:c.rect});
  scan(c,screen,trail);
 }
}
async function capture(name:string,ids:string[]){await sleep(180);const nodes:any={};for(const id of ids){const q=await query(id);nodes[id]=q;if(Array.isArray(q))for(const n of q)scan(n,name);else report.screens.push({name,id,query_limit:true});}await writeFile(join(out,name+'.json'),JSON.stringify(nodes,null,2));assert((await screenshot(join(out,name+'.png'))).ok);report.screens.push({name,ids});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
async function reveal(id:string){for(let i=0;i<14;i++){const n=await visible(id),v=await visible('settings.viewport');if(n.rect.y>=v.rect.y&&n.rect.y+n.rect.h<=v.rect.y+v.rect.h)return;await scrollAt(v.rect.x+v.rect.w/2,v.rect.y+v.rect.h/2,0,v.rect.y+8-n.rect.y);await sleep(100)}throw Error('Cannot reveal '+id)}
const sectionIds:Record<string,string[]>={appearance:['settings.appearance.themes','settings.appearance.font','settings.appearance.materials','settings.appearance.aids','settings.appearance.app_icon'],keys:['settings.keys.tabs','settings.keys.terminal'],ssh:['settings.ssh.connection','settings.ssh.reconnect','settings.ssh.socks','settings.ssh.authentication'],transfer:['settings.transfer.connection','settings.transfer.engine','settings.transfer.defaults'],ai:['settings.ai.permissions','settings.ai.context','settings.ai.attachments','settings.ai.behavior','settings.ai.providers'],plugins:['settings.plugins'],notifications:['settings.notifications.events','settings.notifications.attention'],data:['settings.data.location','settings.data.history','settings.data.actions']};
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 if(pathOnly){
  await click('toolbar.settings');await edit('settings.search','默认下载目录');
  for(const [w,h] of [[1440,900],[860,480]]){await resizeWindow(w,h);await visible('settings.field.download_dir');await capture(`long-directory-${w}`,['settings.field.download_dir','settings.transfer.defaults','settings.footer']);
   const button=await visible('settings.field.download_dir'),label=await visible('settings.directory.label');assert(inside(label.rect,button.rect),'path label is constrained by field');
   await mouseMove(420,310);await sleep(120);await mouseMove(button.rect.x+button.rect.w/2,button.rect.y+button.rect.h/2);const tip=await visible('settings.directory.tooltip');assert(flat(tip).map((n:any)=>n.text??'').join('').includes(longDirectory),'full path retained');assert(inside(tip.rect,{x:0,y:0,w,h}));assert(tip.rect.h>30,'full path wraps');await capture(`long-directory-tooltip-${w}`,['settings.directory.tooltip']);await key('escape');await hidden('settings.directory.tooltip');await visible('settings.search');await mouseMove(420,310);await sleep(120);}
 }else{
 for(const [w,h] of [[1440,900],[860,480]]){
  await resizeWindow(w,h);const local=await visible('workspace.empty.local'),choose=await visible('workspace.empty.choose');assert(local.rect.x+local.rect.w+7<=choose.rect.x);await capture(`empty-${w}`,['workspace.empty','workspace.sidebar']);
  await click('workspace.empty.choose');await visible('quick.query');await edit('quick.query','no-such-audit-host');await capture(`quick-${w}`,['quick.connect']);await click('quick.clear');await click('quick.close');await hidden('quick.connect');report.checks.push(`quick clear/close ${w}`);
  await click('toolbar.transfers');await capture(`transfers-${w}`,['transfer.panel','transfer.empty']);await key('escape');
  await click('toolbar.settings');
  for(const [page,ids] of Object.entries(sectionIds)){
   await click('settings.nav.'+page);await capture(`settings-${page}-${w}`,['settings.footer',...ids]);
   const vp=await visible('settings.viewport');await scrollAt(vp.rect.x+vp.rect.w/2,vp.rect.y+vp.rect.h/2,0,-2400);await capture(`settings-${page}-bottom-${w}`,['settings.footer',...ids]);
   for(const id of ids){const q=await query(id);if(!q.some(shown))continue;const accordion=q.find(shown);const body=accordion.children?.find((n:any)=>n.test_id==='accordion.content');if(!body)continue;const head=accordion.children.find((n:any)=>n.test_id?.endsWith('.header'));if(!head)continue;await reveal(head.test_id);if(body.rect.h===0)await click(head.test_id);await capture(`${id.replaceAll('.','-')}-expanded-${w}`,[id,'settings.footer']);report.checks.push(`section expand/reachable ${id} ${w}`);}

  }
  const before=await readFile(join(data,'config.toml'),'utf8');await click('settings.save');assert.equal(await readFile(join(data,'config.toml'),'utf8'),before,'unchanged disabled save has no write');
  await click('settings.close');await hidden('settings.panel');report.checks.push(`all 8 settings navigation/scroll/close ${w}`);
 }
 await click('workspace.empty.local');await visible('terminal.surface');report.checks.push('Local terminal actually opens');
 for(const [w,h] of [[1440,900],[860,480]]){
  await resizeWindow(w,h);await capture(`local-${w}`,['local.statusbar','tabs.strip']);
  await click('ai.strip');await visible('ai.prompt');await capture(`ai-${w}`,['ai.panel']);await click('ai.collapse');await visible('ai.strip');report.checks.push(`assistant open/collapse ${w}`);
  await key('r',{cmd:true,shift:true});await visible('tabs.rename');await capture(`rename-${w}`,['tabs.rename']);await key('escape');await hidden('tabs.rename');report.checks.push(`rename cancel ${w}`);
 }
 }
 report.status='passed_behavior_pending_candidate_review';
}catch(e){report.status='failed';report.error=String(e);await capture('failure',['workspace.empty','settings.footer','quick.connect','settings.directory.tooltip','settings.field.download_dir']).catch(()=>{});process.exitCode=1;}
finally{if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await Promise.race([ended,sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}await log.close();await rm(iso,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,buttons:Object.keys(report.buttons).length,candidates:report.overflow_candidates.length,error:report.error,report:join(out,'report.json')}));}
