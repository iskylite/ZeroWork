/** Real system file chooser; run with a serialized foreground CUA lease. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,realpath,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
const prefix=process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-ai-v3-prefix',h=await import(join(prefix,'share/zenit/harness/client.ts'));
const out=resolve(process.argv[2]??'/tmp/zw-ai-local-picker');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-ai-local-picker-')),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
const fixtureKind=process.env.ZW_LOCAL_FIXTURE_KIND??'text';
const referenceKind=['binary','large_text','large_image','huge_image'].includes(fixtureKind);
const fixture=join(iso,fixtureKind==='binary'?'selected.iso':fixtureKind==='image'?'selected.txt':fixtureKind.endsWith('_image')?'selected.png':'selected.log');
if(fixtureKind==='binary'){const file=await open(fixture,'w');await file.truncate(16*1024*1024*1024);await file.close()}
else if(fixtureKind==='large_text')await writeFile(fixture,'t'.repeat(65537));
else if(fixtureKind==='large_image'||fixtureKind==='huge_image'){await writeFile(fixture,Buffer.from('iVBORw0KGgoAAAANSUhEUgAAIygAAAABCAYAAACzIwVFAAAAPUlEQVR4nO3DQQ0AAAwDofNvurOxByS0mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqr64wFXfA3LIKy7pwAAAABJRU5ErkJggg==','base64'));if(fixtureKind==='huge_image'){const file=await open(fixture,'r+');await file.truncate(10000001);await file.close()}}
else if(fixtureKind==='image')await writeFile(fixture,Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==','base64'));
else await writeFile(fixture,'Native system chooser selected this owned UTF-8 file.\n');
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n');process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');const app=spawn(process.env.ZW_AI_BINARY??join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'0',ZENIT_E2E_ISOLATE_POINTER:'0'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
const report:any={status:'running',pid:app.pid,rpc,fixture,fixtureKind,checks:[]};await writeFile(join(out,'live.json'),JSON.stringify(report));
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const click=async(id:string)=>{report.lastAction=id;await h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);assert((await h.clickTestId(id)).ok)};
try{
 await h.waitForServerReady();await h.resizeWindow(1100,760);await click('workspace.empty.local');await click('ai.strip');
 await click('ai.composer.attachment');await click(process.env.ZW_LOCAL_ENTRY==='image'?'ai.attachment.image':'ai.attachment.local_text').catch(e=>{if(!String(e).includes('request timeout'))throw e});
 const id=referenceKind?'ai.attachment.local_reference':fixtureKind==='image'?'ai.image':'ai.attachment.local_text';
 await h.waitFor(async()=>(await h.query(id)).some(shown)||null,180000);
 await h.screenshot(join(out,'01-local-selected.png'));
 if(fixtureKind==='image'){
  await click('ai.image.preview');await h.waitFor(async()=>(await h.query('ai.image.preview.panel')).some(shown)||null,10000);
  await h.screenshot(join(out,'02-local-preview.png'));await click('ai.image.preview.close');
 }else{
  await click('ai.attachment.open');await h.waitFor(async()=>(await h.query('ai.attachment.preview')).some(shown)||null,10000);
  const text=(await h.query('ai.attachment.preview.text')).find(shown)?.text??'';
  assert(text.includes(fixtureKind==='large_text'?'64 KiB':fixtureKind==='large_image'?'像素限制':referenceKind?'大小限制':'owned UTF-8'));
  if(referenceKind){assert(text.includes('本机绝对路径'));assert((await h.query('ai.attachment.metadata')).filter(shown).every(n=>n.text.includes('本机')))}
  await h.screenshot(join(out,'02-local-preview.png'));await click('ai.attachment.preview.keep');
 }
 report.checks.push(`Actual native file chooser routes ${fixtureKind} to ${id} and opens its matching native preview`);
 assert((await h.request('POST','/zerowork/windows',{action:'quit'})).ok);await Promise.race([ended,h.sleep(10000)]);assert.equal(app.exitCode,0);report.appExit=app.exitCode;
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);process.exitCode=1;await h.screenshot(join(out,'failure.png')).catch(()=>{})}
finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await ended}await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report))}
