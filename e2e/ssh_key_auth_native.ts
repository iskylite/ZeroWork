/** Production native App → libssh2 → owned SSH peer → actual isolated ZSH PTY.
 * node e2e/ssh_key_auth_native.ts BINARY PEER_READY_JSON OUTPUT [OPTIONAL_USER_KEY] [CASE]
 * Start ssh_key_native_peer.py separately; no external host is contacted.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,realpath,readFile,writeFile,open,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {createHash} from 'node:crypto';
import * as h from '../vendor/zenit/e2e/client.ts';
const [binaryArg,peerArg,outArg,userKey,onlyCase]=process.argv.slice(2);
const binary=resolve(binaryArg),out=resolve(outArg),peer=JSON.parse(await readFile(resolve(peerArg),'utf8'));
assert.equal(peer.host,'127.0.0.1');await mkdir(out,{recursive:true});
const report:any={status:'running',binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),cases:[],limits:['Actual native Metal window and public synthetic Harness input; physical keyboard/IME/VoiceOver are not covered.','Only the owned 127.0.0.1 SSH peer is contacted. The peer starts a disposable local ZSH PTY; automatic shell integration is disabled in this auth-specific fixture.']};
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>!shown(n)?[]:[n,...(n.children??[]).flatMap(flat)];
const content=(n:any):string=>flat(n).map(x=>x.text??'').join(' ');
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
async function click(id:string){const n=await visible(id);assert((await h.clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok);await h.sleep(120);}
async function modal(){return (await h.query('plugin.challenge.modal')).find(shown);}
async function snapshot(){return await h.request('POST','/zerowork/windows',{action:'snapshot'});}
async function capture(name:string){await h.sleep(250);assert((await h.screenshot(join(out,name+'.png'))).ok);await writeFile(join(out,name+'.json'),JSON.stringify({challenge:await h.query('plugin.challenge.modal'),progress:await h.query('connection.progress'),input:await h.query('terminal.input'),focused:await h.focused(),pane:await h.query('workspace.pane')},null,2));}
const invalidKey=join(out,'invalid-key');await writeFile(invalidKey,'invalid private key fixture\n',{mode:0o600});
const cases:any[]=[{name:'openssh-clear',key:peer.clear_key,prompts:0},{name:'openssh-encrypted-retry',key:peer.key,prompts:2},{name:'server-rejected',key:peer.clear_key,prompts:0,rejected:true},{name:'invalid-key',key:invalidKey,prompts:0,error_text:'私钥文件格式无效、已损坏或当前不支持'},{name:'missing-key',key:join(out,'missing-key-does-not-exist'),prompts:0,error_text:'无法读取私钥文件，请检查路径与权限'}];
if(userKey)cases.push({name:'provided-openssh-key-loopback',key:resolve(userKey),prompts:0});
try{for(const test of cases.filter(test=>!onlyCase||test.name===onlyCase)){
 const isolated=await realpath(await mkdtemp('/private/tmp/zw-native-key-')),data=join(isolated,'data'),rpc=join(isolated,'rpc');await mkdir(data);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const hosts=`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauto_shell_integration=false\nauth_mode="private_key"\noptions={strict_host_key=true}\nname="Owned RSA key fixture"\nhost="127.0.0.1"\nport=${peer.port}\nuser="${test.rejected?'rejected-fixture':peer.user}"\nauth={key=${JSON.stringify(test.key)}}\n`;
 await writeFile(join(data,'hosts.toml'),hosts);await writeFile(join(data,'config.toml'),'[ui]\ntheme="dark"\n');
 const log=await open(join(out,test.name+'.log'),'w'),app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
 const record:any={case:test.name,status:'running',key_prompts:0};
 try{
  await h.waitForServerReady(60000);assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);await h.resizeWindow(1280,720);
  const row=await visible('sidebar.host');assert((await h.clickAt(row.rect.x+50,row.rect.y+row.rect.h/2)).ok);
  await h.waitFor(async()=>content(await modal()).includes('核对主机密钥')||null,15000);
  assert(content(await modal()).includes(peer.fingerprint));await capture(test.name+'-host-key');await click('plugin.challenge.choice.0');
  if(test.prompts){
   await h.waitFor(async()=>content(await modal()).includes('解锁 SSH 私钥')||null,15000);record.key_prompts++;
   assert(!content(await modal()).includes(peer.fingerprint));await capture(test.name+'-unlock');
   await click('plugin.challenge.answer.0');assert((await h.type_('incorrect-fixture-passphrase')).ok);await click('plugin.challenge.submit');
   await h.waitFor(async()=>{const details=(await h.query('plugin.challenge.detail')).filter(shown);return details.some(n=>content(n).includes('密码短语不正确'))||null},15000);record.key_prompts++;
   await capture(test.name+'-wrong-passphrase');await click('plugin.challenge.answer.0');await h.key('a',{cmd:true});assert((await h.type_('fixture-key-passphrase')).ok);await click('plugin.challenge.submit');
  }
  if(test.prompts)await h.waitFor(async()=>!(await modal())||null,30000);
  await h.waitFor(async()=>{
   const m=await modal();if(m){assert(!content(m).includes('解锁 SSH 私钥'),'unexpected or repeated key passphrase prompt');}
   if(test.rejected||test.error_text)return (await h.query('connection.progress.state')).some(n=>shown(n)&&content(n).includes('连接失败'))||null;
   return content((await h.query('workspace.pane')).find(shown)).includes('keyfixture')||null;
  },30000);
  const state:any=await snapshot();
  assert.equal((state.sessions??[]).filter((s:any)=>s.plugin==='ssh').length,1,'one row click creates exactly one SSH session');
  assert(!(await modal()));record.state=state;
  if(test.error_text){
   const detail=await h.waitFor(async()=>{const n=(await h.query('connection.progress.summary.detail')).find(shown);return content(n).includes(test.error_text)?n:null},15000);record.failure_text=content(detail);
  }
  if(!test.rejected&&!test.error_text){
   await h.sleep(700); // Production SSH admission waits for 500ms of quiet output.
   const terminal=await visible('terminal.input');assert((await h.clickAt(terminal.rect.x+30,terminal.rect.y+10)).ok);await h.sleep(250);assert((await h.type_("printf '%s%s\\n' ZW_KEY_AUTH_ CONFIRMED")).ok);assert((await h.key('return')).ok);
   await h.waitFor(async()=>content((await h.query('workspace.pane')).find(shown)).includes('ZW_KEY_AUTH_CONFIRMED')||null,15000);
   record.command_output='ZW_KEY_AUTH_CONFIRMED';
  }
  assert.equal(record.key_prompts,test.prompts);await capture(test.name+'-result');
  assert.equal(await readFile(join(data,'hosts.toml'),'utf8'),hosts);record.credentials_not_saved=true;record.status='passed';
 }catch(error){record.status='failed';record.error=String(error);await capture(test.name+'-failure').catch(()=>{});throw error;}
 finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,h.sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}}await log.close();await rm(isolated,{recursive:true,force:true});report.cases.push(record);await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
 console.log(test.name+' passed');
}report.status='passed';}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;}finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
console.log(JSON.stringify({status:report.status,cases:report.cases.map((x:any)=>({case:x.case,status:x.status,prompts:x.key_prompts})),error:report.error}));
