/** Own native window + real Local PTY; validates material/caret popup regressions. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,realpath,writeFile,readFile,open} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';
import {deflateSync} from 'node:zlib';
const prefix=process.env.ZW_RATIO_PREFIX??'/private/tmp/zw-material-ratio';
const {waitForServerReady,waitFor,query,clickAt,key,type_,resizeWindow,screenshot,sleep}=await import(join(prefix,'share/zenit/harness/client.ts'));
const output=resolve(process.argv[2]);await mkdir(output,{recursive:true});
const binary=join(prefix,'bin/zerowork');
function crc32(bytes:Buffer){let c=0xffffffff;for(const b of bytes){c^=b;for(let i=0;i<8;i++)c=(c>>>1)^((c&1)?0xedb88320:0)}return(c^0xffffffff)>>>0}
function chunk(kind:string,body:Buffer){const t=Buffer.from(kind),n=Buffer.alloc(4),c=Buffer.alloc(4);n.writeUInt32BE(body.length);c.writeUInt32BE(crc32(Buffer.concat([t,body])));return Buffer.concat([n,t,body,c])}
const pixels=Buffer.alloc(160*961);for(let y=0;y<160;y++)for(let x=0;x<240;x++)pixels.set([x<120?70:190,y<80?110:180,140,255],y*961+1+x*4);
const ihdr=Buffer.alloc(13);ihdr.writeUInt32BE(240);ihdr.writeUInt32BE(160,4);ihdr[8]=8;ihdr[9]=6;
const fixture=Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),chunk('IHDR',ihdr),chunk('IDAT',deflateSync(pixels)),chunk('IEND',Buffer.alloc(0))]);
const report:any={status:'running',sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),cases:[],limits:['Synthetic Harness input in an own native Metal window; not physical keyboard/IME acceptance.','Uses isolated saved settings and real Local PTY; screenshots require visual inspection.']};
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&n.rect?.w>0&&n.rect?.h>0;
const vis=(id:string)=>waitFor(async()=>(await query(id)).find(shown)??null,15000).catch((e:any)=>{throw new Error(`Waiting for ${id}: ${e}`)});
async function click(id:string){const n=await vis(id);assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)}
async function press(k:string){assert((await key(k)).ok)}
async function text(s:string){assert((await type_(s)).ok)}
async function palette(){await text('@');await vis('terminal.commands')}
async function command(s:string){await palette();await text(s);await press('right');await press('return');await sleep(400)}
async function capture(name:string,item:any){await sleep(200);assert((await screenshot(join(output,name+'.png'))).ok);item.captures.push(name)}
async function placement(name:string,item:any){
  const p=await vis('terminal.commands'),edit=await vis('terminal.surface.caret'),surface=(await query('terminal.surface')).find((n:any)=>shown(n)&&edit.rect.x>=n.rect.x&&edit.rect.x<n.rect.x+n.rect.w);
  assert(surface,'input belongs to a visible pane');
  assert(p.rect.y+p.rect.h<=edit.rect.y-3||p.rect.y>=edit.rect.y+edit.rect.h+3,'popup must leave the entire input row unobscured');
  assert(p.rect.x>=surface.rect.x-.6&&p.rect.x+p.rect.w<=surface.rect.x+surface.rect.w+.6,'popup fits owner pane horizontally');
  assert(p.rect.y>=surface.rect.y-.6&&p.rect.y+p.rect.h<=surface.rect.y+surface.rect.h+.6,'popup fits owner pane vertically');
  item.geometry.push({name,popup:p.rect,input:edit.rect,pane:surface.rect});await capture(name,item);
}
try{
 for(const [theme,t,b] of [['dark',75,24],['light',75,0],['light',100,0],['dark',100,96],['light',0,0]] as const){
  if(process.env.ZW_RATIO_ONLY&&process.env.ZW_RATIO_ONLY!==`${theme}-t${t}-b${b}`)continue;
  const name=`${theme}-t${t}-b${b}`,iso=await realpath(await mkdtemp(join(tmpdir(),'zw-ratio-'))),data=join(iso,'data'),rpc=join(iso,'rpc'),shell=join(iso,'shell');
  await Promise.all([mkdir(data),mkdir(rpc),mkdir(shell)]);
  await writeFile(join(shell,'.zshrc'),"bindkey -e\nPS1='ratio%# '\n");
  const image=join(data,'background.png');await writeFile(image,fixture);
  await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="${theme}"\nfont_family="Menlo"\nfont_size=14\n[ui.materials]\nblur_px=${b}\n[ui.materials.background]\nenabled=${t===75}\npath=${JSON.stringify(image)}\ntransparency=${t}\n`);
  process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;const log=await open(join(output,name+'.log'),'w');
  const app=spawn(binary,[],{env:{...process.env,ZDOTDIR:shell,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
  const ended=new Promise(r=>app.once('close',r));const item:any={name,isolated:iso,captures:[],geometry:[]};report.cases.push(item);
  try{
   await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);
   await resizeWindow(1100,760);await click('workspace.empty.local');await vis('terminal.surface');await sleep(1500);
   await command('ts');await command('ts');await palette();await placement(name+'-history',item);
   await resizeWindow(860,480);await sleep(250);await placement(name+'-compact',item);await press('escape');
   if(theme==='dark'&&t===75){
    await resizeWindow(1100,760);await command('grp Material');await vis('groups.waiting');
    await click('toolbar.new_session');await click('session.menu.local');await vis('terminal.surface');await sleep(1500);await command('grp Material');
    await waitFor(async()=>(await query('terminal.surface')).filter(shown).length===2||null,15000);
    await palette();await placement(name+'-group',item);await press('escape');
   }
   if(t===0){
    await resizeWindow(1440,900);await click('toolbar.settings');await click('settings.nav.appearance');await click('settings.materials.header');
    for(const [id,value] of [['settings.field.transparency','65'],['settings.field.blur_px','16']]){
     await click(id);await key('a',{cmd:true});await text(value);await press('return');
    }
    await click('settings.materials.preview.open');await vis('settings.materials.preview.actions');await capture(name+'-no-image-draft-preview',item);
    await click('settings.materials.preview.return');await vis('settings.close');
    item.noImageDraftPreview=true;
   }
   if(t===100&&b===0){
    await resizeWindow(1100,760);await click('toolbar.settings');await click('settings.nav.appearance');await capture(name+'-settings',item);
   }
   item.status='passed';
  }catch(error){await capture(name+'-failure',item).catch(()=>{});const q:any={};for(const id of ['terminal.input','terminal.surface','terminal.commands','terminal.surface.caret'])q[id]=await query(id);await writeFile(join(output,name+'-failure.json'),JSON.stringify(q,null,2));throw error}
  finally{app.kill('SIGTERM');await Promise.race([ended,sleep(3000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}await log.close()}
 }
 report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1}
finally{await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,error:report.error,output}))}
