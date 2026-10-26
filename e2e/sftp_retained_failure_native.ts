/** Native closed-source retained upload: resume, prefix tamper/cancel and active FIN recovery.
 * Own loopback peer only; public synthetic Harness input, no injected success.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, cp, mkdir, mkdtemp, open, readFile, readdir, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, clickAt, key, type_, resizeWindow, screenshot, consoleEvents, sleep, dragAt } from "../zig-out/share/zenit/harness/client.ts";
const options: Record<string, string> = {};
for (let i=2; i<process.argv.length; i+=2) { assert(["--binary","--expected-sha","--out","--python","--theme","--hold","--peer","--mode"].includes(process.argv[i])); options[process.argv[i]]=process.argv[i+1]; }
assert(options["--out"] && options["--binary"] && /^[0-9a-f]{64}$/.test(options["--expected-sha"]));
const mode=options["--mode"]??"resume";assert(["resume","tamper","fin"].includes(mode));
const theme=options["--theme"]??"dark";assert(["dark","light"].includes(theme));
const output=resolve(options["--out"]); await mkdir(output,{recursive:true}); assert.equal((await readdir(output)).length,0);
const isolated=await realpath(await mkdtemp(join(tmpdir(),"zerowork-native-upload-"))), rpc=join(isolated,"rpc"), data=join(isolated,"data"), local=join(isolated,"local");
await Promise.all([mkdir(rpc),mkdir(data),mkdir(local)]);
const report:any={theme,status:"running",started_at:new Date().toISOString(),stages:[],actions:[],checks:[],host_key_decisions:[],isolated,rpc,data,local_fixture:local,evidence:{synthetic_harness_input:true,physical_input_verified:false,injected_job:false,external_hosts:0},scope:"Real local-card upload to own loopback in-memory SFTP file"};
const sourceBinary=resolve(options["--binary"]), binary=join(output,"ZeroWork Files V3.app/Contents/MacOS/zerowork");
await mkdir(dirname(binary),{recursive:true});await writeFile(join(dirname(dirname(binary)),"Info.plist"),'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>zerowork</string><key>CFBundleIdentifier</key><string>local.zerowork.files.v3</string><key>CFBundleName</key><string>ZeroWork Files V3</string><key>NSHighResolutionCapable</key><true/></dict></plist>');await copyFile(sourceBinary,binary); await copyFile(join(dirname(sourceBinary),"zw_ipc.so"),join(output,"zw_ipc.so"));
const sha=createHash("sha256").update(await readFile(binary)).digest("hex"); assert.equal(sha,options["--expected-sha"]); Object.assign(report,{binary,source_binary:sourceBinary,binary_sha256:sha});
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const appLog=await open(join(output,"app.log"),"w"), peerLog=await open(join(output,"peer.log"),"w"), peerOut=join(output,"peer");
const peer=spawn(options["--python"]??"python3",[resolve(options["--peer"]??"e2e/sftp_v3_peer.py"),"--out",peerOut],{stdio:["ignore",peerLog.fd,peerLog.fd]});
const peerEnded=new Promise<void>(done=>peer.once("close",()=>done())); let peerError:Error|undefined; peer.once("error",e=>{peerError=e;});
let app:ReturnType<typeof spawn>|undefined, appEnded:Promise<void>|undefined, appError:Error|undefined, ready:any, failure:unknown;
const payload=Buffer.concat([Buffer.from("ZEROWORK_MAIN_APP_UPLOAD_V1\n"),Buffer.from(Array.from({length:1024*1024},(_,i)=>i%251))]);
const filename="upload-main.txt", destination="/fixture/upload-main.txt"; await writeFile(join(local,filename),payload);
function shown(n: any): boolean { return !!n?.rect && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? n.opacity ?? 1) > 0 && n.rect.w > 0 && n.rect.h > 0; }
function nodes(n: any): any[] { return !shown(n) ? [] : [n, ...(n.children ?? []).flatMap(nodes)]; }
function text(n: any): string { return nodes(n).filter(v => typeof v.text === "string" && v.text.length > 0).map(v => v.text).join(" "); }
function inside(n: any, id: string): any { return nodes(n).find(v => v.test_id === id); }
async function visible(id: string, timeout = 15000): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null, timeout); }
async function clickNode(n: any, reason: string): Promise<void> {
  assert(shown(n), reason);
  report.actions.push({ reason, id: n.test_id, node_id: n.id, rect: n.rect, at: new Date().toISOString() });
  assert((await clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok, reason);
}
async function click(id: string): Promise<void> { await clickNode(await visible(id), id); }
async function stableMenuItem(menuId: string, itemId: string): Promise<any> {
  let previous = "", stable = 0;
  return waitFor(async () => {
    const menu = (await query(menuId)).find(n => shown(n) && (n.effective_opacity ?? n.opacity ?? 1) >= 0.999);
    const item = menu && inside(menu, itemId);
    if (!menu || !shown(item) || !item.focusable || item.rect.x < menu.rect.x || item.rect.y < menu.rect.y || item.rect.x + item.rect.w > menu.rect.x + menu.rect.w + 1 || item.rect.y + item.rect.h > menu.rect.y + menu.rect.h + 1) { stable = 0; return null; }
    const current = JSON.stringify([menu.id, menu.rect, item.id, item.rect]);
    stable = current === previous ? stable + 1 : 0;
    previous = current;
    await sleep(80);
    return stable >= 2 ? item : null;
  }, 15000);
}
async function tabs(): Promise<any[]> { return nodes(await visible("tabs.strip")).filter(n => /^tabs\.tab\.\d+$/.test(n.test_id ?? "")); }
const evidenceIds = ["tabs.strip", "sidebar.host", "auth.challenge.modal", "connection.progress", "files.presentation", "transfer.confirmation", "transfer.conflict", "transfer.manager", "workspace.statusbar", "files.context.menu", "files.history.menu", "files.drag.preview", "files.drag.target", "files.copy.confirmation", "files.workspace", "transfer.session.tray", "files.toolbar", "files.footer", "plugin.challenge.title", "notifications.local", "session.close.confirm"];
async function capture(name: string): Promise<void> {
  await sleep(120);
  const samples = Object.fromEntries(await Promise.all(evidenceIds.map(async id => [id, await query(id)])));
  const treePath = join(output, `${name}.tree.json`), imagePath = join(output, `${name}.png`);
  await writeFile(treePath, JSON.stringify(samples, null, 2));
  assert((await screenshot(imagePath)).ok, `Real native screenshot ${name}`);
  report.stages.push({ name, at: new Date().toISOString(), tree: treePath, screenshot: imagePath, query_screenshot_atomic: false });
  console.log(`[sftp-upload] ${name}`);
}
async function traces(): Promise<any[]> {
  const log = await readFile(join(output, "app.log"), "utf8"), complete = log.slice(0, log.lastIndexOf("\n") + 1);
  const prefixes = ["SFTP_WORKSPACE_TRACE ", "SFTP_READONLY_READY ", "FILE_TRANSFER_READY ", "FILE_TRANSFER_ENQUEUED ", "FILE_TRANSFER_VERIFICATION ", "FILE_TRANSFER_MANAGER_VERIFICATION "];
  return complete.split("\n").flatMap((line, index) => {
    const prefix = prefixes.find(p => line.includes(p));
    return prefix ? [{ ...JSON.parse(line.slice(line.indexOf(prefix) + prefix.length)), trace_prefix: prefix.trim(), log_line: index + 1 }] : [];
  });
}
async function settleSftp(): Promise<void> {
  const deadline = Date.now() + 75000;
  let decisions = 0;
  while (Date.now() < deadline) {
    assert(app && app.exitCode === null && app.signalCode === null, "Owned app remains alive while connecting");
    if ((await query("files.workspace")).some(shown)) return;
    const plugin = (await query("plugin.challenge.title")).find(shown);
    if (plugin) {
      const values=(await Promise.all(["plugin.challenge.title","plugin.challenge.source","plugin.challenge.material","plugin.challenge.choice.0","plugin.challenge.answer.0","plugin.challenge.secret"].map(id=>query(id)))).flat().filter(shown);
      const part=(id:string)=>values.find(n=>n.test_id===id), source=text(part("plugin.challenge.source"));
      assert(source.includes(ready.host)&&source.includes(String(ready.port))&&source.includes(ready.user),"Only this exact owned peer");
      const title=text(plugin), choice=part("plugin.challenge.choice.0");
      if(title==="核对主机密钥"&&choice&&text(choice).includes("仅本次信任")){
        const fingerprint=text(part("plugin.challenge.material"));assert(fingerprint.includes(ready.fingerprint));assert(++decisions<=6);
        await clickNode(choice,"Trust the generated loopback key once in the existing plugin challenge");report.host_key_decisions.push({endpoint:source,fingerprint,choice:"trust_once"});
      }else if(title==="SSH 密码认证"){
        const answer=part("plugin.challenge.answer.0")??part("plugin.challenge.secret");assert(answer&&++decisions<=6);
        await clickNode(answer,"Enter only the owned peer fixture password");await type_(ready.password);await click("plugin.challenge.submit");
      }else throw new Error("Unexpected owned-peer authentication challenge");
      await sleep(160);continue;
    }
    const modal = (await query("auth.challenge.modal")).find(n => shown(n) && (n.effective_opacity ?? n.opacity ?? 1) >= 0.999);
    const trust = modal && inside(modal, "auth.challenge.trust_once");
    if (trust?.focusable) {
      const endpoint = text(inside(modal, "auth.challenge.endpoint")), fingerprint = text(inside(modal, "auth.challenge.fingerprint"));
      assert(endpoint.includes("127.0.0.1") && endpoint.includes(String(ready.port)) && endpoint.includes(ready.user), `Trust only this exact owned peer: ${endpoint}`);
      assert(fingerprint.includes(ready.fingerprint), "UI must display this peer's actual generated key fingerprint");
      assert(++decisions <= 6, "Bound real trust/password decisions");
      await capture(`01-trust-once-${decisions}`);
      const same = (await query("auth.challenge.modal")).find(n => n.id === modal.id && shown(n));
      const button = same && inside(same, "auth.challenge.trust_once");
      if (button?.focusable && text(inside(same, "auth.challenge.fingerprint")).includes(ready.fingerprint)) {
        await clickNode(button, "Trust this exact loopback host key once through the live modal");
        report.host_key_decisions.push({ endpoint, fingerprint, choice: "trust_once", modal_id: modal.id });
      }
      await sleep(120); continue;
    }
    const answer = modal && inside(modal, "auth.challenge.answer.0");
    if (answer?.focusable) {
      assert(++decisions <= 6);
      assert(!/输入小写 yes|替换已保存/.test(text(modal)), "Key replacement is not authorized");
      assert(text(inside(modal, "auth.challenge.endpoint")).includes("127.0.0.1"));
      await clickNode(answer, "Enter only this peer's fixture password");
      assert((await key("a", { cmd: true })).ok); assert((await type_(ready.password)).ok);
      await clickNode(inside(modal, "auth.challenge.submit"), "Submit real authentication UI");
      await sleep(120); continue;
    }
    await sleep(80);
  }
  throw new Error("Actual loopback file workspace did not attach within 75 seconds");
}

async function settleRetainedAuth(){
 for(let i=0;i<80;i++){
  const title=(await query("plugin.challenge.title")).find(shown);
  if(title){
   if(text(title)==="核对主机密钥"){const material=await visible("plugin.challenge.material");assert(text(material).includes(ready.fingerprint));await click("plugin.challenge.choice.0")}
   else if(text(title)==="SSH 密码认证"){const input=(await query("plugin.challenge.answer.0")).find(shown)??(await query("plugin.challenge.secret")).find(shown);await clickNode(input,"Authenticate only exact retained peer");await type_(ready.password);await click("plugin.challenge.submit")}
   else throw new Error("Unexpected retained auth: "+text(title));
  }
  await sleep(100);
 }
}
try {
 ready=await waitFor(async()=>{try{return JSON.parse(await readFile(join(peerOut,"ready.json"),"utf8"))}catch{return null}},15000);
 await writeFile(join(data,"hosts.toml"),`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="sftp"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Owned retained SFTP"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
 await writeFile(join(data,"config.toml"),'[ui]\ntheme="dark"\n[transfer]\ndedicated_connection=true\nwindow_chunks=1\nchunk_kb=32\nmax_tasks=1\nresume=true\nverify_md5=false\n');
 report.peer={...ready,password:undefined};
 app=spawn(binary,[],{cwd:process.cwd(),env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:"1",ZENIT_E2E_ISOLATE_POINTER:"1",ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:"0",ZEROWORK_FILE_TRACE:"1"},stdio:["ignore",appLog.fd,appLog.fd]});report.pid=app.pid;
 await waitForServerReady();await resizeWindow(1440,900);await click("sidebar.host");await settleSftp();
 const tab=(await tabs()).at(-1);report.source_tab=tab.test_id;
 const remote=await visible("files.remote"),x=remote.rect.x+remote.rect.w/2,y=remote.rect.y+remote.rect.h-65;
 await dragAt(x,y,0);await dragAt(x,y,3,"file://"+encodeURI(join(local,filename)));await visible("files.copy.confirmation");await click("files.copy.submit");
 await waitFor(async()=>{const t=await traces();return t.find(v=>v.trace_prefix==="FILE_TRANSFER_ENQUEUED")??null},15000);
 await waitFor(async()=>{const s=JSON.parse(await readFile(join(peerOut,"state.json"),"utf8"));return s.files[destination]?.bytes>0?s:null},20000);
 await capture("01-nonzero-partial");
 await click("toolbar.transfers");await visible("transfer.manager");
 let manager=await visible("transfer.manager");await clickNode(inside(manager,"transfer.task.primary"),"Pause real upload after peer wrote nonzero bytes");
 await waitFor(async()=>text(await visible("transfer.manager")).includes("已暂停")||null,15000);await capture("02-paused");
 await clickNode(inside(await visible("transfer.manager"),"transfer.window.close"),"Close manager before source tab");await sleep(300);
 const close=(await query(tab.test_id.replace("tabs.tab.","tabs.close."))).find(shown);await clickNode(close,"Close original SFTP source tab while transfer is paused");
 // Existing close confirmation must explicitly retain its independent transfer owner.
 await visible("session.close.confirm");await click("session.close.accept");
 await waitFor(async()=>!(await query("session.close.confirm")).some(shown)||null,15000);await sleep(1000);await capture("03-close-source");
 await click("toolbar.transfers");await visible("transfer.manager");await capture("04-retained-manager");
 report.retained_tree=await query("transfer.manager");report.traces_before=await traces();
 assert(text(await visible("transfer.manager")).includes("原会话已关闭"));
 assert(report.traces_before.some((v:any)=>v.event==="closed"&&v.cleanup==="released"));
 const partial=JSON.parse(await readFile(join(peerOut,"state.json"),"utf8"));report.partial=partial.files[destination];
 if(mode==="tamper"){
  await writeFile(join(peerOut,"control.json"),JSON.stringify({tamper_prefix:true}));
  await waitFor(async()=>JSON.parse(await readFile(join(peerOut,"state.json"),"utf8")).calls.some((v:any)=>v.op==="TAMPER_PREFIX")||null,5000);
 }

 await sleep(600);
 const primary=await waitFor(async()=>{const n=inside(await visible("transfer.manager"),"transfer.task.primary");return n?.focusable?n:null},15000);await clickNode(primary,"Resume retained transfer after owned peer fault");
 await settleRetainedAuth();
 if(mode==="fin"){
  await waitFor(async()=>JSON.parse(await readFile(join(peerOut,"state.json"),"utf8")).files[destination].bytes>report.partial.bytes||null,20000);
  await writeFile(join(peerOut,"control.json"),JSON.stringify({disconnect_all:true}));
 }
 await waitFor(async()=>{
  const status=text((await query("transfer.task.status")).find(shown));
  return (mode==="resume"?status==="已完成":status==="已暂停"||status==="失败"||status==="传输失败")?status:null;
 },180000);await capture("05-disconnected-retained");
 report.final_tree=await query("transfer.manager");report.final_traces=await traces();report.peer_state=JSON.parse(await readFile(join(peerOut,"state.json"),"utf8"));
 const terminal=text(await visible("transfer.manager"));
 if(mode==="resume"){
  assert(terminal.includes("已完成"),terminal);
  assert.equal(report.peer_state.files[destination].bytes,payload.length);
  assert.equal(report.peer_state.files[destination].sha256,createHash("sha256").update(payload).digest("hex"));
  report.checks.push("Closed original source retained partial resumes through new binding with exact final SHA-256");
 }else if(mode==="tamper"){
  assert(terminal.includes("文件冲突或内容已变化"),terminal);
  assert.equal(report.peer_state.files[destination].bytes,report.partial.bytes);
  const mark=report.peer_state.calls.findIndex((v:any)=>v.op==="TAMPER_PREFIX");
  assert(mark>=0&&!report.peer_state.calls.slice(mark+1).some((v:any)=>v.op==="WRITE"));
  await clickNode(inside(await visible("transfer.manager"),"transfer.task.cancel"),"Cancel retained rejected prefix without overwriting it");
  await waitFor(async()=>text(await visible("transfer.manager")).includes("已取消")||null,15000);
  await capture("06-tampered-retained-cancelled");
  report.checks.push("Remote prefix tamper remains rejected without any resumed write; retained job cancels");
 }else{
  assert(report.peer_state.calls.some((v:any)=>v.op==="DISCONNECT_ALL"));
  assert.equal(text((await query("transfer.task.status")).find(shown)),"已暂停");
  report.checks.push("Actual retained active transport FIN pauses original retained task and never reports successful completion");
  const failedBytes=report.peer_state.files[destination].bytes;
  await clickNode(inside(await visible("transfer.manager"),"transfer.task.primary"),"Explicitly resume retained task after actual transport FIN");
  await settleRetainedAuth();
  await waitFor(async()=>text((await query("transfer.task.status")).find(shown))==="已完成"||(await query("transfer.conflict")).some(shown)||null,180000);
  if((await query("transfer.conflict")).some(shown)){
   await capture("06-fin-recovery-conflict");
   await click("transfer.conflict.overwrite");await click("transfer.conflict.apply");
   await visible("transfer.conflict.confirm.paths");await capture("07-fin-recovery-explicit-overwrite");
   await click("transfer.conflict.apply");
   report.checks.push("Post-FIN uncertain partial requires explicit two-step overwrite before fresh transfer");
  }
  await waitFor(async()=>text((await query("transfer.task.status")).find(shown))==="已完成"||null,180000);
  report.recovered_peer=JSON.parse(await readFile(join(peerOut,"state.json"),"utf8"));
  assert.equal(report.recovered_peer.files[destination].bytes,payload.length);
  assert.equal(report.recovered_peer.files[destination].sha256,createHash("sha256").update(payload).digest("hex"));
  await capture("06-fin-explicit-resume-completed");
  report.checks.push("Explicit post-FIN recovery completes exact SHA-256 without reviving source tab");
 }
 assert(!(await query(tab.test_id)).some(shown),"Recovery must never revive the original closed source tab");
 report.mode=mode;report.status="passed";
}catch(e){failure=e;report.status="failed";report.error=String(e);try{await capture("failure")}catch{}}
finally{if(app?.exitCode===null)app.kill("SIGTERM");if(peer.exitCode===null)peer.kill("SIGTERM");await sleep(500);await appLog.close();await peerLog.close();report.finished_at=new Date().toISOString();await writeFile(join(output,"report.json"),JSON.stringify(report,null,2))}
console.log(report.status+": "+join(output,"report.json"));if(failure)throw failure;
