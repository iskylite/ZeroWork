/** Built-in declarations: independent terminfo/input matrices over real SSH.
 * Local transport's configurable Options.term is covered by real-PTY service
 * tests; the product Local default remains xterm-256color.
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {resolve,join} from 'node:path';
const out=resolve(process.argv[2]),binary=resolve(process.argv[3]);
const terms=process.argv[4]?[process.argv[4]]:['xterm-256color','xterm','vt100'];
await mkdir(out,{recursive:true});
const matrix:any={status:'running',runs:[],limits:['Uses each owned SSH peer PTY request TERM; no user hosts or credentials.','VT100 is the installed terminfo compatibility contract, not strict hardware-model emulation.','Unadvertised capabilities and declared but uncovered aliases remain explicit in per-capability matrices.','Local terminal type configuration is not changed by the SSH setting.']};
try{
 for(const term of terms){
  assert(['xterm-256color','xterm','vt100'].includes(term));
  const dir=join(out,term),child=spawn(process.execPath,['e2e/xterm_capabilities_native.ts',dir,binary,'ssh',term],{stdio:'inherit'});
  const code=await new Promise(r=>child.once('close',r));
  const report=JSON.parse(await readFile(join(dir,'report.json'),'utf8'));
  matrix.runs.push({term,report:term+'/report.json',...report.runs[0]});
  await writeFile(join(out,'matrix.json'),JSON.stringify(matrix,null,2));
  assert.equal(code,0,term+' process failed');assert.equal(report.status,'passed');
 }
 matrix.status='passed';
}catch(e){matrix.status='failed';matrix.error=String(e);process.exitCode=1}
finally{await writeFile(join(out,'matrix.json'),JSON.stringify(matrix,null,2));console.log(JSON.stringify({status:matrix.status,out,runs:matrix.runs.map((r:any)=>({term:r.term,status:r.status,checks:r.checks.length}))}))}
