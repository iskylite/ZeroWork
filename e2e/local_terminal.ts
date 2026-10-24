/** Actual Local PTY/Metal integration. Requires a fresh -Dtest-mode=true build.
 * Cleanup termination is reported separately and is never normal-close proof.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { waitForServerReady, waitFor, tree, query, clickTestId, key, type_, resizeWindow, screenshot, sleep } from "../zig-out/share/zenit/harness/client.ts";

const args = process.argv.slice(2);
const options: Record<string, string> = {};
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--out"].includes(args[i]) && args[i + 1], `Invalid option ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--out"], "--out is required");
const output = resolve(options["--out"]);
const binary = resolve(options["--binary"] ?? "zig-out/bin/zerowork");
const isolated = await mkdtemp(join(tmpdir(), "zerowork-local-ui-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data)]);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(output, "app.log"), "w");
const child = spawn(binary, [], { env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_ISOLATE_POINTER: "1", ZENIT_E2E_BACKGROUND: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0" }, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>((done) => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", (error) => { launchError = error; });
const report: Record<string, unknown> = { status: "running", binary, binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"), pid: child.pid, started_at: new Date().toISOString(), checks: [] };
const checks = report.checks as string[];
type Node = Awaited<ReturnType<typeof tree>>;
function nodes(root: Node, id: string, visible = true): Node[] {
  const shown = visible && root.hidden !== true && (root.effective_opacity ?? 1) > 0;
  if (!shown) return [];
  return [...(root.test_id === id && root.rect.w > 0 && root.rect.h > 0 ? [root] : []), ...(root.children ?? []).flatMap((value) => nodes(value, id, shown))];
}
function text(root: Node, visible = true): string {
  const shown = visible && root.hidden !== true && (root.effective_opacity ?? 1) > 0;
  if (!shown) return "";
  return (root.text ?? "") + (root.children ?? []).map((value) => text(value, shown)).join("");
}
async function visible(id: string): Promise<Node> {
  return await waitFor(async () => (await query(id)).find((node) => node.hidden !== true && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0) ?? null);
}
function descendants(): { pid: number; parent: number; command: string }[] {
  const all = execFileSync("/bin/ps", ["-axo", "pid=,ppid=,comm="], { encoding: "utf8" }).trim().split("\n").flatMap((line) => {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/);
    return match ? [{ pid: Number(match[1]), parent: Number(match[2]), command: match[3] }] : [];
  });
  const owned = new Set([child.pid!]);
  for (let i = 0; i < all.length; i++) {
    let changed = false;
    for (const process of all) if (owned.has(process.parent) && !owned.has(process.pid)) { owned.add(process.pid); changed = true; }
    if (!changed) break;
  }
  return all.filter((process) => process.pid !== child.pid && owned.has(process.pid));
}
function ptyDescriptors(): string[] {
  const output = execFileSync("/usr/sbin/lsof", ["-nP", "-a", "-p", String(child.pid), "-Ffn"], { encoding: "utf8" });
  let descriptor = "";
  return output.split("\n").flatMap((line) => {
    if (line.startsWith("f")) descriptor = line.slice(1);
    return /^n\/dev\/(ttys|ptmx|pty)/.test(line) ? [`${descriptor}:${line.slice(1)}`] : [];
  });
}
async function capture(name: string): Promise<void> {
  // Let the actual widget enter transition settle before recording its pixels.
  await sleep(250);
  assert((await screenshot(join(output, `${name}.png`))).ok);
  const projection: Record<string, unknown> = {};
  for (const id of ["local.statusbar", "tabs.strip", "status.detail", "status.theme", "local.close.confirmation"]) {
    const result = await query(id);
    assert(Array.isArray(result), `Invalid query result for ${id}: ${JSON.stringify(result)}`);
    projection[id] = result;
  }
  await writeFile(join(output, `${name}.queries.json`), JSON.stringify(projection, null, 2));
}
let failure: unknown;
try {
  await waitForServerReady();
  const owner = JSON.parse(await readFile(join(rpc, "owner.json"), "utf8"));
  assert.equal(Number(owner.pid), child.pid);
  await resizeWindow(1440, 900);
  const initialPtyDescriptors = ptyDescriptors();
  await clickTestId("workspace.empty.local");
  await visible("terminal.surface");
  await visible("local.status.identity");
  await visible("tabs.tab.1");
  await visible("tabs.close.1");
  assert.equal((await query("workspace.statusbar")).filter((node) => node.hidden !== true && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0).length, 0, "Local must not reveal the SSH statusbar");
  await waitFor(async () => descendants().some((process) => process.command.endsWith("/zsh")) || null);
  const activePtyDescriptors = ptyDescriptors();
  assert(activePtyDescriptors.length > initialPtyDescriptors.length, "The app must actually own a new PTY descriptor while Local runs");
  checks.push("Local entry creates a real owned zsh PTY and visible service surface");
  await type_("printf '\\033[31mZEROWORK_%s_OK\\033[0m\\n' LOCAL");
  await key("enter");
  await waitFor(async () => {
    const surface = (await query("terminal.surface"))[0];
    return surface && text(surface).includes("ZEROWORK_LOCAL_OK") || null;
  });
  checks.push("Real shell output reaches the VT projection and rendered grapheme nodes");
  await capture("local-output");
  const verifyGrid = async (): Promise<string> => {
    const label = text(await visible("local.status.grid"));
    const match = label.match(/(\d+)×(\d+)/);
    assert(match, `Missing actual grid: ${label}`);
    const expected = `__GRID_${match[2]} ${match[1]}__`;
    await type_("printf '__GRID_%s__\\n' \"$(stty size)\"");
    await key("enter");
    await waitFor(async () => {
      const surface = (await query("terminal.surface"))[0];
      return surface && text(surface).includes(expected) || null;
    });
    return match[0];
  };
  const originalGrid = await verifyGrid();
  await resizeWindow(860, 480);
  await waitFor(async () => {
    const button = (await query("local.status.grid"))[0];
    return button && !text(button).includes(originalGrid) || null;
  });
  const compactGrid = await verifyGrid();
  report.pty_grid = { original: originalGrid, compact: compactGrid };
  checks.push("Status grid and real stty winsize agree before and after actual window resize");
  await capture("local-compact");
  await clickTestId("local.status.grid");
  await visible("status.detail");
  await capture("local-compact-grid");
  const compactDetail = await visible("status.detail");
  const compactBar = await visible("local.statusbar");
  assert.equal(compactDetail.rect.w, 360);
  assert(compactDetail.rect.x >= 8 && compactDetail.rect.x + compactDetail.rect.w <= 852);
  assert(Math.abs(compactBar.rect.y - compactDetail.rect.y - compactDetail.rect.h - 6) <= 1, "Compact detail stays 6pt above the statusbar");
  checks.push("Actual compact grid detail is 360pt wide, stays inside the window and anchors 6pt above the statusbar");
  await clickTestId("status.detail.close");
  await resizeWindow(1440, 900);
  await waitFor(async () => {
    const button = (await query("local.status.grid"))[0];
    return button && text(button).includes(originalGrid) || null;
  });
  await clickTestId("local.status.grid");
  await visible("status.detail");
  await capture("local-grid");
  await clickTestId("status.detail.close");
  await clickTestId("local.status.theme");
  await visible("status.theme");
  await clickTestId("status.theme.item.nord");
  await waitFor(async () => {
    const feedback = (await query("status.theme.feedback"))[0];
    return feedback && text(feedback).includes("已") || null;
  });
  const savedConfig = await readFile(join(data, "config.toml"), "utf8");
  assert(/theme\s*=\s*"nord"/.test(savedConfig), "Global theme must be persisted by the real Config transaction");
  await waitFor(async () => text(await visible("local.status.grid")).includes(originalGrid) || null);
  const themedGrid = await verifyGrid();
  assert.equal(themedGrid, originalGrid, "Changing only the theme must preserve terminal font geometry");
  checks.push("Global Nord selection is acknowledged and persisted through the real settings transaction without changing the PTY grid");
  await capture("local-theme-nord");
  await clickTestId("status.theme.close");
  for (const theme of ["light", "sauber", "dark"]) {
    await clickTestId("local.status.theme");
    await visible("status.theme");
    await clickTestId(`status.theme.item.${theme}`);
    await waitFor(async () => new RegExp(`theme\\s*=\\s*"${theme}"`).test(await readFile(join(data, "config.toml"), "utf8")) || null);
    await clickTestId("status.theme.close");
    await capture(`local-${theme}-standard`);
    await resizeWindow(860, 480);
    await waitFor(async () => !text(await visible("local.status.grid")).includes(originalGrid) || null);
    await capture(`local-${theme}-compact`);
    await resizeWindow(1440, 900);
    await waitFor(async () => text(await visible("local.status.grid")).includes(originalGrid) || null);
  }
  checks.push("Dark, Light and Sauber are selected through the real global palette and captured at standard and minimum sizes for separate visual review");
  await clickTestId("terminal.surface");
  await type_("/bin/sleep 30");
  await key("enter");
  const running = await waitFor(async () => descendants().find((process) => process.command.endsWith("/sleep")) ?? null);
  report.foreground_pid = running.pid;
  await sleep(400);
  await clickTestId("tabs.close.1");
  await visible("local.close.confirmation");
  await capture("local-close-risk");
  await clickTestId("local.close.cancel");
  await waitFor(async () => (await query("local.close.confirmation")).filter((node) => node.hidden !== true && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0).length === 0 || null);
  assert(descendants().some((process) => process.pid === running.pid));
  checks.push("Cancel closes the risk modal while the same real foreground process continues");
  await clickTestId("tabs.close.1");
  await visible("local.close.confirmation");
  await clickTestId("local.close.accept");
  await waitFor(async () => !descendants().some((process) => process.pid === running.pid) || null);
  await visible("workspace.empty.local");
  assert(!descendants().some((process) => process.command.endsWith("/zsh")));
  await waitFor(async () => ptyDescriptors().length <= initialPtyDescriptors.length || null);
  report.pty_descriptors = { before: initialPtyDescriptors, active: activePtyDescriptors, after: ptyDescriptors() };
  checks.push("Confirm closes the captured Local session, releases its PTY foreground process and returns the app's PTY descriptor count to baseline");
  await capture("local-after-close");
  report.status = "passed";
} catch (error) {
  failure = launchError ?? error;
  report.status = "failed";
  report.error = String(failure);
  if (child.exitCode === null && child.signalCode === null) {
    await Promise.allSettled([capture("failure"), writeFile(join(output, "remaining-processes.json"), JSON.stringify(descendants(), null, 2))]);
  }
} finally {
  // Own process tree only; failure cleanup is not normal-close evidence.
  if (child.exitCode === null && child.signalCode === null) {
    const remaining = descendants();
    report.forced_child_cleanup = remaining.map((value) => value.pid);
    for (const value of remaining.reverse()) { try { process.kill(value.pid, "SIGHUP"); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error; } }
    child.kill("SIGTERM");
  }
  await Promise.race([ended, sleep(2000)]);
  if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await ended; }
  report.process_cleanup = { exit_code: child.exitCode, signal: child.signalCode };
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  await log.close();
  await rm(isolated, { recursive: true, force: true });
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
