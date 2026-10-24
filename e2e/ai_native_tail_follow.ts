/** Native conversation tail-follow regression. Explicit production mock mode,
 * no external provider or SSH requests, isolated background main application.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, open, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, clickTestId, inputState, key, type_, resizeWindow, screenshot, sleep } from "../zig-out/share/zenit/harness/client.ts";

const options: Record<string, string> = {}, args = process.argv.slice(2);
for (let index = 0; index < args.length; index += 2) {
  assert(["--binary", "--out"].includes(args[index]) && args[index + 1], `Invalid argument ${args[index]}`);
  options[args[index]] = args[index + 1];
}
assert(options["--out"], "--out is required");
const output = resolve(options["--out"]), sourceBinary = resolve(options["--binary"] ?? "zig-out/bin/zerowork");
const isolated = await mkdtemp(join(tmpdir(), "zerowork-ai-tail-native-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data)]);
const binary = join(output, "zerowork-frozen"), appLog = join(output, "app.log");
await copyFile(sourceBinary, binary);
await writeFile(join(data, "config.toml"), '[meta]\nconfig_revision = 1\n[ui]\ntheme = "dark"\nfont_family = "Menlo"\nfont_size = 14\n[ai]\npermission_mode = "confirm"\n');
const environment = {
  ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1", ZEROWORK_DATA_DIR: data,
  ZEROWORK_AUTOCONNECT: "0", ZEROWORK_AI_MOCK: "1", ZEROWORK_AI_TOOL_TRACE: "1", ZEROWORK_AI_PROVIDER: "openai_compat",
  ZEROWORK_AI_ENDPOINT: "http://127.0.0.1:9/v1/chat/completions", ZEROWORK_AI_MODEL: "mock", OPENAI_API_KEY: "", ANTHROPIC_API_KEY: "",
};
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(appLog, "w");
const child = spawn(binary, [], { cwd: process.cwd(), env: environment, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>(done => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", error => { launchError = error; });
const report: Record<string, any> = {
  status: "running", started_at: new Date().toISOString(), source_binary: sourceBinary, binary,
  binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"), isolated, pid: child.pid,
  provider: { real: false, mock_enabled: true, expected_response: "AI provider response", network_requests: 0, remote_ssh_requests: 0 },
  native_window: { real: true, background_isolated: true }, input: { synthetic: true, method: "public file-RPC Harness" },
  stages: [], rounds: [], checks: [],
  limits: ["The provider is intentionally mocked; this verifies native scrolling and layout, not live transport.", "No SSH session or tool execution is requested.", "No wheel input or programmatic scroll is sent by the runner; visibility must result from production tail-follow.", "Own-process SIGTERM is not normal application close lifecycle evidence."],
};
type Rect = { x: number; y: number; w: number; h: number };
let viewport: Rect = { x: 0, y: 0, w: 1440, h: 900 };
function shown(node: any): boolean { return !!node?.rect && node.hidden !== true && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0; }
function flatten(node: any): any[] { return !shown(node) ? [] : [node, ...(node.children ?? []).flatMap(flatten)]; }
async function visible(id: string): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null, 20000); }
async function click(id: string): Promise<void> { report.last_action = { id, at: new Date().toISOString() }; await visible(id); assert((await clickTestId(id)).ok, `Click ${id}`); }
async function panel(): Promise<any> { return visible("ai.panel"); }
function intersect(a: Rect, b: Rect): Rect {
  const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
  return { x, y, w: Math.max(0, Math.min(a.x + a.w, b.x + b.w) - x), h: Math.max(0, Math.min(a.y + a.h, b.y + b.h) - y) };
}
function pathTo(root: any, id: number): any[] | null {
  if (root.id === id) return [root];
  for (const child of root.children ?? []) { const path = pathTo(child, id); if (path) return [root, ...path]; }
  return null;
}
function project(root: any, answer: any): any {
  const path = pathTo(root, answer.id) ?? [];
  const scrolls = path.filter(node => node.component === "ScrollArea");
  assert(scrolls.length > 0, "Answer must be measured within its actual ScrollArea ancestors");
  const clips = [viewport, root.rect, ...scrolls.map(node => node.rect)];
  const clip = clips.reduce(intersect);
  const visiblePart = intersect(answer.rect, clip);
  const fullyVisible = visiblePart.w >= answer.rect.w - 0.5 && visiblePart.h >= answer.rect.h - 0.5;
  return {
    id: answer.id, text: answer.text, rect: answer.rect, effective_clip: clip, intersection: visiblePart, fully_visible: fullyVisible,
    scroll_ancestors: scrolls.map(node => ({ id: node.id, viewport: node.rect, content: node.children?.[0]?.rect,
      overflow: (node.children?.[0]?.rect.h ?? 0) - node.rect.h, scroll_offset_from_geometry: node.rect.y - (node.children?.[0]?.rect.y ?? node.rect.y) })),
  };
}
async function latestVisible(round: number): Promise<any> {
  return waitFor(async () => {
    if ((await query("ai.stop")).some(shown)) return null;
    const current = await panel();
    const answers = flatten(current).filter(node => node.tag === "text" && node.text === "AI provider response");
    if (answers.length < round) return null;
    const projection = project(current, answers.at(-1));
    report.last_projection = projection;
    if (!projection.fully_visible) return null;
    assert(projection.scroll_ancestors.some(scroll => scroll.overflow > 200), "Long prompts must create real history overflow");
    assert(projection.scroll_ancestors.some(scroll => scroll.scroll_offset_from_geometry > 100), "Native content must actually move; a shown node alone is insufficient");
    return { current, answers: answers.length, projection };
  }, 15000);
}
async function capture(name: string, current?: any): Promise<void> {
  await sleep(100);
  const screenshotPath = join(output, `${name}.png`);
  assert((await screenshot(screenshotPath)).ok);
  await writeFile(join(output, `${name}.tree.json`), JSON.stringify(current ?? await panel(), null, 2));
  report.stages.push({ name, at: new Date().toISOString(), screenshot: screenshotPath, tree: join(output, `${name}.tree.json`) });
  console.log(`[ai-tail] ${name}`);
}
function longPrompt(round: number): string {
  return `TAIL_FOLLOW_ROUND_${round}\n` + Array.from({ length: 26 }, (_, index) => `History overflow line ${String(index + 1).padStart(2, "0")}: verify the newest answer remains visible after layout.`).join("\n") + "\nReturn the default mock reply only. Do not use tools.";
}
async function submit(round: number): Promise<void> {
  const prompt = longPrompt(round);
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
  assert.equal(Number(owner.pid), child.pid, "Address only this isolated process");
  assert((await resizeWindow(viewport.w, viewport.h)).ok);
  await click("workspace.empty.local");
  await visible("terminal.surface");
  await click("toolbar.ai");
  await visible("ai.prompt");
  await capture("00-native-mock-ready");
  await submit(1);
  const first = await latestVisible(1);
  report.rounds.push({ round: 1, answers: first.answers, projection: first.projection });
  await capture("01-first-overflow-answer-visible", first.current);
  report.checks.push("First long prompt creates actual scroll overflow; latest short mock answer is fully inside the intersection of window, panel and every ancestor ScrollArea");
  viewport = { x: 0, y: 0, w: 860, h: 480 };
  assert((await resizeWindow(viewport.w, viewport.h)).ok);
  const resized = await latestVisible(1);
  report.after_resize = resized.projection;
  await capture("02-first-answer-visible-after-resize", resized.current);
  await submit(2);
  const second = await latestVisible(2);
  report.rounds.push({ round: 2, answers: second.answers, projection: second.projection });
  await capture("03-second-overflow-answer-visible", second.current);
  report.checks.push("After compact resize and a second long prompt, both replies remain in history and the newest reply automatically returns fully into the real clipped viewport");
  const contents = await readFile(appLog, "utf8");
  assert(!/AI_TOOL_TRACE .*"event":"(?:wire_request|exec_started|host_received|terminal_read)"/.test(contents), "No provider HTTP serialization or tool dispatch in explicit mock regression");
  report.trace_check = { wire_requests: 0, exec_starts: 0, tool_calls: 0 };
  report.status = "passed";
} catch (error) {
  failure = launchError ?? error;
  report.status = "failed"; report.error = String(failure);
  report.failure_evidence = { process_exit_code: child.exitCode, process_signal: child.signalCode };
  if (child.exitCode === null && child.signalCode === null) try { await capture("failure-live"); } catch (captureError) { report.failure_evidence.capture_error = String(captureError); }
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
