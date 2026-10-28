/** Quick-connect hierarchy: isolated native windows, all registered builtin palettes. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,writeFile,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../vendor/zenit/e2e/client.ts';
const binary=resolve(process.argv[2]??'/tmp/zw-quick-hierarchy/build/bin/zerowork');
const out=resolve(process.argv[3]??'/tmp/zw-quick-hierarchy/native');
const themes=(process.argv[4]??'dark,light,sauber,midnight,forest,ocean,plum,ember,graphite,paper,sand,ice,catppuccin-mocha,dracula,dark-pro,solarized-dark,nord').split(',');
await mkdir(out,{recursive:true});
const report:any={status:'running',binary,binary_sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),cases:[],limits:['Synthetic Harness events; no physical keyboard or IME claim.','Fixtures never submit a network connection. SIGTERM cleans up only runner-owned processes.']};
const shown=(n:any)=>n?.rect&&n.hidden!==true&&n.visible!==false&&n.rect.w>0&&n.rect.h>0;
const visible=async(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const descendants=(n:any):any[]=>[n,...(n.children??[]).flatMap(descendants)];
async function input(text:string){const n=await visible('quick.query');await h.clickAt(n.rect.x+70,n.rect.y+20);await h.key('a',{cmd:true});await h.type_(text);}
try{
 for(const theme of themes){
  const iso=await mkdtemp('/private/tmp/zw-quick-native-'),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
  process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
  await writeFile(join(data,'config.toml'),`[ui]\ntheme="${theme}"\n[ui.materials]\nblur_px=0\n[ui.materials.background]\ntransparency=100\n`);
  const names=['ScaleX40-AI01','Build-Runner-02','Production-Database-With-A-Long-Name','File-Server'];
  await writeFile(join(data,'hosts.toml'),'[registry]\nschema_version=2\nrevision=1\nnext_connection_id=5\nnext_group_id=1\n'+names.map((name,i)=>`[[hosts]]\nconnection_id=${i+1}\nrevision=1\nprotocol="ssh"\nauth_mode="agent"\nname="${name}"\nhost="192.0.2.${20+i}"\nport=22\nuser="deploy"\n`).join(''));
  const log=await open(join(out,theme+'.log'),'w');
  const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
  const ended=new Promise<void>(r=>app.once('close',()=>r()));const item:any={theme,status:'running',checks:[]};report.cases.push(item);
  const capture=async(name:string)=>{await h.waitFor(async()=>{const v=(await h.query('quick.connect')).find(shown) as any;return v&&(v.effective_opacity??1)===1&&(v.scale_x??1)===1&&(v.scale_y??1)===1?v:null},15000);const ids=['quick.connect','quick.query','quick.saved.row','quick.footer','quick.submit'];const nodes=Object.fromEntries(await Promise.all(ids.map(async id=>[id,await h.query(id)])));await writeFile(join(out,name+'.json'),JSON.stringify(nodes,null,2));assert((await h.screenshot(join(out,name+'.png'))).ok);};
  try{
   await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
   await h.resizeWindow(960,640);await h.key('k',{cmd:true});const panel=await visible('quick.connect');assert.equal(panel.rect.w,520);
   await h.waitFor(async()=>(await h.query('quick.saved.row')).filter(shown).length>=3||null);
   const rows=(await h.query('quick.saved.row')).filter(shown);assert(rows.every((r:any)=>r.rect.h===44));
   const nodes=descendants(rows[0]);const name=nodes.find(n=>n.test_id==='quick.saved.name'),endpoint=nodes.find(n=>n.test_id==='quick.saved.endpoint');assert(name&&endpoint);assert(endpoint.rect.y>=name.rect.y+name.rect.h);assert(name.rect.w>300);assert(endpoint.rect.w>300);
   item.checks.push('520px popup; 44px two-line results; name/endpoint do not overlap');await capture(theme+'-standard');
   if(['midnight','light','sauber'].includes(theme)){
    await h.key('down');await h.key('down');await h.key('down');const viewport=await visible('quick.results');await h.waitFor(async()=>{const last=(await h.query('quick.saved.name')).find(n=>n.text==='File-Server');return last&&last.rect.y>=viewport.rect.y&&last.rect.y+last.rect.h<=viewport.rect.y+viewport.rect.h||null});await capture(theme+'-fourth-selected');
    await input('ScaleX40');await h.waitFor(async()=>(await h.query('quick.saved.row')).filter(shown).length===1||null);await capture(theme+'-single');
    await h.resizeWindow(860,480);await input('ssh root@[2001:db8::1]:70000');await visible('quick.port');
    const temp=await visible('quick.connect'),submit=await visible('quick.submit');assert(temp.rect.y>=0&&temp.rect.y+temp.rect.h<=480);assert(submit.rect.y+submit.rect.h<=temp.rect.y+temp.rect.h);await capture(theme+'-invalid-minimum');
    await input('no-such-host');await visible('quick.empty.title');await capture(theme+'-empty-minimum');
    await h.clickTestId('quick.clear');await h.waitFor(async()=>(await h.query('quick.saved.row')).filter(shown).length>=3||null);await h.key('escape');await h.waitFor(async()=>!(await h.query('quick.connect')).some(shown)||null);await h.key('k',{cmd:true});await visible('quick.query');item.checks.push('Arrow selection scrolls to fourth result; filter, clear, invalid and empty states; 860×480 fit; Esc closes and Cmd+K reopens');
   }
   item.status='passed';console.log(theme+' passed');
  }catch(e){item.status='failed';item.error=String(e);await capture(theme+'-failure').catch(()=>{});throw e;}
  finally{if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');await ended;await log.close();await rm(iso,{recursive:true,force:true});}
 }
 report.status='passed';
}catch(e){report.status='failed';report.error=String(e);process.exitCode=1;console.error(e);}
finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));}
