/** Native transcript tail-follow regression with an isolated app and loopback provider.
 * Build with -Dtest-mode=true, then run with --binary <prefix>/bin/zerowork --out <dir>.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { createServer, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const options: Record<string, string> = {}, args = process.argv.slice(2);
for (let index = 0; index < args.length; index += 2) {
  assert(["--binary", "--out"].includes(args[index]) && args[index + 1], `Invalid argument ${args[index]}`);
  options[args[index]] = args[index + 1];
}
assert(options["--out"], "--out is required");
const output = resolve(options["--out"]), binary = resolve(options["--binary"] ?? "zig-out/bin/zerowork");
const { waitForServerReady, waitFor, query, request, clickAt, clickTestId, inputState, key, type_, resizeWindow, screenshot, scrollAt, sleep } =
  await import(join(dirname(binary), "../share/zenit/harness/client.ts"));
const isolated = await realpath(await mkdtemp(join(tmpdir(), "zerowork-ai-tail-native-")));
const rpc = join(isolated, "rpc"), data = join(isolated, "data"), zdot = join(isolated, "zdot");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data), mkdir(zdot)]);
await writeFile(join(zdot, ".zshrc"), "PS1='tail-follow-test%# '\n");

const prompts = [
  Array.from({ length: 26 }, (_, index) => `History line ${index + 1}: enough content to scroll the transcript.`).join("\n"),
  "Send after reading history",
  "Send after opening details",
];
const replyMarker = (round: number) => `Tail follow reply ${round}`;
function answer(round: number): string {
  const marker = replyMarker(round);
  // Leave room above the second answer to open its disclosures without scrolling.
  return round === 2 ? `${marker}. ${"This response provides several wrapped lines of conversation. ".repeat(9).trimEnd()}` : marker;
}
const reasoning = "Reasoning detail from the second turn.\n".repeat(20).trimEnd();
const frame = (delta: Record<string, string>) => `data: ${JSON.stringify({ choices: [{ index: 0, delta }] })}\n\n`;
const done = "data: [DONE]\n\n";
const requests: number[] = [];
const pending = new Map<number, ServerResponse>();
let fixtureError: unknown;
const server = createServer(async (req, res) => {
  try {
    if (req.method === "GET") return res.end(JSON.stringify({ data: [{ id: "tail-follow-fixture" }] }));
    let raw = "";
    for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw);
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    if (body.messages[0]?.content?.startsWith("将用户的问题概括")) {
      return res.end(frame({ content: "Transcript scroll regression" }) + done);
    }
    const user = body.messages.findLast((message: any) => message.role === "user");
    const round = prompts.indexOf(user?.content) + 1;
    assert(round > 0 && !requests.includes(round), `Unexpected fixture request for turn ${round}`);
    requests.push(round);
    if (round === 1) return res.end(frame({ content: answer(round) }) + done);
    res.flushHeaders();
    pending.set(round, res);
  } catch (error) {
    fixtureError = error;
    res.end();
  }
});
await new Promise<void>(ready => server.listen(0, "127.0.0.1", ready));
const address = server.address();
assert(address && typeof address !== "string");
await writeFile(join(data, "config.toml"), `[meta]
config_revision = 1
[ui]
theme = "dark"
[ai]
default_provider = "tail-follow-fixture"
permission_mode = "confirm"
step_display = "collapsed"
[[ai.providers]]
id = "tail-follow-fixture"
kind = "openai_compat"
endpoint = "http://127.0.0.1:${address.port}/v1/chat/completions"
enabled = true
[[ai.providers.models]]
name = "tail-follow-fixture"
context_window = 200000
default = true
reasoning = true
`);
const environment: NodeJS.ProcessEnv = {
  ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1", ZEROWORK_DATA_DIR: data,
  ZEROWORK_AUTOCONNECT: "0", ZEROWORK_AI_TOOL_TRACE: "1", ZDOTDIR: zdot, OPENAI_API_KEY: "", ANTHROPIC_API_KEY: "",
};
for (const name of ["ZEROWORK_AI_MOCK", "ZEROWORK_AI_ENDPOINT", "ZEROWORK_AI_MODEL", "ZEROWORK_AI_PROVIDER"]) delete environment[name];
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const appLog = join(output, "app.log");
const log = await open(appLog, "w");
const child = spawn(binary, [], { cwd: process.cwd(), env: environment, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>(done => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", error => { launchError = error; });
const report: Record<string, any> = {
  status: "running", started_at: new Date().toISOString(), binary,
  binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"), pid: child.pid,
  provider: { loopback: true, transcript_requests: requests },
  stages: [], checks: [],
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
  const scrolls = path.filter(node => node.tag === "scroll" || node.component === "ScrollArea");
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
    if (fixtureError) throw fixtureError;
    if ((await query("ai.stop")).some(shown)) return null;
    const current = await panel();
    const nodes = flatten(current);
    const latest = nodes.find(node => node.text?.startsWith(replyMarker(round)));
    if (!latest) return null;
    const projection = project(current, latest);
    report.last_projection = projection;
    if (!atTail(projection)) return null;
    for (let previous = 1; previous < round; previous++) {
      assert(nodes.some(node => node.text?.startsWith(replyMarker(previous))), `Reply ${previous} remains in the transcript`);
    }
    return { current, projection };
  }, 15000);
}
function atTail(projection: ReturnType<typeof project>): boolean {
  const scroll = projection.scroll_ancestors[0];
  return projection.fully_visible && scroll.overflow > 200 && Math.abs(scroll.scroll_offset_from_geometry - scroll.overflow) <= 1;
}
async function capture(name: string, current?: any): Promise<void> {
  await sleep(100);
  const screenshotPath = join(output, `${name}.png`);
  assert((await screenshot(screenshotPath)).ok);
  await writeFile(join(output, `${name}.tree.json`), JSON.stringify(current ?? await panel(), null, 2));
  report.stages.push({ name, at: new Date().toISOString(), screenshot: screenshotPath, tree: join(output, `${name}.tree.json`) });
  console.log(`[ai-tail] ${name}`);
}
const retainedReplies = new Map<number, number>();
let retainedDetail: number | null = null;
async function submit(round: number): Promise<void> {
  const prompt = prompts[round - 1];
  await click("ai.prompt");
  assert((await key("a", { cmd: true })).ok);
  assert((await type_(prompt)).ok);
  assert.equal((await inputState("ai.prompt")).buffer, prompt);
  const before = flatten(await panel());
  for (let previous = 1; previous < round; previous++) {
    const reply = before.find(node => node.text?.startsWith(replyMarker(previous)));
    assert(reply, `Reply ${previous} exists before Enter`);
    retainedReplies.set(previous, reply.id);
  }
  retainedDetail = before.find(node => node.test_id === "ai.step.detail" && node.text?.startsWith("Reasoning detail"))?.id ?? null;
  assert((await key("return")).ok);
}
async function sentBeforeReply(round: number, stage: string): Promise<void> {
  await waitFor(() => pending.get(round) ?? null, 10000);
  const sent = await waitFor(async () => {
    const current = await panel();
    const message = flatten(current).find(node => node.test_id === "ai.message.user.text" && node.text === prompts[round - 1]);
    if (!message) return null;
    report.last_projection = project(current, message);
    return atTail(report.last_projection) ? current : null;
  }, 5000);
  const nodes = flatten(sent);
  for (const [previous, id] of retainedReplies) {
    assert.equal(nodes.find(node => node.text?.startsWith(replyMarker(previous)))?.id, id,
      `Enter preserves the actual reply ${previous} node, including current-to-history archival`);
  }
  if (retainedDetail !== null) {
    assert(nodes.some(node => node.id === retainedDetail), "Enter retains the expanded reasoning body");
  }
  report.checks.push(`Turn ${round}: Enter retains all completed reply nodes and expanded reasoning bodies`);
  await capture(stage, sent);
  const response = pending.get(round)!;
  pending.delete(round);
  response.end((round === 2 ? frame({ reasoning_content: reasoning }) : "") + frame({ content: answer(round) }) + done);
}
async function clickTranscriptNode(id: string): Promise<void> {
  const node = await waitFor(async () => {
    const current = await panel();
    const target = flatten(current).filter(node => node.test_id === id).at(-1);
    return target && project(current, target).fully_visible ? target : null;
  }, 5000);
  const { x, y, w, h } = node.rect;
  assert((await clickAt(x + w / 2, y + h / 2)).ok, `Click ${id}`);
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
  await submit(1);
  const first = await latestVisible(1);
  await capture("01-first-overflow-answer-visible", first.current);
  viewport = { x: 0, y: 0, w: 860, h: 480 };
  assert((await resizeWindow(viewport.w, viewport.h)).ok);
  const resized = await latestVisible(1);
  report.after_resize = resized.projection;
  const { x, y, w, h } = resized.projection.scroll_ancestors[0].viewport;
  assert((await scrollAt(x + w - 12, y + h / 2, 0, 200)).ok);
  await waitFor(async () => {
    const current = await panel();
    const reply = flatten(current).find(node => node.text?.startsWith(replyMarker(1)));
    report.after_scroll = project(current, reply);
    return report.after_scroll.intersection.h === 0 ? current : null;
  }, 5000);
  await capture("02-reading-history");
  await submit(2);
  await sentBeforeReply(2, "03-message-visible-after-reading-history");
  const second = await latestVisible(2);
  report.after_history_send = second.projection;
  report.checks.push("After scrolling into history, the sent message is visible before the provider replies and the reply stays at the tail");

  // Completed turns may fold their process. Open the latest turn without wheel input.
  if (flatten(second.current).some(node => node.test_id === "ai.turn.process.toggle")) {
    await clickTranscriptNode("ai.turn.process.toggle");
  }
  await clickTranscriptNode("ai.step_group.header");
  await clickTranscriptNode("ai.step.header");
  await waitFor(async () => {
    const current = await panel();
    const nodes = flatten(current);
    const detail = nodes.find(node => node.test_id === "ai.step.detail" && node.text?.startsWith("Reasoning detail"));
    if (!detail || project(current, detail).intersection.h < 1) return null;
    report.after_disclosure = project(current, nodes.find(node => node.text?.startsWith(replyMarker(2))));
    return report.after_disclosure.intersection.h === 0 ? current : null;
  }, 5000);
  await capture("04-expanded-reasoning-detail");
  await submit(3);
  await sentBeforeReply(3, "05-message-visible-after-expanding-details");
  const third = await latestVisible(3);
  report.after_detail_send = third.projection;
  await capture("06-latest-reply-visible", third.current);
  report.checks.push("After expanding reasoning details without wheel input, the sent message and reply automatically return to the tail");

  assert.deepEqual(requests, [1, 2, 3]);
  const contents = await readFile(appLog, "utf8");
  assert(!/AI_TOOL_TRACE .*"event":"(?:exec_started|host_received|terminal_read)"/.test(contents), "The fixture must not dispatch tools");
  assert((await request("POST", "/zerowork/windows", { action: "quit" })).ok);
  await waitFor(async () => {
    if (child.exitCode !== null || child.signalCode !== null) return true;
    const confirmation = await Promise.race([query("local.close.accept"), ended.then(() => [])]);
    if (child.exitCode === null && child.signalCode === null && confirmation.some(shown)) {
      assert((await clickTestId("local.close.accept")).ok);
    }
    return null;
  }, 15000);
  assert.equal(child.exitCode, 0, "The isolated app must quit normally");
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
  server.closeAllConnections();
  await new Promise<void>(closed => server.close(() => closed()));
  await log.close();
  await rm(isolated, { recursive: true, force: true });
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
