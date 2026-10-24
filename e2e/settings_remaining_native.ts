/** Existing-main-window settings evidence. No launcher, scenario route or config writes.
 * node e2e/settings_remaining_native.ts --live live.json --out EMPTY_DIR [--fields a,b]
 * [--keep-target yes] [--restore-from previous/report.json]
 */
import assert from 'node:assert/strict';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { health, query, tree, inputState, clickTestId, key, type_, screenshot, sleep, type QueryNode } from '../zig-out/share/zenit/harness/client.ts';
const options: Record<string,string> = {};
for (let i=2;i<process.argv.length;i+=2) {
  assert(['--live','--out','--fields','--keep-target','--restore-from','--targets'].includes(process.argv[i]) && process.argv[i+1], `Invalid option ${process.argv[i]}`);
  options[process.argv[i]]=process.argv[i+1];
}
assert(options['--live'] && options['--out'], '--live and --out required');
assert(!options['--keep-target'] || options['--keep-target']==='yes');
const output=resolve(options['--out']);
await mkdir(output,{recursive:true});
assert.equal((await readdir(output)).length,0,'Output directory must be empty');
const live=JSON.parse(await readFile(resolve(options['--live']),'utf8'));
assert(Number.isSafeInteger(live.pid) && live.pid>0 && live.rpc && live.data,'live must contain pid,rpc,data');
process.env.ZENIT_E2E_FILE_RPC_DIR=resolve(live.rpc);
assert(!process.env.ZENIT_E2E_HTTP_JOB_ID,'Only the identified local file-RPC instance is allowed');
const owner=JSON.parse(await readFile(join(live.rpc,'owner.json'),'utf8'));
assert.equal(Number(owner.pid),live.pid,'RPC owner mismatch');
process.kill(live.pid,0);
const audit=JSON.parse(await readFile(resolve('dist/local-acceptance/20261021/resume-settings-native-gap-audit.json'),'utf8'));
assert.equal(audit.fields.length,52);
const restored=options['--restore-from'] ? JSON.parse(await readFile(resolve(options['--restore-from']),'utf8')) : null;
const requested=options['--fields']?.split(',');
for (const f of requested??[]) assert(audit.fields.some((x:any)=>x.field===f),`Unknown field ${f}`);
const targets=options['--targets'] ? JSON.parse(await readFile(resolve(options['--targets']),'utf8')) : {};
for(const f of Object.keys(targets)) assert(audit.fields.some((x:any)=>x.field===f),`Unknown target ${f}`);
const configPath=join(live.data,'config.toml');
function values(source:string): Record<string,unknown> {
  const result:Record<string,unknown>={}; let section='';
  for (const raw of source.split('\n')) {
    const line=raw.trim(); if (/^\[[^\[]/.test(line)) {section=line.slice(1,line.indexOf(']'));continue;}
    const m=line.match(/^([a-z_][a-z_0-9]*)\s*=\s*(.*)$/); if (!m) continue;
    const id=`${section}.${m[1]}`;
    // Only the audited scalar allowlist is parsed or serialized. Provider/key/model tables are excluded.
    if (!audit.fields.some((x:any)=>x.field===id)) continue;
    try {result[id]=JSON.parse(m[2]);} catch {throw new Error(`Unsupported audited TOML value: ${id}`);}
  }
  return result;
}
const readValues=async()=>values(await readFile(configPath,'utf8'));
let baseline=await readValues();
// Compare AI provider/model/key bytes in memory only; emit neither source nor digest.
// Full config is held only in memory. Changes are checked through the scalar allowlist instead.
const originalConfig=await readFile(configPath,'utf8');
// Compare explicitly supplied provider fields semantically: the App may materialize omitted defaults.
// Never include protected values in assertion arguments, reports, logs or snapshots.
function statements(line:string):string[]{let quoted=false,escaped=false,start=0;const out:string[]=[];for(let i=0;i<line.length;i++){const c=line[i];if(quoted){if(escaped)escaped=false;else if(c==='\\')escaped=true;else if(c==='"')quoted=false;}else if(c==='"')quoted=true;else if(c==='#'){out.push(line.slice(start,i));return out;}else if(c===';'){out.push(line.slice(start,i));start=i+1;}}out.push(line.slice(start));return out;}
function providerFields(source:string):Map<string,string>{const fields=new Map<string,string>();let section='',provider=-1,model=-1;const models:number[]=[];
 for(const raw of source.split('\n'))for(const piece of statements(raw)){const line=piece.trim();if(!line)continue;
  if(line==='[[ai.providers]]'){section='provider';provider++;model=-1;models[provider]=0;continue;}
  if(line==='[[ai.providers.models]]'){assert(provider>=0,'Invalid protected provider table');section='model';model++;models[provider]++;continue;}
  if(line.startsWith('[')){section=line.slice(1,-1);continue;}
  const m=line.match(/^([a-z_0-9]+)\s*=\s*(.+)$/);if(!m)continue;let k=m[1];
  if(section==='provider')k=`provider_${provider}_${k==='id'?'name':k}`;
  else if(section==='model')k=`provider_${provider}_model_${model}_${k==='name'?'id':k}`;
  else if(section!=='ai'||!(/^(provider_|provider_count$|default_provider$)/.test(k)))continue;
  let value:string;try{value=JSON.stringify(JSON.parse(m[2].replace(/(?<=\d)_(?=\d)/g,'')));}catch{throw new Error('Unsupported protected config syntax; root inspection required');}fields.set(k,value);
 }
 if(provider>=0){fields.set('provider_count',String(provider+1));for(let i=0;i<models.length;i++)fields.set(`provider_${i}_model_count`,String(models[i]));}return fields;
}
const protectedProviders=providerFields(originalConfig);
async function assertProvidersPreserved(){const after=providerFields(await readFile(configPath,'utf8'));for(const [k,v]of protectedProviders)assert(after.get(k)===v,'AI provider/model/key changed; protected values withheld');}
const report:any={status:'running',started_at:new Date().toISOString(),pid:live.pid,input:'public Harness synthetic events in existing production main window; not physical CUA',fields:audit.fields.map((f:any)=>({field:f.field,plan:f.plan??null,prior_status:f.status,prior_evidence:f.native_evidence,control_status:'not_run',consumer_status:'not_run',remaining: f.plan ? audit.plans[f.plan].evidence : []})),captures:[],limits:['Screenshots require root visual review. Config and reopened controls prove persistence only.','Protocol, OS notification, picker, log capacity/checkpoint/retention and AI execution require their real consumer evidence; no unit result is substituted.']};
async function flush(){await writeFile(join(output,'report.json'),JSON.stringify(report,null,2));}
type Node=QueryNode & {hidden?:boolean;effective_opacity?:number};
const shown=(n:Node)=>n.hidden!==true && n.visible!==false && (n.effective_opacity??1)>0 && n.rect.w>0 && n.rect.h>0;
async function unique(id:string):Promise<Node>{const nodes=(await query(id)).filter(shown);assert.equal(nodes.length,1,`Expected one visible ${id}, got ${nodes.length}`);return nodes[0];}
async function click(id:string){await unique(id);assert((await clickTestId(id)).ok,`Click failed: ${id}`);await sleep(100);}
async function press(k:string,mods?:{cmd?:boolean}){assert((await key(k,mods)).ok,`Key failed: ${k}`);}
async function edit(id:string,value:string,submit=true){await click(id);await press('a',{cmd:true});await press('backspace');if(value)assert((await type_(value)).ok);if(submit)await press('return');assert.equal((await inputState(id)).buffer,value,`Input mismatch ${id}`);}
async function waitValue(field:string,value:unknown){for(let i=0;i<30;i++){if(JSON.stringify((await readValues())[field])===JSON.stringify(value))return;await sleep(100);}throw new Error(`Persisted value mismatch: ${field}`);}
function safeTree(n:Node):Node {const hide=/api.?key|secret|password|token|seed/i.test(n.test_id??'');return {...n,text:hide?'[REDACTED]':n.text,children:n.children?.map(safeTree)};}
async function capture(name:string){await sleep(200);const path=join(output,`${name}.png`);assert((await screenshot(path)).ok,`Screenshot ${name}`);const full=await tree(); const observed=('error' in full) ? {full_tree_limit:(full as any).error,scoped:await Promise.all(['settings.search','settings.footer.state','settings.save',...(active?[control(active.field)]:[])].map(async id=>({id,nodes:(await query(id)).map(safeTree)})))} : safeTree(full); await writeFile(join(output,`${name}.tree.json`),JSON.stringify(observed,null,2));report.captures.push(path);await flush();}
async function openSettings(){if(!(await query('settings.close')).some(shown))await click('toolbar.settings');}
async function locate(field:string){await openSettings();const leaf=field.slice(field.lastIndexOf('.')+1);await edit('settings.search',field==='completion.enabled'?'completion':field==='ui.materials.background.enabled'?'background':leaf,false);const section=field.split('.')[0];const page=({ui:'appearance',completion:'appearance',ssh:'ssh',transfer:'transfer',ai:'ai',notify:'notifications',log:'data'} as Record<string,string>)[section];await click(`settings.nav.${page}`);await sleep(200);}
const appearanceToggles=new Set(['ui.sidebar_collapsed','ui.input_line_highlight','ui.timestamp_gutter','completion.enabled','ui.materials.background.enabled']);
const appearanceChoices=new Set(['ui.font_family','ui.font_weight','ui.cursor_style','ui.materials.background.fit']);
const selectValues:Record<string,string[]>={ 'ssh.term':['xterm-256color','xterm','vt100'], 'ssh.socks_bind':['127.0.0.1','0.0.0.0'], 'ai.permission_mode':['confirm','auto'], 'transfer.conflict_policy':['ask'], 'log.export_format':['txt_cast','txt','cast'] };
function control(field:string){const leaf=field.slice(field.lastIndexOf('.')+1);return `${appearanceToggles.has(field)?'settings.toggle.':'settings.field.'}${leaf}`;}
async function setValue(field:string,value:any,current:any){const leaf=field.slice(field.lastIndexOf('.')+1),id=control(field);
  if(typeof value==='boolean'){if(value!==current)await click(id);return;}
  if(appearanceChoices.has(field)){await click(id);await click(`settings.option.${leaf}.${value}`);return;}
  if(field==='ui.materials.background.alignment_x'||field==='ui.materials.background.alignment_y'){
    const saved=await readValues();const x=field.endsWith('_x')?value:saved['ui.materials.background.alignment_x'];const y=field.endsWith('_y')?value:saved['ui.materials.background.alignment_y'];
    const names=[['左上','上中','右上'],['左中','居中','右中'],['左下','下中','右下']];const xi=['left','center','right'].indexOf(x as string),yi=['top','center','bottom'].indexOf(y as string);assert(xi>=0&&yi>=0,'Unknown background alignment enum');await click('settings.field.alignment');await click(`settings.alignment.${names[yi][xi]}`);return;
  }
  if(selectValues[field]){const index=selectValues[field].indexOf(value);assert(index>=0,`Unsupported select restoration ${field}`);await click(id);await press('home');for(let i=0;i<index;i++)await press('down');await press('return');return;}
  assert(field!=='ai.default_provider','Provider stays unchanged; explicit same-value UI reselection needs root inspection');
  await edit(id,Array.isArray(value)?JSON.stringify(value):String(value));
}
function target(field:string,before:any):any{
  if(field in targets)return targets[field];
  if(typeof before==='boolean')return !before;
  if(appearanceChoices.has(field)){const opts:Record<string,string[]>={'ui.font_family':['Menlo','Monaco'],'ui.font_weight':['regular','bold'],'ui.cursor_style':['block','bar'],'ui.materials.background.fit':['fill','fit']};return opts[field].find(x=>x!==before);}
  if(selectValues[field])return selectValues[field].find(x=>x!==before)??before;
  if(field.endsWith('alignment_x'))return before==='left'?'right':'left';
  if(field.endsWith('alignment_y'))return before==='top'?'bottom':'top';
  const choices:Record<string,any>={'ssh.reconnect_backoff':[1,2,3,4,5],'notify.quiet_hours':'23:40-23:50','ui.font_size':18,'ui.line_height':1.8,'ssh.keepalive_sec':7,'ssh.connect_timeout_sec':9,'ssh.reconnect_max':3,'ssh.socks_port':18992,'transfer.window_chunks':4,'transfer.chunk_kb':16,'transfer.max_tasks':2,'transfer.shared_pacing_kbps':64,'log.ring_mb':8,'log.checkpoint_sec':2,'log.retention_days':3650};
  assert(field in choices,`No safe target ${field}`);const t=choices[field];if(JSON.stringify(t)!==JSON.stringify(before))return t;if(typeof t==='number')return t+1;if(field==='notify.quiet_hours')return '23:35-23:45';return [2,3,4,5,6];
}
async function settledClean(){for(let i=0;i<30;i++){if((await unique('settings.save')).focusable!==true)return;assert(i<29,'Save did not settle to disabled');await sleep(100);}}
async function save(field:string,value:any){await click('settings.save');await waitValue(field,value);await settledClean();await assertProvidersPreserved();}
let active:any=null;
try {
 await health();await openSettings();assert((await unique('settings.save')).focusable!==true,'Existing settings draft has enabled Save; root must resolve it before this run');assert(!['未保存','请修正设置中的错误','正在保存…'].includes((await unique('settings.footer.state')).text??''),'Existing settings draft is invalid or busy');await flush();
 // Sparse private configs legitimately omit defaults. Read one actual native Input and ask
 // the App's normal Save to serialize its effective config, then restore that input via UI.
 if(audit.fields.some((f:any)=>baseline[f.field]===undefined)){
  await locate('ui.font_size');const raw=(await inputState('settings.field.font_size')).buffer;const before=Number(raw);assert(Number.isInteger(before)&&before>=8&&before<=48,'Invalid effective font size');const temporary=before===18?19:18;
  const sparseBaseline={...baseline};report.initialization={kind:'native_input_save_materializes_omitted_defaults',field:'ui.font_size',before,target:temporary,status:'before'};await capture('initialization-before');
  await edit('settings.field.font_size',String(temporary));report.initialization.status='draft_changed';await capture('initialization-draft');await save('ui.font_size',temporary);report.initialization.status='temporary_saved';await capture('initialization-saved');
  await edit('settings.field.font_size',raw);await save('ui.font_size',before);report.initialization.status='original_value_restored';await capture('initialization-restored');baseline=await readValues();for(const [field,value]of Object.entries(sparseBaseline))assert.deepEqual(baseline[field],value,`Initialization changed original scalar ${field}`);assert(audit.fields.every((f:any)=>baseline[f.field]!==undefined),'App Save did not serialize all audited defaults');
 }

 for(const item of report.fields){
  const field=item.field;if(requested&&!requested.includes(field))continue;
  if(restored&&!restored.fields.some((x:any)=>x.field===field&&x.before!==undefined&&x.control_status==='saved_reopened_target_retained'))continue;
  if(!restored&&item.prior_status==='existing_native_basic_field_evidence'){item.control_status='reuse_prior_native';item.consumer_status='reuse_prior_native';continue;}
  const before=(await readValues())[field];assert(before!==undefined,`Missing persisted baseline ${field}`);item.before=before;
  if(!restored && (field==='ai.default_provider'||field==='transfer.conflict_policy'||field==='transfer.download_dir'||field==='ui.materials.background.path')){item.control_status='root_handoff';item.reason=field==='ai.default_provider'?'Preserve original provider/model/key; only same-value reselect allowed':field==='transfer.conflict_policy'?'Only ask is supported; root can inspect/reselect without claiming value transition':'Native picker requires root CUA';await flush();continue;}
  if(!restored&&field==='ui.materials.background.enabled'&&!baseline['ui.materials.background.path']){item.control_status='root_handoff';item.reason='No existing background path; use native picker first';continue;}
  if(!restored&&(field==='ssh.reconnect_max'||field==='ssh.reconnect_backoff'||field==='ssh.buffer_input')&&(!baseline['ssh.auto_reconnect']||(field!=='ssh.reconnect_max'&&Number(baseline['ssh.reconnect_max'])===0))){item.control_status='root_handoff';item.reason='Dependent reconnect control disabled in baseline; root must stage parent toggles explicitly';continue;}
  if(!restored&&appearanceChoices.has(field)&&field==='ui.font_family'&&!['Menlo','Monaco','JetBrains Mono'].includes(String(before))){item.control_status='root_handoff';item.reason='Custom original font requires custom-font UI restoration';continue;}
  if(!restored&&selectValues[field]&&!selectValues[field].includes(String(before))){item.control_status='root_handoff';item.reason='Original custom Select option needs explicit safe restoration';continue;}
  const beforeAll=await readValues();
  const desired=restored?restored.fields.find((x:any)=>x.field===field).before:target(field,before);item.target=desired;active=item;
  await locate(field);await capture(`${field}-before`);await setValue(field,desired,before);item.control_status='draft_changed';await capture(`${field}-draft`);await save(field,desired);const savedAll=await readValues();item.saved_value=savedAll[field];for(const [other,v] of Object.entries(beforeAll))if(other!==field)assert.deepEqual(savedAll[other],v,`Unrelated scalar changed: ${other}`);await capture(`${field}-saved`);
  await click('settings.close');await capture(`${field}-main-consumer-candidate`);
  item.consumer_status=['A','B','C'].includes(item.plan)?'main_window_captured_visual_review_required':'real_event_fixture_handoff_required';
  await locate(field);await unique(field.includes('alignment_')?'settings.field.alignment':control(field));
  if(typeof desired==='number'||Array.isArray(desired)||field==='notify.quiet_hours')assert.equal((await inputState(control(field))).buffer,Array.isArray(desired)?JSON.stringify(desired):String(desired),'Reopened raw control');
  await capture(`${field}-reopened`);item.control_status='saved_reopened_target_retained';await flush();
  if(!options['--keep-target']&&!restored){await setValue(field,before,desired);await save(field,before);item.restored_value=(await readValues())[field];item.control_status='saved_reopened_restored';await capture(`${field}-restored`);}
  if(restored)item.control_status='restore_saved';await click('settings.close');active=null;await flush();
 }
 report.status='control_run_complete_consumers_pending';
} catch(error){report.status='failed';report.error=String(error);if(active)active.failure=String(error);report.recovery='Stop. Inspect last screenshots and current draft. Do not rerun into a nonempty output directory. Restore recorded before values through Settings; never overwrite config.';await flush();throw error;}
finally{report.finished_at=new Date().toISOString();await flush();}
console.log(`${report.status}: ${join(output,'report.json')}`);
