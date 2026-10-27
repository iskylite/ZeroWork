import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,writeFile,rm,realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out=resolve(process.argv[2]||'/tmp/zw-input-host'); await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp(join(tmpdir(),'zw-input-host-'))),rpc=join(iso,'rpc'),data=join(iso,'data');await mkdir(rpc);await mkdir(data);
await writeFile(join(data,'hosts.toml'),'[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname="X40-AI01-long-host"\nhost="192.0.2.1"\nport=22\nuser="root"\nroute=[]\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const app=spawn(resolve(process.env.ZW_GEOMETRY_BINARY||'zig-out/bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:'inherit'});
const shown=(n:any)=>n.visible!==false&&n.rect.w>0&&n.rect.h>0;
const get=async(id:string)=>await h.waitFor(async()=>(await h.query(id)).find(shown)||null,10000);
const cap=async(name:string)=>{await h.sleep(200);await h.screenshot(join(out,name+'.png'));await writeFile(join(out,name+'.json'),JSON.stringify(await Promise.all(['sidebar.host','sidebar.host.protocol','sidebar.host.hops','sidebar.host.connect','wizard.name'].map(async id=>({id,nodes:await h.query(id)}))),null,2));};
try {
  await h.waitForServerReady(60000);
  await h.resizeWindow(1440,900);
  const host=await get('sidebar.host');
  await h.mouseMove(host.rect.x+10,host.rect.y+12);
  await cap('narrow-hover');
  const grip=await get('sidebar.resize');
  await h.mouseDown(grip.rect.x+4,grip.rect.y+100);
  await h.mouseMove(grip.rect.x+150,grip.rect.y+100);
  await h.mouseUp(grip.rect.x+150,grip.rect.y+100);
  const wide=await get('sidebar.host');
  await h.mouseMove(wide.rect.x+10,wide.rect.y+12);
  await cap('wide-hover');
  await h.clickTestId('sidebar.host.edit');
  await get('wizard.name');
  await h.clickTestId('wizard.name');
  await h.key('a',{cmd:true});
  await h.type_('X40-AI01');
  assert.equal((await h.inputState('wizard.name')).cursor_pos,8);
  await cap('input-end');
  await h.key('left');await h.key('left');
  assert.equal((await h.inputState('wizard.name')).cursor_pos,6);
  await cap('input-middle');
  await h.type_('中');
  assert.equal((await h.inputState('wizard.name')).buffer,'X40-AI中01');
  await cap('input-insert');
  await writeFile(join(out,'report.json'),JSON.stringify({status:'passed',checks:['narrow and wide native hover captures','caret end and middle positioning','Chinese insertion at selected byte offset']},null,2));
  console.log(out);
} finally {
  if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await new Promise(r=>app.once('close',r));}
  await rm(iso,{recursive:true,force:true});
}
