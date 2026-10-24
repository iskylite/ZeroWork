/** Real main-application SFTP workspace against an explicit VM or owned loopback peer.
 * Own isolated data/RPC/background Metal process, public synthetic Harness.
 * Remote operations list a nonce /tmp directory and upload/download one owned sentinel.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, cp, mkdir, mkdtemp, open, readFile, readdir, realpath, writeFile, rm, chmod } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { request, waitForServerReady, waitFor, query, clickTestId, clickAt, key, type_, focused, resizeWindow, scrollAt, screenshot, consoleEvents, sleep } from "../zig-out/share/zenit/harness/client.ts";

const options: Record<string, string> = {}, args = process.argv.slice(2);
for (let index = 0; index < args.length; index += 2) {
  assert(["--binary", "--expected-sha", "--out", "--prepare-only", "--md5", "--shared-challenge", "--sftp-ai", "--ai-config", "--fresh-ai-chat", "--continuous-ai"].includes(args[index]) && args[index + 1], `Invalid argument ${args[index]}`);
  options[args[index]] = args[index + 1];
}
assert(options["--out"], "--out is required");
const prepareOnly = options["--prepare-only"] === "1";
assert(options["--md5"] === undefined || options["--md5"] === "1", "Optional --md5 accepts only 1");
const md5Requested = options["--md5"] === "1";
const sharedChallenge=options["--shared-challenge"]==="1";
const sftpAi=options["--sftp-ai"]==="1";
const continuous=options["--continuous-ai"]==="1";
assert(!continuous||sftpAi,"Continuous acceptance requires actual SFTP AI");
assert(!continuous||options["--fresh-ai-chat"]!=="1","Continuous acceptance forbids replacing the assistant conversation");
assert(!continuous||options["--expected-sha"],"Continuous acceptance requires root frozen binary SHA");
assert(!sftpAi||options["--ai-config"],"SFTP AI acceptance requires explicit private provider configuration");
const aiConfig=sftpAi?await readFile(resolve(options["--ai-config"]),"utf8"):"";
const aiSection=aiConfig.indexOf("[ai]");assert(!sftpAi||aiSection>=0,"Use production [ai] provider configuration");
const aiSecrets=[...aiConfig.matchAll(/^api_key\s*=\s*"([^"]+)"/gm)].map(m=>m[1]);
assert(prepareOnly || options["--binary"], "Run requires an explicit newly integrated --binary; no old-app default");
const output = resolve(options["--out"]), isolated = await mkdtemp(join(tmpdir(), "zerowork-sftp-native-"));
await chmod(isolated,0o700);
const rpc = join(isolated, "rpc"), data = join(isolated, "data"), localFixture = join(isolated, "local-readonly-fixture");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data), mkdir(localFixture)]);
await mkdir(join(localFixture, "local-child"));
const localFilename = "zerowork-local-list-sentinel.txt";
await writeFile(join(localFixture, localFilename), "Owned temporary SFTP roundtrip fixture, explicitly authorized for upload.\n");
await writeFile(join(localFixture, "local-child", "child-sentinel.txt"), "Local navigation fixture.\n");
const credential = JSON.parse(await readFile(process.env.ZEROWORK_ACCEPTANCE_CONFIG!, "utf8")).direct;
const remoteHost=credential.host,remotePort=credential.port??22,remoteUser=credential.user??"root";
assert(typeof remoteHost === "string" && remoteHost.length > 0, "Supply an explicit private test endpoint");
assert(Number.isInteger(remotePort)&&remotePort>0&&remotePort<=65535);
const controlledLoopback=remoteHost==="127.0.0.1",peerLabel=controlledLoopback?"Controlled loopback":"Direct VM";
const sshName=peerLabel+" SSH independent owner",sftpName=peerLabel+" SFTP acceptance";
const remoteFixture=process.env.ZEROWORK_ACCEPTANCE_REMOTE_DIR!;
assert(/^\/tmp\/zerowork-unified-[0-9a-f]{16}$/.test(remoteFixture));
const endpoint=`host = ${JSON.stringify(remoteHost)}\nport = ${remotePort}\nuser = ${JSON.stringify(remoteUser)}\n`;
const sshAsset = '\n[[hosts]]\nconnection_id = 2\nrevision = 1\nprotocol = "ssh"\nauth_mode = "password"\noptions = { strict_host_key = true }\nname = '+JSON.stringify(sshName)+'\n'+endpoint;
const fixture = '[registry]\nschema_version = 2\nrevision = 1\nnext_connection_id = 3\nnext_group_id = 1\n\n[[hosts]]\nconnection_id = 1\nrevision = 1\nprotocol = "sftp"\nauth_mode = "password"\noptions = { strict_host_key = true }\nname = '+JSON.stringify(sftpName)+'\n'+endpoint + sshAsset;
await writeFile(join(data, "hosts.toml"), fixture, {mode:0o600});
await writeFile(join(data, "config.toml"), '[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Menlo"\nfont_size = 14\n[ssh]\nauto_reconnect = false\nconnect_timeout_sec = 8\n'+(sftpAi?"\n"+aiConfig.slice(aiSection):""),{mode:0o600});
const report: Record<string, any> = {
  status: prepareOnly ? "prepared_not_run" : "running", started_at: new Date().toISOString(),
  isolated, rpc, data, local_fixture: localFixture, stages: [], actions: [], checks: [], host_key_decisions: [], runtime_traces: [],
  remote: { host: remoteHost, port: remotePort, user: remoteUser, environment: controlledLoopback?"controlled_loopback_paramiko_not_user_vm":"user_vm", protocol: "sftp", operations: ["REALPATH", "LIST", "WRITE owned sentinel", "READ owned sentinel"], writes_authorized: true },
  input: { synthetic: true, method: "public file-RPC Harness click/key/type/resize/scroll", physical_input_verified: false },
  no_pty: { status: "unverified", required: "Actual attached tab fields, both actual directory/transfer ready channel_absent, and the frozen no-shell native SourceFactory path" },
  md5: { requested: md5Requested, status: md5Requested ? "awaiting_real_ui_and_backend_receipts" : "not_requested" },
  sftp_ai: {conversation_mode:continuous?"strict_continuous_same_assistant_conversation":"default_continuous",requested:sftpAi,status:sftpAi?"awaiting_real_provider_readonly_tools":"not_requested",turns:[]},
  limits: ["Real background native Metal pixels with synthetic Harness input; no physical mouse/keyboard/IME claim.",
    "Only this run's temporary files/data/config/RPC and child process are owned by the runner.",
    "The retained SSH tab owns its own real remote shell; per-directory/transfer channel_absent receipts prove SFTP opens no shell.",
    "Only one owned sentinel is uploaded/downloaded in a nonce remote /tmp directory; independent setup/cleanup is recorded separately.",
    "Failure cleanup may signal only this owned PID; successful acceptance requires normal owned window close."],
};
if (prepareOnly) {
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  console.log(`prepared_not_run: ${join(output, "report.json")}`);
  process.exit(0);
}
const sourceBinary = resolve(options["--binary"]), frozenDirectory = join(isolated,"bin");
await mkdir(frozenDirectory);
const binary = join(frozenDirectory, "zerowork-frozen");
await copyFile(sourceBinary, binary);
await copyFile(join(sourceBinary, "..", "zw_ipc.so"), join(frozenDirectory, "zw_ipc.so"));
const binaryHash = createHash("sha256").update(await readFile(binary)).digest("hex");
if (options["--expected-sha"]) assert.equal(binaryHash, options["--expected-sha"], "Use the root's exact integrated binary");
Object.assign(report, { source_binary: sourceBinary, binary, binary_sha256: binaryHash });
const sourceFactoryPath = resolve("src/host/file_route_factory.zig"), sourceFactory = await readFile(sourceFactoryPath, "utf8");
assert(sourceFactory.includes(".open_shell = false"), "The actual file SourceFactory explicitly disables shell opening");
await writeFile(join(output, "file-route-factory-source.zig"), sourceFactory);
report.no_pty.source_factory = { path: sourceFactoryPath, sha256: createHash("sha256").update(sourceFactory).digest("hex"), snapshot: join(output, "file-route-factory-source.zig"), open_shell_false_present: true };
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const appLog = join(output, "app.log"), log = await open(appLog, "w");
const environment = { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", ZEROWORK_FILE_TRACE: "1", ZEROWORK_AI_TOOL_TRACE:sftpAi?"1":"0", OPENAI_API_KEY: "", ANTHROPIC_API_KEY: "" };
delete environment.ZEROWORK_AI_MOCK;
const child = spawn(binary, [], { cwd: process.cwd(), env: environment, stdio: ["ignore", log.fd, log.fd] });
report.pid = child.pid;
const ended = new Promise<void>(done => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", error => { launchError = error; });

function shown(node: any): boolean { return !!node?.rect && node.hidden !== true && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0; }
function flatten(node: any): any[] { return !shown(node) ? [] : [node, ...(node.children ?? []).flatMap(flatten)]; }
function text(node: any): string { return flatten(node).map(node => node.text ?? "").join(""); }
function byId(node: any, id: string): any[] { return flatten(node).filter(item => item.test_id === id); }
async function visible(id: string, timeout = 20000): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null, timeout); }
async function click(id: string): Promise<void> {
  report.actions.push({ type: "click", id, at: new Date().toISOString() });
  const target=await visible(id); assert((await clickAt(target.rect.x+target.rect.w/2,target.rect.y+target.rect.h/2)).ok, `Click ${id}`);
}
async function clickNode(node: any, description: string): Promise<void> {
  report.actions.push({ type: "coordinate_click", description, id: node.id, rect: node.rect });
  assert(shown(node));
  assert((await clickAt(node.rect.x + Math.min(60, node.rect.w / 2), node.rect.y + node.rect.h / 2)).ok, description);
}
async function pane(side: "local" | "remote"): Promise<any> { return visible(`files.${side}`); }
async function tabs(): Promise<any[]> { return flatten(await visible("tabs.strip")).filter(node => /^tabs\.tab\.\d+$/.test(node.test_id ?? "")); }
const evidenceIds = ["workspace.pane", "tabs.strip", "sidebar.host", "sidebar.host.connect", "terminal.surface", "connection.progress", "auth.challenge.modal", "auth.challenge.endpoint", "auth.challenge.fingerprint", "auth.challenge.trust_once", "auth.challenge.status", "plugin.challenge.modal", "plugin.challenge.source", "plugin.challenge.material", "plugin.challenge.answer.0", "plugin.challenge.choice.0", "files.presentation", "files.workspace", "files.local", "files.remote", "files.initial.local.status", "files.initial.remote.status", "files.copy.confirmation", "transfer.confirmation", "transfer.local_directory", "transfer.manager", "transfer.task", "workspace.statusbar", "status.connection.identity", "status.connection.encoding", "status.connection.grid", "status.connection.forward",...(sftpAi?["ai.panel","ai.tool.results","ai.response","ai.composer.model"]:[])];
async function capture(name: string): Promise<void> {
  report.last_capture = name;
  await sleep(120);
  const queries = Object.fromEntries(await Promise.all(evidenceIds.map(async id => [id, await query(id)])));
  const screenshotPath = join(output, `${name}.png`), treePath = join(output, `${name}.tree.json`), queriesPath = join(output, `${name}.queries.json`);
  await writeFile(queriesPath, JSON.stringify(queries, null, 2));
  await writeFile(treePath, JSON.stringify({ tabs: queries["tabs.strip"], files: queries["files.presentation"], authentication: queries["auth.challenge.modal"], confirmation: queries["transfer.confirmation"], manager: queries["transfer.manager"] }, null, 2));
  assert((await screenshot(screenshotPath)).ok, `Capture ${name}`);
  report.stages.push({ name, at: new Date().toISOString(), screenshot: screenshotPath, tree: treePath, queries: queriesPath });
  console.log(`[sftp-native] ${name}`);
}
async function traces(): Promise<any[]> {
  const contents = await readFile(appLog, "utf8"), complete = contents.slice(0, contents.lastIndexOf("\n") + 1);
  const prefixes = ["SFTP_WORKSPACE_TRACE ", "FILE_TRANSFER_READY ", "SFTP_READONLY_READY ", "FILE_TRANSFER_ENQUEUED ", "FILE_TRANSFER_VERIFICATION ", "FILE_TRANSFER_MANAGER_VERIFICATION "];
  return complete.split("\n").flatMap((line, index) => {
    const prefix = prefixes.find(value => line.includes(value));
    return prefix ? [{ ...JSON.parse(line.slice(line.indexOf(prefix) + prefix.length)), trace_prefix: prefix.trim(), log_line: index + 1 }] : [];
  });
}
async function aiTraces():Promise<any[]>{
 const contents=await readFile(appLog,"utf8");return contents.slice(0,contents.lastIndexOf("\n")+1).split("\n").flatMap((line,index)=>{const at=line.indexOf("AI_TOOL_TRACE ");return at<0?[]:[{...JSON.parse(line.slice(at+14)),log_line:index+1}];});
}
async function readonlyAiTurn(tool:"list_remote_files"|"read_remote_file",path:string,expected:string):Promise<void>{
 if(options["--fresh-ai-chat"]==="1"){await click("ai.session.new");await visible("ai.prompt");report.sftp_ai.conversation_mode="fresh_assistant_conversation_per_tool_same_sftp_owner";}
 const owner=(await traces()).find(e=>e.event==="attached").owner.session_id;assert(Number.isInteger(owner));
 const offset=(await aiTraces()).length;
 await click("ai.prompt");await key("a",{cmd:true});
 const toolArguments={session_ids:[owner],path,...(tool==="read_remote_file"?{max_bytes:4096}:{})};
 assert((await type_(`Actually invoke ${tool} exactly once with exact JSON arguments ${JSON.stringify(toolArguments)}. Do not merely acknowledge or guess the file contents. Do not call run_command, read_terminal or any other tool, and do not retry. After receiving the actual tool result, briefly report the returned ${tool==="list_remote_files"?"filename":"text content"}.`)).ok);
 await click("ai.send");
 await waitFor(async()=>{const events=(await aiTraces()).slice(offset);return !(await query("ai.stop")).some(shown)&&events.some(e=>e.event==="wire_request")?events:null;},150000);
 const events=(await aiTraces()).slice(offset),calls=events.filter(e=>e.event==="dynamic_invocation"),dispatch=events.filter(e=>e.event==="dynamic_dispatch"),result=events.filter(e=>e.event==="dynamic_result");
 const currentTurn={tool,path,events,response:(await query("ai.response")).filter(shown).map(text)};
 report.sftp_ai.turns.push(currentTurn);await capture("08-ai-"+tool+"-completed");

 if(continuous){const identities=events.filter(e=>e.event==="request_identity");assert.equal(identities.length,1);const identity=identities[0];assert(Number.isInteger(identity.conversation_id));const prepared=events.find(e=>e.event==="tools_prepared");assert.equal(prepared?.conversation_id,identity.conversation_id);if(report.sftp_ai.turns.length>1){const firstIdentity=report.sftp_ai.turns[0].request_identity;assert.equal(identity.conversation_id,firstIdentity.conversation_id,"Same SFTP assistant conversation across list/read");assert.deepEqual(identity.owner,firstIdentity.owner);assert(identity.turn_id>firstIdentity.turn_id);assert(identity.history_messages>0);}Object.assign(currentTurn,{request_identity:identity});assert(events.some(e=>e.event==="provider_http_response"&&e.status===200));assert(events.some(e=>e.event==="provider_response_finish"));if(calls.length){const finish=events.find(e=>e.event==="provider_response_finish");assert(["tool_calls","stop"].includes(finish.finish_reason));assert(finish.tool_call_deltas>0&&finish.tool_plan_deltas>0);Object.assign(currentTurn,{provider_tool_finish_protocol:finish.finish_reason==="tool_calls"?"tool_calls":"valid_tool_deltas_with_stop"});}const first=events.find(e=>e.event==="wire_request");assert(first);const prior=report.sftp_ai.turns.slice(0,-1).flatMap((t:any)=>t.events.filter((e:any)=>e.event==="dynamic_invocation").map((e:any)=>e.call_id));for(const id of prior){assert(first.tool_use_ids?.includes(id),"Next SFTP turn retains original assistant tool call "+id);assert(first.tool_result_ids?.includes(id),"Next SFTP turn retains original tool result ID "+id);}Object.assign(currentTurn,{continuation:{prior_call_ids:prior,first_wire_request:first}});}

 assert.equal(calls.length,1);assert.equal(calls[0].tool_id,tool);assert.equal(dispatch.length,1);assert.equal(dispatch[0].tool_id,tool);assert.equal(result.length,1);assert.equal(result[0].status,"succeeded");assert.equal(result[0].local_released,true);assert.equal(result[0].remote_effect_unknown,false);assert.equal(result[0].call_id,calls[0].call_id);assert.equal(result[0].operation_id,dispatch[0].operation_id);
 assert(events.some(e=>e.event==="wire_request"&&(e.tool_result_ids??[]).includes(calls[0].call_id)),"Original readonly tool-call ID returns to actual provider");
 for(const event of events.filter(e=>e.event==="wire_request")){assert.deepEqual([...event.tool_names].sort(),["list_remote_files","read_remote_file"].sort(),"SFTP request declares only directory/file-read tools");}
 const disclosure=(await query("ai.tool.result.disclosure")).filter(shown).at(-1);assert(disclosure);await clickNode(disclosure,"Expand actual readonly tool result");
 // Harness deliberately truncates every node.text at 200 characters. Directory
 // metadata precedes entries, so verify complete bytes in the actual serialized
 // tool result already sent back to the provider, plus the rendered card.
 const feedback=events.find(e=>e.event==="tool_feedback"&&e.call_id===calls[0].call_id);assert(feedback,"Actual provider tool feedback is available");
 const body=JSON.parse(feedback.content),target=body.targets?.[0];assert.equal(target.status,"succeeded");
 const resultBlocks=(target.content??[]).filter((block:any)=>block.type==="structured").map((block:any)=>JSON.parse(block.text));
 const returned=resultBlocks.map((block:any)=>block.stdout??"");assert(returned.some((value:string)=>value.includes(expected)),"Actual readonly file binding result contains expected remote bytes, independent of model prose");
 const stdout=(await query("ai.tool.result.stdout")).filter(shown).map(text);assert(stdout.some(value=>value.length>0),"Actual result card renders its output text prefix");
 Object.assign(currentTurn,{returned,card_stdout_prefix:stdout});await capture("08-ai-"+tool);
}
function ptyDescriptors(): string[] {
  const result = execFileSync("/usr/sbin/lsof", ["-nP", "-a", "-p", String(child.pid), "-Ffn"], { encoding: "utf8" });
  let descriptor = "";
  return result.split("\n").flatMap(line => {
    if (line.startsWith("f")) descriptor = line.slice(1);
    return /^n\/dev\/(ttys|ptmx|pty)/.test(line) ? [`${descriptor}:${line.slice(1)}`] : [];
  });
}
async function trustAndAwaitWorkspace(terminal = false,cancelPassword = false): Promise<void> {
  const modalId=sharedChallenge?"plugin.challenge.modal":"auth.challenge.modal";
  const phase=cancelPassword?"cancel":terminal?"ssh":"sftp";
  await waitFor(async()=> (await query("connection.progress")).some(shown)||(await query(modalId)).some(shown)||null,10000);
  const deadline = Date.now() + 90000;
  let decisions = 0;
  while (Date.now() < deadline) {
    const failure = (await query("connection.progress.summary.title")).find(shown);
    if (/失败/.test(text(failure))) throw new Error("ENVIRONMENT_BLOCKED: " + text((await query("connection.progress")).find(shown)));
    const modal = (await query(modalId)).find(shown);
    if(modal&&sharedChallenge){assert.equal((await query(modalId)).length,1,"One shared Presenter exists in this Cx");assert.equal((await query("auth.challenge.modal")).length,0,"Legacy AuthView is absent");report.shared_challenge_presenter={modal_id:modalId,registered_instances:1,legacy_auth_view_instances:0,same_modal_id_as_fixture:true};}
    const trustId=sharedChallenge?"plugin.challenge.choice.0":"auth.challenge.trust_once";
    const trust = (await query(trustId)).find(shown);
    if (modal && trust) {
      assert(++decisions <= 8, "Bound all real host key/password UI decisions");
      const endpoint = text(await visible(sharedChallenge?"plugin.challenge.source":"auth.challenge.endpoint")), fingerprint = text(await visible(sharedChallenge?"plugin.challenge.material":"auth.challenge.fingerprint"));
      assert(endpoint.includes(remoteHost) && endpoint.includes(remoteUser), `Trust only the explicit peer: ${endpoint}`);
      assert(fingerprint.includes("SHA256:"), "Display the actual server fingerprint before trust once");
      await capture(sharedChallenge?`01-${phase}-host-key-${decisions}`:`01-host-key-${decisions}`);
      const boxes = sharedChallenge?[]:flatten(modal).filter(node => /checkbox/i.test(`${node.component ?? ""} ${node.tag ?? ""}`));
      for (const box of boxes) {
        assert((await clickAt(box.rect.x + Math.min(8, box.rect.w / 2), box.rect.y + box.rect.h / 2)).ok);
      }
      report.host_key_decisions.push({ endpoint, fingerprint, choice: "trust_once", checkbox_count: boxes.length, at: new Date().toISOString() });
      if(sharedChallenge)assert(text(trust).includes("仅本次信任"));await click(trustId);
      await sleep(250);
      continue;
    }
    const answerId=sharedChallenge?"plugin.challenge.answer.0":"auth.challenge.answer.0";
    const answer = (await query(answerId)).find(shown);
    if (modal && answer) {
      assert(++decisions <= 8, "Bound authentication UI decisions");
      assert(!/输入小写 yes|替换已保存/.test(text(modal)), "Changed keys are not authorized for replacement");
      if(cancelPassword){
       assert(sharedChallenge);await capture("00-password-cancel-pending");await click("plugin.challenge.cancel");
       await waitFor(async()=>{let zero=false;try{execFileSync("/usr/sbin/lsof",["-nP","-a","-p",String(child.pid),"-iTCP","-Fn"],{stdio:["ignore","pipe","pipe"]});}catch(e:any){if(e.status===1)zero=true;else throw e;}return zero&&!(await query(modalId)).some(shown)||null;},20000);
       assert(child.exitCode===null&&child.signalCode===null);report.authentication_cancel={at:"password_prompt",modal_id:modalId,app_alive:true,zero_tcp:true};await capture("00-authentication-cancelled-released");
       if((await query("connection.progress.close")).some(shown))await click("connection.progress.close");
       const cancelledTabs=(await query("tabs.strip")).flatMap(flatten).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id??""));assert(cancelledTabs.length<=1);
       if(cancelledTabs.length){const cancelled=cancelledTabs[0];report.authentication_cancel.cancelled_tab=cancelled.test_id;await click(cancelled.test_id);await click(cancelled.test_id.replace("tabs.tab.","tabs.close."));await sleep(150);if((await query("session.close.accept")).some(shown))await click("session.close.accept");await waitFor(async()=>!(await query(cancelled.test_id)).some(shown)||null,15000);}
       return;
      }
      await capture(sharedChallenge?`02-${phase}-password-${decisions}`:`02-password-${decisions}`);
      await click(answerId);
      assert((await key("a", { cmd: true })).ok);
      assert((await type_(credential.password)).ok);
      await click(sharedChallenge?"plugin.challenge.submit":"auth.challenge.submit");
      report.actions.push({ type: "password_ui_submit", at: new Date().toISOString() });
      await sleep(250);
      continue;
    }
    if (terminal && !(await query("connection.progress")).some(shown) && (await query("terminal.input")).some(shown)) return;
    if (!terminal && (await query("files.workspace")).some(shown)) {
      await pane("local"); await pane("remote");
      assert(!(await query("connection.progress")).some(shown), "Connection progress exits on actual file-tab attachment");
      return;
    }
    assert(child.exitCode === null && child.signalCode === null, "The owned app is alive while establishing SFTP");
    await sleep(100);
  }
  throw new Error("Real SFTP attachment did not complete within 90s");
}
async function navigate(side: "local" | "remote", path: string): Promise<void> {
  const canonical = side === "local" ? await realpath(path) : path;
  const pathNode = byId(await pane(side), "files.path")[0];
  assert(pathNode, `Actual ${side} path input`);
  await clickNode(pathNode, `${side} path`);
  assert((await key("a", { cmd: true })).ok);
  assert((await type_(path)).ok);
  assert((await key("return")).ok);
  report.actions.push({ type: "navigate", side, requested_path: path, expected_canonical_path: canonical, at: new Date().toISOString() });
  await waitFor(async () => {
    const card = await pane(side), value = byId(card, "files.path")[0];
    if (/正在读取目录/.test(text(card))) return null;
    if (byId(card, "files.error").some(shown)) throw new Error(`${side} LIST failed: ${text(card).slice(-600)}`);
    return value && text(value) === canonical ? card : null;
  }, 30000);
}
function visibleRows(card: any): any[] {
  const clip = byId(card, "files.data_clip")[0];
  assert(clip, "Production file data clip exists");
  return byId(card, "files.row").filter(row => row.rect.y + row.rect.h / 2 > clip.rect.y && row.rect.y + row.rect.h / 2 < clip.rect.y + clip.rect.h);
}
async function findRemoteName(name: string): Promise<any> {
  for (let attempt = 0; attempt < 32; attempt++) {
    const card = await pane("remote"), rows = visibleRows(card);
    const found = rows.find(row => byId(row, "files.row.name").some(item => item.text === name));
    if (found) return found;
    const clip = byId(card, "files.data_clip")[0];
    assert((await scrollAt(clip.rect.x + Math.min(100, clip.rect.w / 2), clip.rect.y + clip.rect.h / 2, 0, -Math.max(100, clip.rect.h - 56))).ok);
    await sleep(80);
  }
  throw new Error(`Actual /etc listing never exposed ${name} in its production virtual list`);
}
let failure: unknown;
try {
 await waitForServerReady();
 assert.equal(Number(JSON.parse(await readFile(join(rpc,"owner.json"),"utf8")).pid),child.pid);
 await resizeWindow(1440,900);
 if(sharedChallenge){
  const cancelledRow=(await query("sidebar.host")).find(n=>shown(n)&&text(n).includes(sshName));assert(cancelledRow);await clickNode(cancelledRow,"Select SSH asset for real authentication cancellation");
  const cancelConnect=byId((await query("sidebar.host")).find(n=>shown(n)&&text(n).includes(sshName)),"sidebar.host.connect")[0];assert(cancelConnect);await clickNode(cancelConnect,"Connect exact SSH row for cancellation");await trustAndAwaitWorkspace(true,true);
  report.checks.push("Real shared password challenge cancellation leaves the same App alive and releases all attempt TCP connections");
 }
 const sshRow = (await query("sidebar.host")).find(n => shown(n) && text(n).includes(sshName));
 assert(sshRow); await clickNode(sshRow,"Select independent SSH asset");
 const sshControl=byId((await query("sidebar.host")).find(n=>shown(n)&&text(n).includes(sshName)),"sidebar.host.connect")[0];assert(sshControl);await clickNode(sshControl,"Connect exact SSH row"); await trustAndAwaitWorkspace(true);
 const sshTab = (await tabs()).at(-1)!; assert(sshTab);
 await click("terminal.input"); await type_("id; test -t 0 && printf 'V021_SSH_%s_OK\\n' OWNER"); await key("return");
 await waitFor(async()=>{const rendered=text((await query("workspace.pane")).find(shown));return rendered.includes(controlledLoopback?"uid=":"uid=0(root)")&&rendered.includes("V021_SSH_OWNER_OK")||null;},15000);
 // The owned loopback fixture records window-change packets but does not apply
 // an OS PTY winsize. Exact stty/status matching is a real-VM acceptance only.
 if(!controlledLoopback){
 const verifyRemoteGrid=async()=>{
  const label=text(await visible("status.connection.grid")),match=label.match(/(\d+)×(\d+)/);assert(match,`Actual SSH status grid: ${label}`);
  const expected=`V021_GRID_${match[2]} ${match[1]}_OK`;
  await click("terminal.input");await type_("printf 'V021_GRID_%s_OK\\n' \"$(stty size)\"");await key("return");
  const rendered=await waitFor(async()=>{const value=text((await query("workspace.pane")).find(shown));return value.includes(expected)?value:null;},15000);
  return {grid:match[0],rows:Number(match[2]),columns:Number(match[1]),expected,rendered};
 };
 const originalGrid=await verifyRemoteGrid();await capture("00-independent-ssh-owner-connected");
 await resizeWindow(1100,720);await waitFor(async()=>text(await visible("status.connection.grid"))!==originalGrid.grid||null,10000);
 const resizedGrid=await verifyRemoteGrid();assert.notEqual(resizedGrid.grid,originalGrid.grid);await capture("00-ssh-remote-pty-resized");
 report.remote_pty={uid_root:!controlledLoopback,tty:true,marker:"V021_SSH_OWNER_OK",before:originalGrid,after:resizedGrid,actual_stty_matches_status:true};
 report.checks.push("Real SSH remote shell returns id/printf through a PTY; native window resize propagates to remote stty size and matches status grid");
 await resizeWindow(1440,900);await waitFor(async()=>text(await visible("status.connection.grid")).includes(originalGrid.grid)||null,10000);
 }else await capture("00-independent-ssh-owner-connected");
 const initialSockets = execFileSync("/usr/sbin/lsof",["-nP","-a","-p",String(child.pid),"-iTCP","-Fn"],{encoding:"utf8"}).split("\n").filter(s=>s.startsWith("n"));
 const sftpRow = (await query("sidebar.host")).find(n => shown(n) && text(n).includes(sftpName));
 assert(sftpRow); await clickNode(sftpRow,"Select separate SFTP asset");
 const sftpControl=byId((await query("sidebar.host")).find(n=>shown(n)&&text(n).includes(sftpName)),"sidebar.host.connect")[0];assert(sftpControl);await clickNode(sftpControl,"Connect exact SFTP row"); await trustAndAwaitWorkspace();
 const twoOwnerSockets = execFileSync("/usr/sbin/lsof",["-nP","-a","-p",String(child.pid),"-iTCP","-Fn"],{encoding:"utf8"}).split("\n").filter(s=>s.startsWith("n"));
 assert(twoOwnerSockets.length > initialSockets.length,"Independent SFTP owner opens additional TCP connection while SSH remains alive");
 const owners = await tabs(); assert.equal(owners.length,2); report.independent_owners={ssh_tab:sshTab.test_id,sftp_tab:owners.find(t=>t.test_id!==sshTab.test_id)!.test_id,ssh_sockets:initialSockets,both_sockets:twoOwnerSockets};
 await capture("03-sftp-connected");
 await navigate("local",localFixture); await navigate("remote",remoteFixture);
 await capture("04-owned-directories");
 const sourceBytes = await readFile(join(localFixture,localFilename));
 const localRow = visibleRows(await pane("local")).find(row=>byId(row,"files.row.name").some(n=>n.text===localFilename));
 assert(localRow); await clickNode(localRow,"Select owned upload sentinel");
 const upload=byId(await pane("local"),"files.transfer")[0]; assert(upload); await clickNode(upload,"Upload owned sentinel");
 await visible("files.copy.confirmation"); await capture("05-upload-confirmation"); await clickNode(await visible("files.copy.submit"),"Confirm captured cross-card transfer");
 await waitFor(async()=> !(await query("files.copy.confirmation")).some(shown) || null,10000);
 await waitFor(async()=> {await navigate("remote",remoteFixture);return visibleRows(await pane("remote")).find(row=>byId(row,"files.row.name").some(n=>n.text===localFilename)) ?? null;},30000);
 await capture("06-upload-present-remote");
 // Close the original SSH owner before downloading from the independent SFTP owner.
 await click(sshTab.test_id);
 await click(sshTab.test_id.replace("tabs.tab.","tabs.close."));
 await sleep(200);
 if ((await query("session.close.accept")).some(shown)) await click("session.close.accept");
 await waitFor(async()=>!(await query(sshTab.test_id)).some(shown)||null,20000);
 assert.equal((await tabs()).length,1); await navigate("remote",remoteFixture);
 assert(visibleRows(await pane("remote")).some(row=>byId(row,"files.row.name").some(n=>n.text===localFilename)));
 report.checks.push("Original SSH owner closed while independent SFTP directory remains readable");
 await capture("06b-ssh-closed-sftp-still-live");
 const downloadedDir=join(localFixture,"download-target"); await mkdir(downloadedDir);
 await navigate("local",downloadedDir);
 const row=visibleRows(await pane("remote")).find(row=>byId(row,"files.row.name").some(n=>n.text===localFilename)); assert(row);
 await clickNode(row,"Select uploaded remote sentinel");
 const download=byId(await pane("remote"),"files.transfer")[0];assert(download);await clickNode(download,"Download uploaded sentinel");
 await visible("files.copy.confirmation");await capture("07-download-confirmation");await clickNode(await visible("files.copy.submit"),"Confirm captured cross-card transfer");
 const downloaded=await waitFor(async()=>{try{return await readFile(join(downloadedDir,localFilename));}catch(e){if(e.code==='ENOENT')return null;throw e;}},30000);
 assert.deepEqual(downloaded,sourceBytes);
 await click("toolbar.transfers");await capture("08-roundtrip-completed");
 await key("escape");await key("escape");
 if(sftpAi){
  await click("toolbar.ai");await visible("ai.prompt");
  await readonlyAiTurn("list_remote_files",remoteFixture,localFilename);
  await readonlyAiTurn("read_remote_file",remoteFixture+"/"+localFilename,sourceBytes.toString("utf8").trim());
  assert(!(await query("terminal.input")).some(shown));report.sftp_ai.status="passed";
  report.checks.push("Actual SFTP-only assistant declares exactly list_remote_files/read_remote_file, dispatches each readonly tool once through original file bindings, and renders the remote 74B sentinel after original SSH closes");
  await key("escape");
 }
 const fileTab=(await tabs()).find(n=>/^tabs\.tab\.\d+$/.test(n.test_id??""));assert(fileTab);await click(fileTab.test_id.replace("tabs.tab.","tabs.close."));
 await waitFor(async()=>{try{execFileSync("/usr/sbin/lsof",["-nP","-a","-p",String(child.pid),"-iTCP","-Fn"],{stdio:["ignore","pipe","pipe"]});return null;}catch(e:any){if(e.status===1)return !(await query(fileTab.test_id)).some(shown)||null;throw e;}},30000);
 assert(child.exitCode===null&&child.signalCode===null);report.socket_release={app_alive:true,sockets:[]};await capture("09-file-tab-closed-and-released");
 if(sharedChallenge){let savedKeys="";try{savedKeys=await readFile(join(data,"known_hosts"),"utf8");}catch(e:any){if(e.code!=="ENOENT")throw e;}assert.equal(savedKeys,"");report.trust_once_store={isolated_store_unchanged:true,bytes:0};}
 const liveTraces=await traces();
 const attached=liveTraces.find(e=>e.trace_prefix==="SFTP_WORKSPACE_TRACE"&&e.event==="attached");
 assert(attached&&attached.terminal_present===false&&attached.runtime_present===false,"Actual SFTP tab has no terminal/runtime placeholder");
 const directoryReady=liveTraces.filter(e=>e.trace_prefix==="SFTP_READONLY_READY");
 const transferReady=liveTraces.filter(e=>e.trace_prefix==="FILE_TRANSFER_READY");
 assert(directoryReady.length&&transferReady.length&&[...directoryReady,...transferReady].every(e=>e.channel_absent===true),"Actual directory and transfer transports open no shell channel");
 const jobs=liveTraces.filter(e=>e.trace_prefix==="FILE_TRANSFER_ENQUEUED");
 assert.equal(jobs.length,2);assert(jobs.every(e=>e.owner_id===attached.owner.session_id&&e.owner_generation===attached.owner.generation));
 const closed=liveTraces.filter(e=>e.trace_prefix==="SFTP_WORKSPACE_TRACE"&&e.event==="closed");
 assert.equal(closed.length,1);assert.deepEqual(closed[0].owner,attached.owner);assert.equal(closed[0].cleanup,"released");
 report.no_pty={...report.no_pty,status:"passed",attached,directory_ready:directoryReady,transfer_ready:transferReady};
 report.owner_receipts={attached,jobs,closed};
 report.roundtrip={remote_directory:remoteFixture,filename:localFilename,bytes:sourceBytes.length,sha256:createHash("sha256").update(downloaded).digest("hex"),equal:true};
 report.checks.push("Real SFTP password and host-key UI establish file workspace","Actual local and remote panes list owned directories","Product upload transfers owned file to unique remote /tmp directory","Product download returns uploaded bytes into separate local directory and content matches exactly");
 const windows=await request("POST","/zerowork/windows",{action:"snapshot"});assert.equal(windows.windows.length,1);assert((await request("POST","/zerowork/windows",{action:"close",window:windows.windows[0].window})).ok);await Promise.race([ended,sleep(10000)]);assert.equal(child.exitCode,0);assert.equal(child.signalCode,null);report.normal_app_close=true;
 report.status="passed";
} catch(error) {
 failure=launchError??error;report.status=String(failure).includes("ENVIRONMENT_BLOCKED:") ? "environment_blocked" : "failed";report.error=String(failure);
 if(report.status === "environment_blocked") {
  const socketListing = execFileSync("/usr/sbin/lsof",["-nP","-a","-p",String(child.pid),"-Ffn"],{encoding:"utf8"});
  report.network_failure_receipt={text:text((await query("connection.progress")).find(shown)),app_alive:child.exitCode===null,zero_tcp:!socketListing.includes("->")};
  if(!report.network_failure_receipt.zero_tcp||!/释放/.test(report.network_failure_receipt.text)) {
   report.status="failed";failure=new Error("Real network failure did not release owned resources");report.error=String(failure);
  }
 }
 try {await capture("failure-live");}catch(e){report.capture_error=String(e);}
} finally {
 try {report.runtime_traces=await traces();}catch(e){}
 if(child.exitCode===null&&child.signalCode===null) child.kill("SIGTERM");
 await Promise.race([ended,sleep(2000)]);
 if(child.exitCode===null&&child.signalCode===null){child.kill("SIGKILL");await ended;}
 report.process_cleanup={exit_code:child.exitCode,signal:child.signalCode};
 await log.close();await rm(isolated,{recursive:true,force:true});
 report.finished_at=new Date().toISOString();
 const secretValues = [credential.password,...aiSecrets].filter(Boolean);
 await writeFile(appLog,secretValues.reduce((s,v)=>s.replaceAll(v,"[REDACTED]"),await readFile(appLog,"utf8")));
 await writeFile(join(output,"report.json"),JSON.stringify(report,null,2));
}
console.log(`${report.status}: ${join(output,"report.json")}`);
if(failure){if(report.status==="environment_blocked")process.exitCode=2;else throw failure;}
