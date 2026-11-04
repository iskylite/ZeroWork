/** Public Harness, isolated real Local sessions. Root owns execution/native slot.
 * node e2e/session_group_controls_native.ts --binary PATH --expected-sha SHA --out EMPTY_DIR
 * --prepare-only 1 writes a plan without starting an app.
 */
import assert from "node:assert/strict";
import net from "node:net";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, realpath, open, readFile, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { waitForServerReady, waitFor, query, clickAt, key, type_, screenshot, sleep, resizeWindow, screenPos, scrollAt, mouseDown, mouseMove, mouseUp } from "../zig-out/share/zenit/harness/client.ts";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args: Record<string,string> = {};
for(let i=2;i<process.argv.length;i+=2) { assert(["--binary","--expected-sha","--out","--prepare-only","--theme","--pointer-handoff"].includes(process.argv[i]) && process.argv[i+1]); args[process.argv[i]]=process.argv[i+1]; }
assert(args["--out"]);
const output=resolve(args["--out"]); await mkdir(output,{recursive:true}); assert.equal((await readdir(output)).length,0);
const report:any={theme:args["--theme"]??"dark",status:"prepared_not_run",checks:[],screenshots:[],input:"Synthetic public Harness only",visual_status:"not_reviewed",limits:["Physical pointer is verified only with --pointer-handoff 1; IME and VoiceOver require separate acceptance","Runner cleanup SIGTERM is not normal application shutdown proof","Local mixed-group paths only; SSH reconnect/offline and AI impacts require their own fixtures"]};
const save=()=>writeFile(join(output,"report.json"),JSON.stringify(report,null,2));
if(args["--prepare-only"]==="1") { report.plan=["Scroll the real builtin candidate popup", "Reorder three Local tabs, cancel drag, center-drop to create/join a group", "Toggle each member independently and verify real shell PID fanout from multiple sources", "Deselect current source, batch off/on, resize popup", "Use @new --pick and an exact host name inside the source group"]; await save(); process.exit(0); }
assert(args["--binary"] && /^[a-f0-9]{64}$/.test(args["--expected-sha"]??""));
const sourceBinary=resolve(args["--binary"]);
const pointer=args["--pointer-handoff"]==="1",bundle=join(output,"ZeroWork Controls Review.app"),mac=join(bundle,"Contents/MacOS");
if(pointer){await mkdir(mac,{recursive:true});await writeFile(join(bundle,"Contents/Info.plist"),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.zerowork.controls.${process.pid}</string><key>CFBundleExecutable</key><string>ControlsReview</string><key>CFBundleName</key><string>ZeroWork Controls Review</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);}
const binary=pointer?join(mac,"ControlsReview"):join(output,"zerowork-frozen");
if(pointer)report.input="Public Harness plus CUA physical drag and context-menu handoffs"; await copyFile(sourceBinary,binary); await copyFile(join(dirname(sourceBinary),"zw_ipc.so"),join(dirname(binary),"zw_ipc.so")); assert.equal(createHash("sha256").update(await readFile(binary)).digest("hex"),args["--expected-sha"]);
assert(["dark","light"].includes(args["--theme"]??"dark"));
const isolated=await realpath(await mkdtemp(join(process.env.ZW_BROADCAST_DEFAULT_SHELL?tmpdir():"/private/tmp","zw-group-broadcast-"))), rpc=join(isolated,"rpc"),data=join(isolated,"data"); await Promise.all([mkdir(rpc),mkdir(data)]);
await writeFile(join(data,"config.toml"),`[meta]\nconfig_revision = 1\n[ui]\ntheme = "${args["--theme"]??"dark"}"\nfont_family = "Menlo"\nfont_size = 14\n`);
const reservation=net.createServer();await new Promise<void>(r=>reservation.listen(0,"127.0.0.1",r));const refusedPort=(reservation.address() as net.AddressInfo).port;await new Promise<void>(r=>reservation.close(()=>r()));
await writeFile(join(data,"hosts.toml"),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\nname="Owned unavailable SSH"\nhost="127.0.0.1"\nport=${refusedPort}\nuser="fixture"\n`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const shellConfig=join(isolated,"shell-config");await mkdir(shellConfig);await writeFile(join(shellConfig,".zshrc"),"bindkey -e\nPS1='ZeroWork-broadcast%# '\n");
const log=await open(join(output,"app.log"),"w");
if(pointer)execFileSync("/usr/bin/codesign",["--force","--sign","-",bundle]);
const child=spawn(binary,[],{cwd:root,env:{...process.env,...(process.env.ZW_BROADCAST_DEFAULT_SHELL?{}:{ZDOTDIR:shellConfig}),ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:"0",ZENIT_E2E_BACKGROUND:pointer?"0":"1",ZENIT_E2E_ISOLATE_POINTER:pointer?"0":"1",OPENAI_API_KEY:"",ANTHROPIC_API_KEY:""},stdio:["ignore",log.fd,log.fd]});
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
const tabs=async()=>{const strip=(await query("tabs.strip")).find(shown);return strip?flat(strip).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id??"")):[]};
const panes=async()=>{const group=(await query("groups.workspace")).find(shown);return group?flat(group).filter(n=>/^groups\.pane\.\d+$/.test(n.test_id??"")):[]};
const capture=async(name:string)=>{await sleep(180);assert((await screenshot(join(output,`${name}.png`))).ok);const observed:any={};for(const id of ["tabs.strip","groups.workspace","groups.close.confirm","groups.close.partial","local.close.confirmation","group.broadcast.card","group.broadcast.footer","status.group.broadcast"])observed[id]=await query(id);await writeFile(join(output,`${name}.queries.json`),JSON.stringify(observed,null,2));report.screenshots.push(name);await save()};
const check=(name:string,detail:any)=>report.checks.push({name,status:"passed",detail});
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
 const path=join(isolated,`broadcast-${label}.txt`);await focusPane(source);await type(`printf '%s\\n' "$$" >> ${JSON.stringify(path)}`);await sleep(180);await press("return");
 await waitFor(async()=>{const lines=(await fileValue(path)).trim().split("\n").filter(Boolean);return lines.length>=expected.length?lines:null},10000);
 await sleep(350);const lines=(await fileValue(path)).trim().split("\n").filter(Boolean);
 assert.deepEqual(lines.sort(),[...expected].sort(),`${label}: exactly once per approved real shell; no source double-send or unapproved target`);
 report.checks.push({name:label,status:"passed",pids:lines});await save();
}

async function broadcastUi(ids:string[],selected:string[],label:string){
 const expected=new Set(selected);
 const footer=await waitFor(async()=>{const n=await visible("status.group.broadcast");const text=flat(n).map(x=>x.text??"").join("");return text===(selected.length?`广播 · ${selected.length}`:"广播")?n:null},8000);
 const already=(await query("group.broadcast.card")).some(shown);
 if(!already)await click("status.group.broadcast");
 await waitFor(async()=>{const summary=await visible("group.broadcast.summary");return flat(summary).some(n=>n.text?.includes(`${selected.length} 个参与会话`))||null},8000);
 for(const id of ids){
  const row=await visible(`group.broadcast.member.${id}`);
  const text=flat(row).map(n=>n.text??"").filter(Boolean).at(-1);
  assert(expected.has(id)?text==="参与"||text==="当前 · 参与":text==="未参与"||text==="当前 · 未参与",`${label}: member ${id} state ${text}`);
  const check=await visible(`group.broadcast.member.${id}.select`);
  const glyph=check.children?.[0]?.children?.[0];assert(glyph,`${label}: checkbox glyph`);
  assert.equal(shown(glyph),expected.has(id),`${label}: checkbox ${id} mirrors state`);
 }
 const action=flat(await visible("group.broadcast.accept")).map(n=>n.text??"").join("");
 assert.equal(action,selected.length?"全部关闭":"全部开启",`${label}: batch action matches actual state`);
 if(!already){await press("escape");await hidden("group.broadcast.card")}
 check(label+"-surfaces",{selected,footer:flat(footer).map(n=>n.text??"").join("")});
}
async function pointerHandoff(stage:string,details:any){
 if(!pointer)return;
 const marker=join(output,stage+".done");
 await writeFile(join(output,"handoff.json"),JSON.stringify({stage,bundle,pid:child.pid,marker,...details},null,2));
 console.log("CUA "+stage);
 await waitFor(async()=>{try{return (await readFile(marker,"utf8"))==="done"||null}catch{return null}},300000);
}
async function dragTab(source:string,target:string,edge=false,cancel=false){
 const a=await visible(source),b=await visible(target);
 const x=a.rect.x+a.rect.w/2,y=a.rect.y+a.rect.h/2;
 const tx=edge?b.rect.x+b.rect.w-2:b.rect.x+b.rect.w/2,ty=b.rect.y+b.rect.h/2;
 assert((await mouseDown(x,y)).ok);
 for(let i=1;i<=8;i++){assert((await mouseMove(x+(tx-x)*i/8,y+(ty-y)*i/8)).ok);await sleep(35)}
 if(cancel)await press("escape");
 assert((await mouseUp(tx,ty)).ok);await sleep(350);
}
async function newLocal(){await click("toolbar.new_session");await click("session.menu.local");await visible("terminal.surface");await sleep(1800)}
try {
 await waitForServerReady();await resizeWindow(1440,900);
 await click("workspace.empty.local");await visible("terminal.surface");await sleep(1800);
 // Real native candidate popup: wheel can reach the last command without
 // forwarding the event to the shell viewport.
 await type("@");await visible("terminal.commands.rows");
 const candidates=await visible("terminal.commands.rows");
 await scrollAt(candidates.rect.x+30,candidates.rect.y+candidates.rect.h/2,0,-200);
 await capture("00-command-candidates-scrolled");
 const commands=await visible("terminal.commands");
 await writeFile(join(output,"candidate-scroll.json"),JSON.stringify(commands,null,2));
 await press("escape");await press("c",{ctrl:true});
 await newLocal();await newLocal();
 let initial=await tabs();assert.equal(initial.length,3);
 let order=initial.map(n=>n.test_id);
 if(pointer){await capture("00-before-physical-drag");await pointerHandoff("physical-tab-reorder",{tabs:initial});
 const after=(await tabs()).map(n=>n.test_id);assert.notDeepEqual(after,order,"physical AppKit drag reorders tabs");order=after;check("physical-tab-drag-retains-window",{});}

 await dragTab(order[0],order[2],true,true);
 assert.deepEqual((await tabs()).map(n=>n.test_id),order,"Escape preserves tab order");
 await dragTab(order[0],order[2],true);
 const reordered=(await tabs()).map(n=>n.test_id);assert.notDeepEqual(reordered,order,"tab edge reorders");
 check("tab-edge-reorder-and-Escape",{order,reordered});
 await dragTab(order[1],order[0]);
 await waitFor(async()=>(await panes()).length===2||null,15000);
 assert.equal((await tabs()).length,2,"two sessions become one group tab");
 let groupTab=(await tabs()).find(n=>n.children?.some((c:any)=>c.test_id==="tabs.group_marker"));
 if(!groupTab)groupTab=(await tabs()).find(n=>n.test_id!==order[2]);assert(groupTab);
 await dragTab(order[2],groupTab.test_id);
 await waitFor(async()=>(await panes()).length===3||null,15000);
 assert.equal((await tabs()).length,1);check("center-drop-creates-and-joins-group",{});
 const ids=(await panes()).map(n=>n.test_id.split(".").at(-1)!);
 const pids=[];for(let i=0;i<ids.length;i++)pids.push(await recordPid(ids[i],"member-"+i));
 assert.equal(new Set(pids).size,3);
 for(const id of ids)assert.equal((await visible(`groups.broadcast.${id}`)).a11y?.pressed??false,false);
 await focusPane(ids[0]);await trustedCommand("sync on");
 await hidden("group.broadcast.card");
 await trustedCommand("sync on");
 await sendMarker(ids[0],"sync-on-only-current-and-idempotent",[pids[0]]);
 await broadcastUi(ids,[ids[0]],"sync-on-current");
 await click(`groups.broadcast.${ids[1]}`);
 await sendMarker(ids[0],"two-selected-first-origin",[pids[0],pids[1]]);
 await sendMarker(ids[1],"two-selected-second-origin",[pids[0],pids[1]]);
 await click(`groups.broadcast.${ids[2]}`);
 await sendMarker(ids[2],"three-selected-third-origin",pids);
 await click("status.group.broadcast");await visible("group.broadcast.card");
 const checks=await Promise.all(ids.map(id=>visible(`group.broadcast.member.${id}.select`)));
 await writeFile(join(output,"broadcast-checkboxes.json"),JSON.stringify(checks,null,2));
 assert(flat(await visible("group.broadcast.summary")).some(n=>n.text?.includes("3 个参与会话")),"popup counts exactly the three enabled members");
 await capture("01-three-independent-broadcast-members");
 // Currently focused member can opt out; the other two stay on.
 await click(`group.broadcast.member.${ids[2]}.select`);await press("escape");await hidden("group.broadcast.card");
 await sendMarker(ids[2],"unselected-current-is-local-only",[pids[2]]);
 await sendMarker(ids[0],"other-selected-members-remain-on",[pids[0],pids[1]]);
 await click("status.group.broadcast");await click("group.broadcast.accept");
 await press("escape");await hidden("group.broadcast.card");
 await sendMarker(ids[0],"bulk-off-stops-fanout",[pids[0]]);
 await broadcastUi(ids,[],"footer-batch-off");
 await click("status.group.broadcast");await click("group.broadcast.accept");
 await press("escape");await hidden("group.broadcast.card");
 await sendMarker(ids[1],"bulk-on-includes-all",pids);
 await broadcastUi(ids,ids,"footer-batch-on");
 // A builtin only changes its origin member; the footer remains batch control.
 await focusPane(ids[0]);await trustedCommand("sync off");
 await sendMarker(ids[0],"sync-off-only-current",[pids[0]]);
 await sendMarker(ids[1],"sync-off-preserves-other-members",[pids[1],pids[2]]);
 await broadcastUi(ids,[ids[1],ids[2]],"sync-off-current");
 await focusPane(ids[0]);await trustedCommand("sync off");
 await sendMarker(ids[1],"sync-off-repeat-preserves-other-members",[pids[1],pids[2]]);
 await focusPane(ids[0]);await trustedCommand("sync on");
 await sendMarker(ids[0],"sync-on-rejoins-without-changing-peers",pids);
 await focusPane(ids[0]);await trustedCommand("sync on");
 await sendMarker(ids[1],"sync-on-repeat-keeps-all-members",pids);
 await broadcastUi(ids,ids,"sync-on-repeat");

 await click("status.group.broadcast");await resizeWindow(860,480);await sleep(250);
 const card=await visible("group.broadcast.card");assert(card.rect.x>=0&&card.rect.y>=0&&card.rect.x+card.rect.w<=860&&card.rect.y+card.rect.h<=480);
 await capture("02-compact-broadcast-canvas");
 await resizeWindow(1440,900);await press("escape");
 await focusPane(ids[0]);await trustedCommand("sync off");
 await trustedCommand("new --pick");await visible("session.menu");
 await click("session.menu.local");
 await waitFor(async()=>(await panes()).length===4||null,15000);
 check("new-pick-local-preserves-origin-group",{});
 await focusPane(ids[0]);await trustedCommand('new "Owned unavailable SSH"');
 await waitFor(async()=>(await panes()).length===5||null,15000);
 check("new-exact-host-name-preserves-origin-group",{});
 await capture("03-new-host-inside-group");
 if(pointer){await pointerHandoff("physical-group-context-menu",{tab:(await tabs())[0]});await hidden("groups.tab.menu");check("physical-group-context-menu",{});}
 report.status="passed";
} catch(error){report.status="failed";report.error=String(error);await capture("failed").catch(()=>{});process.exitCode=1}
finally{await save();if(child.exitCode===null)child.kill("SIGTERM");await Promise.race([ended,sleep(3000)]);await log.close();console.log(JSON.stringify({status:report.status,error:report.error,output}))}
