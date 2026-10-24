/** Real MiMo streaming in an isolated background main application.
 * Network/provider stays real; all input uses the public synthetic Harness.
 * Copy the binary at startup so concurrent builds cannot change the run.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, open, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { waitForServerReady, waitFor, tree, query, clickTestId, inputState, key, type_, resizeWindow, screenshot, sleep } from "../zig-out/share/zenit/harness/client.ts";

const args = process.argv.slice(2), options: Record<string, string> = {};
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--out", "--config"].includes(args[i]) && args[i + 1], `Invalid argument ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--out"], "--out is required");
const output = resolve(options["--out"]), sourceBinary = resolve(options["--binary"] ?? "zig-out/bin/zerowork");
const configPath = resolve(options["--config"] ?? "/tmp/zerowork-mimo-native-20261020.toml");
const isolated = await mkdtemp(join(tmpdir(), "zerowork-ai-stream-ui-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data)]);
const binary = join(output, "zerowork-frozen");
await copyFile(sourceBinary, binary);
const binaryHash = createHash("sha256").update(await readFile(binary)).digest("hex");
// Credentials are read directly into the isolated config and never logged.
await copyFile(configPath, join(data, "config.toml"));
const environment = { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0" };
delete environment.ZEROWORK_AI_MOCK;
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(output, "app.log"), "w");
const child = spawn(binary, [], { cwd: process.cwd(), env: environment, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>(done => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", error => { launchError = error; });
const marker = "STREAM_NATIVE_20261020_BEGIN", sentinel = "STREAM_NATIVE_20261020_OK";
const longPrompt = `Begin your reply exactly with ${marker}. Then print the integers from 1 to 1000 separated by spaces. No explanation. Use no tools and execute no commands.`;
const shortPrompt = `Reply with exactly this token and nothing else: ${sentinel}`;
const report: Record<string, any> = {
  status: "running", started_at: new Date().toISOString(), source_binary: sourceBinary, binary, binary_sha256: binaryHash,
  config_source: configPath, pid: child.pid, isolated, stages: [], growth_samples: [], checks: [],
  limits: ["Background Metal-window screenshots and synthetic Harness events do not establish physical input/IME correctness.",
    "Harness text serialization is capped at 200 bytes per node; rendered text bounds provide continued growth evidence beyond that prefix.",
    "This run proves real plain-text incremental rendering, not Markdown rendering.",
    "Own-process SIGTERM cleanup is not normal application close lifecycle evidence."],
};
function shown(node: any): boolean { return !!node?.rect && node.hidden !== true && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0; }
function flatten(node: any, inherited = true): any[] {
  if (!node || typeof node !== "object" || !inherited || node.hidden === true || node.visible === false || (node.effective_opacity ?? 1) <= 0) return [];
  return [node, ...(node.children ?? []).flatMap((child: any) => flatten(child, true))];
}
function nodeText(node: any): string { return flatten(node).map(n => n.text ?? "").join(""); }
async function visible(id: string, timeout = 20000): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null, timeout); }
async function click(id: string): Promise<void> {
  report.last_action = { kind: "click", id, at: new Date().toISOString() };
  await visible(id);
  assert((await clickTestId(id)).ok, `Click ${id}`);
}
async function assistantTree(): Promise<any> {
  const panel = (await query("ai.panel")).find(shown);
  if (panel) return panel;
  const current: any = await tree();
  assert(!current.error, `Cannot inspect current AI UI: ${current.error}; use the scoped ai.panel test ID`);
  return current;
}
async function capture(name: string, sampledTree?: any): Promise<void> {
  const path = join(output, `${name}.png`);
  assert((await screenshot(path)).ok);
  report.last_screenshot = path;
  const current = sampledTree ?? await assistantTree();
  await writeFile(join(output, `${name}.tree.json`), JSON.stringify(current, null, 2));
  const queries = Object.fromEntries(await Promise.all(["ai.prompt", "ai.send", "ai.stop", "ai.float.drag", "tabs.strip", "local.statusbar"].map(async id => [id, await query(id)])));
  await writeFile(join(output, `${name}.queries.json`), JSON.stringify(queries, null, 2));
  report.stages.push({ name, at: new Date().toISOString(), screenshot: path, tree: join(output, `${name}.tree.json`) });
}
async function submit(prompt: string): Promise<void> {
  await click("ai.prompt");
  assert((await key("a", { cmd: true })).ok);
  assert((await type_(prompt)).ok);
  assert.equal((await inputState("ai.prompt")).buffer, prompt);
  await click("ai.send");
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
  await capture("00-ai-ready");
  await submit(longPrompt);
  const stop = await visible("ai.stop");
  assert.equal(nodeText(stop).trim(), "", "Stop must be an icon button without visible label text");
  report.stop_icon_only = true;
  await capture("01-request-in-flight");
  const started = Date.now();
  let last: any;
  while (report.growth_samples.length < 3 && Date.now() - started < 120000) {
    const current = await assistantTree();
    const nodes = flatten(current);
    const response = nodes.find(n => shown(n) && n.tag === "text" && (n.text ?? "").startsWith(marker));
    const stopVisible = nodes.some(n => n.test_id === "ai.stop" && shown(n));
    const busy = nodes.filter(n => n.tag === "text" && /请求中/.test(n.text ?? "")).map(n => n.text);
    if (response && stopVisible && busy.length > 0) {
      const sample = { at: new Date().toISOString(), elapsed_ms: Date.now() - started, node_id: response.id,
        serialized_prefix: response.text, prefix_length: response.text.length, rect: response.rect, stop_visible: stopVisible, request_labels: busy };
      if (!last || (sample.node_id === last.node_id && sample.prefix_length >= last.prefix_length &&
        (sample.prefix_length > last.prefix_length || sample.rect.h > last.rect.h + 0.5))) {
        report.growth_samples.push(sample);
        last = sample;
        await capture(`02-stream-growth-${report.growth_samples.length}`, current);
      }
    }
    if (!stopVisible) throw new Error(`Long request ended before three live-growth samples; current labels: ${nodes.filter(n => n.tag === "text").map(n => n.text).join(" | ").slice(0, 600)}`);
    await sleep(50);
  }
  assert.equal(report.growth_samples.length, 3, "Need three actual live samples and two strict growth transitions before completion");
  report.checks.push("One actual response text Node grows in three samples while Stop and request-in-flight labels remain visible");
  await click("ai.stop");
  await waitFor(async () => {
    const nodes = flatten(await assistantTree());
    return !nodes.some(n => n.test_id === "ai.stop" && shown(n)) && nodes.some(n => /AI 已停止/.test(n.text ?? "")) || null;
  }, 20000);
  await capture("03-stopped-partial-response");
  report.checks.push("Real Stop finishes through cancellation and preserves partial response without an error state");
  await submit(shortPrompt);
  await visible("ai.stop");
  const shortStarted = Date.now();
  const final = await waitFor(async () => {
    const current = await assistantTree();
    const nodes = flatten(current);
    const response = nodes.find(n => shown(n) && n.tag === "text" && (n.text ?? "").trim() === sentinel);
    return response && !nodes.some(n => n.test_id === "ai.stop" && shown(n)) ? { current, response } : null;
  }, 90000);
  report.followup = { elapsed_ms: Date.now() - shortStarted, node_id: final.response.id, text: final.response.text };
  await capture("04-followup-sentinel-complete", final.current);
  report.checks.push("A new real MiMo request after Stop returns the exact short sentinel and ends the in-flight state");
  report.status = "passed";
} catch (error) {
  failure = launchError ?? error;
  report.status = "failed"; report.error = String(failure);
  report.failure_evidence = { process_exit_code: child.exitCode, process_signal: child.signalCode };
  if (child.exitCode === null && child.signalCode === null) {
    try { await capture("failure-live"); } catch (captureError) { report.failure_evidence.capture_error = String(captureError); }
  }
} finally {
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
  await Promise.race([ended, sleep(2000)]);
  if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await ended; }
  report.process_cleanup = { exit_code: child.exitCode, signal: child.signalCode };
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  await log.close();
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
