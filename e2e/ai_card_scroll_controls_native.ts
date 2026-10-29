/** Native horizontal output and vertical containment on the production execution-card fixture. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,open} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'dist/patch-card-scroll-candidate');
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'dist/ui-acceptance/patch-card-scroll-controls');await mkdir(out,{recursive:true});
const rpc=await mkdtemp('/tmp/zw-card-scroll-controls-');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const binary=join(prefix,'bin/execution-result-preview'),log=await open(join(out,'app.log'),'w');
const app=spawn(binary,['--theme=dark','--state=running','--long-output'],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<any>(done=>app.once('exit',(code,signal)=>done({code,signal})));
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
const rect=async(id:string)=>(await visible(id)).rect;
const report:any={status:'running',binary,checks:[],limits:['Uses the existing production execution-card native fixture with immutable synthetic receipts.','Synthetic input exercises native dispatch and rendering; no physical touchpad hardware was driven.']};
try{
 await h.waitForServerReady(15000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(360,420);
 const body=await rect('ai.execution.result.details');assert.equal(body.h,150);
 await h.scrollAt(body.x+40,body.y+body.h/2,0,-100000);await h.sleep(80);const tree=await h.query('ai.execution.result.details');const findOutputViewport=(n:any):any=>{if(n.component==='ScrollArea'&&n.children?.[0]?.children?.some((c:any)=>c.test_id==='ai.execution.result.terminal_output'))return n;for(const child of n.children??[]){const result=findOutputViewport(child);if(result)return result}return null};const horizontalViewport=findOutputViewport(tree[0]);assert(horizontalViewport);const initialThumb=horizontalViewport.children[2];assert(initialThumb.rect.w>0&&initialThumb.rect.h>0);await h.mouseMove(2,400);await h.sleep(3000);const afterIdle=findOutputViewport((await h.query('ai.execution.result.details'))[0]),idleThumb=afterIdle.children[2];assert(idleThumb.rect.w>0&&idleThumb.rect.h>0);assert((idleThumb.opacity??1)>0);report.idle_thumb={node_id:idleThumb.id,rect:idleThumb.rect,opacity:idleThumb.opacity??1};assert(idleThumb.rect.y>=body.y&&idleThumb.rect.y+idleThumb.rect.h<=body.y+body.h+.1,'Horizontal thumb must be inside the clipped card viewport at the output end');assert((await h.screenshot(join(out,'idle-horizontal-thumb.png'))).ok);report.checks.push('Initially overflowing horizontal output retains its native thumb after three idle seconds before any horizontal input');await h.scrollAt(body.x+40,body.y+body.h/2,0,100000);await h.sleep(80);
 await h.scrollAt(body.x+40,body.y+body.h/2,0,-110);await h.sleep(100);
 const text=await rect('ai.execution.result.terminal_output');assert(text.w>body.w);
 const x=body.x+40,y=Math.min(body.y+body.h-10,Math.max(body.y+10,text.y+10));assert(y>=text.y&&y<text.y+text.h);
 await h.scrollAt(x,y,-45,0);await h.sleep(70);let now=await rect('ai.execution.result.terminal_output');assert(now.x<text.x-30);assert.equal(now.y,text.y);report.checks.push('Horizontal wheel moves the long execution output without moving its vertical body');
 const initial=now;await h.scrollAt(x,y,0,0,{phase:'began'});await h.scrollAt(x,y,-30,0,{phase:'changed'});await h.scrollAt(x,y,-20,0,{phase:'changed'});await h.scrollAt(x,y,0,0,{phase:'ended'});await h.scrollAt(x,y,-20,0,{momentum:'began'});await h.scrollAt(x,y,-10,0,{momentum:'changed'});await h.scrollAt(x,y,0,0,{momentum:'ended'});await h.sleep(80);now=await rect('ai.execution.result.terminal_output');assert(now.x<initial.x-40);assert.equal(now.y,initial.y);report.checks.push('Horizontal phased trackpad and momentum pass through the vertical card capture');
 const beforeVertical=now;await h.scrollAt(x,y,0,-40);await h.sleep(80);now=await rect('ai.execution.result.terminal_output');assert(now.y<beforeVertical.y-20);assert.equal(now.x,beforeVertical.x);report.checks.push('Vertical input over the horizontal output scrolls the surrounding bounded card');
 assert((await h.screenshot(join(out,'horizontal-and-vertical.png'))).ok);await writeFile(join(out,'tree.json'),JSON.stringify(await h.tree(),null,2));report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await h.screenshot(join(out,'failure.png')).catch(()=>{})}
finally{
 if(app.exitCode===null&&app.signalCode===null){try{await h.request('POST','/quit');await h.waitFor(async()=>app.exitCode!==null||app.signalCode!==null||null,10000)}catch(error){report.shutdown_error=String(error);app.kill('SIGTERM')}}
 report.shutdown=await ended;await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
console.log(JSON.stringify(report,null,2));
