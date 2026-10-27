/** Owned loopback regression: save a prompted password, open a second session, inspect focus. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,realpath,readFile,writeFile,open} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const binary=resolve(process.argv[2]),out=resolve(process.argv[3]);await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-password-regression-'))),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const peerLog=await open(join(out,'peer.log'),'w'),log=await open(join(out,'app.log'),'w');
const peer=spawn('python3',['e2e/builtin_records_ssh_peer.py','--out',join(out,'peer')],{stdio:['ignore',peerLog.fd,peerLog.fd]});let app:any;
const shown=(n:any)=>n&&n.visible!==false&&n.hidden!==true&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=async(id:string)=>(await h.query(id)).find(shown);
async function click(id:string){const n=await h.waitFor(()=>visible(id),15000);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await h.sleep(120)}
const report:any={checks:[],status:'running',iso};
try{
 const ready=await h.waitFor(async()=>{try{return JSON.parse(await readFile(join(out,'peer','ready.json'),'utf8'))}catch{return null}},15000);
 await writeFile(join(data,'known_hosts'),ready.known_host);
 await writeFile(join(data,'hosts.toml'),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Password regression"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\n`);
 await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n');
 app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
 await h.waitForServerReady(30000);await h.resizeWindow(1200,800);
 const host=await h.waitFor(()=>visible('sidebar.host'));await h.clickAt(host.rect.x+host.rect.w/2,host.rect.y+host.rect.h/2,2);
 await h.waitFor(()=>visible('plugin.challenge.answer.0'));await click('plugin.challenge.remember');const field=await visible('plugin.challenge.answer.0'),remember=await visible('plugin.challenge.remember');assert(remember.rect.y-(field.rect.y+field.rect.h)<=10);assert(!await visible('plugin.challenge.error'));await writeFile(join(out,'challenge-geometry.json'),JSON.stringify({field:field.rect,remember:remember.rect},null,2));report.checks.push('Password form fits content and empty error row is hidden');await h.screenshot(join(out,'password-save-option.png'));
 await click('plugin.challenge.answer.0');await h.type_(ready.password);await click('plugin.challenge.submit');
 await h.waitFor(async()=>!(await visible('plugin.challenge.modal'))&&await visible('terminal.input'),30000);await h.sleep(700);
 const saved=await readFile(join(data,'hosts.toml'),'utf8');assert(saved.includes('password_ref'));assert(!saved.includes(ready.password));report.checks.push('Prompted password saved as a Keychain reference without plaintext');
 const firstFocus=await h.focused();await writeFile(join(out,'focus.json'),JSON.stringify(firstFocus,null,2));assert.equal(firstFocus.test_id,'terminal.input');report.checks.push('Connected terminal receives keyboard focus');
 await h.type_('@');await h.waitFor(()=>visible('terminal.commands'));await h.type_('new');await h.key('right');await h.waitFor(async()=>!await visible('terminal.commands')||null);await h.key('return');
 await h.waitFor(async()=>(await h.query('tabs.title')).filter(shown).length>=2||null,15000);await h.sleep(1500);assert(!await visible('plugin.challenge.modal'));const secondFocus=await h.focused();assert.equal(secondFocus.test_id,'terminal.input');assert.notEqual(secondFocus.id,firstFocus.id);report.checks.push('New session reuses credentials without a second prompt and retains focus in its own terminal');
 for (let i=0;i<3;i++) assert(!await visible('notifications.toast.'+i));report.checks.push('Connection and new-session success do not show status notifications');await h.screenshot(join(out,'second-session.png'));report.status='passed';
}catch(e){report.status='failed';report.error=String(e);await h.screenshot(join(out,'failure.png')).catch(()=>{});process.exitCode=1}
finally{app?.kill('SIGTERM');peer.kill('SIGTERM');await log.close();await peerLog.close();await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
console.log(JSON.stringify(report));
