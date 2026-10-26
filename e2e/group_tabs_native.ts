/** Public Harness, isolated real Local sessions. Root owns execution/native slot.
 * node e2e/group_tabs_native.ts --binary PATH --expected-sha SHA --out EMPTY_DIR
 * --prepare-only 1 writes a plan without starting an app.
 */
import assert from "node:assert/strict";
import { cleanupOwnedBridgeDirectories } from './native_owned_cleanup.ts';
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, open, readFile, readdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { waitForServerReady, waitFor, query, clickAt, key, type_, screenshot, sleep, resizeWindow, mouseDown, mouseMove, mouseUp } from "../zig-out/share/zenit/harness/client.ts";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args: Record<string,string> = {};
for(let i=2;i<process.argv.length;i+=2) { assert(["--binary","--expected-sha","--out","--prepare-only","--geometry-only"].includes(process.argv[i]) && process.argv[i+1]); args[process.argv[i]]=process.argv[i+1]; }
assert(args["--out"]);
const output=resolve(args["--out"]); await mkdir(output,{recursive:true}); assert.equal((await readdir(output)).length,0);
const report:any={status:"prepared_not_run",checks:[],screenshots:[],input:"Synthetic public Harness only",visual_status:"not_reviewed",limits:["Public Harness synthetic input; physical pointer/IME/VoiceOver not verified", "Window blur rollback is covered in focused Cx unit test; native window blur not driven","Runner cleanup SIGTERM is not normal application shutdown proof","Local mixed-group paths only; SSH reconnect/offline and AI impacts require their own fixtures"]};
const save=()=>writeFile(join(output,"report.json"),JSON.stringify(report,null,2));
if(args["--prepare-only"]==="1") { report.plan=["Create real Local and join group through trusted @grp", "Create another independent Local and verify unified mixed tab order", "Keyboard ordinal, previous/next and MRU include group", "Mixed drag Escape rollback and commit preserve real source shell PID", "Create twelve real presentation entries and verify overflow ordinals stay absolute", "Picker filters and activates the real group owner; no-match Enter and Escape preserve active group"]; await save(); process.exit(0); }
assert(args["--binary"] && /^[a-f0-9]{64}$/.test(args["--expected-sha"]??""));
const sourceBinary=resolve(args["--binary"]), binary=join(output,"zerowork-frozen"); await copyFile(sourceBinary,binary); await copyFile(join(dirname(sourceBinary),"zw_ipc.so"),join(output,"zw_ipc.so")); assert.equal(createHash("sha256").update(await readFile(binary)).digest("hex"),args["--expected-sha"]);
const isolated=await mkdtemp(join("/private/tmp","zw-group-tabs-")), rpc=join(isolated,"rpc"),data=join(isolated,"data"); await Promise.all([mkdir(rpc),mkdir(data)]);
const shellConfig=join(isolated,"shell-config");await mkdir(shellConfig);await writeFile(join(shellConfig,".zshrc"),"bindkey -e\nPS1='ZeroWork-acceptance%# '\n");
await writeFile(join(data,"config.toml"),'[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Menlo"\nfont_size = 14\n');
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(output,"app.log"),"w");
const child=spawn(binary,[],{cwd:root,env:{...process.env,ZDOTDIR:shellConfig,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:"0",ZENIT_E2E_BACKGROUND:"1",ZENIT_E2E_ISOLATE_POINTER:"1",OPENAI_API_KEY:"",ANTHROPIC_API_KEY:""},stdio:["ignore",log.fd,log.fd]});
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
const panes=async()=>flat(await visible("groups.workspace")).filter(n=>/^groups\.pane\.\d+$/.test(n.test_id??""));
const capture=async(name:string)=>{await sleep(180);assert((await screenshot(join(output,`${name}.png`))).ok);const observed:any={};for(const id of ["tabs.strip","tabs.viewport","tabs.picker","tabs.all","workspace.titlebar","groups.workspace"])observed[id]=await query(id);await writeFile(join(output,`${name}.queries.json`),JSON.stringify(observed,null,2));report.screenshots.push(name);await save()};
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

