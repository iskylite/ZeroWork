/** Real MiMo -> production Local tools -> original tool-result feedback.
 * Uses an isolated background main application and public synthetic Harness
 * input. The opt-in production trace establishes actual Local process results;
 * model prose alone is never execution evidence. Full mode sends two user
 * turns; --phase approval reuses a verified readonly proof to avoid repeating
 * an already observed df request. --diagnose-prepare 1 uses no-network mock.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, open, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, clickTestId, inputState, key, type_, resizeWindow, screenshot, sleep } from "../zig-out/share/zenit/harness/client.ts";

const options: Record<string, string> = {}, args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--out", "--config", "--diagnose-prepare", "--phase", "--readonly-evidence"].includes(args[i]) && args[i + 1], `Invalid argument ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--out"], "--out is required");
assert(options["--diagnose-prepare"] === undefined || options["--diagnose-prepare"] === "1", "Only explicit --diagnose-prepare 1 enables the no-network mock diagnosis");
const diagnosePrepare = options["--diagnose-prepare"] === "1";
const phase = options["--phase"] ?? "all";
assert(phase === "all" || phase === "approval", "--phase must be all or approval");
assert(!diagnosePrepare || phase === "all", "Prepare-only diagnostic is separate from real approval");
const readonlyEvidencePath = options["--readonly-evidence"] ? resolve(options["--readonly-evidence"]) : null;
assert(phase !== "approval" || readonlyEvidencePath, "Approval-only avoids another df request and requires its existing real evidence");
const readonlyEvidence = readonlyEvidencePath ? JSON.parse(await readFile(readonlyEvidencePath, "utf8")) : null;
if (phase === "approval") {
  assert.equal(readonlyEvidence.status, "passed");
  assert.equal(readonlyEvidence.provider_real, true);
  assert.equal(readonlyEvidence.local_real, true);
  assert.equal(readonlyEvidence.received.command, "df -h");
}
const output = resolve(options["--out"]), sourceBinary = resolve(options["--binary"] ?? "zig-out/bin/zerowork");
const configPath = resolve(options["--config"] ?? "/tmp/zerowork-mimo-native-20261020.toml");
const config = await readFile(configPath, "utf8");
assert(config.includes('kind = "openai_compat"') && config.includes('name = "mimo-v2.6-flash"'), "Use the configured real MiMo provider");
assert(config.includes('permission_mode = "confirm"'), "Keep production confirm policy; readonly df is automatically classified");
const isolated = await mkdtemp(join(tmpdir(), "zerowork-ai-tools-ui-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data"), appLog = join(output, "app.log");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data)]);
const binary = join(output, "zerowork-frozen");
await copyFile(sourceBinary, binary);
await copyFile(configPath, join(data, "config.toml"));
const environment = { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", ZEROWORK_AI_TOOL_TRACE: "1" };
if (diagnosePrepare) environment.ZEROWORK_AI_MOCK = "1"; else delete environment.ZEROWORK_AI_MOCK;
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(appLog, "w");
const child = spawn(binary, [], { cwd: process.cwd(), env: environment, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>(done => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", error => { launchError = error; });
const marker = `ZEROWORK_TOOL_APPROVAL_20261020_${child.pid}_OK`;
const readonlyCommand = "df -h", confirmedCommand = `printf '${marker}\\n'`;
const readonlyPrompt = "Call run_command exactly once for the current assistant_session_id with command exactly df -h. Do not call read_terminal or any other tool. After receiving its actual tool result, reply in two short lines: first DF_READONLY_DONE, then one actual filesystem and mount point from stdout. Do not just suggest a command.";
const confirmPrompt = `Call run_command exactly once for the current assistant_session_id with command exactly: ${confirmedCommand}. Do not call read_terminal or any other command. Wait for the real tool result, then reply with its stdout token only. Do not merely print or predict the token before execution.`;
const report: Record<string, any> = {
  status: "running", started_at: new Date().toISOString(), source_binary: sourceBinary, binary,
  binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"), config_source: configPath,
  isolated, pid: child.pid, stages: [], checks: [], pending_samples: [], visual_findings: [],
  phase, readonly_evidence_external: readonlyEvidencePath ? { path: readonlyEvidencePath, proof: readonlyEvidence, note: "Previously observed real df run; no df request is repeated in this process" } : undefined,
  diagnostic_prepare_only: diagnosePrepare,
  provider: { real: !diagnosePrepare, kind: "openai_compat", model: "mimo-v2.6-flash", endpoint: config.match(/^endpoint\s*=\s*"([^"]+)"/m)?.[1], mock_enabled: diagnosePrepare },
  local: { real: true, executed_by_this_diagnostic: diagnosePrepare ? false : undefined, commands_authorized: [readonlyCommand, confirmedCommand], execution_evidence: "Opt-in AI_TOOL_TRACE from actual LocalAdapter startExec/execSnapshot and original tool feedback, correlated by sequence/turn/call/owner" },
  input: { synthetic: true, method: "public file-RPC Harness clickTestId/key/type_/resizeWindow", physical_mouse_keyboard_ime_verified: false },
  limits: ["Background Metal-window screenshots are real pixels; input and approval clicks are synthetic, not physical user acceptance.", "Own-process SIGTERM cleanup is not normal application-close lifecycle evidence.", "Two user turns may each make an initial provider request and a tool-feedback continuation; no standalone probe requests are made.", "Only the known df -h and exact safe printf call may be approved; unexpected approval commands fail the run."],
  figma: { file: "ZeroWork · 交互原型", file_key: "session-mvgeqdxp-kmw89t", node: "401:1871715", read_via_local_bridge: true, card: { width: 560, height: 152, header: 32, body: 73, footer: 38, icon_buttons: 26 }, reference: resolve("exports/20261020-ai-local-approval-reference.png") },
};
function shown(node: any): boolean { return !!node?.rect && node.hidden !== true && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0; }
function flatten(node: any): any[] {
  if (!node || !shown(node)) return [];
  return [node, ...(node.children ?? []).flatMap(flatten)];
}
function text(node: any): string { return flatten(node).map(n => n.text ?? "").join(""); }
async function visible(id: string, timeout = 20000): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null, timeout); }
async function click(id: string): Promise<void> {
  report.last_action = { id, at: new Date().toISOString() };
  await visible(id);
  assert((await clickTestId(id)).ok, `Click ${id}`);
}
async function panel(): Promise<any> { return visible("ai.panel"); }
async function busy(): Promise<boolean> { return (await query("ai.stop")).some(shown); }
async function traces(): Promise<any[]> {
  const contents = await readFile(appLog, "utf8");
  // Only complete log lines: a concurrent stderr write can be observed midway.
  return contents.slice(0, contents.lastIndexOf("\n") + 1).split("\n").flatMap((line, lineIndex) => {
    const markerIndex = line.indexOf("AI_TOOL_TRACE ");
    if (markerIndex < 0) return [];
    return [{ ...JSON.parse(line.slice(markerIndex + "AI_TOOL_TRACE ".length)), log_line: lineIndex + 1 }];
  });
}
function sameCall(event: any, received: any): boolean { return event.call_id === received.call_id && (event.turn_id === undefined || event.turn_id === received.turn_id); }
async function capture(name: string): Promise<void> {
  await sleep(100);
  const path = join(output, `${name}.png`);
  assert((await screenshot(path)).ok);
  const current = await panel();
  await writeFile(join(output, `${name}.tree.json`), JSON.stringify(current, null, 2));
  const projection = Object.fromEntries(await Promise.all(["ai.panel", "ai.prompt", "ai.send", "ai.stop", "ai.approval", "ai.approval.target", "ai.approval.command", "ai.approval.disclosure", "ai.approval.accept", "ai.approval.reject", "ai.composer.model", "local.statusbar", "terminal.surface"].map(async id => [id, await query(id)])));
  await writeFile(join(output, `${name}.queries.json`), JSON.stringify(projection, null, 2));
  report.stages.push({ name, at: new Date().toISOString(), screenshot: path, tree: join(output, `${name}.tree.json`) });
  console.log(`[ai-tools] ${name}`);
}
async function submit(prompt: string, requireBusy = true): Promise<void> {
  await click("ai.prompt");
  assert((await key("a", { cmd: true })).ok);
  assert((await type_(prompt)).ok);
  assert.equal((await inputState("ai.prompt")).buffer, prompt);
  await click("ai.send");
  if (requireBusy) await visible("ai.stop");
}
async function receivedCall(command: string): Promise<any> {
  const deadline = Date.now() + 90000;
  while (Date.now() < deadline) {
    const events = await traces();
    const received = events.filter(e => e.event === "host_received" && e.command === command);
    assert(received.length <= 1, `Duplicate actual dispatch of ${command}`);
    if (received.length) return received[0];
    if (!(await busy())) throw new Error(`Provider completed without the required actual run_command dispatch: ${text(await panel()).slice(-500)}`);
    await sleep(100);
  }
  throw new Error("Actual run_command dispatch did not arrive within 90 seconds");
}
function finalAnswerNode(current: any, prefix: string): any | null {
  // Tool rounds can retain a preamble or an empty initial text card. Locate
  // the real rendered answer by its requested prefix across all text nodes.
  return flatten(current).filter(n => n.tag === "text" && (n.text ?? "").trim().startsWith(prefix)).at(-1) ?? null;
}
async function completedCall(received: any, answerPrefix: string): Promise<{ result: any; feedback: any; answer: string; events: any[] }> {
  return waitFor(async () => {
    const events = await traces(), own = events.filter(e => sameCall(e, received));
    const result = own.find(e => e.event === "host_result"), feedback = own.find(e => e.event === "tool_feedback");
    if (!result || !feedback || await busy()) return null;
    assert.equal(result.result.transport, "local");
    assert.equal(result.result.status, "succeeded");
    assert.equal(result.result.exit, 0);
    assert.equal(result.result.local_released, true);
    assert.equal(result.result.session_id, received.owner.session);
    const encoded = JSON.parse(feedback.content);
    assert.equal(encoded.targets.length, 1);
    for (const field of ["session_id", "status", "transport", "stdout", "stderr", "exit", "local_released"]) assert.deepEqual(encoded.targets[0][field], result.result[field], `Original feedback preserves actual ${field}`);
    assert(result.log_line < feedback.log_line, "Actual Local result precedes the original tool message trace");
    const response = finalAnswerNode(await panel(), answerPrefix);
    if (!response) return null;
    return { result, feedback, answer: response.text, answer_node_id: response.id, events };
  }, 90000);
}
function inside(inner: any, outer: any): boolean { return inner.x >= outer.x - 0.5 && inner.y >= outer.y - 0.5 && inner.x + inner.w <= outer.x + outer.w + 0.5 && inner.y + inner.h <= outer.y + outer.h + 0.5; }
async function approvalGeometry(stage: string): Promise<void> {
  const approval = await visible("ai.approval"), accept = await visible("ai.approval.accept"), reject = await visible("ai.approval.reject"), prompt = await visible("ai.prompt");
  const card = (approval.children ?? []).find(shown), currentPanel = await panel();
  const geometry = { stage, approval: approval.rect, card: card?.rect, accept: accept.rect, reject: reject.rect, prompt: prompt.rect, panel: currentPanel.rect, accept_icon_only: text(accept).trim() === "", reject_icon_only: text(reject).trim() === "" };
  assert(card && Math.abs(card.rect.h - 152) < 0.6, "Actual expanded approval keeps its 152px card");
  for (const button of [accept, reject]) {
    assert(Math.abs(button.rect.w - 26) < 0.6 && Math.abs(button.rect.h - 26) < 0.6, "Actual decision buttons are 26px");
    assert.equal(text(button).trim(), "", "Decision controls have icons rather than visible annotation labels");
    assert(inside(button.rect, currentPanel.rect), "Decision remains reachable inside the real AI panel");
    assert(button.rect.y + button.rect.h <= prompt.rect.y + 0.5, "Fixed decisions stay above composer input");
  }
  if (Math.abs(card.rect.w - 560) > 0.6) report.visual_findings.push({ stage, kind: "prototype_width_difference", actual_card_width: card.rect.w, prototype_card_width: 560, note: "Recorded actual geometry; screenshot review required rather than claiming pixel parity" });
  const body = (await query("ai.approval.details")).find(shown);
  const impact = flatten(approval).find(n => (n.text ?? "").startsWith("影响"));
  if (body && impact) {
    const clipped = impact.rect.y + impact.rect.h - body.rect.y - body.rect.h;
    if (clipped > 0.5) report.visual_findings.push({ stage, kind: "impact_initially_clipped_in_scroll_body", clipped_px: clipped, body: body.rect, impact: impact.rect, note: "Default viewport clips the impact line; this records the initial scroll position, not whether later scrolling can reveal it" });
  }
  report.approval_geometry ??= [];
  report.approval_geometry.push(geometry);
}
let failure: unknown;
try {
  await waitForServerReady();
  const owner = JSON.parse(await readFile(join(rpc, "owner.json"), "utf8"));
  assert.equal(Number(owner.pid), child.pid, "Only this isolated process may receive input");
  assert((await resizeWindow(1440, 900)).ok);
  await click("workspace.empty.local");
  await visible("terminal.surface");
  await click("toolbar.ai");
  await visible("ai.prompt");
  assert(text(await visible("ai.composer.model")).includes("mimo-v2.6"), "UI resolves the configured actual model");
  await capture("00-local-ai-ready");
  report.initial_trace_count = (await traces()).length;
  assert.equal(report.initial_trace_count, 0, "No tool invocation before the actual request");

  if (diagnosePrepare) {
    await submit("Prepare-only diagnostic. Reply with one word and do not call any tools.", false);
    const prepared = await waitFor(async () => (await traces()).find(e => e.event === "tools_prepared") ?? null, 15000);
    await waitFor(async () => !(await busy()) || null, 15000);
    report.prepare_diagnostic = { prepared, unavailable: (await traces()).filter(e => e.event === "tools_unavailable"), network_requests: 0, tool_exec_starts: (await traces()).filter(e => e.event === "exec_started").length };
    assert.equal(report.prepare_diagnostic.tool_exec_starts, 0);
    await capture("01-mock-prepare-diagnostic");
    report.status = "diagnostic-completed";
  } else {
  if (phase === "all") {
  await submit(readonlyPrompt);
  const prepared = await waitFor(async () => (await traces()).find(e => e.event === "tools_prepared") ?? null, 15000);
  assert.equal(prepared.tools_count, 2, `Actual Local capability preparation: ${JSON.stringify(await traces())}`);
  report.real_prepare = prepared;
  await capture("00-readonly-real-request-in-flight");
  const df = await receivedCall(readonlyCommand);
  assert.equal(df.verdict, "allow_auto");
  assert(!(await query("ai.approval")).some(shown), "Readonly call needs no approval card");
  const dfDone = await completedCall(df, "DF_READONLY_DONE");
  assert.match(dfDone.result.result.stdout, /Filesystem/);
  assert.match(dfDone.result.result.stdout, /\/dev\//);
  assert.match(dfDone.answer, /DF_READONLY_DONE/);
  assert(!dfDone.events.some(e => sameCall(e, df) && e.event === "approval_decision"));
  const dfStart = dfDone.events.filter(e => sameCall(e, df) && e.event === "exec_started");
  assert.equal(dfStart.length, 1, "Exactly one actual readonly exec start");
  assert(df.log_line < dfStart[0].log_line && dfStart[0].log_line < dfDone.result.log_line);
  report.readonly = { received: df, started: dfStart[0], actual_result: dfDone.result, original_feedback: dfDone.feedback, final_answer: dfDone.answer, approval_clicks: 0 };
  await writeFile(join(output, "df-stdout.txt"), dfDone.result.result.stdout);
  await capture("01-readonly-actual-tool-result");
  report.checks.push("Real MiMo requested exact df -h; readonly policy auto-started one real Local exec, actual stdout/exit/released fed back under the original call ID, then the model answered");

  }
  await submit(confirmPrompt);
  const approvalPrepared = await waitFor(async () => (await traces()).filter(e => e.event === "tools_prepared").at(-1) ?? null, 15000);
  assert.equal(approvalPrepared.tools_count, 2);
  report.approval_prepare = approvalPrepared;
  const pending = await receivedCall(confirmedCommand);
  assert.equal(pending.verdict, "need_confirm");
  await visible("ai.approval");
  assert.equal(text(await visible("ai.approval.command")), confirmedCommand, "Approval presents the complete exact safe command");
  assert(text(await visible("ai.approval.target")).includes(`#${pending.owner.session}`), "Approval target is the captured Local owner");
  for (let index = 0; index < 3; index++) {
    const own = (await traces()).filter(e => sameCall(e, pending));
    assert(!own.some(e => ["exec_started", "host_result", "tool_feedback", "approval_decision"].includes(e.event)), "Pending approval must have zero actual execution or result feedback");
    assert((await query("ai.approval.accept")).some(shown));
    report.pending_samples.push({ at: new Date().toISOString(), call_id: pending.call_id, sequence: pending.sequence, exec_started: 0, host_results: 0, tool_feedback: 0 });
    await sleep(500);
  }
  await approvalGeometry("default");
  await capture("02-approval-pending-zero-exec");
  assert((await resizeWindow(860, 480)).ok);
  await sleep(200);
  await approvalGeometry("compact");
  await capture("03-approval-compact-still-pending");
  const beforeApproval = (await traces()).filter(e => sameCall(e, pending));
  assert(!beforeApproval.some(e => e.event === "exec_started"));
  report.approval_click = { at: new Date().toISOString(), test_id: "ai.approval.accept", call_id: pending.call_id, sequence: pending.sequence, command_verified: confirmedCommand };
  await click("ai.approval.accept");
  const approved = await completedCall(pending, marker);
  assert.equal(approved.result.result.stdout, `${marker}\n`);
  assert.equal(approved.answer.trim(), marker);
  const own = approved.events.filter(e => sameCall(e, pending));
  const decisions = own.filter(e => e.event === "approval_decision"), starts = own.filter(e => e.event === "exec_started");
  assert.equal(decisions.length, 1);
  assert.equal(decisions[0].approved, true);
  assert.equal(decisions[0].sequence, pending.sequence);
  assert.equal(starts.length, 1);
  assert.equal(starts[0].sequence, pending.sequence);
  assert(pending.log_line < decisions[0].log_line && decisions[0].log_line < starts[0].log_line && starts[0].log_line < approved.result.log_line && approved.result.log_line < approved.feedback.log_line);
  assert(!(await query("ai.approval")).some(shown), "Completed approval card disappears");
  report.confirmed = { received: pending, decision: decisions[0], started: starts[0], actual_result: approved.result, original_feedback: approved.feedback, final_answer: approved.answer };
  await writeFile(join(output, "printf-stdout.txt"), approved.result.result.stdout);
  await capture("04-approved-real-output-and-model-feedback");
  const all = await traces();
  const expectedCalls = phase === "approval" ? 1 : 2;
  assert.equal(all.filter(e => e.event === "host_received").length, expectedCalls, "Only the planned tool invocations, without hidden extras");
  assert.equal(all.filter(e => e.event === "exec_started").length, expectedCalls, "Only the planned actual exec starts");
  report.wire_requests = all.filter(e => e.event === "wire_request");
  if (report.wire_requests.length) {
    assert(report.wire_requests[0].tool_names.includes("run_command"), "Actual serialized initial body declares run_command");
    assert(report.wire_requests.some(e => e.tool_result_ids.includes(pending.call_id)), "Actual serialized continuation carries the original confirmed call ID");
  }
  report.checks.push("Need-confirm printf stayed unexecuted in three pending samples and after compact resize; only the original approval icon started its actual Local process, whose exact output/exit/released was fed to the original call and answered by real MiMo");
  report.status = "passed";
  }
} catch (error) {
  failure = launchError ?? error;
  report.status = "failed";
  report.error = String(failure);
  report.failure_evidence = { process_exit_code: child.exitCode, process_signal: child.signalCode };
  if (child.exitCode === null && child.signalCode === null) {
    try { await capture("failure-live"); } catch (captureError) { report.failure_evidence.capture_error = String(captureError); }
  }
} finally {
  try { await writeFile(join(output, "tool-trace.json"), JSON.stringify(await traces(), null, 2)); } catch (error) { report.trace_capture_error = String(error); }
  if (child.exitCode === null && child.signalCode === null) {
    try { if (await busy()) { await click("ai.stop"); await waitFor(async () => !(await busy()) || null, 15000); } } catch (error) { report.stop_cleanup_error = String(error); }
    child.kill("SIGTERM");
  }
  await Promise.race([ended, sleep(2000)]);
  if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await ended; }
  report.process_cleanup = { exit_code: child.exitCode, signal: child.signalCode };
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  await log.close();
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
