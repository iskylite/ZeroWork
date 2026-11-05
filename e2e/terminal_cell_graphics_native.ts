/** Real Local PTY regression for cell graphics; --baseline records the old gaps. */
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,open,readFile,writeFile,rm} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
const [binArg,outArg,...flags]=process.argv.slice(2),binary=resolve(binArg),out=resolve(outArg);
const baseline=flags.includes('--baseline');
const h=await import(pathToFileURL(resolve(process.env.ZW_HARNESS_CLIENT??'zig-out/share/zenit/harness/client.ts')).href);
await mkdir(out,{recursive:true});
const report:any={binary,sha256:createHash('sha256').update(await readFile(binary)).digest('hex'),baseline,runs:[],status:'running',limits:['Controlled reproduction of screenshot symptoms; original CLI byte stream was not supplied. Public Harness with actual Local PTY and Metal captures; no physical keyboard/IME claims.']};
const shown=(n:any)=>n&&!n.hidden&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const quote=(s:string)=>"'"+s.replaceAll("'","'\\''")+"'";
try{for(const [font,size,line] of (baseline?[['Monaco',14,1.5]]:[['Monaco',14,1.5],['Menlo',13,1.35]]) as [string,number,number][]){
 const name=`${font}-${size}-${line}`,iso=await mkdtemp('/private/tmp/zw-cell-'),data=join(iso,'data'),rpc=join(iso,'rpc');await mkdir(data);await mkdir(rpc);
 await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="${font}"\nfont_size=${size}\nline_height=${line}\nfont_weight="regular"\ntimestamp_gutter=false\ninput_line_highlight=false\n[completion]\nenabled=false\n`);
 process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
 const log=await open(join(out,name+'.log'),'w');const app=spawn(binary,[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});const ended=new Promise(r=>app.once('close',r));
 const run:any={font,size,line,status:'running'};report.runs.push(run);
 const node=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,20000);
 const collect=async()=>{const label=(await node('local.status.grid')).children?.map((n:any)=>n.text??'').join('')??'';const direct=await node('local.status.grid');const text=(n:any):string=>(n.text??'')+(n.children??[]).map(text).join('');const m=text(direct).match(/(\d+)×(\d+)/);assert(m,'grid '+label);const rows=[];for(let y=0;y<Number(m[2]);y++){const ns=await h.query(`terminal.surface.row.${y}`);const n=ns.find(shown);if(n)rows.push(n)}return rows};
 try{
  await h.waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,'owner.json'),'utf8')).pid),app.pid);assert((await h.resizeWindow(1440,900)).ok);assert((await h.clickTestId('workspace.empty.local')).ok);await node('terminal.surface');
  const lines=['CELL_GRAPHICS '+name,'BLOCKS / VERTICAL (must join across rows)'];
  for(let i=0;i<8;i++)lines.push(`\x1b[38;2;255;190;40m▌\x1b[0m   \x1b[38;2;180;180;180m█\x1b[0m   │   ┃   ║   ▐`);
  lines.push('HORIZONTAL '+ '─'.repeat(40),'HEAVY      '+ '━'.repeat(40),'DOUBLE     '+ '═'.repeat(40),'┌────────────┬────────────┐','│            │            │','├────────────┼────────────┤','│            │            │','└────────────┴────────────┘','╔════════════╦════════════╗','║            ║            ║','╚════════════╩════════════╝','FRACTIONS '+Array.from({length:32},(_,i)=>String.fromCodePoint(0x2580+i)).join(''),'ATLAS '+Array.from({length:64},(_,i)=>String.fromCodePoint(0x2500+i)).join(''),'ATLAS '+Array.from({length:64},(_,i)=>String.fromCodePoint(0x2540+i)).join(''),'STYLES \x1b[7m▌│█\x1b[0m \x1b[2m▌│█\x1b[0m \x1b[8m▌│█\x1b[0m END','CELL_GRAPHICS_DONE');
  const bytes='\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H'+lines.join('\r\n');
  const fixture=join(iso,'fixture.zsh'),raw=join(iso,'stdout');await writeFile(fixture,`printf '%s' ${quote(bytes)}\n`);await writeFile(join(out,name+'.fixture.zsh'),await readFile(fixture));
  assert((await h.clickTestId('terminal.surface')).ok);assert((await h.type_(`/bin/zsh -f ${quote(fixture)} | /usr/bin/tee ${quote(raw)}`)).ok);assert((await h.key('enter')).ok);
  await h.waitFor(async()=>{try{return (await readFile(raw)).equals(Buffer.from(bytes))||null}catch{return null}});
  let rows:any[]=[];await h.waitFor(async()=>{rows=await collect();return rows.some(n=>(n.children??[]).map((c:any)=>c.text??'').join('').includes('CELL_GRAPHICS_DONE'))||null});await h.sleep(300);
  const screenshot=join(out,name+'.png');assert((await h.screenshot(screenshot)).ok);await writeFile(join(out,name+'.rows.json'),JSON.stringify(rows,null,2));await writeFile(join(out,name+'.stdout'),await readFile(raw));
  const probes=rows.flatMap((row:any)=>(row.children??[]).filter((n:any)=>shown(n)&&['▌','█','│','┃','║','▐'].includes(n.text)).map((n:any)=>({text:n.text,rect:n.rect}))).filter((n:any)=>n.rect.y<rows[10].rect.y&&n.rect.y>=rows[2].rect.y);
  assert.equal(probes.length,48);assert(Math.abs(probes[0].rect.h-size*line)<0.1);run.row_height=probes[0].rect.h;run.screenshot=screenshot;run.probes=probes;
  const manifest=join(out,name+'.probes.json');await writeFile(manifest,JSON.stringify({rows,probes,screenshot,baseline},null,2));
  run.pixels=JSON.parse(execFileSync('python3',[resolve('e2e/terminal_cell_graphics_pixels.py'),manifest],{encoding:'utf8'}));run.status='passed';
 }catch(e){run.status='failed';run.error=String(e);await h.screenshot(join(out,name+'-failure.png')).catch(()=>{});throw e}
 finally{if(app.exitCode===null&&app.signalCode===null){app.kill('SIGTERM');await Promise.race([ended,h.sleep(2000)]);if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended}}await log.close();await rm(iso,{recursive:true,force:true})}
}report.status='passed'}catch(e){report.status='failed';report.error=String(e);process.exitCode=1}finally{await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));console.log(report.status+': '+join(out,'report.json'))}