const allTabs=async()=>{const strip=(await query("tabs.strip"))[0];const visit=(n:any):any[]=>[n,...(n.children??[]).flatMap(visit)];return strip?visit(strip).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id??"")):[]};
const activeTab=async()=> (await allTabs()).find(n=>n.a11y?.selected||n.selected||n.accessibility?.selected);
const tabOrder=async()=> (await allTabs()).map(n=>n.test_id);
const label=(n:any)=>flat(n).filter(n=>n.text).map(n=>n.text).join(" ");
async function newLocal(){await click("toolbar.new_session");await click("session.menu.local");await sleep(150);}
async function dragTo(source:any,target:any,cancel=false){await mouseDown(source.rect.x+source.rect.w/2,source.rect.y+15);await mouseMove(target.rect.x+8,target.rect.y+15);await sleep(120);if(cancel)await press("escape");await mouseUp(target.rect.x+8,target.rect.y+15);await sleep(120);}
try {
 await waitForServerReady();assert.equal(Number(JSON.parse(await readFile(join(rpc,"owner.json"),"utf8")).pid),child.pid);
 await resizeWindow(1440,900);await click("workspace.empty.local");await visible("terminal.surface");
 const firstTab=(await tabs())[0].test_id;
 await joinTrustedGroup("source");await visible("groups.workspace");
 const groupTab=(await allTabs()).find(n=>n.test_id!==firstTab);assert(groupTab);report.groupTab=groupTab.test_id;
 await newLocal();await sleep(1000);const lastTab=(await allTabs()).at(-1).test_id;
 if(args["--geometry-only"]==="1") {
   for(let i=0;i<9;i++)await newLocal();await visible("tabs.all");
   for(const width of [1440,860]) {
     await resizeWindow(width,width===1440?900:480);await sleep(200);
     await click("tabs.all");await visible("tabs.picker");await type("Acceptance");await sleep(150);
     const picker=await visible("tabs.picker"), trigger=await visible("tabs.all"), titlebar=await visible("workspace.titlebar");
     assert(Math.abs(picker.rect.x-(width-14-420))<0.01,JSON.stringify({width,picker:picker.rect,trigger:trigger.rect}));
     assert(Math.abs(picker.rect.y-62)<0.01,JSON.stringify({width,picker:picker.rect,titlebar:titlebar.rect}));
     assert.equal(picker.rect.w,420);assert.equal(picker.rect.h,270);
     const rows=(await query("tabs.picker.row")).filter(shown);assert.equal(rows.length,1);assert(label(rows[0]).includes("Acceptance"));
     await capture(`geometry-${width}-picker`);
     await press("return");await visible("groups.workspace");await hidden("tabs.picker");
     check(`picker geometry and real group selection at ${width}`,{width,picker:picker.rect,trigger:trigger.rect,titlebar:titlebar.rect,groupTab:groupTab.test_id});
   }
 } else {
 let order=await tabOrder();assert.deepEqual(order,[firstTab,groupTab.test_id,lastTab]);check("group installed between ordinary tabs in a single presentation order",order);
 await press("2",{cmd:true});await visible("groups.workspace");check("Command-2 activates actual second group owner",{});
 await press("]",{cmd:true,shift:true});await hidden("groups.workspace");
 await press("[",{cmd:true,shift:true});await visible("groups.workspace");check("previous and next include group",{});
 await press("tab",{ctrl:true});await hidden("groups.workspace");await press("tab",{ctrl:true});await sleep(100);check("MRU moves through mixed stable tab identities",{});await press("modifiers_released");
 await press("2",{cmd:true});await visible("groups.workspace");await press("modifiers_released");
 async function recordGroupSourcePid(label:string){const pane=(await panes())[0];assert(pane);const input=flat(pane).find(n=>n.test_id==="terminal.input");assert(input);await clickNode(input);const path=join(isolated,`source-pid-${label}.txt`);await type(`printf '%s' "$$" > ${JSON.stringify(path)}`);await press("return");return await waitFor(async()=>{try{const value=await readFile(path,"utf8");return /^\d+$/.test(value)?value:null}catch{return null}},10000);}
 const originalSourcePid=await recordGroupSourcePid("before");await capture("01-mixed-group-tabs");
 const before=await tabOrder();await dragTo((await allTabs())[1],(await allTabs())[0],true);assert.deepEqual(await tabOrder(),before);check("Esc cancels mixed tab drag and restores exact order",before);
 await dragTo((await allTabs())[1],(await allTabs())[0]);assert.deepEqual(await tabOrder(),[groupTab.test_id,firstTab,lastTab]);check("group drag crosses ordinary tab without changing session owner",await tabOrder());
 await press("1",{cmd:true});await visible("groups.workspace");await capture("02-command-slot-group-first");await press("modifiers_released");
 assert.equal(await recordGroupSourcePid("after"),originalSourcePid);check("mixed drag preserves the original real group source shell PID",originalSourcePid);
 // Real Local services create overflow. No internal group/tab state is injected.
 for(let i=0;i<9;i++)await newLocal();await visible("tabs.all");await resizeWindow(860,480);await sleep(200);
 const overflowOrder=await tabOrder();assert.equal(overflowOrder.length,12);await press("9",{cmd:true});
 const nine=await allTabs();for(let i=0;i<nine.length;i++){const ordinal=flat(nine[i]).find(n=>n.test_id==="tabs.ordinal");if(ordinal)assert.equal(ordinal.text,String(i+1));if(i>=9)assert(!ordinal,"ordinals after 9 stay hidden even when scrolled into view");}
 await capture("03-overflow-command-absolute-slots");await press("modifiers_released");
 await click("tabs.all");await visible("tabs.picker");await click("tabs.picker.query");await type("Acceptance");await sleep(150);
 const rows=(await query("tabs.picker.row")).filter(shown);assert.equal(rows.length,1);assert(label(rows[0]).includes("Acceptance"));await capture("04-picker-real-group-result");await press("return");await visible("groups.workspace");await hidden("tabs.picker");
 assert.equal((await allTabs())[0].test_id,groupTab.test_id);check("picker resolves group TabId and restores real group workspace",{order:await tabOrder()});
 await click("tabs.all");await type("not-found-unique");await visible("tabs.picker.empty");await press("return");await visible("groups.workspace");await visible("tabs.picker.empty");await press("escape");await hidden("tabs.picker");check("empty picker Enter and Escape preserve group active identity",{});
 await capture("05-group-restored-after-picker"); }
 report.status="passed";
} catch(error){report.status="failed";report.error=String(error?.stack??error);await capture("failure").catch(()=>{});process.exitCode=1;}
finally {
 const processes=execFileSync('/bin/ps',['-axo','pid=,ppid='],{encoding:'utf8'}).trim().split('\n').map(line=>line.trim().split(/\s+/).map(Number));const owned=new Set([child.pid]);for(let pass=0;pass<processes.length;pass++){let changed=false;for(const [pid,parent] of processes)if(owned.has(parent)&&!owned.has(pid)){owned.add(pid);changed=true}if(!changed)break}
 if(child.exitCode===null&&child.signalCode===null){child.kill("SIGTERM");await Promise.race([ended,sleep(3000)]);if(child.exitCode===null&&child.signalCode===null){child.kill('SIGKILL');await ended}}
 for(const pid of [...owned].filter(pid=>pid!==child.pid).reverse()){try{process.kill(pid!,'SIGHUP')}catch{}}
 await waitFor(async()=>[...owned].every(pid=>{try{process.kill(pid!,0);return false}catch{return true}})||null,5000);
 const bridges=await cleanupOwnedBridgeDirectories(child.pid!);
 await rm(isolated,{recursive:true,force:true});report.cleanup={app_exited:child.exitCode!==null||child.signalCode!==null,owned_descendants_exited:true,isolated_removed:true,private_bridge_directories_removed:bridges,shutdown_kind:'runner_cleanup'};await save();await log.close();
}
