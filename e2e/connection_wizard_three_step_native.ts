/** Registered SSH/SFTP/BMC editor chrome and BMC retained three-step flow.
 * Isolated config, synthetic Harness input, offline save only; no remote connection.
 * node e2e/connection_wizard_three_step_native.ts [prefix] [output] [theme]
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,writeFile,rm,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.argv[2]??'zig-out'),out=resolve(process.argv[3]??'/tmp/zw-three-step-evidence'),theme=process.argv[4]??'sauber';
await mkdir(out,{recursive:true});
const base=await realpath(await mkdtemp('/tmp/zw-three-step-')),data=join(base,'data'),rpc=join(base,'rpc');
await mkdir(data);await mkdir(rpc);
await writeFile(join(data,'config.toml'),`[ui]\ntheme="${theme}"\n[updates]\nauto_check=false\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZENIT_E2E_ISOLATE_KEYBOARD:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(done=>app.once('close',done));
const shown=(n:any)=>n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>.98&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,8000);
const absent=async(id:string)=>h.waitFor(async()=>!(await h.query(id)).some(shown)||null,8000);
const text=(n:any):string=>[n.text??'',...(n.children??[]).map(text)].join(' ');
async function ensure(id:string){
 for(let i=0;i<5;i++){
  const n=await visible(id),body=(await h.query('bmc.editor.scroll')).find(shown);
  if(!body||id.startsWith('wizard.')||id.startsWith('bmc.editor.scale.')||id.endsWith('.next')||id.endsWith('.back')||['bmc.editor.save','bmc.editor.temporary','bmc.editor.save_and_open'].includes(id))return n;
  if(n.rect.y>=body.rect.y-1&&n.rect.y+n.rect.h<=body.rect.y+body.rect.h+1)return n;
  await h.scrollAt(body.rect.x+body.rect.w-10,body.rect.y+body.rect.h/2,0,n.rect.y<body.rect.y?400:-400);
  await h.sleep(100);
 }
 throw Error('Could not scroll to '+id);
}
async function click(id:string){await ensure(id);assert((await h.clickTestId(id)).ok,id);await h.sleep(120);}
async function edit(id:string,value:string){await click(id);await h.key('a',{cmd:true});await h.type_(value);}
async function openKvm(){await h.key('t',{cmd:true});await visible('session.menu.new_kvm');await click('session.menu.new_kvm');await visible('bmc.editor.name');}
async function capture(name:string){await h.screenshot(join(out,name+'.png'));}
const checks:string[]=[];
try{
 await h.waitForServerReady();
 for(const [width,height] of [[1440,900],[860,480]]){
  await h.resizeWindow(width,height);await openKvm();
  const picker=await visible('wizard.protocol'),steps=await visible('wizard.steps');
  assert.equal(picker.rect.w,152);assert.equal(picker.rect.h,30);assert.equal(steps.rect.h,60);
  for(let i=0;i<2;i++){
   const line=await visible('wizard.steps.connector.'+i),left=await visible(['wizard.step.identity','wizard.step.route'][i]),right=await visible(['wizard.step.route','wizard.step.review'][i]);
   assert(Math.abs(line.rect.x-left.rect.x-left.rect.w-20)<.2,'left connector gap');
   assert(Math.abs(right.rect.x-line.rect.x-line.rect.w-20)<.2,'right connector gap');
   assert(Math.abs(line.rect.y+line.rect.h/2-left.rect.y-left.rect.h/2)<.2,'connector vertical alignment');
  }

  await absent('bmc.editor.probe');await absent('bmc.editor.save');
  await click('bmc.editor.next');await visible('bmc.editor.host');
  if(width===1440)await edit('bmc.editor.name','compute-bmc-01');
  await edit('bmc.editor.host','bmc.example.internal');
  await edit('bmc.editor.username','operator');
  await capture('kvm-'+width+'-identity');
  await click('bmc.editor.next');await absent('bmc.editor.name');await visible('bmc.editor.advanced');
  await click('bmc.editor.advanced');await click('bmc.editor.scale');await click('bmc.editor.scale.original');await click('bmc.editor.readonly');
  await capture('kvm-'+width+'-advanced');
  await click('bmc.editor.access.ssh');await click('bmc.editor.next');
  await visible('bmc.editor.message');await absent('bmc.editor.review');
  await click('bmc.editor.access.direct');await click('bmc.editor.next');
  const review=await visible('bmc.editor.review');
  assert.match(text(review),/原始比例 100%/);assert.match(text(review),/只读：开启/);
  await visible('bmc.editor.save_and_open');await absent('bmc.editor.next');
  await capture('kvm-'+width+'-review');
  await click('bmc.editor.review.edit_identity');await visible('bmc.editor.name');
  await click('bmc.editor.next');await visible('bmc.editor.scale');
  await click('bmc.editor.next');assert.match(text(await visible('bmc.editor.review')),/只读：开启/);
  if(width===1440){
   await click('bmc.editor.save');await absent('wizard.close');
   const saved=await readFile(join(data,'hosts.toml'),'utf8');
   assert.match(saved,/bmc_ikvm/);assert.match(saved,/original/);assert.match(saved,/read_only_requested[^\n]*true/);
  }else{await click('wizard.close');await absent('wizard.close');}
  checks.push(`${width}×${height}: validation, retained steps/advanced options, route validation, review, fixed footer`);
 }
 // Each registered protocol shares one header Select; SSH advanced items remain intact.
 await h.resizeWindow(1440,900);await openKvm();
 await click('wizard.protocol');await click('wizard.protocol.ssh');await visible('wizard.name');
 await visible('wizard.steps');await absent('bmc.editor.name');
 await click('wizard.advanced.toggle');await visible('wizard.strict_host_key');
 await visible('wizard.compression');await visible('wizard.startup');
 await capture('ssh-advanced');
 await click('wizard.protocol');await click('wizard.protocol.sftp');await visible('wizard.name');
 await capture('sftp-identity');
 await click('wizard.close');await absent('wizard.close');
 checks.push('Shared protocol Select switches KVM → SSH → SFTP; SSH advanced settings remain available');
 await writeFile(join(out,'report.json'),JSON.stringify({status:'passed',theme,checks},null,2));
 console.log(JSON.stringify({status:'passed',theme,checks}));
}catch(error){await capture('failure').catch(()=>{});await writeFile(join(out,'report.json'),JSON.stringify({status:'failed',theme,checks,error:String(error)},null,2));throw error;}
finally{if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;await log.close();await rm(base,{recursive:true,force:true});}
