/** V3 native tab colour acceptance. CUA opens the original tab context menu;
 * public Harness then selects the actual menu/colour and checks original TabId. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdir,copyFile,readFile,writeFile,open} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {resolve,join} from 'node:path';
import {waitForServerReady,waitFor,query,clickAt,resizeWindow,screenshot,key,sleep,type_,mouseMove} from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]),prefix=resolve(process.argv[3]);await mkdir(out,{recursive:false});
const nonce=createHash('sha256').update(out+process.pid).digest('hex').slice(0,10),bundleId='local.zerowork.tabcolors.'+nonce;
const data=join(out,'data'),rpc=join(out,'rpc'),bundle=join(out,'ZeroWork Tab Colors.app'),mac=join(bundle,'Contents/MacOS');for(const p of [data,rpc,mac])await mkdir(p,{recursive:true});
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n');
await writeFile(join(data,'hosts.toml'),'[registry]\nschema_version=2\nrevision=1\nnext_connection_id=1\nnext_group_id=1\n');
await writeFile(join(bundle,'Contents/Info.plist'),'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>'+bundleId+'</string><key>CFBundleExecutable</key><string>TabColors</string><key>CFBundleName</key><string>ZeroWork Tab Colors</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>');
const binary=join(mac,'TabColors');await copyFile(join(prefix,'bin/zerowork'),binary);await copyFile(join(prefix,'bin/zw_ipc.so'),join(mac,'zw_ipc.so'));process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
execFileSync('/usr/bin/codesign',['--force','--sign','-','--identifier',bundleId,bundle]);
const log=await open(join(out,'app.log'),'w'),app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'0',ZENIT_E2E_ISOLATE_POINTER:'0'},stdio:['ignore',log.fd,log.fd]});
const report:any={status:'running',pid:app.pid,bundle,bundle_id:bundleId,nonce,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks:[]};
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const vis=(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null,15000);
async function click(id:string){const n=await vis(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await sleep(180)}
async function handoff(stage:string,id:string){const n=await vis(id);await screenshot(join(out,stage+'-before.png'));await writeFile(join(out,'handoff.json'),JSON.stringify({stage,pid:app.pid,bundle,bundle_id:bundleId,nonce,action:'CUA right-click exact original tab',tab:id,rect:n.rect,marker:join(out,stage+'.done')},null,2));console.log('CUA '+stage);await waitFor(async()=>{try{return(await readFile(join(out,stage+'.done'),'utf8'))==='done'||null}catch{return null}},900000)}
try{
await waitForServerReady();await resizeWindow(1440,900);await click('workspace.empty.local');await vis('terminal.surface');await click('toolbar.new_session');await click('session.menu.local');await sleep(1000);await type_(`printf 'ZW_COLOR_${nonce}\n'`);await key('return');await sleep(300);
const tabs=(await query('tabs.strip')).flatMap(function flat(n:any):any[]{return[n,...(n.children??[]).flatMap(flat)]}).filter((n:any)=>/^tabs.tab.\d+$/.test(n.test_id??''));assert.equal(tabs.length,2);const first=tabs[0].test_id,second=tabs[1].test_id;
await handoff('01-first-owner',first);await click('context.menu.tab_color');const panel=await vis('tabs.color');assert(panel.rect.x>=0&&panel.rect.x+panel.rect.w<=1440);assert.equal(panel.rect.w,344);assert.equal(panel.rect.h,106);await screenshot(join(out,'01-picker.png'));await writeFile(join(out,'01-picker.query.json'),JSON.stringify(await query('tabs.color'),null,2));const swatch=await vis('tabs.color.818cf8');await mouseMove(swatch.rect.x+swatch.rect.w/2,swatch.rect.y+swatch.rect.h/2);await sleep(150);await screenshot(join(out,'01-picker-hover.png'));await writeFile(join(out,'01-swatch.query.json'),JSON.stringify(await query('tabs.color.818cf8'),null,2));await click('tabs.color.67b88b');await sleep(300);
const flatten=(n:any):any[]=>[n,...(n.children??[]).flatMap(flatten)];
const title=async(id:string)=>flatten(await vis(id)).find(n=>n.test_id==='tabs.title');
assert.equal((await query('tabs.unread_attention')).length,0);assert.equal((await query('tabs.connection_status')).length,0);
const originalTitle=await title(first);assert(originalTitle);assert.equal((await query('tabs.color_marker')).length,0);await writeFile(join(out,'02-title.query.json'),JSON.stringify(originalTitle,null,2));await screenshot(join(out,'02-original-owner-colored.png'));report.checks.push('original TabId title receives custom color without top marker; icon keeps connection state');
await handoff('03-second-owner',second);await click('context.menu.tab_color');await key('escape');await sleep(200);assert(!(await query('tabs.color')).some(shown));assert.equal((await query('tabs.color_marker')).length,0);report.checks.push('Escape cancels without changing second owner');
await resizeWindow(860,480);await handoff('04-compact',second);await click('context.menu.tab_color');const compact=await vis('tabs.color');assert(compact.rect.x>=0&&compact.rect.x+compact.rect.w<=860&&compact.rect.y+compact.rect.h<=480);await click('tabs.color.df8598');await sleep(300);assert.equal((await query('tabs.color_marker')).length,0);await screenshot(join(out,'04-two-independent-colors-compact.png'));report.checks.push('compact picker clamped and independent second color');report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await screenshot(join(out,'failure.png')).catch(()=>{});process.exitCode=1}finally{app.kill('SIGTERM');await log.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report))}
