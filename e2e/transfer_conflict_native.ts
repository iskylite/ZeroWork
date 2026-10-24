/** Native production conflict View, with explicit synthetic frozen snapshots.
 * No Manager, SFTP, local file transfer, network request or IO success receipt.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, tree, clickTestId, key, type_, inputState, resizeWindow, screenshot, stats, mouseMove, scrollAt, sleep } from "../zig-out/share/zenit/harness/client.ts";

const options: Record<string, string> = {};
for (let index = 2; index < process.argv.length; index += 2) {
  assert(["--binary", "--out"].includes(process.argv[index]) && process.argv[index + 1]);
  options[process.argv[index]] = process.argv[index + 1];
}
assert(options["--binary"] && options["--out"], "--binary and --out are required");
const binary = resolve(options["--binary"]), output = resolve(options["--out"]);
await mkdir(output, { recursive: true });
const report: any = {
  status: "running", started_at: new Date().toISOString(), binary,
  binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"),
  evidence_kind: { native_zenit_window: true, production_view: true, synthetic_frozen_snapshot: true, synthetic_input: true, frame_pacing: "poll (SDK wall clock, background fixture)", real_transfer_io: false, network_requests: 0, vm_mutations: 0 },
  prototypes: { choice: "223:330800", rename: "236:475949", keep_both: "236:477759", remote: "236:481403", local: "321:911916" },
  scenes: [], limits: ["The fixture does not create or run a Manager, transfer, SSH or SFTP session.", "Callbacks log original keys only; they do not acknowledge real IO completion.", "Tree queries and GPU screenshots are sequential rather than atomic. Frame counters are retained for attribution.", "Own isolated process SIGTERM is cleanup, not normal application shutdown evidence."],
};
function shown(node: any): boolean { return !!node?.rect && node.visible !== false && node.hidden !== true && (node.opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0; }
async function visible(id: string): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null, 10000); }
async function click(id: string): Promise<void> { await visible(id); assert((await clickTestId(id)).ok, `click ${id}`); }
const epsilon = 0.6;
async function scene(kind: string, body: (current: any, capture: (name: string, w: number, h: number) => Promise<any>) => Promise<void>): Promise<void> {
  const isolated = await mkdtemp(join(tmpdir(), `zerowork-conflict-${kind}-`)), rpc = join(isolated, "rpc"), destination = join(output, kind);
  await Promise.all([mkdir(rpc), mkdir(destination)]);
  process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
  const log = await open(join(destination, "app.log"), "w");
  const child = spawn(binary, [`--scene=${kind}`], { env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1" }, stdio: ["ignore", log.fd, log.fd] });
  const ended = new Promise<void>(done => child.once("close", () => done()));
  const current: any = { scene: kind, pid: child.pid, isolated, status: "running", stages: [] };
  report.scenes.push(current);
  async function capture(name: string, w: number, h: number): Promise<any> {
    const dialog = await waitFor(async () => {
      const node = (await query("transfer.conflict")).find(shown);
      return node && Math.abs(node.rect.w - w) <= epsilon && node.rect.h <= h + epsilon ? node : null;
    }, 10000);
    await mouseMove(1, 1);
    // Observational queries must not demand new frames from an already idle
    // window. Wait for the real Modal enter animation rather than forcing or
    // clock-stepping the renderer to make a screenshot look settled.
    await waitFor(async () => {
      const overlay = (await query("transfer.conflict.overlay")).find(shown);
      const card = (await query("transfer.conflict")).find(shown);
      return overlay && card && (overlay.opacity ?? 1) >= 0.999 && (card.opacity ?? 1) >= 0.999 ? card : null;
    }, 10000);
    const before = await stats();
    const measuredAt = new Date().toISOString();
    const nodes: Record<string, any> = {};
    for (const id of ["transfer.conflict", "transfer.conflict.viewport", "transfer.conflict.footer", "transfer.conflict.skip", "transfer.conflict.save_as", "transfer.conflict.keep_both", "transfer.conflict.overwrite", "transfer.conflict.name", "transfer.conflict.apply", "transfer.conflict.back", "transfer.conflict.confirm.paths"]) nodes[id] = (await query(id)).filter(shown);
    await writeFile(join(destination, `${name}.tree.json`), JSON.stringify(await tree(), null, 2));
    await writeFile(join(destination, `${name}.queries.json`), JSON.stringify(nodes, null, 2));
    const path = join(destination, `${name}.png`);
    assert((await screenshot(path)).ok);
    const after = await stats();
    const stage = { name, screenshot: path, measured_at: measuredAt, screenshot_at: new Date().toISOString(), query_screenshot_atomic: false, expected_card: { w, h }, dialog: dialog.rect, nodes, frames: { before: before.frame_count, after: after.frame_count } };
    current.stages.push(stage);
    console.log(`[conflict-native] ${kind}/${name}`);
    return stage;
  }
  try {
    await waitForServerReady();
    const owner = JSON.parse(await readFile(join(rpc, "owner.json"), "utf8"));
    assert.equal(Number(owner.pid), child.pid, "Only this background isolated process may receive events");
    await body(current, capture);
    current.status = "passed";
  } catch (error) {
    current.status = "failed"; current.error = String(error);
    if (child.exitCode === null && child.signalCode === null) try {
      await writeFile(join(destination, "failure.tree.json"), JSON.stringify(await tree(), null, 2));
      await screenshot(join(destination, "failure.png"));
    } catch (captureError) { current.capture_error = String(captureError); }
    throw error;
  } finally {
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
    await Promise.race([ended, sleep(2000)]);
    if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await ended; }
    current.cleanup = { exit_code: child.exitCode, signal: child.signalCode };
    current.callback_log = await readFile(join(destination, "app.log"), "utf8");
    await log.close();
  }
}
let failure: unknown;
try {
  await scene("choice", async (current, capture) => {
    assert((await resizeWindow(636, 425)).ok);
    const initial = await capture("00-no-default-selection", 620, 381);
    for (const id of ["skip", "save_as", "keep_both", "overwrite"]) {
      const row = initial.nodes[`transfer.conflict.${id}`][0];
      assert.equal(row.rect.w, 596); assert.equal(row.rect.h, 34);
    }
    await click("transfer.conflict.apply");
    assert(!/CONFLICT_UI_FIXTURE event=/.test(await readFile(join(output, "choice/app.log"), "utf8")), "No default approval");
    await click("transfer.conflict.save_as");
    assert((await resizeWindow(636, 439)).ok);
    await click("transfer.conflict.name");
    assert((await key("a", { cmd: true })).ok);
    assert((await type_("release-final.tar.gz")).ok);
    assert.equal((await inputState("transfer.conflict.name")).buffer, "release-final.tar.gz");
    await capture("01-rename-draft", 620, 395);
    await click("transfer.conflict.keep_both");
    assert((await resizeWindow(636, 425)).ok);
    await capture("02-keep-both", 620, 381);
    await click("transfer.conflict.save_as");
    assert.equal((await inputState("transfer.conflict.name")).buffer, "release-final.tar.gz", "Choice switches retain exact draft");
    await click("transfer.conflict.overwrite");
    await capture("03-overwrite-selected", 620, 381);
    await click("transfer.conflict.close");
    await waitFor(async () => /event=pause_request_only job=42 attempt=1 session=101 generation=9/.test(await readFile(join(output, "choice/app.log"), "utf8")) ? true : null);
    current.checks = ["No default Apply dispatch", "Real pointer four-choice state", "Real Input typing retains exact rename across choices", "Choice close requests pause only for original captured key"];
  });
  await scene("remote", async (current, capture) => {
    assert((await resizeWindow(476, 292)).ok);
    await capture("00-remote-overwrite", 460, 256);
    await click("transfer.conflict.back");
    await waitFor(async () => /event=return_to_choice job=42 attempt=1 intent=501 session=101 generation=9 revision=1/.test(await readFile(join(output, "remote/app.log"), "utf8")) ? true : null);
    assert(!/event=pause_request_only|event=confirm_overwrite/.test(await readFile(join(output, "remote/app.log"), "utf8")));
    current.checks = ["Exact 460×276 remote confirmation", "Back emits original return-to-choice identity only"];
  });
  await scene("local", async (current, capture) => {
    assert((await resizeWindow(496, 244)).ok);
    await capture("00-local-overwrite", 480, 199);
    await click("transfer.conflict.apply");
    await waitFor(async () => /event=confirm_overwrite job=42 attempt=1 intent=501 session=101 generation=9 revision=1/.test(await readFile(join(output, "local/app.log"), "utf8")) ? true : null);
    current.checks = ["Exact 480×228 local confirmation", "Explicit confirm emits original captured identity without claiming IO"];
  });
  await scene("batch", async (current, capture) => {
    assert((await resizeWindow(860, 480)).ok);
    const before = await capture("00-batch-top-fixed-footer", 480, 464);
    const viewport = before.nodes["transfer.conflict.viewport"][0].rect;
    const beforePaths = before.nodes["transfer.conflict.confirm.paths"][0].rect;
    assert(beforePaths.h > viewport.h, "Actual batch paths overflow the actual body viewport");
    assert((await scrollAt(viewport.x + 40, viewport.y + 30, 0, -600)).ok);
    await waitFor(async () => (await visible("transfer.conflict.confirm.paths")).rect.y < beforePaths.y - 50 ? true : null);
    const after = await capture("01-batch-scrolled-fixed-footer", 480, 464);
    assert.deepEqual(after.nodes["transfer.conflict.footer"][0].rect, before.nodes["transfer.conflict.footer"][0].rect, "Footer stays outside scrolling body");
    assert((await key("escape")).ok);
    await waitFor(async () => /event=return_to_choice job=42/.test(await readFile(join(output, "batch/app.log"), "utf8")) ? true : null);
    current.checks = ["20 full paths create real body overflow", "Real wheel scroll moves body while footer geometry remains fixed", "Escape returns to original choice rather than pausing or cancelling"];
  });
  report.status = "passed";
} catch (error) { failure = error; report.status = "failed"; report.error = String(error); }
finally {
  report.finished_at = new Date().toISOString();
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
}
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
