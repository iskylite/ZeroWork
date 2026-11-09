/** Real SSH/Bash Tab completion -> submission -> application history menu.
 * ZW_TEST_PYTHON=/path/to/python-with-paramiko node e2e/completion_tab_ssh_native.ts /fresh/output /path/to/zerowork
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { clickAt, focused, key, query, request, resizeWindow, screenshot, sleep, type_, waitFor, waitForServerReady } from "../zig-out/share/zenit/harness/client.ts";

const output = resolve(process.argv[2]), binary = resolve(process.argv[3]);
await mkdir(output, { recursive: false });
const isolated = await realpath(await mkdtemp(join(tmpdir(), "zw-tab-history-")));
const rpc = join(isolated, "rpc"), data = join(isolated, "data"), peerOutput = join(output, "peer");
await Promise.all([mkdir(rpc), mkdir(data)]);
const peerLog = await open(join(output, "peer.log"), "w"), appLog = await open(join(output, "app.log"), "w");
const peer = spawn(process.env.ZW_TEST_PYTHON ?? "python3", ["e2e/builtin_records_ssh_peer.py", "--out", peerOutput, "--plain-bash"], { stdio: ["ignore", peerLog.fd, peerLog.fd] });
const peerEnded = new Promise(resolve_ => peer.once("close", resolve_));
let app: ReturnType<typeof spawn> | undefined, appEnded: Promise<unknown> | undefined;
const report: any = {
    status: "running", binary, sha256: createHash("sha256").update(await readFile(binary)).digest("hex"), checks: [],
    limits: ["Owned loopback SSH with a real Bash PTY and isolated application data.", "Public Harness input and actual Metal screenshot; physical keyboard and IME are not exercised."],
};
const shown = (node: any) => node && !node.hidden && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect?.w > 0 && node.rect?.h > 0;
const content = (node: any): string => shown(node) ? (node.text ?? "") + (node.children ?? []).map(content).join("") : "";
const visible = (id: string) => waitFor(async () => (await query(id)).find(shown) ?? null, 15000);
const hidden = (id: string) => waitFor(async () => !(await query(id)).some(shown) || null, 10000);
const press = async (name: string, mods?: any) => assert((await key(name, mods)).ok);
const type = async (text: string) => assert((await type_(text)).ok);
async function click(id: string) {
    const node = await visible(id);
    assert((await clickAt(node.rect.x + node.rect.w / 2, node.rect.y + node.rect.h / 2)).ok);
}
async function screen() { return (await query("terminal.surface")).map(content).join(""); }
async function received() { return readFile(join(peerOutput, "received-1.bin")); }
let failure: unknown;
try {
    const ready = await waitFor(async () => {
        if (peer.exitCode !== null) throw new Error("SSH fixture exited; inspect peer.log");
        try { return JSON.parse(await readFile(join(peerOutput, "ready.json"), "utf8")); } catch { return null; }
    }, 15000);
    await writeFile(join(peerOutput, "bench.log"), Array.from({ length: 250 }, (_, i) => `bench-output-${i}\n`).join(""));
    await writeFile(join(peerOutput, ".bashrc"), `unset PROMPT_COMMAND\nPS1='tab-history# '\ncd '${peerOutput.replaceAll("'", "'\\''")}'\n`);
    await writeFile(join(data, "config.toml"), '[completion]\nenabled=true\n[ssh]\nauto_shell_integration=false\n[ui]\ntheme="dark"\nfont_family="Menlo"\n');
    await writeFile(join(data, "known_hosts"), ready.known_host);
    await writeFile(join(data, "hosts.toml"), `[registry]\nschema_version=2\nrevision=1\nnext_connection_id=2\nnext_group_id=1\n[[hosts]]\nconnection_id=1\nrevision=1\nprotocol="ssh"\nauth_mode="password"\noptions={strict_host_key=true}\nname="Tab history SSH"\nhost="127.0.0.1"\nport=${ready.port}\nuser="${ready.user}"\nauth={password="${ready.password}"}\n`);
    process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
    app = spawn(binary, [], { env: { ...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0", ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1" }, stdio: ["ignore", appLog.fd, appLog.fd] });
    appEnded = new Promise(resolve_ => app!.once("close", resolve_));
    await waitForServerReady();
    assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), app.pid);
    await resizeWindow(1200, 800);
    await click("sidebar.host"); await press("return");
    await waitFor(async () => (await screen()).includes("tab-history#") || null, 30000);
    await click("terminal.surface");
    await waitFor(async () => (await focused()).test_id === "terminal.input" || null);
    // The first prompt can be painted before the connection UI has finished
    // attaching its native input handlers (the existing SSH fixtures settle too).
    await sleep(1200);
    await type("cat ben");
    await waitFor(async () => (await screen()).includes("cat ben") || null);
    await press("tab");
    await waitFor(async () => (await screen()).includes("cat bench.log") || null);
    await hidden("terminal.completion");
    assert.equal((await received()).toString(), "cat ben\t");
    report.checks.push("Native Tab reaches Bash unchanged and completes the actual bench.log filename; the application menu stays closed");
    await press("return");
    await waitFor(async () => (await screen()).includes("bench-output-249") || null);
    await type("cat");
    const menu = await visible("terminal.completion");
    assert(content(menu).includes("cat bench.log"));
    assert(!(content(menu).includes("cat ben历史")), "The partial pre-Tab input must not become history");
    await sleep(200);
    assert((await screenshot(join(output, "cat-bench-history.png"))).ok);
    await writeFile(join(output, "completion.json"), JSON.stringify(await query("terminal.completion"), null, 2));
    report.checks.push("After cat bench.log prints 250 real lines, typing cat automatically offers cat bench.log");
    const beforeRight = await received();
    await press("right"); await hidden("terminal.completion");
    await waitFor(async () => (await received()).length > beforeRight.length || null);
    assert.equal((await received()).subarray(beforeRight.length).toString(), " bench.log");
    report.checks.push("Right adopts only the missing suffix, with no Enter or erase controls");
    await press("u", { ctrl: true });
    await waitFor(async () => (await received()).at(-1) === 0x15 || null);
    await type("exit"); await press("return");
    await waitFor(async () => {
        try { return JSON.parse(await readFile(join(peerOutput, "closed-1.json"), "utf8")).exit_code === 0 || null; } catch { return null; }
    }, 15000);
    assert((await request("POST", "/zerowork/windows", { action: "quit" })).ok);
    await waitFor(async () => app!.exitCode === 0 || null, 15000);
    report.checks.push("Owned SSH shell exits with code 0 and the application quits normally");
    report.status = "passed";
} catch (error) {
    failure = error; report.status = "failed"; report.error = String(error);
    if (app?.exitCode === null) await screenshot(join(output, "failure.png")).catch(() => {});
} finally {
    if (app && app.exitCode === null && app.signalCode === null) {
        app.kill("SIGTERM"); await Promise.race([appEnded, sleep(3000)]);
        if (app.exitCode === null && app.signalCode === null) { app.kill("SIGKILL"); await appEnded; }
    }
    if (peer.exitCode === null && peer.signalCode === null) {
        peer.kill("SIGTERM"); await Promise.race([peerEnded, sleep(3500)]);
        if (peer.exitCode === null && peer.signalCode === null) { peer.kill("SIGKILL"); await peerEnded; }
    }
    await peerLog.close(); await appLog.close();
    await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
    await rm(isolated, { recursive: true, force: true });
}
console.log(JSON.stringify({ status: report.status, output, error: report.error }));
if (failure) throw failure;
