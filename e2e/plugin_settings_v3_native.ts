/** Plugin V3 contract against an isolated native process and real registry. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,realpath,open} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep,scrollAt,inputState} from '../vendor/zenit/e2e/client.ts';
const [binaryArg,outputArg]=process.argv.slice(2);assert(binaryArg&&outputArg);
const binary=resolve(binaryArg),output=resolve(outputArg);await mkdir(output,{recursive:true});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-plugin-v3-'))),rpc=join(iso,'rpc'),data=join(iso,'data');await mkdir(rpc);await mkdir(data);
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_size=14\n',{mode:0o600});
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(output,'native.log'),'w');const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});const ended=new Promise<void>(r=>app.once('close',()=>r()));
const shown=(n:any)=>n.visible!==false&&n.rect.w>0&&n.rect.h>0&&(n.effective_opacity??1)>0;
const text=(n:any)=>typeof n.text==='string'?n.text:n.text?.content??'';
const node=async(id:string):Promise<any>=>waitFor(async()=>(await query(id)).find(shown)??null,12000);
const click=async(id:string)=>{const n=await node(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await sleep(180);};
const shot=async(name:string)=>{await sleep(400);const path=join(output,name+'.png');await screenshot(path);return path;};
const hidden=async(id:string)=>{await waitFor(async()=>!(await query(id)).some(shown)?true:null,5000);};
const report:any={status:'running',checks:[],screenshots:[],iso};
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
 await resizeWindow(1440,900);await click('toolbar.settings');await click('settings.nav.ssh');await click('settings.field.keepalive_sec');await key('a',{cmd:true});await key('backspace');await type_('44');
 await click('settings.nav.plugins');
 for(const [id,desc] of [['local','本机 Shell 与终端会话'],['ssh','远程终端、认证与端口转发'],['sftp','目录浏览、文件读写与文件传输']]){
  const row=await node(`settings.plugin.${id}.row`);assert.equal(row.rect.h,66);assert.equal(text(await node(`settings.plugin.${id}.description`)),desc);
  assert((await query(`settings.plugin.${id}.version`)).filter(shown).length===1);
 }
 report.geometry={row:(await node('settings.plugin.local.row')).rect,footer:(await node('settings.footer')).rect};
 report.screenshots.push(await shot('plugins-standard'));
 await click('settings.plugin.ssh.version');await node('settings.plugin.ssh.version.dialog');assert.equal(text(await node('settings.plugin.ssh.version.message')),'静态链接插件随应用管理');report.screenshots.push(await shot('ssh-version'));
 await key('escape');await hidden('settings.plugin.ssh.version.dialog');await sleep(240);await node('settings.plugin.ssh.row');await node('settings.close');
 await click('settings.plugin.local.permissions');await node('settings.plugin.local.permissions.dialog');report.screenshots.push(await shot('local-permissions'));await click('settings.plugin.local.permissions.close');await hidden('settings.plugin.local.permissions.dialog');
 await click('settings.plugin.sftp.permissions');const d=await node('settings.plugin.sftp.permissions.dialog');assert((await clickAt(d.rect.x-15,d.rect.y+10)).ok);await hidden('settings.plugin.sftp.permissions.dialog');await sleep(250);await node('settings.plugin.sftp.row');
 await click('settings.nav.ssh');assert.equal((await inputState('settings.field.keepalive_sec')).buffer,'44');report.checks.push('all plugin rows66/descriptions, unique actions, Esc/button/scrim close only detail layer, draft retained');
 await click('settings.nav.plugins');await resizeWindow(860,480);await sleep(250);const footer=(await node('settings.footer')).rect,viewport=(await node('settings.viewport')).rect;
 report.screenshots.push(await shot('plugins-compact'));await scrollAt(viewport.x+viewport.w/2,viewport.y+viewport.h/2,0,-500);await sleep(200);assert.equal((await node('settings.footer')).rect.y,footer.y);report.screenshots.push(await shot('plugins-compact-scrolled'));report.checks.push('compact scroll keeps settings footer fixed');
 await scrollAt(viewport.x+viewport.w/2,viewport.y+viewport.h/2,0,500);await sleep(200);await click('settings.plugin.local.permissions');const md=(await node('settings.plugin.local.permissions.dialog')).rect;assert(md.x>=0&&md.y>=0&&md.x+md.w<=860&&md.y+md.h<=480);await node('settings.plugin.local.permissions.close');report.screenshots.push(await shot('permissions-compact'));await key('escape');await hidden('settings.plugin.local.permissions.dialog');
 report.status='passed_pending_pixel_review';
}catch(e){report.status='failed';report.error=String(e);report.screenshots.push(await shot('failure'));throw e;}finally{await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));if(app.exitCode===null)app.kill('SIGTERM');await ended;await log.close();}
console.log(JSON.stringify(report));
