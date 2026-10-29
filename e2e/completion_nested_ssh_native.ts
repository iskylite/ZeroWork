/** App-owned history through Local zsh -> ede alias -> actual loopback SSH/ZSH.
 * node e2e/completion_nested_ssh_native.ts /absolute/output /absolute/test-binary
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, open, readFile, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, clickAt, key, type_, screenshot, sleep, resizeWindow } from "../zig-out/share/zenit/harness/client.ts";

const output = resolve(process.argv[2]), source = resolve(process.argv[3]);
await mkdir(output, { recursive: false });
const isolated = await realpath(await mkdtemp(join(tmpdir(), "zw-completion-ssh-")));
const rpc = join(isolated, "rpc"), data = join(isolated, "data"), zdot = join(isolated, "zdot"), remote = join(isolated, "remote");
await Promise.all([mkdir(rpc), mkdir(data), mkdir(zdot), mkdir(remote)]);
await mkdir(join(remote, "__pycache__"));
const quote = (text: string) => `'${text.replaceAll("'", "'\\''")}'`;
const peerOut = join(output, "peer"), peerLog = await open(join(output, "peer.log"), "w");
const peer = spawn("python3", ["e2e/builtin_records_ssh_peer.py", "--out", peerOut], { stdio: ["ignore", peerLog.fd, peerLog.fd] });
const peerEnded = new Promise(resolve_ => peer.once("close", resolve_));
const ready = await waitFor(async () => { try { return JSON.parse(await readFile(join(peerOut, "ready.json"), "utf8")); } catch { return null; } }, 15000);
const knownHosts = join(isolated, "known_hosts");
await writeFile(knownHosts, ready.known_host);
await writeFile(join(peerOut, ".zshrc"), `bindkey -e\nPS1='container# '\ncd ${quote(remote)}\n`);
const ssh = `/usr/bin/ssh -F /dev/null -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${quote(knownHosts)} -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 -p ${ready.port} ${ready.user}@127.0.0.1`;
await writeFile(join(zdot, ".zshrc"), `bindkey -e\nPS1='local-history%# '\nalias ede=${quote(ssh)}\n`);
await writeFile(join(data, "config.toml"), '[meta]\nconfig_revision=1\n[ui]\ntheme="dark"\nfont_family="Menlo"\nfont_size=14\n');
const binary = join(isolated, "zerowork");
await copyFile(source, binary);
for (const module of ["zw_ipc.so", "zw_execution.so"]) await copyFile(join(dirname(source), module), join(isolated, module));
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const appLog = await open(join(output, "app.log"), "w");
const app = spawn(binary, [], { env: { ...process.env, ZDOTDIR: zdot, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1" }, stdio: ["ignore", appLog.fd, appLog.fd] });
const ended = new Promise(resolve_ => app.once("close", resolve_));
const report: any = { status: "running", pid: app.pid, isolated, binary_sha256: createHash("sha256").update(await readFile(source)).digest("hex"), checks: [], screenshots: [], limits: ["Synthetic public Harness input and actual Metal screenshots; physical keyboard/IME not verified", "SSH connects only to this runner's verified loopback peer, which owns an actual ZSH PTY", "History is scoped to the live session; no private user startup files or saved connections are used"] };
const shown = (n: any) => n && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
const content = (n: any): string => shown(n) ? (n.text ?? "") + (n.children ?? []).map(content).join("") : "";
const visible = (id: string) => waitFor(async () => (await query(id)).find(shown) ?? null, 15000);
const hidden = (id: string) => waitFor(async () => !(await query(id)).some(shown) || null, 10000);
const press = async (name: string, mods?: any) => { assert((await key(name, mods)).ok); };
const type = async (text: string) => { assert((await type_(text)).ok); };
const click = async (id: string) => { const n = await visible(id); assert((await clickAt(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2)).ok); };
const file = async (path: string) => { try { return await readFile(path, "utf8"); } catch { return ""; } };
async function screenText() { let result = ""; for (let i = 0; i < 12; i++) result += (await query(`terminal.surface.row.${i}`)).map(content).join("") + "\n"; return result; }
async function capture(name: string) { await sleep(200); assert((await screenshot(join(output, `${name}.png`))).ok); await writeFile(join(output, `${name}.json`), JSON.stringify(await query("terminal.completion"), null, 2)); report.screenshots.push(name); }
async function command(text: string) { await type(text); await sleep(120); await press("return"); }
async function settlePrompt() { await waitFor(async () => (await screenText()).includes("container#") || null, 15000); await sleep(200); }
let failed: unknown;
try {
    await waitForServerReady();
    assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), app.pid);
    await resizeWindow(1440, 900);
    await click("workspace.empty.local");
    await visible("terminal.surface");
    await waitFor(async () => (await screenText()).includes("local-history") || null, 15000);
    await click("terminal.surface");
    await command("ede");
    await waitFor(async () => (await screenText()).includes("password:") || null, 15000);
    await command(ready.password);
    await settlePrompt();
    report.checks.push("Real Local zsh alias ede launches /usr/bin/ssh to the verified loopback peer and enters its actual ZSH without an app edit provider");

    await command("find . -name __pycache__");
    await waitFor(async () => (await screenText()).includes("./__pycache__") || null, 15000);
    await sleep(200);
    await type("find");
    assert(content(await visible("terminal.completion")).includes("find . -name __pycache__"));
    await capture("01-nested-ssh-find-auto-history");
    await press("escape"); await hidden("terminal.completion"); await sleep(250); await hidden("terminal.completion");
    await press("semicolon", { cmd: true }); await visible("terminal.completion");
    const beforeRight = await readFile(join(peerOut, "received-1.bin"));
    await press("right"); await hidden("terminal.completion"); await sleep(200);
    const afterRight = await readFile(join(peerOut, "received-1.bin"));
    assert.equal(afterRight.subarray(beforeRight.length).toString(), " . -name __pycache__");
    await capture("02-prefix-adopted-without-enter");
    await press("c", { ctrl: true }); await sleep(250);
    report.checks.push("Typing find automatically shows the prior full command; Escape stays dismissed; Right sends only the missing suffix, with no Enter or erase controls");

    await type("find"); await visible("terminal.completion");
    const beforeEnter = await readFile(join(peerOut, "received-1.bin"));
    await press("return"); await hidden("terminal.completion"); await sleep(250);
    assert.equal((await readFile(join(peerOut, "received-1.bin"))).subarray(beforeEnter.length).toString(), "\r");
    await type("find"); await visible("terminal.completion");
    const beforeTab = await readFile(join(peerOut, "received-1.bin"));
    await press("tab"); await hidden("terminal.completion"); await sleep(200);
    assert.equal((await readFile(join(peerOut, "received-1.bin"))).subarray(beforeTab.length).toString(), "\t");
    await press("c", { ctrl: true }); await sleep(200);
    report.checks.push("Enter transmits the original input exactly once; Tab is forwarded unchanged to the remote shell");

    await type("records-"); await sleep(250); await hidden("terminal.completion");
    await press("c", { ctrl: true }); await sleep(200);
    await resizeWindow(860, 480);
    if ((await query("status.theme")).some(shown)) await click("status.theme.close");
    await click("terminal.surface");
    await type("find");
    const compact = await visible("terminal.completion");
    assert(compact.rect.x >= 0 && compact.rect.y >= 0 && compact.rect.x + compact.rect.w <= 860 && compact.rect.y + compact.rect.h <= 480);
    await capture("03-compact-auto-history");
    await press("c", { ctrl: true }); await sleep(200);
    report.checks.push("The SSH login password never becomes a history candidate; the automatic menu fits the 860×480 window");
    await command("exit");
    await waitFor(async () => (await file(join(peerOut, "closed-1.json"))).length > 0 || null, 15000);
    report.status = "passed";
} catch (error) { failed = error; report.status = "failed"; report.error = String(error); await capture("failure").catch(() => {}); }
finally {
    if (app.exitCode === null && app.signalCode === null) app.kill("SIGTERM");
    await Promise.race([ended, sleep(3000)]);
    if (app.exitCode === null && app.signalCode === null) { app.kill("SIGKILL"); await ended; }
    peer.kill("SIGTERM"); await Promise.race([peerEnded, sleep(4000)]);
    await appLog.close(); await peerLog.close();
    await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
}
console.log(JSON.stringify({ status: report.status, output, error: report.error }));
if (failed) throw failed;
