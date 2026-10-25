/** Real background window acceptance using the current installed Harness binary.
 * node e2e/tab_shortcuts.ts --out DIR [--fixture-dir DIR]
 * Uses only public Harness APIs. Harness has no key_up command, so physical
 * modifier release, window blur and real IME require separate CUA acceptance.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, open, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { waitForServerReady, waitFor, query, clickTestId, key, resizeWindow, screenshot, stats, sleep } from "../zig-out/share/zenit/harness/client.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2), options: Record<string, string> = {};
for (let i = 0; i < args.length; i += 2) {
  assert(["--out", "--binary", "--fixture-dir"].includes(args[i]) && args[i + 1], `Invalid option ${args[i]}`);
  options[args[i]] = args[i + 1];
}
const binary = resolve(options["--binary"] ?? join(root, "zig-out/bin/zerowork"));
const output = resolve(options["--out"] ?? join(root, "dist/ui-acceptance/20261018/tab-shortcuts"));
const fixture = resolve(options["--fixture-dir"] ?? join(root, "dist/ui-acceptance/20261018/session-close-host-diagnostic/fixture-short-timeout"));
const isolated = await mkdtemp(join(tmpdir(), "zerowork-tab-shortcuts-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data");
await mkdir(output, { recursive: true });
await mkdir(rpc); await cp(fixture, data, { recursive: true });
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(output, "app.log"), "w");
const child = spawn(binary, [], { cwd: root, stdio: ["ignore", log.fd, log.fd], env: {
  ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZEROWORK_DATA_DIR: data,
  ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1", ZEROWORK_AUTOCONNECT: "0",
} });
const ended = new Promise<void>((done) => child.once("close", () => done()));
const report: any = { started_at: new Date().toISOString(), binary, binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"), pid: child.pid,
  storage: "isolated temporary data and file RPC", background: true, source: "src/main.zig", checks: [], status: "running",
  limits: ["Only public Harness APIs are used. Harness has no key_up command: physical modifier release, window blur, and real IME require separate CUA acceptance.", "Runner SIGTERM cleanup is not evidence of normal application shutdown."] };
type Node = any;
function flatten(node: Node): Node[] { return [node, ...(node.children ?? []).flatMap(flatten)]; }
function shown(node: Node): boolean { return !node.hidden && node.visible !== false && node.rect.w > 0 && node.rect.h > 0 && (node.opacity ?? 1) > 0; }
async function strip(): Promise<Node> { const nodes = await query("tabs.strip"); assert.equal(nodes.length, 1); return nodes[0]; }
async function active(): Promise<number> {
  const matches = flatten(await strip()).filter(n => /^tabs\.close\.\d+$/.test(n.test_id ?? "") && n.focusable === true);
  assert.equal(matches.length, 1, "Exactly one active close control must be focusable");
  return Number(matches[0].test_id.split(".").at(-1));
}
async function expectActive(id: number) {
  try { await waitFor(async () => await active() === id || null); }
  catch (cause) { throw new Error(`Expected active tab ${id}, actual ${await active()}`, { cause }); }
}
async function press(name: string, mods?: { cmd?: boolean; ctrl?: boolean; shift?: boolean }) { assert((await key(name, mods)).ok); }
async function click(id: string) { assert((await clickTestId(id)).ok, `Click ${id}`); }
async function tab(id: number) { const nodes = await query(`tabs.tab.${id}`); assert.equal(nodes.length, 1); return nodes[0]; }
function digit(node: Node): string | null {
  const iconSlot = node.children?.[0];
  return iconSlot?.children?.find((child: Node) => shown(child) && /^[1-9]$/.test(child.text ?? ""))?.text ?? null;
}
async function numbers(expected: boolean) {
  const values = await Promise.all(Array.from({ length: 10 }, (_, i) => tab(i + 1).then(digit)));
  assert.deepEqual(values, Array.from({ length: 10 }, (_, i) => expected && i < 9 ? String(i + 1) : null));
  return values;
}
async function capture(name: string) {
  await sleep(150); assert((await screenshot(join(output, `${name}.png`))).ok);
  await writeFile(join(output, `${name}.strip.json`), JSON.stringify(await strip(), null, 2));
}
async function check(name: string, fn: () => Promise<any>) {
  const result: any = { name, status: "running" }; report.checks.push(result);
  try { result.observed = await fn(); result.status = "passed"; }
  catch (error) {
    result.status = "failed"; result.error = String(error); failure ??= error;
    await capture(`failed-check-${report.checks.length}`).catch(() => {});
  }
}
let failure: unknown;
try {
  await waitForServerReady();
  const owner = JSON.parse(await readFile(join(rpc, "owner.json"), "utf8"));
  assert.equal(Number(owner.pid), child.pid, "Never attach to a different process");
  for (let i = 1; i <= 10; i++) {
    await click("toolbar.new_session");
    await waitFor(async () => (await query("session.menu.quick")).some(shown) || null);
    await click("session.menu.quick");
    await waitFor(async () => (await query("quick.submit")).some(shown) || null);
    await click("quick.submit"); await expectActive(i);
  }
  report.tab_count = 10;
  await check("Command shows ordered slots 1–9 and leaves tab 10 as its type icon", async () => {
    await press("1", { cmd: true }); await expectActive(1);
    await waitFor(async () => digit(await tab(1)) === "1" || null);
    const values = await numbers(true); await capture("command-held-first-nine"); return values;
  });
  await check("Command 1–9 each activates that ordered tab", async () => {
    const actual = [];
    for (let i = 1; i <= 9; i++) { await press(String(i), { cmd: true }); await expectActive(i); actual.push(await active()); }
    return actual;
  });
  await check("A key event without Command restores all type icons (not a native key-up test)", async () => {
    await press("escape");
    await waitFor(async () => digit(await tab(1)) === null || null);
    const values = await numbers(false); await capture("command-released"); return values;
  });
  await check("Overflow left boundary disables and cannot scroll farther", async () => {
    assert((await resizeWindow(860, 480)).ok);
    await waitFor(async () => (await query("tabs.scroll_left")).length === 1 || null);
    let button: Node;
    for (let attempt = 0; attempt < 20; attempt++) {
      button = (await query("tabs.scroll_left"))[0];
      if (!button.focusable) break;
      await click("tabs.scroll_left");
    }
    button = (await query("tabs.scroll_left"))[0]; assert(!button.focusable, "Left arrow must disable at start");
    const viewport = (await query("tabs.viewport"))[0].rect;
    assert(Math.abs((await tab(1)).rect.x - viewport.x) <= 0.5, "Disabled left arrow requires tab 1 at the viewport start");
    const before = (await tab(1)).rect.x;
    await click("tabs.scroll_left"); await click("tabs.scroll_left");
    const after = (await tab(1)).rect.x; assert.equal(after, before);
    assert((await query("tabs.scroll_right"))[0].focusable, "Right arrow must remain enabled");
    await capture("overflow-left-disabled"); return { before, after, left: button };
  });
  await check("Overflow right boundary disables and cannot scroll farther", async () => {
    let button: Node;
    for (let attempt = 0; attempt < 20; attempt++) {
      button = (await query("tabs.scroll_right"))[0];
      if (!button.focusable) break;
      await click("tabs.scroll_right");
    }
    button = (await query("tabs.scroll_right"))[0]; assert(!button.focusable, "Right arrow must disable at end");
    const viewport = (await query("tabs.viewport"))[0].rect;
    const last = (await tab(10)).rect;
    assert(Math.abs(last.x + last.w - viewport.x - viewport.w) <= 0.5, "Disabled right arrow requires the last tab at the viewport end");
    const before = (await tab(1)).rect.x;
    await click("tabs.scroll_right"); await click("tabs.scroll_right");
    const after = (await tab(1)).rect.x; assert.equal(after, before);
    assert((await query("tabs.scroll_left"))[0].focusable, "Left arrow must remain enabled");
    await capture("overflow-right-disabled"); return { before, after, right: button };
  });
  await check("Ctrl+Tab uses frozen MRU order and Shift reverses the preview", async () => {
    for (const id of [2, 5, 3]) { await press(String(id), { cmd: true }); await expectActive(id); }
    const observed = [], expected = [5, 2, 9, 8, 7, 6, 4, 1, 10, 3];
    for (const target of expected) {
      await press("tab", { ctrl: true }); observed.push(await active());
      await expectActive(target);
    }
    await press("tab", { ctrl: true, shift: true }); await expectActive(10);
    const reverse = await active();
    await capture("mru-frozen-preview"); return { established: [2, 5, 3], expected, observed, reverse };
  });
  report.stats = await stats(); report.status = failure ? "failed" : "passed";
} catch (error) {
  failure = error; report.status = "failed"; report.error = String(error);
  if (child.exitCode === null && child.signalCode === null) {
    const diagnostics = await Promise.allSettled([capture("failure"), query("tabs.scroll_left"), query("tabs.scroll_right")]);
    report.diagnostics = diagnostics.map(result => result.status === "fulfilled" ? result.value : String(result.reason));
  }
} finally {
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
  await Promise.race([ended, sleep(2000)]);
  if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await ended; }
  report.process_cleanup = { exit_code: child.exitCode, signal: child.signalCode };
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "harness-report.json"), JSON.stringify(report, null, 2));
  await log.close(); await rm(isolated, { recursive: true, force: true });
}
console.log(`${report.status}: ${join(output, "harness-report.json")}`);
if (failure) throw failure;
