/** Visual checks for the production bottom-bar control; no popover actions. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,writeFile} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {waitForServerReady,query,screenshot,sleep} from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);await mkdir(out,{recursive:true});
const rpc=await mkdtemp('/tmp/zw-status-transfer-');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,['--status-transfer'],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n?.rect?.w>0&&n.rect.h>0&&n.visible!==false&&n.hidden!==true;
const visible=async(id:string)=>(await query(id)).filter(shown);
try{
 await waitForServerReady();await sleep(350);
 const roots=await visible('status.transfer'),names=await visible('status.transfer.name'),percent=await visible('status.transfer.percent'),rates=await visible('status.transfer.speed'),counts=await visible('status.transfer.counts');
 await writeFile(join(out,'tree.json'),JSON.stringify({roots,names,percent,rates,counts},null,2));
 assert((await screenshot(join(out,'native.png'))).ok);
 const parents=(node:any):any[]=>[node,...(node.children??[]).flatMap(parents)];
 const badges=roots.flatMap(parents).filter(n=>n.children?.some(c=>c.test_id==='status.transfer.counts')&&shown(n));
 assert.equal(roots.length,7);assert.equal(rates.length,4);assert.equal(badges.length,6);
 for(const root of roots)assert.equal(root.rect.h,26);
 for(const rate of rates){assert(rate.rect.w>0&&rate.rect.w<76);const root=roots.find(r=>rate.rect.y>=r.rect.y&&rate.rect.y<r.rect.y+r.rect.h);assert(root);assert(rate.rect.x+rate.rect.w<=root.rect.x+root.rect.w)}
 for(const p of percent){const root=roots.find(r=>p.rect.y>=r.rect.y&&p.rect.y<r.rect.y+r.rect.h);assert.equal(p.rect.w,root===roots[3]||root===roots[4]?36:28)}
 assert.equal(roots.at(-1).rect.w,240);
 assert(roots[5].rect.w<140,'Idle fits its label');assert.equal(roots[0].rect.w,280);assert.equal(roots[4].rect.w,220);for(const b of badges){assert.equal(b.rect.w,18);assert.equal(b.rect.h,18)}for(const c of counts)assert(/^[0-9]+$/.test(c.text));assert(!rates.some(n=>n.text==='已完成'));
 for(const [i,name] of names.entries()){assert(name.rect.x>=roots[i].rect.x);assert(name.rect.x+name.rect.w<=roots[i].rect.x+roots[i].rect.w)}
 await writeFile(join(out,'tree.json'),JSON.stringify({roots,names,percent,rates,counts},null,2));
 assert((await screenshot(join(out,'native.png'))).ok);
 await writeFile(join(out,'report.json'),JSON.stringify({passed:true,states:7,height:26,active_width:280,completed_width:220,percent_width:28,rate_width:'content',badge_diameter:18,narrow_width:240,popover_actions:false},null,2));
 console.log(JSON.stringify({passed:true,out}));
}finally{if(app.exitCode===null)app.kill('SIGTERM');await ended;await log.close()}
