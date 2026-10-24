/** Real main-app settings Save -> default MD5 consumer -> immutable peer/hash.
 * Run only when root grants the native verification slot. The peer listens on
 * loopback only; local writes remain in this run's private temporary directory.
 * No synthetic Snapshot, injected transfer JobSpec, VM or remote mutation.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, cp, mkdir, mkdtemp, open, readFile, readdir, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, clickAt, key, type_, resizeWindow, screenshot, consoleEvents, sleep } from "../zig-out/share/zenit/harness/client.ts";

const options: Record<string, string> = {};
for (let i = 2; i < process.argv.length; i += 2) {
  assert(["--binary", "--expected-sha", "--out", "--prepare-only", "--python", "--resume-false"].includes(process.argv[i]) && process.argv[i + 1], `Invalid argument ${process.argv[i]}`);
  options[process.argv[i]] = process.argv[i + 1];
}
const prepare = options["--prepare-only"] === "1";
const resumeFalse = options["--resume-false"] === "1";
assert(options["--resume-false"] === undefined || resumeFalse, "--resume-false accepts 1");
assert(options["--prepare-only"] === undefined || prepare, "--prepare-only accepts 1");
assert(options["--out"], "--out is required and must be a fresh directory");
assert(prepare || (options["--binary"] && /^[0-9a-f]{64}$/.test(options["--expected-sha"] ?? "")), "Run requires the newly integrated --binary and its exact --expected-sha");
const output = resolve(options["--out"]);
await mkdir(output, { recursive: true });
assert.equal((await readdir(output)).length, 0, "Keep previous evidence; use a fresh output directory");
const report: any = {
  status: prepare ? "prepared_not_run" : "running", started_at: new Date().toISOString(), stages: [], actions: [], checks: [], host_key_decisions: [],
  scope: resumeFalse ? "Settings Save resume=false; one real SFTP-card download consumes saved resume default without confirmation override and matches complete hashes" : "Settings Save verify_md5=true and dedicated_connection=true; one real SFTP-card download consumes default MD5 without checkbox override",
  evidence: { synthetic_harness_input: true, physical_input_verified: false, synthetic_conflict_snapshot: false, vm_connections: 0, remote_writes_authorized: false },
  prerequisites: ["Fresh main-app test-mode build with current conflict/MD5/file transfer integration and public Harness client installed", "macOS native verification slot granted by root; no concurrent test app", "Node supporting TypeScript stripping; Python with installed Paramiko; no new packages or service", "SourceFactory no-shell path and gated ZEROWORK_FILE_TRACE diagnostics in the supplied binary"],
  planned_steps: resumeFalse ? ["Own loopback peer and isolated background native app", "Save resume=false through the real control", "Enqueue one file-card download without changing confirmation controls", "Verify real transfer task completed and complete target MD5/SHA256"] : ["Own loopback peer and isolated background native app", "Save verify_md5=true and dedicated_connection=true through real controls", "Enqueue one file-card download without changing MD5 confirmation", "Release reads and compare actual source/target MD5 and SHA256"],
  limits: ["Prepared report alone is not an executed native test", "GPU screenshots and tree queries are sequential, not atomic; a human still reviews saved native pixels", "The loopback source is controlled data, not a user-server acceptance result", "Own process SIGTERM cleanup is not a normal application window-close acceptance result"],
};
if (prepare) {
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  console.log(`prepared_not_run: ${join(output, "report.json")}`);
  process.exit(0);
}

const isolated = await mkdtemp(join(tmpdir(), "zerowork-transfer-policy-")), rpc = join(isolated, "rpc"), data = join(isolated, "data"), local = join(isolated, "download-target");
await Promise.all([mkdir(rpc), mkdir(data), mkdir(local)]);
Object.assign(report, { isolated, rpc, data, local_fixture: local });
const binary = join(output, "zerowork-frozen"), sourceBinary = resolve(options["--binary"]);
await copyFile(sourceBinary, binary);
await copyFile(join(dirname(sourceBinary), "zw_ipc.so"), join(output, "zw_ipc.so"));
const sha = createHash("sha256").update(await readFile(binary)).digest("hex");
assert.equal(sha, options["--expected-sha"], "Use root's exact newly integrated binary");
Object.assign(report, { binary, source_binary: sourceBinary, binary_sha256: sha });
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const appLog = await open(join(output, "app.log"), "w"), peerLog = await open(join(output, "peer.log"), "w");
const peerOut = join(output, "peer");
const peer = spawn(options["--python"] ?? "python3", [resolve("e2e/transfer_policy_loopback.py"), "--out", peerOut], { stdio: ["ignore", peerLog.fd, peerLog.fd] });
const peerEnded = new Promise<void>(done => peer.once("close", () => done()));
let peerError: Error | undefined;
peer.once("error", error => { peerError = error; });
let app: ReturnType<typeof spawn> | undefined, appEnded: Promise<void> | undefined, appError: Error | undefined, ready: any;
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
const evidenceIds = ["settings.search", "settings.field.chunk_kb", "settings.field.window_chunks", "settings.field.max_tasks", "settings.footer.state", "tabs.strip", "sidebar.host", "auth.challenge.modal", "connection.progress", "files.presentation", "transfer.confirmation", "transfer.conflict", "transfer.manager", "workspace.statusbar", "files.context.menu", "files.history.menu", "files.drag.preview", "files.drag.target", "files.copy.confirmation"];
async function capture(name: string): Promise<void> {
  await sleep(120);
  const samples = Object.fromEntries(await Promise.all(evidenceIds.map(async id => [id, await query(id)])));
  const treePath = join(output, `${name}.tree.json`), imagePath = join(output, `${name}.png`);
  await writeFile(treePath, JSON.stringify(samples, null, 2));
  assert((await screenshot(imagePath)).ok, `Real native screenshot ${name}`);
  report.stages.push({ name, at: new Date().toISOString(), tree: treePath, screenshot: imagePath, query_screenshot_atomic: false });
  console.log(`[sftp-conflict] ${name}`);
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
let failure: unknown;
try {
  ready = await waitFor(async () => {
    if (peerError || peer.exitCode !== null || peer.signalCode !== null) throw peerError ?? new Error("Owned peer exited before ready");
    try { return JSON.parse(await readFile(join(peerOut, "ready.json"), "utf8")); } catch (error) { if (error.code === "ENOENT") return null; throw error; }
  }, 15000);
  assert.equal(ready.host, "127.0.0.1"); assert(ready.port > 0); assert.equal(ready.remote_path, "/fixture/release.txt");
  const fixture = `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="sftp"\nauth_mode="password"\noptions={strict_host_key=true}\nname="SFTP Loopback Conflict"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`;
  await writeFile(join(data, "hosts.toml"), fixture);
  await writeFile(join(data, "config.toml"), '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n[transfer]\nchunk_kb=64\nwindow_chunks=16\nmax_tasks=3\ndedicated_connection=false\nresume=true\nverify_md5=false\nconflict_policy="ask"\n');
  report.peer = { pid: peer.pid, ...ready, password: undefined, output: peerOut };
  const sourceFactory = await readFile(resolve("src/host/file_route_factory.zig"), "utf8");
  assert(sourceFactory.includes(".open_shell = false"));
  await writeFile(join(output, "file-route-factory-source.zig"), sourceFactory);
  app = spawn(binary, [], { cwd: process.cwd(), env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", ZEROWORK_FILE_TRACE: "1", OPENAI_API_KEY: "", ANTHROPIC_API_KEY: "" }, stdio: ["ignore", appLog.fd, appLog.fd] });
  appEnded = new Promise<void>(done => app!.once("close", () => done())); app.once("error", error => { appError = error; });
  report.pid = app.pid;
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), app.pid, "Only this owned native app receives RPC input");
  assert((await resizeWindow(1440, 900)).ok);
  await click("workspace.empty.local"); await visible("terminal.surface");
  const original = await tabs(); assert.equal(original.length, 1); const localTab = original[0].test_id;
  await click("sidebar.host"); await click("sidebar.host.connect");
  await settleSftp();
  assert.equal(report.host_key_decisions.length, 2, "Both independent unknown SFTP connections require actual trust-once UI");
  assert(!(await query("connection.progress")).some(shown));
  const attachedTabs = await tabs(); assert.equal(attachedTabs.length, 2);
  const fileTab = attachedTabs.find(n => n.test_id !== localTab)?.test_id; assert(fileTab);
  const attached = await waitFor(async () => (await traces()).find(t => t.trace_prefix === "SFTP_WORKSPACE_TRACE" && t.event === "attached") ?? null, 10000);
  assert.equal(attached.plugin, "sftp"); assert.equal(attached.terminal_present, false); assert.equal(attached.runtime_present, false);
  report.attachment = attached;


  // Change the actual settings controls, Save once, and read only owned transfer scalars.
  await click("toolbar.settings");
  await click("settings.nav.transfer");
  const configPath=join(data,"config.toml");
  for (const field of (resumeFalse ? ["resume"] : ["verify_md5", "dedicated_connection"])) {
    await click("settings.search"); await key("a", {cmd:true}); await type_(field);
    await click(`settings.field.${field}`);
    await capture(`02-settings-draft-${field}`);
  }
  await click("settings.save");
  await waitFor(async()=>{
    const c=await readFile(configPath,"utf8");
    return (resumeFalse ? ["resume = false"] : ["verify_md5 = true", "dedicated_connection = true"]).every(x=>c.includes(x))?true:null;
  },10000);
  report.saved_transfer_values=resumeFalse ? {resume:false} : {verify_md5:true,dedicated_connection:true};
  await capture("03-settings-saved-policy");
  await click("settings.close");
  const dir=await realpath(local);
  const path=inside(await visible("files.local"),"files.path");
  await clickNode(path,"Use owned local target"); await key("a",{cmd:true}); await type_(dir); await key("return");
  await waitFor(async()=>text(inside(await visible("files.local"),"files.path"))===dir?true:null,10000);
  const row=nodes(await visible("files.remote")).find(n=>n.test_id==="files.row"&&inside(n,"files.row.name")?.text==="release.txt"); assert(row);
  await clickNode(row,"Select immutable peer source");
  await clickNode(inside(await visible("files.remote"),"files.transfer"),"Open actual download confirmation using saved defaults");
  const panel=await visible("files.copy.confirmation");
  assert(inside(panel,"files.copy.md5"));
  await capture(resumeFalse ? "04-resume-false-confirmation-default-not-overridden" : "04-md5-confirmation-default-not-overridden");
  await click("files.copy.submit");
  const enqueued=await waitFor(async()=>(await traces()).find(t=>t.trace_prefix==="FILE_TRANSFER_ENQUEUED")??null,10000);
  assert.equal(enqueued.md5_check,!resumeFalse,"Actual JobSpec preserves untouched MD5 confirmation default");
  if(resumeFalse) assert.equal(enqueued.resume_transfer,false,"Saved resume=false flows to actual capturedJobSpec without manual confirmation override");
  report.enqueued=enqueued;
  await writeFile(join(peerOut,"release-reads"),"owned release\n");
  let proof: any;
  if(resumeFalse) {
    if(!(await query("transfer.manager")).some(shown)) await click("toolbar.transfers");
    const completed=await waitFor(async()=>nodes(await visible("transfer.manager")).find(n=>n.test_id==="transfer.task"&&text(n).includes("release.txt")&&text(n).includes("已完成"))??null,45000);
    proof={job:enqueued.job,state:"succeeded",evidence:"real transfer manager task UI",label:text(completed)};
  } else {
    proof=await waitFor(async()=>(await traces()).find(t=>t.trace_prefix==="FILE_TRANSFER_MANAGER_VERIFICATION"&&t.state==="succeeded"&&t.verification_state==="passed")??null,45000);
  }
  if(!resumeFalse) { assert.equal(proof.source_md5,ready.md5); assert.equal(proof.target_md5,ready.md5); }
  const actual=await readFile(join(dir,"release.txt"));
  assert.equal(createHash("sha256").update(actual).digest("hex"),ready.sha256);
  assert.equal(createHash("md5").update(actual).digest("hex"),ready.md5);
  report.verification=proof;
  report.actual_file={path:join(dir,"release.txt"),bytes:actual.length,sha256:createHash("sha256").update(actual).digest("hex"),md5:createHash("md5").update(actual).digest("hex")};
  report.peer_before_shutdown=JSON.parse(await readFile(join(peerOut,"state.json"),"utf8"));
  await capture(resumeFalse ? "05-saved-resume-false-real-download-passed" : "05-saved-md5-default-real-download-passed");
  report.checks.push(...(resumeFalse ? ["Real resume setting saved true to false", "Actual capturedJobSpec.resume_transfer=false without confirmation override", "New full download succeeded and target SHA256/MD5 match complete peer fixture"] : ["Real setting controls saved verify_md5 and dedicated_connection false to true", "Actual SFTP copy confirmation defaults consumed saved verify_md5; checkbox never toggled", "Enqueue md5_check=true; actual network publication source/target MD5 and SHA256 match"]));
  report.dedicated_connection_scope=resumeFalse ? "Not exercised in resume=false run" : "Saved true control proven; this SFTP-card run naturally uses independent no-shell sources and cannot prove the ordinary-SSH dedicated/shared policy branch. Ordinary SSH requires separate network evidence.";
  report.limitations=["Public Harness synthetic native input, not physical input", "Screenshot visual review required", "SFTP TCP count is not counted as dedicated_connection ordinarySSH policy proof", "Own SIGTERM teardown is not normal window close"];
  if((await query("transfer.manager")).some(shown))await click("transfer.window.close");
  await click(fileTab.replace("tabs.tab.","tabs.close."));
  await waitFor(async()=>(await tabs()).length===1?true:null,15000);
  report.status="passed";
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
