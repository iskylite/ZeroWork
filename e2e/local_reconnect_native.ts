/** Real Local PTY exit/reconnect in one tab, with isolated data and shell setup. */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, writeFile, rm, realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const prefix = resolve(process.argv[2] ?? "zig-out");
const out = resolve(process.argv[3] ?? "/tmp/zerowork-local-reconnect-evidence");
const h = await import(pathToFileURL(join(prefix, "share/zenit/harness/client.ts")).href);
const binary = join(prefix, "bin/zerowork");
const isolated = await realpath(await mkdtemp(join(tmpdir(), "zw-local-reconnect-")));
const rpc = join(isolated, "rpc"), data = join(isolated, "data"), shell = join(isolated, "shell");
await Promise.all([mkdir(out, { recursive: true }), mkdir(rpc), mkdir(data), mkdir(shell)]);
await writeFile(join(shell, ".zshenv"), "setopt NO_RCS\nunsetopt IGNORE_EOF\nPROMPT='reconnect-test % '\nRPROMPT=''\n");
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(out, "app.log"), "w");
const app = spawn(binary, [], { env: { ...process.env, ZDOTDIR: shell, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_ISOLATE_POINTER: "1", ZENIT_E2E_BACKGROUND: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0" }, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>(done => app.once("close", () => done()));
const alive = () => app.exitCode === null && app.signalCode === null;
const report: Record<string, unknown> = { status: "running", binary, binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"), pid: app.pid, checks: [] };
const checks = report.checks as string[];
const shown = (n: any) => !n.hidden && (n.effective_opacity ?? 1) > 0 && n.rect.w > 0 && n.rect.h > 0;
const text = (n: any): string => !shown(n) ? "" : (n.text ?? "") + (n.children ?? []).map(text).join("");
const visible = async (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null);
const hidden = async (id: string) => h.waitFor(async () => !(await h.query(id)).some(shown) || null);
const output = async (value: string) => h.waitFor(async () => (await h.query("terminal.surface")).some((n: any) => text(n).includes(value)) || null);
function shells(): number[] {
  return execFileSync("/bin/ps", ["-axo", "pid=,ppid=,comm="], { encoding: "utf8" }).split("\n").flatMap(line => {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/);
    return m && Number(m[2]) === app.pid && m[3].endsWith("/zsh") ? [Number(m[1])] : [];
  });
}
async function capture(name: string) {
  await h.sleep(300);
  assert((await h.screenshot(join(out, `${name}.png`))).ok);
  const queries = Object.fromEntries(await Promise.all(["tabs.strip", "local.notice", "local.ended.reconnect", "local.start.retry"].map(async id => [id, await h.query(id)])));
  await writeFile(join(out, `${name}.json`), JSON.stringify(queries, null, 2));
}
let failure: unknown;
try {
  await h.waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), app.pid);
  await h.resizeWindow(1440, 900);
  await h.clickTestId("workspace.empty.local");
  await visible("terminal.surface");
  await hidden("local.notice");
  const originalPid = await h.waitFor(async () => shells()[0] ?? null);
  await h.type_("printf '%s_%s\\n' BEFORE RECONNECT");
  await h.key("return");
  await output("BEFORE_RECONNECT");
  await h.key("d", { ctrl: true });
  await visible("local.ended.reconnect");
  assert(text(await visible("local.notice.title")).includes("本地终端已退出"));
  assert(text(await visible("local.notice.detail")).includes("退出码 0"));
  assert(text(await visible("local.ended.reconnect")).includes("重新连接"));
  await output("BEFORE_RECONNECT");
  await h.waitFor(async () => !shells().includes(originalPid) || null);
  await capture("ctrl-d-exited");
  await h.resizeWindow(860, 480);
  const reconnect = await visible("local.ended.reconnect");
  assert(reconnect.rect.x >= 0 && reconnect.rect.x + reconnect.rect.w <= 860);
  await capture("ctrl-d-exited-compact");
  await h.clickTestId("local.ended.reconnect");
  await hidden("local.notice");
  const replacementPid = await h.waitFor(async () => shells().find(pid => pid !== originalPid) ?? null);
  assert.equal(shells().length, 1, "Reconnect owns exactly one live shell");
  await visible("tabs.tab.1");
  await hidden("tabs.tab.2");
  // No terminal click: successful reconnect must restore keyboard focus.
  await h.type_("printf '%s_%s\\n' AFTER RECONNECT");
  await h.key("return");
  await output("AFTER_RECONNECT");
  checks.push("Ctrl+D retains the transcript and exposes reconnect at standard and minimum sizes");
  checks.push("Reconnect uses the same tab, starts one replacement zsh and restores keyboard input without another click");
  await capture("reconnected-compact");
  await h.type_("exit 3");
  await h.key("return");
  await visible("local.ended.reconnect");
  assert(text(await visible("local.notice.detail")).includes("退出码 3"));
  await h.clickTestId("local.ended.reconnect");
  await hidden("local.notice");
  const secondPid = await h.waitFor(async () => shells().find(pid => pid !== replacementPid) ?? null);
  await h.type_("printf '%s_%s\\n' SECOND RECONNECT");
  await h.key("return");
  await output("SECOND_RECONNECT");
  await visible("tabs.tab.1");
  await hidden("tabs.tab.2");
  assert.equal(shells().length, 1);
  report.shell_pids = [originalPid, replacementPid, secondPid];
  checks.push("A nonzero exit also reconnects repeatedly in the original tab without accumulating live shells");
  await h.resizeWindow(1440, 900);
  await capture("reconnected");
  await h.clickTestId("tabs.close.1");
  await visible("workspace.empty.local");
  await h.waitFor(async () => shells().length === 0 || null);
  checks.push("Closing the reconnected tab releases the replacement shell");
  report.status = "passed";
} catch (error) {
  failure = error;
  report.status = "failed";
  report.error = String(error);
  if (alive()) await capture("failure").catch(() => {});
} finally {
  if (alive()) {
    try {
      report.quit_response = await h.request("POST", "/zerowork/windows", { action: "quit" });
      await Promise.race([ended, h.sleep(15000)]);
    } catch (error) { report.quit_error = String(error); }
  }
  if (alive()) {
    report.forced_cleanup = true;
    for (const pid of shells()) { try { process.kill(pid, "SIGHUP"); } catch {} }
    app.kill("SIGTERM");
    await Promise.race([ended, h.sleep(2000)]);
    if (alive()) { app.kill("SIGKILL"); await ended; }
  }
  report.exit_code = app.exitCode;
  report.signal = app.signalCode;
  if (!failure && (report.forced_cleanup || app.exitCode !== 0)) {
    failure = new Error("Application did not quit cleanly");
    report.status = "failed";
    report.error = String(failure);
  }
  await writeFile(join(out, "report.json"), JSON.stringify(report, null, 2));
  await log.close();
  await rm(isolated, { recursive: true, force: true });
}
console.log(`${report.status}: ${join(out, "report.json")}`);
if (failure) throw failure;
