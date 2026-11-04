/** Focused @log replay acceptance across viewport-only and structured history frames. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,realpath,copyFile,readFile,writeFile,open,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep,scrollAt} from '../zig-out/share/zenit/harness/client.ts';

const out = resolve(process.argv[2]);
const binary = resolve(process.argv[3] ?? 'zig-out/bin/zerowork');
await mkdir(out, {recursive:true});
const iso = await realpath(await mkdtemp(join(tmpdir(), 'zw-log-')));
const rpc = join(iso, 'rpc'), data = join(iso, 'data'), shell = join(iso, 'shell');
let app: ReturnType<typeof spawn> | undefined;
let log: Awaited<ReturnType<typeof open>> | undefined;
const report: {status:string; checks:string[]; error?:string} = {status:'running',checks:[]};
const shown = (n:any) => n && n.visible !== false && n.hidden !== true && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const text = (n:any):string => !shown(n) ? '' : (n.text ?? '') + (n.children ?? []).map(text).join('');
const visible = (id:string) => waitFor(async() => (await query(id)).find(shown) ?? null, 12000);
async function click(id:string) { const n = await visible(id); assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok); }
async function press(name:string,mods?:any) { assert((await key(name,mods)).ok); }
async function type(value:string) { assert((await type_(value)).ok); }
async function command(value:string) {
  await type('@'); await visible('terminal.commands'); await type(value); await press('right');
  await waitFor(async()=> !(await query('terminal.commands')).some(shown) || null);
  await press('return'); await sleep(300);
}
async function capture(name:string) {
  await sleep(200);
  assert((await screenshot(join(out,`${name}.png`))).ok);
  const nodes:any = {};
  for (const id of ['terminal.dots.qr','terminal.command.record','terminal.command.output','terminal.surface','terminal.row','terminal.history.position']) nodes[id] = await query(id);
  await writeFile(join(out,`${name}.json`),JSON.stringify(nodes,null,2));
}
async function donationVisible() {
  await visible('terminal.dots.qr');
  await waitFor(async()=> (await query('terminal.command.output')).filter(shown).map(text).join('\n').includes('支付宝扫码 · 捐献支持开发') || null);
}
try {
  await Promise.all([mkdir(rpc),mkdir(data),mkdir(shell)]);
  await writeFile(join(shell,'.zshrc'),"bindkey -e\nPS1='replay%# '\n");
  await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
  await copyFile(binary,join(iso,'zerowork'));
  for (const name of ['zw_ipc.so','zw_execution.so','zw_execution_guard','zw_secret_consume.so']) await copyFile(join(binary,'..',name),join(iso,name));
  process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
  log=await open(join(out,'app.log'),'w');
  app=spawn(join(iso,'zerowork'),[],{env:{...process.env,ZDOTDIR:shell,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
  await resizeWindow(1280,800); await click('workspace.empty.local'); await visible('terminal.surface'); await sleep(1500);
  const ready=join(iso,'ready');
  await type(`printf ready > ${JSON.stringify(ready)}`); await press('return');
  await waitFor(async()=> {try{return await readFile(ready,'utf8')==='ready'||null}catch{return null}});
  await command('log'); await visible('terminal.history.position');
  await waitFor(async()=> (await query('terminal.command.output')).filter(shown).map(text).join('\n').includes('已打开会话历史') || null);
  await waitFor(async()=> (await query('terminal.row')).filter(shown).map(text).join('\n').includes('printf ready') || null);
  await capture('00-plain-log'); await press('escape'); await visible('terminal.surface');
  report.checks.push('A plain Local terminal opens @log with recorded shell content and the completed result visible');
  await command('dots'); await donationVisible();
  await command('log'); await visible('terminal.history.position'); await donationVisible();
  await capture('01-open-log');
  report.checks.push('@log opens with retained command output and QR visible, without a search or scroll workaround');
  await press('f',{cmd:true}); await visible('terminal.search.query'); await type('@dots');
  await donationVisible(); await capture('02-search-record'); await click('terminal.search.close');
  report.checks.push('History search locates the application command and retains its QR and result');
  await resizeWindow(1100,700); await donationVisible(); await capture('03-resize');
  report.checks.push('Resizing the replay window retains visible recorded content');
  const terminal=await visible('terminal.input');
  await scrollAt(terminal.rect.x+terminal.rect.w/2,terminal.rect.y+terminal.rect.h/2,0,160);
  await sleep(150);
  const track=await visible('terminal.history.track');
  assert((await clickAt(track.rect.x+track.rect.w-1,track.rect.y+track.rect.h/2)).ok);
  await donationVisible(); await capture('04-scroll-and-end');
  report.checks.push('History wheel input and the end of the timeline paint retained rows across frame boundaries');
  await press('escape'); await visible('terminal.surface');
  const resumed=join(iso,'resumed');
  await type(`printf resumed > ${JSON.stringify(resumed)}`); await press('return');
  await waitFor(async()=>{try{return await readFile(resumed,'utf8')==='resumed'||null}catch{return null}});
  report.checks.push('Escape returns to the live Local PTY and shell input continues');
  report.status='passed';
} catch (error) {
  report.status='failed'; report.error=String(error); process.exitCode=1;
  await capture('failure').catch(()=>{});
} finally {
  if(app && app.exitCode===null && app.signalCode===null) {
    const ended=new Promise(r=>app!.once('close',r)); app.kill('SIGTERM');
    await Promise.race([ended,sleep(3000)]);
    if(app.exitCode===null && app.signalCode===null) {app.kill('SIGKILL'); await ended;}
  }
  await log?.close(); await rm(iso,{recursive:true,force:true});
  await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
  console.log(JSON.stringify({out,...report}));
}
