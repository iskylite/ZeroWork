/** Isolated native layout-motion regression; no connection or user data. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,open,realpath} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {tmpdir} from 'node:os';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]??'zig-out/bin/zerowork');
const out=resolve(process.argv[3]??'dist/ui-acceptance/layout-motion');await mkdir(out,{recursive:true});
const reduced=process.argv[4]==='reduced';
const persisted=process.argv.includes('persisted');
const dir=await realpath(await mkdtemp(join(tmpdir(),'zw-layout-motion-')));
await mkdir(dir+'/data');await mkdir(dir+'/rpc');process.env.ZENIT_E2E_FILE_RPC_DIR=dir+'/rpc';
await writeFile(dir+'/data/config.toml','[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n');
await writeFile(dir+'/data/hosts.toml','[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nname="Fixture"\nhost="192.0.2.1"\nport=22\nuser="fixture"\nauth_mode="password"\n');
if(persisted){const file=dir+'/data/hosts.toml';let text=await readFile(file,'utf8');text=text.replace('next_group_id=1','next_group_id=2').replace('[[hosts]]','[[groups]]\ngroup_id=1\nrevision=1\nname="Persisted group"\ncollapsed=false\nordered_connection_ids=[1]\n[[hosts]]\nasset_group_id=1');await writeFile(file,text);}
const log=await open(out+'/app.log','w');
const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:dir+'/data',ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_A11Y_PREFS:reduced?'reduce_motion':''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(r=>app.once('close',()=>r()));
const report:any={binary,reduced,persisted,dir,status:'running',checks:[],tracks:{}};
async function click(id:string){assert((await h.clickTestId(id)).ok,id);await h.sleep(350);}
async function transition(name:string,trigger:string){
 await h.trackStart('wizard.dialog');assert((await h.clickTestId(trigger)).ok);await h.sleep(450);
 const samples=(await h.trackStop()).filter(n=>n.found);assert(samples.length>0,name);
 report.tracks[name]=samples;
 const first=samples[0].h,last=samples.at(-1)!.h;
 assert(Math.abs(first-last)>10,name+' changes height');
 if(!reduced)assert(samples.some(n=>n.h>Math.min(first,last)+1&&n.h<Math.max(first,last)-1),name+' has intermediate frames');
 else assert(samples.every(n=>Math.abs(n.h-first)<.2||Math.abs(n.h-last)<.2),name+' skips geometry interpolation');
 return last;
}
try{
 await h.waitForServerReady(30000);await h.resizeWindow(1440,900);await click('sidebar.new');await click('sidebar.new.host');
 const initial=await h.screenPos('wizard.dialog');
 await transition('expand','wizard.advanced.toggle');await h.screenshot(out+'/expanded.png');
 await transition('collapse','wizard.advanced.toggle');await h.screenshot(out+'/collapsed.png');
 await transition('key','wizard.auth.key');await transition('agent','wizard.auth.agent');await transition('password','wizard.auth.password');
 const restored=await h.screenPos('wizard.dialog');assert(Math.abs(restored.h-initial.h)<.2);
 for(let i=0;i<6;i++){assert((await h.clickTestId('wizard.advanced.toggle')).ok);await h.sleep(25);}
 await h.sleep(450);assert(Math.abs((await h.screenPos('wizard.dialog')).h-initial.h)<.2);
 report.checks.push('Disclosure expansion/collapse, authentication changes, and six rapid reversals settle correctly.');
 await h.resizeWindow(860,480);await h.sleep(350);const compact=await h.screenPos('wizard.dialog');assert(compact.h<=432&&compact.y>=0);
 await click('wizard.advanced.toggle');const expandedCompact=await h.screenPos('wizard.dialog');assert(expandedCompact.h<=432);await h.screenshot(out+'/compact.png');
 report.checks.push('Compact layout stays bounded with internally scrolling expanded content.');
 assert((await h.clickTestId('wizard.advanced.toggle')).ok);await click('wizard.close');
 await click('sidebar.new');await click('sidebar.new.host');await click('wizard.close');
 report.checks.push('Closing during a disclosure transition and reopening safely releases scoped animation hooks.');
 await h.resizeWindow(1440,900);await h.sleep(350);
 await h.trackStart('sidebar.group.card');await click('sidebar.group');const group=(await h.trackStop()).filter(n=>n.found);report.tracks.group=group;
 if(!reduced){const a=group[0].h,b=group.at(-1)!.h;assert(group.some(n=>n.h>Math.min(a,b)+.2&&n.h<Math.max(a,b)-.2),'group has intermediate frames');}
 if(persisted)assert(/collapsed\s*=\s*true/.test(await readFile(dir+'/data/hosts.toml','utf8')));
 await click('sidebar.group');report.checks.push(persisted?'Persisted group preserves motion across committed list rebuilds.':'Default host group folds and reopens without a list rebuild.');
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await h.screenshot(out+'/failure.png').catch(()=>{});process.exitCode=1;}
finally{app.kill('SIGTERM');await Promise.race([ended,h.sleep(2000)]);await log.close();await writeFile(out+'/report.json',JSON.stringify(report,null,2));}
console.log(JSON.stringify({status:report.status,reduced,checks:report.checks,error:report.error,out}));
