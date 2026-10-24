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
import { waitForServerReady, waitFor, query, clickAt, key, type_, screenshot, sleep, resizeWindow, screenPos } from "../zig-out/share/zenit/harness/client.ts";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args: Record<string,string> = {};
for(let i=2;i<process.argv.length;i+=2) { assert(["--binary","--expected-sha","--out","--prepare-only"].includes(process.argv[i]) && process.argv[i+1]); args[process.argv[i]]=process.argv[i+1]; }
assert(args["--out"]);
const output=resolve(args["--out"]); await mkdir(output,{recursive:true}); assert.equal((await readdir(output)).length,0);
const report:any={status:"prepared_not_run",checks:[],screenshots:[],input:"Synthetic public Harness only",visual_status:"not_reviewed",limits:["Physical pointer, IME, window blur, VoiceOver require separate native acceptance","Runner cleanup SIGTERM is not normal application shutdown proof","Local mixed-group paths only; SSH reconnect/offline and AI impacts require their own fixtures"]};
const save=()=>writeFile(join(output,"report.json"),JSON.stringify(report,null,2));
if(args["--prepare-only"]==="1") { report.plan=["Create real source and receiver Local PTYs, record distinct shell PIDs, join same group", "Submit trusted @sync on and verify approval card; Escape causes no fanout", "Approve exact source/receiver and append shell PID to a shared file: exactly one row per approved shell", "Join a third real Local PTY and prove its PID never receives old approval", "@sync off must stop fanout without closing any terminal"]; await save(); process.exit(0); }
assert(args["--binary"] && /^[a-f0-9]{64}$/.test(args["--expected-sha"]??""));
const sourceBinary=resolve(args["--binary"]), binary=join(output,"zerowork-frozen"); await copyFile(sourceBinary,binary); await copyFile(join(dirname(sourceBinary),"zw_ipc.so"),join(output,"zw_ipc.so")); assert.equal(createHash("sha256").update(await readFile(binary)).digest("hex"),args["--expected-sha"]);
const isolated=await mkdtemp(join(tmpdir(),"zw-group-broadcast-")), rpc=join(isolated,"rpc"),data=join(isolated,"data"); await Promise.all([mkdir(rpc),mkdir(data)]);
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
const tabs=async()=>{const strip=(await query("tabs.strip")).find(shown);return strip?flat(strip).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id??"")):[]};
const panes=async()=>{
 const result:any[]=[];
 for(const tab of await tabs()) { const id=tab.test_id.split(".").at(-1); const rect=await screenPos(`groups.pane.${id}`);if(rect.w>0&&rect.h>0)result.push({test_id:`groups.pane.${id}`,rect}); }
 return result;
};
const capture=async(name:string)=>{await sleep(180);assert((await screenshot(join(output,`${name}.png`))).ok);const observed:any={};for(const id of ["tabs.strip","groups.workspace","groups.close.confirm","groups.close.partial","local.close.confirmation"])observed[id]=await query(id);await writeFile(join(output,`${name}.queries.json`),JSON.stringify(observed,null,2));report.screenshots.push(name);await save()};
const check=(name:string,detail:any)=>report.checks.push({name,status:"passed",detail});
async function joinTrustedGroup(label:string):Promise<void>{
 // Shell startup is async and user rc files may take seconds. A real shell
 // command, sent through the public terminal surface, establishes startup
 // completion; it does not set application/session state.
 await sleep(1600);await capture(`before-${label}-shell-readiness`);
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

async function trustedCommand(command:string):Promise<void>{
 let opened=false;
 for(let attempt=0;attempt<3;attempt++){
   await type("@");try{await waitFor(async()=>(await query("terminal.commands")).some(shown)||null,4000);opened=true;break}
   catch{await press("c",{ctrl:true});await sleep(300)}
 }
 assert(opened,"trusted command palette must be available");
 await type(command);await press("right");await hidden("terminal.commands");await press("return");
}
async function focusPane(id:string):Promise<void>{
 const rect=await screenPos(`groups.pane.${id}`);assert(rect.w>0&&rect.h>0);assert((await clickAt(rect.x+rect.w/2,rect.y+Math.max(70,rect.h/2))).ok);
}
const fileValue=async(path:string)=>{try{return await readFile(path,"utf8")}catch{return ""}};
async function recordPid(id:string,label:string):Promise<string>{
 await focusPane(id);const path=join(isolated,`pid-${label}.txt`);await type(`printf '%s' "$$" > ${JSON.stringify(path)}`);await press("return");
 return await waitFor(async()=>{const value=await fileValue(path);return /^\d+$/.test(value)?value:null},10000);
}
async function sendMarker(source:string,label:string,expected:string[]):Promise<void>{
 const path=join(isolated,`broadcast-${label}.txt`);await focusPane(source);await type(`printf '%s\\n' "$$" >> ${JSON.stringify(path)}`);await press("return");
 await waitFor(async()=>{const lines=(await fileValue(path)).trim().split("\n").filter(Boolean);return lines.length>=expected.length?lines:null},10000);
 await sleep(350);const lines=(await fileValue(path)).trim().split("\n").filter(Boolean);
 assert.deepEqual(lines.sort(),[...expected].sort(),`${label}: exactly once per approved real shell; no source double-send or unapproved target`);
 report.checks.push({name:label,status:"passed",pids:lines});await save();
}
try {
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,"owner.json"),"utf8")).pid),child.pid);await resizeWindow(1440,900);
 await click("workspace.empty.local");await visible("terminal.surface");await joinTrustedGroup("source");await visible("groups.waiting");
 const source=(await panes())[0].test_id.split(".").at(-1)!;
 await click("toolbar.new_session");await click("session.menu.local");await joinTrustedGroup("receiver");
 await waitFor(async()=>(await panes()).length===2||null,15000);
 const receiver=(await panes()).find(n=>n.test_id!==`groups.pane.${source}`)!.test_id.split(".").at(-1)!;
 const sourcePid=await recordPid(source,"source"),receiverPid=await recordPid(receiver,"receiver");assert.notEqual(sourcePid,receiverPid);
 await focusPane(source);await trustedCommand("sync on");await visible("group.broadcast.card");await capture("01-unapproved");
 await press("escape");await hidden("group.broadcast.card");await sendMarker(source,"cancel-is-zero-fanout",[sourcePid]);
 await trustedCommand("sync on");await visible("group.broadcast.card");await click("group.broadcast.accept");
 await waitFor(async()=>flat(await visible("group.broadcast.card")).some(n=>n.text==="停止广播")||null,8000);await capture("02-approved");
 await press("escape");await hidden("group.broadcast.card");await sendMarker(source,"approved-source-and-receiver-once",[sourcePid,receiverPid]);
 await click("toolbar.new_session");await click("session.menu.local");await joinTrustedGroup("unapproved-third");
 await waitFor(async()=>(await panes()).length===3||null,15000);
 const third=(await panes()).find(n=>![`groups.pane.${source}`,`groups.pane.${receiver}`].includes(n.test_id))!.test_id.split(".").at(-1)!;
 const thirdPid=await recordPid(third,"third");assert(![sourcePid,receiverPid].includes(thirdPid));
 await sendMarker(source,"new-member-excluded-from-old-approval",[sourcePid,receiverPid]);await capture("03-third-excluded");
 await trustedCommand("sync off");await sendMarker(source,"explicit-off-stops-fanout",[sourcePid]);
 report.status="passed";
 report.limits.push("Real target-generation reconnect and zero-target running detail are covered by controller contract tests; this Local runner proves actual IO for approval/cancel/off/new-member exclusion only.");
} catch(error) { report.status="failed";report.error=String(error);await capture("failed").catch(()=>{});process.exitCode=1 }
finally {await save();if(child.exitCode===null)child.kill("SIGTERM");await Promise.race([ended,sleep(3000)]);await log.close()}
