/** Real delayed ZSH startup -> production trusted @grp -> native cleanup.
 * node e2e/trusted_startup_native.ts --binary PATH --expected-sha SHA --out EMPTY_DIR
 * Own background App, RPC, data, startup files and shell only.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {access,copyFile,mkdir,mkdtemp,open,readFile,readdir,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname,join,resolve} from 'node:path';
import {waitForServerReady,waitFor,query,clickAt,key,type_,screenshot,sleep,resizeWindow,screenPos} from '../zig-out/share/zenit/harness/client.ts';

const args:Record<string,string>={};
for(let i=2;i<process.argv.length;i+=2){assert(['--binary','--expected-sha','--out'].includes(process.argv[i])&&process.argv[i+1]);args[process.argv[i]]=process.argv[i+1]}
assert(args['--binary']&&args['--out']&&/^[a-f0-9]{64}$/.test(args['--expected-sha']??''));
const output=resolve(args['--out']);await mkdir(output,{recursive:true});assert.equal((await readdir(output)).length,0);
const source=resolve(args['--binary']),binary=join(output,'zerowork-frozen');
await copyFile(source,binary);await copyFile(join(dirname(source),'zw_ipc.so'),join(output,'zw_ipc.so'));
assert.equal(createHash('sha256').update(await readFile(binary)).digest('hex'),args['--expected-sha']);
const isolated=await mkdtemp(join(tmpdir(),'zw-trusted-startup-')),rpc=join(isolated,'rpc'),data=join(isolated,'data'),zdot=join(isolated,'zdot');
await Promise.all([mkdir(rpc),mkdir(data),mkdir(zdot)]);
await writeFile(join(data,'config.toml'),'[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Menlo"\nfont_size = 14\n');
await writeFile(join(zdot,'.zshrc'),`zmodload zsh/datetime\nprintf '%s %s\\n' "$$" "$EPOCHREALTIME" > ${JSON.stringify(join(isolated,'startup-start'))}\n/bin/sleep 3\nprintf '%s' "$_zw_socket" > ${JSON.stringify(join(isolated,'real-shell-receipt'))}\nprintf '%s\\n' "$EPOCHREALTIME" > ${JSON.stringify(join(isolated,'startup-end'))}\nbindkey -e\nPS1='Delayed-startup%# '\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(output,'app.log'),'w');
const app=spawn(binary,[],{cwd:process.cwd(),env:{...process.env,ZDOTDIR:zdot,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',OPENAI_API_KEY:'',ANTHROPIC_API_KEY:''},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const report:any={status:'running',pid:app.pid,binary,sha256:args['--expected-sha'],isolated,checks:[],screenshots:[],visual_status:'not_reviewed',limits:['Synthetic public Harness input; physical input, IME and VoiceOver not verified','Isolated real .zshrc sleeps 3 seconds; user startup files are untouched','Runner SIGTERM is cleanup of its own App, not normal application quit proof']};
const save=()=>writeFile(join(output,'report.json'),JSON.stringify(report,null,2));
const shown=(n:any)=>n?.rect&&!n.hidden&&n.visible!==false&&n.rect.w>0&&n.rect.h>0&&(n.effective_opacity??1)>0;
const flat=(n:any):any[]=>shown(n)?[n,...(n.children??[]).flatMap(flat)]:[];
const visible=async(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null,20000);
const hidden=async(id:string)=>waitFor(async()=>!(await query(id)).some(shown)||null,20000);
const click=async(id:string)=>{const n=await visible(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)};
const type=async(text:string)=>{assert((await type_(text)).ok)};
const press=async(name:string,mods?:any)=>{assert((await key(name,mods)).ok)};
const file=async(path:string)=>{try{return await readFile(path,'utf8')}catch{return ''}};
const check=(name:string,detail:any={})=>report.checks.push({name,status:'passed',detail});
const capture=async(name:string)=>{assert((await screenshot(join(output,`${name}.png`))).ok);const nodes:any={};for(const id of ['tabs.strip','terminal.commands','groups.workspace','groups.close.confirm','local.close.confirmation'])nodes[id]=await query(id);await writeFile(join(output,`${name}.queries.json`),JSON.stringify(nodes,null,2));report.screenshots.push(name);await save()};
let shellPid:number|undefined;
try{
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await resizeWindow(1440,900);
 await click('workspace.empty.local');await visible('terminal.surface');
 const start=String(await waitFor(async()=>(await file(join(isolated,'startup-start'))).trim()||null,20000)).split(' ');shellPid=Number(start[0]);assert(shellPid>1);report.shell_pid=shellPid;
 await waitFor(async()=>(await file(join(isolated,'startup-end'))).trim()||null,15000);
 const startupSeconds=Number((await file(join(isolated,'startup-end'))).trim())-Number(start[1]);assert(startupSeconds>=3);check('real owning ZSH startup exceeds original 2s boundary',{startup_seconds:startupSeconds,shell_pid:shellPid});
 // The owned startup script records its actual integration socket. Public
 // Ctrl-C and the @ palette below prove cancellation and trusted editing.
 const receipt=join(isolated,'real-shell-receipt');
 const socket=String(await waitFor(async()=>(await file(receipt)).trim()||null,20000));assert(socket.startsWith('/tmp/zw-edit-')&&socket.endsWith('/control'));report.private_socket=socket;
 await sleep(250);await click('terminal.surface');await press('c',{ctrl:true});await sleep(250);report.explicit_ctrl_c=true;
 let trusted=false;
 for(let attempt=1;attempt<=3;attempt++){
  await type('@');try{await waitFor(async()=>(await query('terminal.commands')).some(shown)||null,4000);trusted=true;report.palette_attempts=attempt;break}catch{await press('c',{ctrl:true});await sleep(250)}
 }
 assert(trusted,'Delayed real shell must expose production trusted command palette');check('production trusted @ palette opens after delayed first handshake');await capture('01-delayed-trusted-palette');
 await type('grp DelayedStartup');await press('right');await hidden('terminal.commands');await press('return');
 await waitFor(async()=>{const p=await screenPos('groups.workspace');return p.w>0&&p.h>0||null},20000);check('production trusted @grp creates group around original Local shell');await capture('02-delayed-real-group');
 await click('groups.close');await visible('groups.close.confirm');await click('groups.close.accept');
 await waitFor(async()=>{if((await query('local.close.confirmation')).some(shown)){await click('local.close.accept');return null}const strip=(await query('tabs.strip')).find(shown);return (!strip||!flat(strip).some(n=>/^tabs\.tab\.\d+$/.test(n.test_id??'')))||null},30000);
 await waitFor(async()=>{try{process.kill(shellPid!,0);return null}catch{return true}},15000);
 await waitFor(async()=>{try{await access(dirname(socket));return null}catch{return true}},15000);
 check('normal member close releases original shell and private bridge directory',{shell_pid:shellPid,private_socket_removed:true});await capture('03-shell-and-bridge-released');
 assert(!/connection refused|IntegrationUnavailable/i.test(await readFile(join(output,'app.log'),'utf8')));report.status='passed';
}catch(error){report.status='failed';report.error=String(error);await capture('failed').catch(()=>{});process.exitCode=1}
finally{await save();if(app.exitCode===null)app.kill('SIGTERM');await Promise.race([ended,sleep(5000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await Promise.race([ended,sleep(2000)])}await log.close();if(shellPid){try{process.kill(shellPid,'SIGHUP')}catch{}}report.cleanup={app_exited:app.exitCode!==null||app.signalCode!==null};await save()}
