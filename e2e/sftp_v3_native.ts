/** Real main-app local selection -> upload confirmation -> Manager -> remote refresh.
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
for (let i=2; i<process.argv.length; i+=2) { assert(["--binary","--expected-sha","--out","--python","--theme","--hold"].includes(process.argv[i])); options[process.argv[i]]=process.argv[i+1]; }
assert(options["--out"] && options["--binary"] && /^[0-9a-f]{64}$/.test(options["--expected-sha"]));
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
const peer=spawn(options["--python"]??"python3",[resolve("e2e/sftp_v3_peer.py"),"--out",peerOut],{stdio:["ignore",peerLog.fd,peerLog.fd]});
const peerEnded=new Promise<void>(done=>peer.once("close",()=>done())); let peerError:Error|undefined; peer.once("error",e=>{peerError=e;});
let app:ReturnType<typeof spawn>|undefined, appEnded:Promise<void>|undefined, appError:Error|undefined, ready:any, failure:unknown;
const payload=Buffer.concat([Buffer.from("ZEROWORK_MAIN_APP_UPLOAD_V1\n"),Buffer.from(Array.from({length:70001},(_,i)=>i%251))]);
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
async function fileTray(side: "local" | "remote"): Promise<any> {
  return waitFor(async()=>nodes(await visible("files."+side)).find(n=>n.test_id==="transfer.session.tray")??null,10000);
}
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
const evidenceIds = ["tabs.strip", "sidebar.host", "auth.challenge.modal", "connection.progress", "files.presentation", "transfer.confirmation", "transfer.conflict", "transfer.manager", "workspace.statusbar", "files.context.menu", "files.history.menu", "files.drag.preview", "files.drag.target", "files.copy.confirmation", "files.workspace", "transfer.session.tray", "files.toolbar", "files.footer", "plugin.challenge.title", "notifications.local"];
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
async function unchanged(reason: string): Promise<void> {
  assert.deepEqual(await readFile(destination), oldBytes, reason);
  assert.deepEqual(await readFile(unrelated), foreignPart, "Unrelated partial bytes remain unchanged");
  report.checks.push(reason);
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

try {
  ready=await waitFor(async()=>{if(peerError||peer.exitCode!==null)throw peerError??new Error("Peer exited");try{return JSON.parse(await readFile(join(peerOut,"ready.json"),"utf8"));}catch(e){if(e.code==="ENOENT")return null;throw e;}},15000);
  const fixture=`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="sftp"\nauth_mode="password"\noptions={strict_host_key=true}\nname="SFTP V3 Owned Peer"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`;
  await writeFile(join(data,"hosts.toml"),fixture);await writeFile(join(data,"config.toml"),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\n');
  const secondName="second.yaml",second=Buffer.from("multi: source-two\n");await writeFile(join(local,secondName),second);
  report.peer={...ready,password:undefined,output:peerOut};
  app=spawn(binary,[],{cwd:process.cwd(),env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:options["--hold"]?"0":"1",ZENIT_E2E_ISOLATE_POINTER:options["--hold"]?"0":"1",ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:"0",ZEROWORK_FILE_TRACE:"1",OPENAI_API_KEY:"",ANTHROPIC_API_KEY:""},stdio:["ignore",appLog.fd,appLog.fd]});
  appEnded=new Promise<void>(done=>app!.once("close",()=>done()));report.pid=app.pid;
  await waitForServerReady();await resizeWindow(1440,900);
  await click("sidebar.host");await settleSftp();
  const attached=await waitFor(async()=>(await traces()).find(t=>t.trace_prefix==="SFTP_WORKSPACE_TRACE"&&t.event==="attached")??null,10000);report.attachment=attached;
  await clickNode(inside(await visible("files.local"),"files.path.edit"),"Activate local path editor");const path=await waitFor(async()=>inside(await visible("files.local"),"files.path")??null,10000);await clickNode(path,"Navigate only local owned fixture");await key("a",{cmd:true});await type_(local);await key("return");
  await waitFor(async()=>nodes(await visible("files.local")).find(n=>n.test_id==="files.row.name"&&n.text===filename)??null,10000);
  for(const [width,height]of [[1440,900],[860,480]]){
    await resizeWindow(width,height);await sleep(200);const panes=[await visible("files.local"),await visible("files.remote")];
    assert(Math.abs(panes[1].rect.x-panes[0].rect.x-panes[0].rect.w-6)<.5);for(const pane of panes){assert.equal(inside(pane,"files.footer").rect.h,36);for(const r of nodes(pane).filter(n=>n.test_id==="files.row"))assert.equal(r.rect.h,40);}
    for(const pane of panes) assert(!nodes(pane).some(n=>n.test_id==="transfer.session.tray"),"empty direction tray occupies no visible card space");
    await capture("v3-empty-"+width);
  }
  await resizeWindow(1440,900);await sleep(200);
  const remote=await visible("files.remote");const x=remote.rect.x+remote.rect.w/2,y=remote.rect.y+remote.rect.h-65;
  assert((await dragAt(x,y,0)).ok);assert((await dragAt(x,y,3,[join(local,filename),join(local,secondName)].map(p=>"file://"+encodeURI(p)).join("\n"))).ok);
  const confirm=await visible("files.copy.confirmation");assert(text(confirm).includes("2 项"));await capture("v3-multi-drop-confirm");await click("files.copy.submit");
  await waitFor(async()=>text(await fileTray("local")).includes("传输中")||null,10000);const uploadCard=await visible("files.local"),uploadTray=await fileTray("local");
  assert(uploadTray.rect.x>=uploadCard.rect.x&&uploadTray.rect.x+uploadTray.rect.w<=uploadCard.rect.x+uploadCard.rect.w+.5);
  assert(uploadTray.rect.y>=inside(uploadCard,"files.footer").rect.y+inside(uploadCard,"files.footer").rect.h-.5);
  assert(uploadTray.rect.y+uploadTray.rect.h<=uploadCard.rect.y+uploadCard.rect.h+.5);
  assert(text(uploadTray).includes("上传传输"));
  assert(!nodes(await visible("files.remote")).some(n=>n.test_id==="transfer.session.tray"));
  await capture("v3-tray-running");
  await waitFor(async()=>{const state=JSON.parse(await readFile(join(peerOut,"state.json"),"utf8"));return state.files["/fixture/"+filename]?.sha256===createHash("sha256").update(payload).digest("hex")&&state.files["/fixture/"+secondName]?.sha256===createHash("sha256").update(second).digest("hex")?state:null;},40000);
  const tray=await fileTray("local");await waitFor(async()=>text(await fileTray("local")).includes("已完成")||null,20000);
  report.checks.push("Native external two-file URI drop froze original owner/remote directory, opened confirmation, and actual SFTP WRITE produced both exact source hashes");
  await waitFor(async()=>{const p=await visible("files.remote");return nodes(p).some(n=>n.test_id==="files.row.name"&&n.text===filename)&&nodes(p).some(n=>n.test_id==="files.row.name"&&n.text===secondName)?true:null;},15000);
  assert(text(await fileTray("local")).includes("等2个文件"));
  await sleep(300);for(const presenter of (await query("notifications.presenter")).filter(shown))assert(!text(presenter).includes("文件传输已完成"),"Visible session tray suppresses duplicate completion toast");
  report.checks.push("Completed multi-file upload refreshes original remote pane, reports true file count, and visible tray suppresses duplicate completion toast");
  for(const [width,height]of [[1440,900],[860,480]]){
    await resizeWindow(width,height);await sleep(200);const current=await fileTray("local");for(const row of nodes(current).filter(n=>n.test_id==="transfer.task"))assert.equal(row.rect.h,40);assert(!nodes(await visible("files.remote")).some(n=>n.test_id==="transfer.session.tray"),"upload never creates a download tray");await capture("v3-tray-completed-"+width);
  }
  let receiptFailure:unknown;
  try {
  await clickNode(inside(await visible("files.local"),"files.refresh"),"Refresh local directory");
  await waitFor(async()=> (await query("notifications.local")).find(n=>shown(n)&&text(n).includes("目录已刷新"))??null,10000);await capture("v3-refresh-receipt");
  await clickNode(inside(await visible("files.local"),"files.row.select"),"Select source for actual path copy");
  await clickNode(inside(await visible("files.local"),"files.context"),"Open original local context menu");
  await clickNode(await stableMenuItem("files.context.menu","files.context.copy"),"Copy real selected path");
  await waitFor(async()=> (await query("notifications.local")).find(n=>shown(n)&&text(n).includes("路径已复制"))??null,10000);await capture("v3-copy-receipt");
  report.checks.push("Refresh receipt follows the accepted request generation and path-copy receipt follows the real clipboard callback, anchored to original clicked controls");
  } catch(error) { receiptFailure=error;report.receipts={status:"failed",error:String(error)};await capture("v3-receipts-failed"); }
  await click("toolbar.transfers");await visible("transfer.manager");assert(text(await visible("transfer.manager")).includes("等2个文件"));await capture("v3-global-shared-row");await clickNode(inside(await visible("transfer.manager"),"transfer.window.close"),"Close own global manager");
  await waitFor(async()=> (await query("transfer.manager")).every(n=>!shown(n))||null,10000);
  await sleep(160);
  if(options["--hold"]){await resizeWindow(860,480);await capture("v3-physical-ready");await writeFile(join(output,"hold.json"),JSON.stringify({pid:app.pid,rpc,data,peer:report.peer,local,output}));console.log("HOLD_APP "+join(output,"hold.json"));await new Promise<void>(done=>{process.once("SIGTERM",()=>done());process.once("SIGINT",()=>done());});}
  if(receiptFailure)throw receiptFailure;
  report.status="passed";
} catch(error){failure=error;report.status="failed";report.error=String(error);try{await capture("failure-live");}catch{}}
finally{
 if(app&&app.exitCode===null)app.kill("SIGTERM");if(peer.exitCode===null)peer.kill("SIGTERM");await sleep(500);await appLog.close();await peerLog.close();report.finished_at=new Date().toISOString();await writeFile(join(output,"report.json"),JSON.stringify(report,null,2));
}
console.log(report.status+": "+join(output,"report.json"));if(failure)throw failure;
