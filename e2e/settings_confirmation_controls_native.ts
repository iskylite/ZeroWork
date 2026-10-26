/** Isolated settings confirmations and long model label; no deletion or network. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,open,realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
const prefix=resolve(process.argv[2]),out=resolve(process.argv[3]);
const h=await import(prefix+'/share/zenit/harness/client.ts');
await mkdir(out,{recursive:true});const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-confirm-controls-'))),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
await writeFile(join(data,'config.toml'),'[ui]\ntheme="dark"\n[ai]\ndefault_provider="Fixture"\n[[ai.providers]]\nid="Fixture"\nkind="ollama"\nendpoint="http://127.0.0.1:9/api/chat"\nenabled=false\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(out,'app.log'),'w');
const app=spawn(prefix+'/bin/zerowork',[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
const shown=(n:any)=>n.rect?.w>0&&n.rect?.h>0&&!n.hidden&&n.visible!==false;
const node=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,10000);
async function reveal(id:string){for(let i=0;i<30;i++){const n=await node(id),v=await node('settings.viewport');if(n.rect.y>=v.rect.y&&n.rect.y+n.rect.h<=v.rect.y+v.rect.h)return;await h.scrollAt(v.rect.x+v.rect.w-4,v.rect.y+v.rect.h/2,0,n.rect.y<v.rect.y?100:-100);await h.sleep(50);}throw Error('unreachable '+id);}
async function click(id:string){await node(id);assert((await h.clickTestId(id)).ok,id);await h.sleep(100);}
async function capture(name:string,id:string){const n=await node(id);await writeFile(join(out,name+'.json'),JSON.stringify(n,null,2));assert((await h.screenshot(join(out,name+'.png'))).ok);}
const report:any={checks:[],limits:['No destructive confirmation, external requests, native OS dialogs or physical keyboard input.']};
try{await h.waitForServerReady(30000);await click('toolbar.settings');await click('settings.nav.data');await click('settings.data.actions.header');
for(const [w,height] of [[1440,900],[860,480]]){await h.resizeWindow(w,height);await reveal('settings.data.clear_logs');await click('settings.data.clear_logs');const dialog=await node('settings.record-cleanup');assert.equal(dialog.rect.w,440);await capture('record-confirm-'+w,'settings.record-cleanup');await click('settings.record-cleanup.cancel');await reveal('settings.data.clear_all');await click('settings.data.clear_all');await capture('data-confirm-'+w,'data.cleanup.modal');const modal=await node('data.cleanup.modal'),button=await node('data.cleanup.confirm');assert(button.rect.y+button.rect.h<=modal.rect.y+modal.rect.h+.5);await click('data.cleanup.cancel');report.checks.push('confirmations open/cancel with actions inside '+w);}
await click('settings.nav.ai');await reveal('settings.ai.provider.0.add_model');await click('settings.ai.provider.0.add_model');await click('settings.ai.model.catalog');await click('settings.ai.model.id');await h.type_('organization/production-inference-model-with-a-very-long-descriptive-name-and-version-2026-10-26');await click('settings.ai.model.catalog.manual');await capture('model-long-compact','settings.ai.model.dialog');await click('settings.ai.model.cancel');report.checks.push('long manual model selection and editor cancel');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await h.screenshot(join(out,'failure.png')).catch(()=>{});throw e;}finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));if(app.exitCode===null)app.kill('SIGTERM');await ended;await log.close();}
