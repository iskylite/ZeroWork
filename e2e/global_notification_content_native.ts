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
try{await h.waitForServerReady(30000);await h.resizeWindow(1280,720);
await h.clickTestId('fixture.connection-failure');await visible('notifications.toast.0');
await h.clickTestId('fixture.connection-failure');await visible('notifications.toast.1');
const failureTitle='连接失败: HandshakeFailed';
await h.waitFor(async()=>{const titles=(await h.query('notifications.title')).filter(shown),metadata=(await h.query('notifications.metadata')).filter(shown);return titles.length===2&&metadata.length===2&&titles.every((n:any,i:number)=>n.rect.h===18&&Math.abs(n.rect.x-metadata[i].rect.x)<0.5)||null;},7000);
for(const i of [0,1]){const card=await visible('notifications.toast.'+i);assert(card.rect.h<=60,'long title without actions stays compact');assert(text(card).includes(failureTitle));assert.equal(text(card).split('ScaleX40-AI01').length-1,1,'session name appears once below the title');}
assert((await h.query('notifications.title')).filter(shown).every((n:any)=>text(n)===failureTitle));
await h.screenshot(dir+'/connection-failure.png');
await h.clickTestId('notifications.dismiss.0');await h.clickTestId('notifications.dismiss.0');
await h.clickTestId('toolbar.notifications');await visible('notifications.history');
assert((await h.query('notifications.history.title')).filter(shown).every((n:any)=>text(n)===failureTitle));
for(const row of (await h.query('notifications.history.record')).filter(shown))assert.equal(text(row).split('ScaleX40-AI01').length-1,1);
await h.screenshot(dir+'/connection-failure-history.png');
const expand=(await h.query('notifications.history.expand')).find(shown);assert(expand);await h.clickAt(expand.rect.x+expand.rect.w/2,expand.rect.y+expand.rect.h/2);
const expanded=await visible('notifications.history.details');assert(text(expanded).includes(failureTitle),'history expansion retains the complete error title');
await h.screenshot(dir+'/connection-failure-expanded.png');await h.clickTestId('notifications.history.close');
await h.resizeWindow(1000,700);await h.clickTestId('fixture.scenes');await visible('notifications.toast.2');await h.screenshot(dir+'/scenes.png');
let cards=await Promise.all([0,1,2].map(i=>visible('notifications.toast.'+i)));for(const [i,expected] of ['文件传输失败','SSH 连接已断开','AI 执行结果待核查'].entries()) assert(text(cards[i]).includes(expected));assert(text(cards[0]).includes('prod-web-01 · backup-2026-10-27.tar.gz'));for(const card of cards){assert(card.rect.h<=109.5);assert(!text(card).includes('prod-api-02 · prod-api-02'));}console.log(cards.map(text));await writeFile(dir+'/scenes.json',JSON.stringify(cards,null,2));
for(const label of ['查看传输','查看连接','查看对话']){const buttons=(await h.query('notifications.action')).filter(shown);const b=buttons.find((b:any)=>text(b)===label);assert(b,label);assert.equal(b.rect.h,24);await h.clickAt(b.rect.x+b.rect.w/2,b.rect.y+b.rect.h/2);await h.waitFor(async()=>text(await visible('fixture.result')).includes(label==='查看传输'?'已定位传输任务':label==='查看连接'?'已定位 SSH 连接':'已定位 AI 对话')||null);}
await h.clickTestId('fixture.outcomes');await visible('notifications.toast.1');assert(!(await h.query('notifications.toast.2')).some(shown),'cancelled transfer stays silent');await h.screenshot(dir+'/outcomes.png');cards=await Promise.all([0,1].map(i=>visible('notifications.toast.'+i)));for(const [i,expected] of ['已恢复','已完成'].entries()) assert(text(cards[i]).includes(expected));console.log(cards.map(text));
for(let i=0;i<2;i++){await h.clickTestId('notifications.dismiss.0');await h.sleep(120);}await h.clickTestId('fixture.long');await visible('notifications.toast.0');await h.resizeWindow(860,480);await h.screenshot(dir+'/long.png');const buttons=(await h.query('notifications.action')).filter(shown);for(const b of buttons)assert.equal(b.rect.h,24);await writeFile(dir+'/report.json',JSON.stringify({status:'passed',checks:['event-only titles in toasts and history','session identity shown once','deduplicated SSH source and object','compact long titles without actions','title and metadata alignment','complete error title in expanded history','original-result actions','cancelled transfer stays silent','status labels','merged source and object','compact cards at 109 points','24-point actions','long content at 860x480','dismissal']},null,2));console.log('actions, statuses, compact long content and dismissal passed');console.log(dir);
}finally{p.kill('SIGTERM');await log.close();await rm(rpc,{recursive:true,force:true});}
