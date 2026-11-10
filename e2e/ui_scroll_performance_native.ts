/** Real Metal-window scroll workload. Milliseconds are diagnostic, not a
 * hardware-dependent FPS promise; fixture input never touches user data. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,writeFile,rm,realpath} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
const [binaryArg,outArg]=process.argv.slice(2);assert(binaryArg&&outArg,'binary output-directory');
const binary=resolve(binaryArg),out=resolve(outArg),iso=await realpath(await mkdtemp('/private/tmp/zw-scroll-perf-'));
const data=join(iso,'data'),rpc=join(iso,'rpc');
await Promise.all([mkdir(out,{recursive:true}),mkdir(data),mkdir(rpc)]);
await writeFile(join(data,'config.toml'),'[ui]\ntheme="sauber"\n[ui.materials]\nblur_px=24\n[ui.materials.background]\ntransparency=50\n');
const hostCount=Number(process.env.ZEROWORK_SCROLL_HOSTS??40);
assert(Number.isInteger(hostCount)&&hostCount>=4&&hostCount<=400,'fixture host count must be 4..400');
const groupCount=Math.min(10,Math.ceil(hostCount/4)),hostsPerGroup=Math.ceil(hostCount/groupCount);
let hosts=`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=${hostCount+1}\nnext_group_id=${groupCount+1}\n`;
for(let g=0;g<groupCount;g++)hosts+=`[[groups]]\ngroup_id=${g+1}\nrevision=1\nname="Scroll fixture ${g+1}"\ncollapsed=false\nordered_connection_ids=[${Array.from({length:Math.max(0,Math.min(hostsPerGroup,hostCount-g*hostsPerGroup))},(_,i)=>g*hostsPerGroup+i+1).join(',')}]\n`;
for(let i=0;i<hostCount;i++)hosts+=`[[hosts]]\nconnection_id=${i+1}\nrevision=1\nasset_group_id=${Math.floor(i/hostsPerGroup)+1}\nprotocol="ssh"\nname="Fixture host ${i+1}"\nhost="192.0.2.1"\nuser="fixture"\n`;
await writeFile(join(data,'hosts.toml'),hosts);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(r=>app.once('close',r)),report:any={binary,cases:[],limits:['Synthetic wheel/trackpad events use the real native dispatcher. CPU/GPU samples exclude RPC round-trip latency.','This is a local rendering workload, not live SSH/KVM network throughput.']};
const shown=(n:any)=>n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>{const nodes=await h.query(id);assert(Array.isArray(nodes),`${id}: ${JSON.stringify(nodes)}`);return nodes.find(shown)||null},15000);
async function click(id:string){
 // Several retained panels share control IDs. Use the visible instance's
 // settled coordinates, rather than scrolling the first hidden match.
 let prior='',repeats=0;
 const node=await h.waitFor(async()=>{const n=(await h.query(id)).find(shown);if(!n)return null;const at=JSON.stringify(n.rect);repeats=at===prior?repeats+1:0;prior=at;await h.sleep(80);return repeats>=2?n:null;},15000);
 const result=await h.clickAt(node.rect.x+node.rect.w/2,node.rect.y+node.rect.h/2);assert(result.ok,`${id}: ${JSON.stringify(result)}`);
}
async function workload(label:string,viewportId:string,probeId:string|null,trackpad=false){
 // Large lists must not serialize their entire subtree just to read geometry.
 // screenPos scrolls its target into view; use a small leaf query to observe
 // movement without accidentally resetting the list's scroll position.
 const probe=async()=>probeId?(await h.query(probeId))[0].rect.y:(await visible(viewportId)).children[0].rect.y;
 const v=await h.screenPos(viewportId),x=v.x+v.w-16,y=v.y+v.h/2;
 assert(v.w>0&&v.h>0,`${label}: viewport has real geometry`);
 const before=await probe();await h.mouseMove(x,y);await h.sleep(250);await h.resetTiming();
 if(trackpad)await h.scrollAt(x,y,0,0,{phase:'began'});
 for(let i=0;i<36;i++)await h.scrollAt(x,y,0,-28,trackpad?{phase:'changed'}:{});
 if(trackpad)await h.scrollAt(x,y,0,0,{phase:'ended'});
 await h.sleep(250);const after=await probe();
 assert(after<before-20,`${label}: content must actually scroll`);
 const down=await h.stats();assert(down.timing_samples>=20,`${label}: collect real frames`);
 assert.equal(down.paint_duplicate_fills,0,`${label}: background fill emitted once`);
 assert((await h.screenshot(join(out,label+'.png'))).ok);
 // Reverse immediately, including a full gesture boundary, then let motion settle.
 if(trackpad)await h.scrollAt(x,y,0,0,{phase:'began'});
 for(let i=0;i<36;i++)await h.scrollAt(x,y,0,28,trackpad?{phase:'changed'}:{});
 if(trackpad)await h.scrollAt(x,y,0,0,{phase:'ended'});
 await h.sleep(500);const returned=await probe();
 assert(returned>after+20,`${label}: reverse wheel direction remains usable`);
 const start=await h.stats();await h.sleep(1200);const stop=await h.stats();
 report.cases.push({label,before,after,returned,down,settled_frame_delta:stop.frame_count-start.frame_count});console.log(label+' passed');
}
try{
 await h.waitForServerReady(60000);await h.resizeWindow(1440,900);
 for(let i=0;i<2;i++){
  await click('sidebar.new');await visible('sidebar.new.menu');
  await h.sleep(250);
  if(i===1)assert((await h.screenshot(join(out,'sidebar-menu.png'))).ok);
  await h.key('escape');
  await h.waitFor(async()=>!(await h.query('sidebar.new.menu')).some(shown)||null,15000);
 }
 report.popup_reopen_passed=true;
 await workload('sidebar-wheel','sidebar.viewport','sidebar.group.badge');
 // Collapsed settings fit a tall window; use a real compact viewport with overflow.
 await h.resizeWindow(1440,650);report.settings_viewport={width:1440,height:650};
 await click('toolbar.settings');await click('settings.nav.appearance');
 await click('settings.appearance.font.header');await h.sleep(250);
 await workload('settings-wheel','settings.viewport','settings.appearance.app_icon.header');
 await workload('settings-trackpad','settings.viewport','settings.appearance.app_icon.header',true);
 await click('settings.nav.ssh');await click('settings.ssh.connection.header');await h.sleep(250);
 await workload('settings-ssh-wheel','settings.viewport','settings.ssh.connection.header');
 await click('settings.close');await h.resizeWindow(1440,900);await click('toolbar.transfers');await visible('transfer.manager');
 await click('transfer.scope.select');await visible('transfer.scope.menu');
 assert((await h.query('transfer.scope.menu')).some((n:any)=>JSON.stringify(n).includes('全局')),'empty transfer registry offers the global scope');
 await h.key('escape');await h.sleep(250);await click('transfer.window.close');
 // Saved hosts populate the wizard's real copy-source Select. Transfer scopes
 // contain only sessions with tasks, so idle saved hosts cannot test its count.
 await click('sidebar.new');await click('sidebar.new.host');await click('wizard.copy.open');
 await click('wizard.copy.source');await h.key('end');await h.sleep(250);await h.key('enter');
 const chosen=(await h.query('wizard.copy.source')).map((n:any)=>JSON.stringify(n)).join('');
 assert(chosen.includes(`Fixture host ${hostCount}`),'keyboard End selects the final saved host');
 await click('wizard.copy.source');await h.sleep(250);
 assert((await h.screenshot(join(out,'large-select.png'))).ok);
 await h.key('escape');await h.sleep(250);await click('wizard.copy.apply');
 assert((await h.query('wizard.name')).some((n:any)=>JSON.stringify(n).includes(`Fixture host ${hostCount}`)),'copy action resolves the selected host identity');
 await click('wizard.cancel');
 assert(!(await readFile(join(out,'app.log'),'utf8')).includes('TooManySelectOptions'),'large host registry does not fail rebuilding Select');
 report.large_select_passed=true;report.host_count=hostCount;
 report.status='passed';console.log(JSON.stringify(report.cases.map(({label,down,settled_frame_delta}:any)=>({label,cpu_p95_ms:down.cpu_p95_us/1000,gpu_p95_ms:down.gpu_p95_us/1000,samples:down.timing_samples,settled_frame_delta}))));
}catch(error){report.status='failed';report.error=String(error);await h.screenshot(join(out,'failure.png')).catch(()=>{});throw error;}
finally{
 if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;
 if(app.pid)await cleanupOwnedBridgeDirectories(app.pid);await log.close();await rm(iso,{recursive:true,force:true});
 await writeFile(join(out,'report.json'),JSON.stringify(report,null,2)+'\n');
}
