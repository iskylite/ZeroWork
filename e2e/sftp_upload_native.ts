/** Real main-app local selection -> upload confirmation -> Manager -> remote refresh.
 * Own loopback peer only; public synthetic Harness input, no injected success.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, cp, mkdir, mkdtemp, open, readFile, readdir, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, clickAt, key, type_, resizeWindow, screenshot, consoleEvents, sleep } from "../zig-out/share/zenit/harness/client.ts";
const options: Record<string, string> = {};
for (let i=2; i<process.argv.length; i+=2) { assert(["--binary","--expected-sha","--out","--python"].includes(process.argv[i])); options[process.argv[i]]=process.argv[i+1]; }
assert(options["--out"] && options["--binary"] && /^[0-9a-f]{64}$/.test(options["--expected-sha"]));
const output=resolve(options["--out"]); await mkdir(output,{recursive:true}); assert.equal((await readdir(output)).length,0);
const isolated=await mkdtemp(join(tmpdir(),"zerowork-native-upload-")), rpc=join(isolated,"rpc"), data=join(isolated,"data"), local=join(isolated,"local");
await Promise.all([mkdir(rpc),mkdir(data),mkdir(local)]);
const report:any={status:"running",started_at:new Date().toISOString(),stages:[],actions:[],checks:[],host_key_decisions:[],isolated,rpc,data,local_fixture:local,evidence:{synthetic_harness_input:true,physical_input_verified:false,injected_job:false,external_hosts:0},scope:"Real local-card upload to own loopback in-memory SFTP file"};
const sourceBinary=resolve(options["--binary"]), binary=join(output,"zerowork-frozen");
await copyFile(sourceBinary,binary); await copyFile(join(dirname(sourceBinary),"zw_ipc.so"),join(output,"zw_ipc.so"));
const sha=createHash("sha256").update(await readFile(binary)).digest("hex"); assert.equal(sha,options["--expected-sha"]); Object.assign(report,{binary,source_binary:sourceBinary,binary_sha256:sha});
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const appLog=await open(join(output,"app.log"),"w"), peerLog=await open(join(output,"peer.log"),"w"), peerOut=join(output,"peer");
const peer=spawn(options["--python"]??"python3",[resolve("e2e/sftp_upload_loopback.py"),"--out",peerOut],{stdio:["ignore",peerLog.fd,peerLog.fd]});
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
const evidenceIds = ["tabs.strip", "sidebar.host", "auth.challenge.modal", "connection.progress", "files.presentation", "transfer.confirmation", "transfer.conflict", "transfer.manager", "workspace.statusbar", "files.context.menu", "files.history.menu", "files.drag.preview", "files.drag.target", "files.copy.confirmation"];
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
  const fixture=`[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="sftp"\nauth_mode="password"\noptions={strict_host_key=true}\nname="SFTP Loopback Upload"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`;
  await writeFile(join(data,"hosts.toml"),fixture); await writeFile(join(data,"config.toml"),'[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
  report.peer={...ready,password:undefined,output:peerOut};
  app=spawn(binary,[],{cwd:process.cwd(),env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:"1",ZENIT_E2E_ISOLATE_POINTER:"1",ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:"0",ZEROWORK_FILE_TRACE:"1",OPENAI_API_KEY:"",ANTHROPIC_API_KEY:""},stdio:["ignore",appLog.fd,appLog.fd]});
  appEnded=new Promise<void>(done=>app!.once("close",()=>done()));app.once("error",e=>{appError=e;});report.pid=app.pid;
  await waitForServerReady(); assert.equal(Number(JSON.parse(await readFile(join(rpc,"owner.json"),"utf8")).pid),app.pid);
  assert((await resizeWindow(1440,900)).ok); await click("workspace.empty.local");await visible("terminal.surface"); const localTab=(await tabs())[0].test_id;
  await click("sidebar.host");await click("sidebar.host.connect");await settleSftp();
  const attached=await waitFor(async()=>(await traces()).find(t=>t.trace_prefix==="SFTP_WORKSPACE_TRACE"&&t.event==="attached")??null,10000); report.attachment=attached;
  const fileTab=(await tabs()).find(n=>n.test_id!==localTab).test_id;
  const path=inside(await visible("files.local"),"files.path"); await clickNode(path,"Navigate local card to owned upload source");assert((await key("a",{cmd:true})).ok);assert((await type_(local)).ok);assert((await key("return")).ok);
  const row=await waitFor(async()=>nodes(await visible("files.local")).find(n=>n.test_id==="files.row"&&inside(n,"files.row.name")?.text===filename)??null,15000);
  assert.equal(text(inside(await visible("files.remote"),"files.path")),"/fixture");
  await clickNode(row,"Select actual owned local file for upload");await waitFor(async()=>/已选 1 项/.test(text(await visible("files.local")))||null,10000);
  await capture("02-selected-local-source-before-upload");
  await clickNode(inside(await visible("files.local"),"files.transfer"),"Open actual local-card upload confirmation");
  const panel=await visible("files.copy.confirmation");assert(text(panel).includes("上传"));assert(text(inside(panel,"files.copy.source")).includes(await realpath(local)));assert(text(inside(panel,"files.copy.target")).includes("/fixture"));assert(text(panel).includes(`#${attached.owner.session_id}`));
  assert.equal(text(await visible("toolbar.transfers")),"");assert.equal(JSON.parse(await readFile(join(peerOut,"state.json"),"utf8")).upload,null);
  await clickNode(inside(panel,"files.copy.md5"),"Enable full MD5 through real upload checkbox");await capture("03-original-owner-upload-confirmation-no-write");await click("files.copy.submit");
  const proof=await waitFor(async()=>{const current=await traces();const accepted=current.find(t=>t.trace_prefix==="FILE_TRANSFER_ENQUEUED"&&t.owner_id===attached.owner.session_id);if(!accepted)return null;assert.equal(accepted.md5_check,true);const backend=current.find(t=>t.trace_prefix==="FILE_TRANSFER_VERIFICATION"&&t.binding_id===accepted.binding_id&&t.engine_state==="succeeded"&&t.verification_state==="passed");const manager=current.find(t=>t.trace_prefix==="FILE_TRANSFER_MANAGER_VERIFICATION"&&t.job===accepted.job&&t.state==="succeeded"&&t.verification_state==="passed");return backend&&manager?{enqueued:accepted,backend,manager}:null;},45000);
  const actual=await readFile(join(peerOut,"actual-upload.bin"));assert.deepEqual(actual,payload);const md5=createHash("md5").update(payload).digest("hex");for(const value of [proof.backend,proof.manager]){assert.equal(value.source_md5,md5);assert.equal(value.target_md5,md5);}report.actual_transfer=proof;report.upload={source:join(local,filename),target:destination,bytes:actual.length,sha256:createHash("sha256").update(actual).digest("hex"),md5};
  await click("toolbar.transfers");const completed=await waitFor(async()=>{const current=await visible("transfer.manager");return nodes(current).find(n=>n.test_id==="transfer.task"&&text(n).includes(filename)&&text(n).includes("已完成"))??null;},15000);
  await clickNode(inside(completed,"transfer.task.expand"),"Inspect actual successful original upload job");await waitFor(async()=>{const current=await visible("transfer.manager");return text(current).includes(destination)&&text(current).includes(`任务 #${proof.enqueued.job}`)?current:null;},10000);await capture("04-upload-full-md5-manager-completed");
  await click("transfer.task.events");
  const events = await visible("transfer.events.dialog");
  const eventContent = text(await visible("transfer.events.entries"));
  assert(eventContent.includes("入队") && eventContent.includes("已完成"));
  assert(eventContent.includes(`会话 #${attached.owner.session_id}`));
  assert.equal(events.rect.w,520); assert.equal(events.rect.h,300);
  await capture("04b-real-task-events");
  await click("transfer.events.close");
  await waitFor(async()=>!(await query("transfer.events.dialog")).some(shown)||null,10000);
  report.checks.push("Real uploaded task's Manager event journal is shown in the 520x300 read-only event dialog under its original session");

  await clickNode(inside(await visible("transfer.manager"),"transfer.window.close"),"Close upload Manager");await waitFor(async()=>!(await query("transfer.manager")).some(shown)||null,10000);
  report.remote_refresh={automatic:false,method:"actual_remote_card_refresh_button",observation:"build17 only auto-refreshes completed downloads; uploaded file needs actual remote refresh"};
  await clickNode(inside(await visible("files.remote"),"files.refresh"),"Refresh actual remote card after successful upload");
  const refreshed=await waitFor(async()=>nodes(await visible("files.remote")).find(n=>n.test_id==="files.row"&&inside(n,"files.row.name")?.text===filename)??null,15000);report.remote_refreshed_row=refreshed;assert(text(refreshed).includes(`${(payload.length/1024).toFixed(1)} KiB`));await capture("05-remote-manually-refreshed-upload-row");
  await click(fileTab.replace("tabs.tab.","tabs.close."));await waitFor(async()=>(await tabs()).length===1&&!(await query("files.workspace")).some(shown)||null,20000);await visible("terminal.surface");
  report.peer_before_shutdown=await waitFor(async()=>{const state=JSON.parse(await readFile(join(peerOut,"state.json"),"utf8"));return state.connections.length===2&&state.active_connections===0?state:null;},15000);
  assert.equal(report.peer_before_shutdown.forbidden_operations.length,0);assert.equal(report.peer_before_shutdown.errors.length,0);assert(report.peer_before_shutdown.calls.some(c=>c.operation==="WRITE"&&c.path===destination));assert.deepEqual([...report.peer_before_shutdown.read_handles_opened].sort(),[...report.peer_before_shutdown.read_handles_closed].sort());
  assert.equal(await readFile(join(data,"hosts.toml"),"utf8"),fixture);assert.equal(await readFile(join(data,"known_hosts"),"utf8").catch(e=>{if(e.code==="ENOENT")return "";throw e;}),"");
  report.checks.push("Actual local-card selection and upload action open original-owner/path confirmation with zero prior write/job", "Explicit submit uploads exact owned bytes; actual backend/Manager full MD5 pass and visible original job/attempt succeeds", "Actual remote refresh button exposes uploaded filename and size; both SFTP connections/handles close before peer shutdown");report.status="passed";
} catch (error) {
  failure = appError ?? peerError ?? error; report.status = "failed"; report.error = String(failure);
  if (app && app.exitCode === null && app.signalCode === null) {
    try { await capture("failure-live"); } catch (captureError) { report.capture_error = String(captureError); }
    try { await writeFile(join(output, "failure-console.json"), JSON.stringify(await consoleEvents(0, 150), null, 2)); } catch (consoleError) { report.console_error = String(consoleError); }
  }
} finally {
  try { report.runtime_traces = await traces(); } catch (traceError) { report.trace_error = String(traceError); }
  if (app) {
    if (app.exitCode === null && app.signalCode === null) app.kill("SIGTERM");
    await Promise.race([appEnded, sleep(2000)]);
    if (app.exitCode === null && app.signalCode === null) { app.kill("SIGKILL"); await appEnded; }
    report.app_cleanup = { exit_code: app.exitCode, signal: app.signalCode };
  }
  if (peer.exitCode === null && peer.signalCode === null) peer.kill("SIGTERM");
  await Promise.race([peerEnded, sleep(3000)]);
  if (peer.exitCode === null && peer.signalCode === null) { peer.kill("SIGKILL"); await peerEnded; }
  report.peer_cleanup = { exit_code: peer.exitCode, signal: peer.signalCode };
  try { report.peer_final = JSON.parse(await readFile(join(peerOut, "report.json"), "utf8")); } catch (peerReportError) { report.peer_report_error = String(peerReportError); }
  await appLog.close(); await peerLog.close();
  try { await cp(data, join(output, "isolated-data"), { recursive: true }); } catch (copyError) { report.data_copy_error = String(copyError); }
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
