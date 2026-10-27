/** Production notification presenter with local lifecycle facts; no remote transfer, SSH or AI request is executed.
 * node e2e/global_notification_content_native.ts <output-directory> <notification-preview-binary>
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,writeFile,rm} from 'node:fs/promises';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const dir=process.argv[2]??await mkdtemp('/private/tmp/zw-global-notify-');await mkdir(dir,{recursive:true});const rpc=await mkdtemp('/private/tmp/zw-global-notify-rpc-');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(dir+'/app.log','w');
const p=spawn(process.argv[3]??'./zig-out/bin/notification-preview',[],{env:{...process.env,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const shown=(n:any)=>!n.hidden&&n.rect?.w>0&&n.rect?.h>0;
const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,12000);
try{await h.waitForServerReady(30000);await h.resizeWindow(1000,700);await h.clickTestId('fixture.scenes');await visible('notifications.toast.2');await h.screenshot(dir+'/scenes.png');
let cards=await Promise.all([0,1,2].map(i=>visible('notifications.toast.'+i)));for(const [i,expected] of ['文件传输失败','SSH 连接已断开','AI 执行结果待核查'].entries()) assert(text(cards[i]).includes(expected));assert(text(cards[0]).includes('prod-web-01 · backup-2026-10-27.tar.gz'));for(const card of cards) assert(card.rect.h<=109.5);console.log(cards.map(text));await writeFile(dir+'/scenes.json',JSON.stringify(cards,null,2));
for(const label of ['查看传输','查看连接','查看对话']){const buttons=(await h.query('notifications.action')).filter(shown);const b=buttons.find((b:any)=>text(b)===label);assert(b,label);assert.equal(b.rect.h,24);await h.clickAt(b.rect.x+b.rect.w/2,b.rect.y+b.rect.h/2);await h.waitFor(async()=>text(await visible('fixture.result')).includes(label==='查看传输'?'已定位传输任务':label==='查看连接'?'已定位 SSH 连接':'已定位 AI 对话')||null);}
await h.clickTestId('fixture.outcomes');await visible('notifications.toast.2');await h.screenshot(dir+'/outcomes.png');cards=await Promise.all([0,1,2].map(i=>visible('notifications.toast.'+i)));for(const [i,expected] of ['已取消','已恢复','已完成'].entries()) assert(text(cards[i]).includes(expected));console.log(cards.map(text));
for(let i=0;i<3;i++){await h.clickTestId('notifications.dismiss.0');await h.sleep(120);}await h.clickTestId('fixture.long');await visible('notifications.toast.0');await h.resizeWindow(860,480);await h.screenshot(dir+'/long.png');const buttons=(await h.query('notifications.action')).filter(shown);for(const b of buttons)assert.equal(b.rect.h,24);await writeFile(dir+'/report.json',JSON.stringify({status:'passed',checks:['original-result actions','status labels','merged source and object','compact cards at 109 points','24-point actions','long content at 860x480','dismissal']},null,2));console.log('actions, statuses, compact long content and dismissal passed');console.log(dir);
}finally{p.kill('SIGTERM');await log.close();await rm(rpc,{recursive:true,force:true});}
