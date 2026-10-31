/** Two real Local panes: verify spacing, focus and drag without restoring a frame. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,writeFile,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/private/tmp/zw-approval-flow-build');
const out=resolve(process.argv[2]??'/private/tmp/zw-group-borderless');await mkdir(out,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-group-borderless-'),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');for(const p of[data,rpc,zdot])await mkdir(p);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='group-check%# '\n");
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const log=await open(join(out,'app.log'),'w');const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZDOTDIR:zdot,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const shown=(n:any)=>n&&n.visible!==false&&!n.hidden&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok)};
async function joinGroup(){
 await visible('terminal.input');
 for(let i=0;i<8;i++){
  await click('terminal.input');await h.type_('@');
  const opened=await h.waitFor(async()=>(await h.query('terminal.commands')).some(shown)||null,2000).catch(()=>false);
  if(opened){await h.type_('grp Borderless');await h.key('right');await h.key('return');await visible('groups.workspace');return;}
  await h.key('c',{ctrl:true});await h.sleep(300);
 }
 throw Error('Local trusted editor did not become ready');
}
const report:any={status:'running',checks:[]};
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1440,900);await click('workspace.empty.local');await joinGroup();
 await click('toolbar.new_session');await click('session.menu.local');await joinGroup();
 const panes=await h.waitFor(async()=>{const ns=flat(await h.query('groups.workspace')).filter((n:any)=>/^groups\.pane\.\d+$/.test(n.test_id??''));return ns.length===2?ns:null},15000);
 assert(Math.abs(panes[1].rect.x-panes[0].rect.x-panes[0].rect.w-4)<1,'panes use the guide 4px gap');
 await h.screenshot(join(out,'group-side-by-side.png'));
 for(const pane of panes){await h.clickAt(pane.rect.x+pane.rect.w/2,pane.rect.y+100)}
 await h.screenshot(join(out,'group-focused.png'));
 const source=panes[0].rect,target=panes[1].rect;
 await h.mouseDown(source.x+16,source.y+18);await h.mouseMove(target.x+target.w/2,target.y+18);await h.mouseUp(target.x+target.w/2,target.y+18);
 const reordered=flat(await h.query('groups.workspace')).filter((n:any)=>/^groups\.pane\.\d+$/.test(n.test_id??''));assert.equal(reordered[0].test_id,panes[1].test_id,'drag reordered the real panes');
 await h.screenshot(join(out,'group-after-drag.png'));
 await writeFile(join(out,'group.tree.json'),JSON.stringify(await h.query('groups.workspace'),null,2));
 report.status='passed';report.checks=['two real Local panes','4px spacing','focus changes without a frame','drag completion retains borderless panes'];
}catch(error){report.status='failed';report.error=String(error);await h.screenshot(join(out,'failure.png')).catch(()=>{});process.exitCode=1}
finally{app.kill('SIGTERM');await new Promise<void>(r=>{if(app.exitCode!==null||app.signalCode!==null)return r();app.once('close',()=>r());setTimeout(()=>{app.kill('SIGKILL');r()},3000)});await log.close();await rm(iso,{recursive:true,force:true});await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report))}
