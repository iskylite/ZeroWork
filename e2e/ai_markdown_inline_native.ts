/** Production AI Markdown acceptance. Build with -Dtest-mode=true, then run
 * node e2e/ai_markdown_inline_native.ts --binary <prefix>/bin/zerowork --out <dir>.
 * Uses a private data directory and loopback provider; no real API or tools.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const options: Record<string, string> = {}, args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--out"].includes(args[i]) && args[i + 1], `Invalid argument ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--out"], "--out is required");
const output = resolve(options["--out"]), binary = resolve(options["--binary"] ?? "zig-out/bin/zerowork");
const { waitForServerReady, waitFor, query, request, clickTestId, type_, resizeWindow, screenshot, sleep } =
  await import(join(dirname(binary), "../share/zenit/harness/client.ts"));
const isolated = await realpath(await mkdtemp(join(tmpdir(), "zerowork-inline-native-")));
const rpc = join(isolated, "rpc"), data = join(isolated, "data"), zdot = join(isolated, "zdot");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data), mkdir(zdot)]);
await writeFile(join(zdot, ".zshrc"), "PS1='inline-test%# '\n");
const prompt = "检查嵌套 Markdown 显示";
const answer = [
  "**1. `tuned` 已改为 `hpc-compute`**",
  "**2. 关键说明：保留 *斜体* 和 `sysctl_config`**",
  "*3. 斜体内的 **加粗** 与 `inline_code`*",
  "[**链接内的 `config`**](https://example.com/a_(b))",
  "**表达式 `a**b` 的说明**",
  "状态是 `EXECUTE_UPDATE_PASSED`，文件 `/etc/selinux/config`。",
  "```text\n**literal** `code`\n```",
].join("\n\n");
const expected = [
  "1. tuned 已改为 hpc-compute", "2. 关键说明：保留 斜体 和 sysctl_config",
  "3. 斜体内的 加粗 与 inline_code", "链接内的 config", "表达式 a**b 的说明",
  "状态是 EXECUTE_UPDATE_PASSED，文件 /etc/selinux/config。", "**literal** `code`",
];
const frame = (text: string) => `data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: text } }] })}\n\n`;
let requestCount = 0, fixtureError: unknown;
const server = createServer(async (req, res) => {
  try {
    if (req.method === "GET") return res.end(JSON.stringify({ data: [{ id: "inline-fixture" }] }));
    let raw = "";
    for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw);
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    if (body.messages[0]?.content?.startsWith("将用户的问题概括")) return res.end(frame("Markdown 显示验证") + "data: [DONE]\n\n");
    assert.equal(body.messages.findLast((message: any) => message.role === "user")?.content, prompt);
    assert.equal(++requestCount, 1, "Only one fixture conversation request");
    // Exercise the same retained tail before and after a bold closer arrives.
    const split = answer.indexOf("**\n\n");
    res.write(frame(answer.slice(0, split)));
    await sleep(150);
    res.end(frame(answer.slice(split)) + "data: [DONE]\n\n");
  } catch (error) { fixtureError = error; res.end(); }
});
await new Promise<void>(ready => server.listen(0, "127.0.0.1", ready));
const address = server.address();
assert(address && typeof address !== "string");
await writeFile(join(data, "config.toml"), `[meta]
config_revision = 1
[ui]
theme = "dark"
[ai]
default_provider = "inline-fixture"
permission_mode = "confirm"
[[ai.providers]]
id = "inline-fixture"
kind = "openai_compat"
endpoint = "http://127.0.0.1:${address.port}/v1/chat/completions"
enabled = true
[[ai.providers.models]]
name = "inline-fixture"
context_window = 200000
default = true
`);
const environment: NodeJS.ProcessEnv = {
  ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1",
  ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", ZDOTDIR: zdot, OPENAI_API_KEY: "", ANTHROPIC_API_KEY: "",
};
for (const name of ["ZEROWORK_AI_MOCK", "ZEROWORK_AI_ENDPOINT", "ZEROWORK_AI_MODEL", "ZEROWORK_AI_PROVIDER"]) delete environment[name];
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(output, "app.log"), "w");
const child = spawn(binary, [], { cwd: process.cwd(), env: environment, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>(done => child.once("close", () => done()));
const report: Record<string, any> = {
  status: "running", binary, binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"),
  pid: child.pid, source: answer, expected, stages: [],
};
const shown = (node: any): boolean => node.hidden !== true && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect?.w > 0 && node.rect?.h > 0;
const flatten = (node: any): any[] => !shown(node) ? [] : [node, ...(node.children ?? []).flatMap(flatten)];
async function visible(id: string): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null, 20000); }
async function click(id: string): Promise<void> { await visible(id); assert((await clickTestId(id)).ok); }
let failure: unknown;
try {
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), child.pid);
  assert((await resizeWindow(1440, 1000)).ok);
  await click("workspace.empty.local");
  await visible("terminal.surface");
  await click("toolbar.ai");
  await click("ai.prompt");
  assert((await type_(prompt)).ok);
  await click("ai.send");
  await waitFor(async () => {
    if (fixtureError) throw fixtureError;
    if ((await query("ai.stop")).some(shown)) return null;
    const panel = await visible("ai.panel");
    const texts = flatten(panel).map(node => node.text);
    return expected.every(text => texts.includes(text)) ? panel : null;
  }, 20000);
  for (const [name, width] of [["wide", 1440], ["narrow", 1040]] as const) {
    assert((await resizeWindow(width, 1000)).ok);
    await sleep(250);
    const panel = await visible("ai.panel"), nodes = flatten(panel);
    for (const text of expected) {
      const node = nodes.find(node => node.text === text);
      assert(node, `Missing rendered text: ${text}`);
      assert(node.rect.x >= panel.rect.x - 1 && node.rect.x + node.rect.w <= panel.rect.x + panel.rect.w + 1, `Text width inside AI panel: ${text}`);
    }
    const path = join(output, `${name}.png`);
    assert((await screenshot(path)).ok);
    await writeFile(join(output, `${name}.tree.json`), JSON.stringify(panel, null, 2));
    report.stages.push({ name, width, screenshot: path });
  }
  assert.equal(requestCount, 1);
  assert((await request("POST", "/zerowork/windows", { action: "quit" })).ok);
  await waitFor(async () => {
    if (child.exitCode !== null || child.signalCode !== null) return true;
    const confirmation = await Promise.race([query("local.close.accept"), ended.then(() => [])]);
    if (confirmation.some(shown)) assert((await clickTestId("local.close.accept")).ok);
    return null;
  }, 15000);
  assert.equal(child.exitCode, 0, "Normal application quit");
  report.status = "passed";
} catch (error) {
  failure = error; report.status = "failed"; report.error = String(error);
  if (child.exitCode === null && child.signalCode === null) try { await screenshot(join(output, "failure.png")); } catch {}
} finally {
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
  await Promise.race([ended, sleep(2000)]);
  if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await ended; }
  report.cleanup = { exit_code: child.exitCode, signal: child.signalCode };
  server.closeAllConnections();
  await new Promise<void>(closed => server.close(() => closed()));
  await log.close();
  await rm(isolated, { recursive: true, force: true });
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
}
if (failure) throw failure;
console.log(`AI inline Markdown acceptance passed: ${output}`);
