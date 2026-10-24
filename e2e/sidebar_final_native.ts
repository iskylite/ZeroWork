/** Owned, background native sidebar identity/status acceptance. No clipboard. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,writeFile,rm,chmod} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {waitForServerReady,waitFor,query,tree,clickTestId,clickAt,key,type_,resizeWindow,screenshot,sleep,mouseMove} from '../zig-out/share/zenit/harness/client.ts';
import {cleanupOwnedBridgeDirectories} from './native_owned_cleanup.ts';
const o:any={};for(let i=2;i<process.argv.length;i+=2)o[process.argv[i]]=process.argv[i+1];
assert(o['--binary']&&o['--expected-sha']&&o['--out']&&o['--config']);
const binary=resolve(o['--binary']),sha=createHash('sha256').update(await readFile(binary)).digest('hex');assert.equal(sha,o['--expected-sha']);
const output=resolve(o['--out']),iso=await mkdtemp(join(tmpdir(),'zw-sidebar-final-')),rpc=join(iso,'rpc'),data=join(iso,'data');await chmod(iso,0o700);await Promise.all([mkdir(output,{recursive:true}),mkdir(rpc),mkdir(data)]);
const credentials=JSON.parse(await readFile(o['--config'],'utf8')).direct;
const theme=o['--theme']??'dark';assert(['dark','light','sauber'].includes(theme));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n`);
await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=3\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname="Sidebar SSH default"\nhost="${credentials.host}"\nport=${credentials.port}\nuser="${credentials.user}"\n[[hosts]]\nconnection_id=2\nrevision=1\nprotocol="sftp"\nauth_mode="password"\nname="Sidebar files default"\nhost="${credentials.host}"\nport=${credentials.port}\nuser="${credentials.user}"\n`,{mode:0o600});
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(output,'app.log'),'w');const child=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise<void>(done=>child.once('close',()=>done()));
const report:any={status:'running',binary_sha256:sha,binary,pid:child.pid,theme,checks:[],captures:[],limits:['Actual Metal app and synthetic public Harness input; physical input and VoiceOver not tested.','Remote OS discovery is absent from current Session contract: SSH uses shared terminal fallback; local tabs use Apple.','Runner-owned SIGTERM cleanup is separate from normal lifecycle evidence.']};
const shown=(n:any)=>n?.visible!==false&&n?.hidden!==true&&(n?.effective_opacity??1)>0&&n?.rect?.w>0&&n?.rect?.h>0;
const flat=(n:any):any[]=>shown(n)?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(n:any)=>flat(n).map(x=>x.text??'').join('');
async function visible(id:string){return waitFor(async()=>(await query(id)).find(shown)??null,20000)}
async function click(id:string){await visible(id);assert((await clickTestId(id)).ok,id)}
async function cap(name:string){await sleep(250);const ids=['workspace.sidebar','workspace.sidebar.collapsed','sidebar.host','sidebar.host.icon','sidebar.rail.host.1','sidebar.rail.host.2','tabs.strip','workspace.statusbar'];const q=Object.fromEntries(await Promise.all(ids.map(async id=>[id,await query(id)])));await writeFile(join(output,`${name}.json`),JSON.stringify(q,null,2));assert((await screenshot(join(output,`${name}.png`))).ok);report.captures.push(name);return q;}
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),child.pid);await resizeWindow(1440,900);
 await visible('sidebar.host');let q=await cap('01-expanded-offline');assert.equal(q['workspace.sidebar'].find(shown).rect.w,224);assert.equal(q['sidebar.host.icon'].filter(shown).length,2);for(const icon of q['sidebar.host.icon'].filter(shown)){assert.equal(icon.rect.w,14);assert.equal(icon.rect.h,14)}report.checks.push('Expanded sidebar width224, SSH and SFTP icons14x14');
 await click('sidebar.collapse');q=await cap('02-collapsed-offline');assert.equal(q['workspace.sidebar.collapsed'].find(shown).rect.w,48);for(const id of ['sidebar.rail.host.1','sidebar.rail.host.2']){assert.equal(q[id].find(shown).rect.w,32);assert.equal(q[id].find(shown).rect.h,32)}report.checks.push('Collapsed sidebar width48 and each host target32x32');
 await click('sidebar.rail.expand');const host=(await query('sidebar.host')).filter(shown)[0];assert((await clickAt(host.rect.x+host.rect.w/2,host.rect.y+host.rect.h/2,2)).ok);await visible('auth.challenge.trust_once');const whole=await tree();for(const cb of flat(whole).filter(n=>/checkbox/i.test(`${n.component??''} ${n.tag??''}`)))await clickAt(cb.rect.x+Math.min(12,cb.rect.w/2),cb.rect.y+cb.rect.h/2);await click('auth.challenge.trust_once');await click('auth.challenge.answer.0');await type_(credentials.password);await click('auth.challenge.submit');await waitFor(async()=>!(await query('connection.progress')).some(shown)&&(await query('status.connection.identity')).some(shown)||null,30000);
 q=await cap('03-expanded-connected');report.checks.push('Real SSH authenticated through production challenges; host expanded online');
 await click('sidebar.collapse');q=await cap('04-collapsed-connected');report.checks.push('Connected host retains same icon in collapsed rail');
 const connectedHost=q['sidebar.rail.host.1'].find(shown);await mouseMove(connectedHost.rect.x+16,connectedHost.rect.y+16);await cap('04b-collapsed-connected-hover');await mouseMove(700,400);
 for(const [index,next] of ['dark','light','sauber',theme].entries()) { await click('status.connection.theme');await click('status.theme.item.'+next);await key('escape');const hot=await cap(`07-hot-theme-${index}-${next}`);const host=hot['sidebar.rail.host.1'].find(shown);await mouseMove(host.rect.x+16,host.rect.y+16);await cap(`08-hot-hover-${index}-${next}`);await mouseMove(700,400); }
 report.checks.push('Same selected host survives actual global Dark/Light/Sauber runtime theme changes with current surface and online tint');
 await click('sidebar.rail.expand');await key('w',{cmd:true});await waitFor(async()=>!(await query('tabs.tab.1')).some(shown)||null,30000);await cap('05-expanded-disconnected');await click('sidebar.collapse');q=await cap('06-collapsed-disconnected');const closedHost=q['sidebar.rail.host.1'].find(shown);await mouseMove(closedHost.rect.x+16,closedHost.rect.y+16);await cap('06b-collapsed-disconnected-hover');await mouseMove(700,400);report.checks.push('Closing actual SSH tab returns expanded and collapsed host to offline status');
 report.pixels=JSON.parse(execFileSync('python3',[resolve('e2e/sidebar_final_pixels.py'),output,theme],{encoding:'utf8'}));report.checks.push('Native pixels verify state tints for all12 host snapshots and shared terminal glyph matches actual tab');report.status='passed';
}catch(error){report.status='failed';report.error=String(error);await screenshot(join(output,'failure.png')).catch(()=>{});process.exitCode=1}
finally{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');await Promise.race([ended,sleep(2000)]);if(child.exitCode===null&&child.signalCode===null){child.kill('SIGKILL');await ended}report.cleanup={app_exited:child.exitCode!==null||child.signalCode!==null,private_bridges_removed:await cleanupOwnedBridgeDirectories(child.pid!)};await log.close();await rm(iso,{recursive:true,force:true});report.cleanup.isolated_removed=true;await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));}
