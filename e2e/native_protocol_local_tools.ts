/** Real native Anthropic/Ollama -> production Local approval/tool feedback.
 * Uses a private background app and public synthetic file-RPC input.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, open, readFile, writeFile, chmod, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { waitForServerReady, waitFor, query, clickTestId, inputState, key, type_, resizeWindow, screenshot, sleep } from "../zig-out/share/zenit/harness/client.ts";

const args = process.argv.slice(2), options: Record<string, string> = {};
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--out", "--config"].includes(args[i]) && args[i + 1]);
  options[args[i]] = args[i + 1];
}
assert(options["--binary"] && options["--out"] && options["--config"]);
const output = resolve(options["--out"]), source = resolve(options["--binary"]), configPath = resolve(options["--config"]);
const config = await readFile(configPath, "utf8");
const kind = config.match(/^kind\s*=\s*"([^"]+)"/m)?.[1];
assert(kind === "anthropic" || kind === "ollama");
assert(config.includes('permission_mode = "confirm"'));
assert(config.includes('reasoning = false') && config.includes('efforts = []'));
const isolated = await mkdtemp(join(tmpdir(), `zerowork-native-${kind}-`));
const rpc = join(isolated, "rpc"), data = join(isolated, "data"), binary = join(output, "zerowork-frozen");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data)]);
await copyFile(source, binary);
await copyFile(join(dirname(source), "zw_ipc.so"), join(output, "zw_ipc.so"));
await copyFile(configPath, join(data, "config.toml"));
await chmod(join(data, "config.toml"), 0o600);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const environment = { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", ZEROWORK_AI_TOOL_TRACE: "1" };
delete environment.ZEROWORK_AI_MOCK;
const log = await open(join(output, "app.log"), "w");
const child = spawn(binary, [], { cwd: process.cwd(), env: environment, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>(done => child.once("close", () => done()));
const marker = `NATIVE_${kind.toUpperCase()}_${child.pid}_OK`;
const rejectedMarker = `NATIVE_${kind.toUpperCase()}_${child.pid}_REJECTED`;
const approvedCommand = `printf '${marker}\\n'`, rejectedCommand = `printf 'DENIED_${child.pid}\\n'`;
const report: Record<string, any> = {
  status: "running", started_at: new Date().toISOString(), binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"),
  source_binary: source, isolated, pid: child.pid,
  provider: { kind, real: true, endpoint: config.match(/^endpoint\s*=\s*"([^"]+)"/m)?.[1], mock_enabled: false },
  local: { real: true, authorized_commands: [approvedCommand], rejected_commands: [rejectedCommand] }, stages: [], cases: [],
  limits: ["Real background native Metal window; approval input is synthetic Harness input, not physical user input.", "Only two targeted user turns per protocol; provider continuations use actual tool results.", "Own-process SIGTERM is cleanup, not proof of normal window-close lifecycle."],
};
function shown(n: any): boolean { return !!n?.rect && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect.w > 0 && n.rect.h > 0; }
function flatten(n: any): any[] { return !shown(n) ? [] : [n, ...(n.children ?? []).flatMap(flatten)]; }
function text(n: any): string { return flatten(n).map(n => n.text ?? "").join(""); }
async function visible(id: string, timeout = 20000): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null, timeout); }
async function click(id: string): Promise<void> { report.last_action = id; await visible(id); assert((await clickTestId(id)).ok); }
async function busy(): Promise<boolean> { return (await query("ai.stop")).some(shown); }
async function traces(): Promise<any[]> {
  const contents = await readFile(join(output, "app.log"), "utf8");
  return contents.slice(0, contents.lastIndexOf("\n") + 1).split("\n").flatMap((line, index) => {
    const at = line.indexOf("AI_TOOL_TRACE ");
    return at < 0 ? [] : [{ ...JSON.parse(line.slice(at + "AI_TOOL_TRACE ".length)), log_line: index + 1 }];
  });
}
async function capture(name: string): Promise<void> {
  const path = join(output, `${name}.png`);
  assert((await screenshot(path)).ok);
  const current = await visible("ai.panel");
  await writeFile(join(output, `${name}.tree.json`), JSON.stringify(current, null, 2));
  report.stages.push({ name, screenshot: path, tree: join(output, `${name}.tree.json`) });
  console.log(`[native-${kind}] ${name}`);
}
async function submit(prompt: string): Promise<void> {
  await click("ai.prompt"); assert((await key("a", { cmd: true })).ok); assert((await type_(prompt)).ok);
  assert.equal((await inputState("ai.prompt")).buffer, prompt); await click("ai.send");
}
async function runCase(approved: boolean): Promise<void> {
  const command = approved ? approvedCommand : rejectedCommand;
  const final = approved ? marker : rejectedMarker;
  const offset = (await traces()).length;
  const prompt = approved
    ? `Call run_command exactly once for the current assistant_session_id with command exactly: ${command}. Do not call any other tool or command. Wait for its actual tool result and then reply with its exact stdout token only.`
    : `Call run_command exactly once for the current assistant_session_id with command exactly: ${command}. Do not call any other tool or command. If the host rejects it, do not retry or execute another command. After the actual tool result, reply only ${final}.`;
  await submit(prompt);
  const received = await waitFor(async () => (await traces()).slice(offset).find(e => e.event === "host_received" && e.command === command) ?? null, 150000);
  assert.equal(received.verdict, "need_confirm");
  await visible("ai.approval");
  assert.equal(text(await visible("ai.approval.command")), command);
  const before = (await traces()).slice(offset);
  assert(!before.some(e => ["exec_started", "host_result", "tool_feedback"].includes(e.event)), "Pending approval has zero execution/results");
  await capture(approved ? "01-approve-pending-zero-exec" : "03-reject-pending-zero-exec");
  await click(approved ? "ai.approval.accept" : "ai.approval.reject");
  await waitFor(async () => {
    if (await busy()) return null;
    const answer = flatten(await visible("ai.panel")).find(n => n.tag === "text" && (n.text ?? "").trim() === final);
    return answer ?? null;
  }, 150000);
  const events = (await traces()).slice(offset), own = events.filter(e => e.call_id === received.call_id && (e.turn_id === undefined || e.turn_id === received.turn_id));
  const decisions = own.filter(e => e.event === "approval_decision"), starts = own.filter(e => e.event === "exec_started"), feedback = own.find(e => e.event === "tool_feedback");
  assert.equal(decisions.length, 1); assert.equal(decisions[0].approved, approved);
  assert(feedback, "Original tool feedback exists");
  const body = JSON.parse(feedback.content);
  if (approved) {
    assert.equal(starts.length, 1);
    const result = own.find(e => e.event === "host_result");
    assert(result && result.result.transport === "local");
    assert.equal(result.result.stdout, `${marker}\n`); assert.equal(result.result.exit, 0); assert.equal(result.result.local_released, true);
    assert.equal(body.targets.length, 1);
    for (const field of ["session_id", "status", "transport", "stdout", "stderr", "exit", "local_released"]) assert.deepEqual(body.targets[0][field], result.result[field]);
    assert(decisions[0].log_line < starts[0].log_line && starts[0].log_line < result.log_line && result.log_line < feedback.log_line);
  } else {
    assert.equal(starts.length, 0, "Rejected invocation never starts a Local process");
    const result = own.find(e => e.event === "host_result");
    assert(result && result.result.status === "rejected");
    assert.equal(result.result.exit, null);
    assert.equal(result.result.local_released, true);
    assert.equal(body.targets.length, 1);
    assert.equal(body.targets[0].status, "rejected");
    assert.equal(body.targets[0].exit, null);
  }
  assert.equal(events.filter(e => e.event === "host_received").length, 1, "No extra tool calls or repeated dispatch");
  const wires = events.filter(e => e.event === "wire_request");
  assert(wires.some(e => e.tool_names.includes("run_command")), "Native wire declares actual tool schema");
  assert(wires.some(e => e.tool_result_ids.includes(received.call_id)), "Native wire carries original result correlation");
  report.cases.push({ approved, command, received, decisions, starts, feedback, events, final_answer: final });
  await capture(approved ? "02-approved-real-output-final-answer" : "04-rejected-zero-exec-final-answer");
}
let failure: unknown;
try {
  await waitForServerReady();
  const owner = JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")); assert.equal(Number(owner.pid), child.pid);
  assert((await resizeWindow(1440, 900)).ok);
  await click("workspace.empty.local"); await visible("terminal.surface"); await click("toolbar.ai"); await visible("ai.prompt");
  await capture("00-local-native-provider-ready");
  await runCase(true); await runCase(false);
  report.status = "passed";
} catch (error) {
  failure = error; report.status = "failed"; report.error = String(error);
  if (child.exitCode === null && child.signalCode === null) try { await capture("failure-live"); } catch {}
} finally {
  try { await writeFile(join(output, "tool-trace.json"), JSON.stringify(await traces(), null, 2)); } catch {}
  if (child.exitCode === null && child.signalCode === null) {
    try { if (await busy()) { await click("ai.stop"); await waitFor(async () => !(await busy()) || null, 15000); } } catch {}
    child.kill("SIGTERM");
  }
  await Promise.race([ended, sleep(2000)]);
  if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await ended; }
  report.process_cleanup = { exit_code: child.exitCode, signal: child.signalCode };
  await rm(isolated, { recursive: true, force: true });
  report.private_data_and_rpc_removed = true;
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  await log.close();
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
