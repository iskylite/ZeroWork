/** New KVM uses the registered editor directly; never connects or saves data. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,writeFile,rm,realpath} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=resolve(process.argv[2]??'zig-out');
const out=resolve(process.argv[3]??'/tmp/zerowork-kvm-menu-evidence');
await mkdir(out,{recursive:true});
const base=await realpath(await mkdtemp('/tmp/zw-kvm-menu-'));
const data=join(base,'data'),rpc=join(base,'rpc');
await Promise.all([mkdir(data),mkdir(rpc)]);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
await writeFile(join(data,'config.toml'),'[updates]\nauto_check=false\n');
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(resolve=>app.once('close',resolve));
const shown=(n:any)=>n.visible!==false&&n.rect.w>0&&n.rect.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null);
const checks:any[]=[];
try{
 await h.waitForServerReady();
 for(const [width,height] of [[1440,900],[860,480]]){
  await h.resizeWindow(width,height);await h.key('t',{cmd:true});
  const menu=await visible('session.menu'),kvm=await visible('session.menu.new_kvm');
  assert(kvm.rect.y>=menu.rect.y&&kvm.rect.y+kvm.rect.h<=menu.rect.y+menu.rect.h+.5);
  assert(menu.rect.y+menu.rect.h<=height+.5);
  await h.screenshot(join(out,`menu-${width}.png`));
  if(width===1440)assert((await h.clickTestId('session.menu.new_kvm')).ok);
  else {
   for(let i=0;i<8&&(await h.focused()).test_id!=='session.menu.new_kvm';i++)await h.key('up');
   assert.equal((await h.focused()).test_id,'session.menu.new_kvm');
   await h.key('return');
  }
  await visible('bmc.editor');await visible('bmc.editor.host');await visible('bmc.editor.port');
  await h.waitFor(async()=>!(await h.query('session.menu')).some(shown)||null);
  await h.screenshot(join(out,`kvm-${width}.png`));
  checks.push({width,height,activation:width===1440?'mouse':'keyboard',editor:'bmc_ikvm'});
  await visible('bmc.editor.cancel');
  assert((await h.clickTestId('bmc.editor.cancel')).ok);
  await h.waitFor(async()=>!(await h.query('wizard.dialog')).some(shown)||null);
 }
 await writeFile(join(out,'report.json'),JSON.stringify({status:'passed',checks},null,2));
 console.log('passed: '+out);
}finally{
 if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');
 await ended;await log.close();await rm(base,{recursive:true,force:true});
}
