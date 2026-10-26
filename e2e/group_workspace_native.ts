/** Public Harness, isolated real Local sessions. Root owns execution/native slot.
 * node e2e/group_workspace_native.ts --binary PATH --expected-sha SHA --out EMPTY_DIR
 * --prepare-only 1 writes a plan without starting an app.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, open, readFile, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { waitForServerReady, waitFor, query, clickAt, key, type_, screenshot, sleep, resizeWindow } from "../zig-out/share/zenit/harness/client.ts";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args: Record<string,string> = {};
for(let i=2;i<process.argv.length;i+=2) { assert(["--binary","--expected-sha","--out","--prepare-only"].includes(process.argv[i]) && process.argv[i+1]); args[process.argv[i]]=process.argv[i+1]; }
assert(args["--out"]);
const output=resolve(args["--out"]); await mkdir(output,{recursive:true}); assert.equal((await readdir(output)).length,0);
const report:any={status:"prepared_not_run",checks:[],screenshots:[],input:"Synthetic public Harness only",visual_status:"not_reviewed",limits:["Physical pointer, IME, window blur, VoiceOver require separate native acceptance","Runner cleanup SIGTERM is not normal application shutdown proof","Local mixed-group paths only; SSH reconnect/offline and AI impacts require their own fixtures"]};
const save=()=>writeFile(join(output,"report.json"),JSON.stringify(report,null,2));
if(args["--prepare-only"]==="1") { report.plan=["Create two real zsh services via native session menu","@grp each original session into same stable group","Verify two panes exactly once and preserve original standalone tabs","Switch existing members side/stack through member menu and verify 4pt geometry","Write different files from each focused real pane","Return standalone tab and group tab","Group close cancel causes zero session loss","Approve group then per-member Local impact confirmations and observe all tabs retire"]; await save(); process.exit(0); }
assert(args["--binary"] && /^[a-f0-9]{64}$/.test(args["--expected-sha"]??""));
const sourceBinary=resolve(args["--binary"]), binary=join(output,"zerowork-frozen"); await copyFile(sourceBinary,binary); await copyFile(join(dirname(sourceBinary),"zw_ipc.so"),join(output,"zw_ipc.so")); assert.equal(createHash("sha256").update(await readFile(binary)).digest("hex"),args["--expected-sha"]);
const isolated=await mkdtemp(join(tmpdir(),"zw-group-workspace-")), rpc=join(isolated,"rpc"),data=join(isolated,"data"); await Promise.all([mkdir(rpc),mkdir(data)]);
await writeFile(join(data,"config.toml"),'[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Menlo"\nfont_size = 14\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(output,"app.log"),"w");
const child=spawn(binary,[],{cwd:root,env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:"0",ZENIT_E2E_BACKGROUND:"1",ZENIT_E2E_ISOLATE_POINTER:"1",OPENAI_API_KEY:"",ANTHROPIC_API_KEY:""},stdio:["ignore",log.fd,log.fd]});
const ended=new Promise<void>(done=>child.once("close",()=>done()));
Object.assign(report,{status:"running",pid:child.pid,binary,sha256:args["--expected-sha"],isolated});
const shown=(n:any)=>n?.rect && !n.hidden && n.visible!==false && n.rect.w>0 && n.rect.h>0 && (n.effective_opacity??1)>0;
const flat=(n:any):any[]=>shown(n)?[n,...(n.children??[]).flatMap(flat)]:[];
const visible=async(id:string)=>waitFor(async()=> (await query(id)).find(shown)??null,15000);
const hidden=async(id:string)=>waitFor(async()=> !(await query(id)).some(shown)||null,15000);
const clickNode=async(n:any)=>{assert(shown(n));assert((await clickAt(n.rect.x+n.rect.w/2,n.rect.y+n.rect.h/2)).ok)};
const click=async(id:string)=>{report.last_action={kind:"click",test_id:id,at:new Date().toISOString()};await save();await clickNode(await visible(id))};
const press=async(name:string,mods?:any)=>{report.last_action={kind:"key",name:name==="enter"?"return":name,mods,at:new Date().toISOString()};await save();assert((await key(name==="enter"?"return":name,mods)).ok)};
const type=async(text:string)=>{report.last_action={kind:"type",text,at:new Date().toISOString()};await save();assert((await type_(text)).ok)};
const menuItem=async(label:string)=>{
 const menu=await visible("groups.member_menu");const n=flat(menu).find(n=>n.text===label);assert(n,`Missing member menu item ${label}`);await clickNode(n);
};
const tabs=async()=>{const strip=(await query("tabs.strip")).find(shown);return strip?flat(strip).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id??"")&&!flat(n).some(c=>c.test_id==="groups.close")):[]};
const panes=async()=>flat(await visible("groups.workspace")).filter(n=>/^groups\.pane\.\d+$/.test(n.test_id??""));
const capture=async(name:string)=>{await sleep(180);assert((await screenshot(join(output,`${name}.png`))).ok);const observed:any={};for(const id of ["tabs.strip","groups.workspace","groups.close.confirm","groups.close.partial","local.close.confirmation"])observed[id]=await query(id);await writeFile(join(output,`${name}.queries.json`),JSON.stringify(observed,null,2));report.screenshots.push(name);await save()};
const check=(name:string,detail:any)=>report.checks.push({name,status:"passed",detail});
async function joinTrustedGroup(label:string):Promise<void>{
 // Shell startup is async and user rc files may take seconds. A real shell
 // command, sent through the public terminal surface, establishes startup
 // completion; it does not set application/session state.
 await click("terminal.surface");await capture(`before-${label}-shell-readiness`);
 const readyFile=join(isolated,`shell-ready-${label}.txt`);
 await type(`printf 'ready-${label}' > ${JSON.stringify(readyFile)}`);await press("return");
 await waitFor(async()=>{try{return await readFile(readyFile,"utf8")===`ready-${label}`||null}catch{return null}},30000);
 // Only the production @ popup proves the trusted ZLE lease is usable. If @
 // raced the next prompt snapshot, cancel that unsubmitted shell draft and
 // retry; never send an untrusted @grp line to the shell.
 let ready=false;
 for(let attempt=1;attempt<=3;attempt++){
   await capture(`before-${label}-trusted-at-${attempt}`);await type("@");
   try{await waitFor(async()=>(await query("terminal.commands")).some(shown)||null,4000);ready=true;break}
   catch(error){report.readiness_attempt={label,attempt,result:"trusted-popup-unavailable"};await save();await press("c",{ctrl:true});await sleep(300)}
 }
 assert(ready,`Real shell ${label} started, but production trusted @ editor never became available`);
 await capture(`${label}-trusted-editor-ready`);await type("grp Acceptance");
 // Public production palette flow: Right explicitly adopts the selected @grp
 // including its arguments into the local editor. The next user Return then
 // requests trusted End and executes only after its real acknowledgement.
 await press("right");await hidden("terminal.commands");await capture(`${label}-group-command-adopted`);await press("return");
}

try {
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,"owner.json"),"utf8")).pid),child.pid);
 await resizeWindow(1440,900);await click("workspace.empty.local");await visible("terminal.surface");
 const firstTab=(await tabs())[0].test_id;
 await joinTrustedGroup("first");await visible("groups.workspace");await visible("groups.waiting");
 const firstPane=(await panes())[0].test_id; assert.equal((await panes()).length,1);await capture("01-single-member-real-pane");
 await click("toolbar.new_session");await click("session.menu.local");await visible("terminal.surface");
 const secondTab=(await tabs()).find(n=>n.test_id!==firstTab).test_id;
 await joinTrustedGroup("second");await waitFor(async()=>(await panes()).length===2||null,15000);
 const ids=(await panes()).map(n=>n.test_id);assert(ids.includes(firstPane));assert.equal(new Set(ids).size,2);assert.equal((await tabs()).length,2);check("two actual sessions plus one group tab",{sessionTabs:[firstTab,secondTab],panes:ids});
 const firstId=firstPane.split(".").at(-1)!, secondId=ids.find(id=>id!==firstPane)!.split(".").at(-1)!;
 let pp=await panes();assert(Math.abs(pp[0].rect.y-pp[1].rect.y)<1);assert(Math.abs(pp[1].rect.x-pp[0].rect.x-pp[0].rect.w-4)<=1);await capture("02-side-by-side");
 await click(`groups.menu.${firstId}`);await menuItem("切换上下布局");await sleep(200);pp=await panes();assert(Math.abs(pp[0].rect.x-pp[1].rect.x)<1);assert(Math.abs(pp[1].rect.y-pp[0].rect.y-pp[0].rect.h-4)<=1);await capture("03-stacked");
 for(const [sessionId,marker] of [[firstId,"first"],[secondId,"second"]]) {
   const pane=await visible(`groups.pane.${sessionId}`);const terminal=flat(pane).find(n=>n.test_id==="terminal.input"&&shown(n));await clickNode(terminal);
   const path=join(isolated,`${marker}.txt`);await type(`printf '${marker}' > ${JSON.stringify(path)}`);await press("enter");await waitFor(async()=>{try{return await readFile(path,"utf8")===marker||null}catch{return null}},10000);
 }
 check("each focused pane writes through its own real zsh service",{first:firstId,second:secondId});
 await click(firstTab);await hidden("groups.workspace");await click("groups.tab");await visible("groups.workspace");check("standalone and group remain independent presentation owners",{});
 await click("groups.close");await visible("groups.close.confirm");await capture("04-group-close-confirm");await click("groups.close.cancel");await hidden("groups.close.confirm");assert.equal((await tabs()).length,2);assert.equal((await panes()).length,2);check("group-close cancel preserves both sessions",{});
 await click("groups.close");await visible("groups.close.confirm");await click("groups.close.accept");
 let memberConfirmations=0;
 await waitFor(async()=>{
   if((await query("local.close.confirmation")).some(shown)){await click("local.close.accept");memberConfirmations++;return null}
   return (await tabs()).length===0||null;
 },20000);
 report.member_impact_confirmations=memberConfirmations;
 // Idle shells may have no extra dangerous impact; the mandatory group
 // approval already occurred. Only actual coordinator confirmations are accepted.
 await waitFor(async()=>(await tabs()).length===0||null,15000);await hidden("groups.workspace");check("approved group closes each real member via V0.1.1 coordinator",{});await capture("05-all-local-members-released");
 report.status="passed";
} catch(error) { report.status="failed";report.error=String(error);await capture("failed").catch(()=>{});process.exitCode=1 }
finally {await save();if(child.exitCode===null)child.kill("SIGTERM");await Promise.race([ended,sleep(3000)]);await log.close()}
