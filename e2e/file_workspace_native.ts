/** Production file-workspace View in a dedicated native component fixture.
 * This run proves real Metal rendering and public synthetic Harness events.
 * It deliberately does not claim filesystem, SFTP, main-app or physical-input acceptance.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, open, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { waitForServerReady, waitFor, query, resizeWindow, screenshot, scrollAt, sleep } from "../zig-out/share/zenit/harness/client.ts";

const options: Record<string, string> = {}, args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--out"].includes(args[i]) && args[i + 1], `Invalid option ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--binary"] && options["--out"], "--binary component-fixture and --out are required");
const output = resolve(options["--out"]), sourceBinary = resolve(options["--binary"]);
await mkdir(output, { recursive: true });
const binary = join(output, "file-workspace-fixture-frozen");
await copyFile(sourceBinary, binary);
const report: Record<string, any> = {
  status: "running", started_at: new Date().toISOString(), source_binary: sourceBinary, binary,
  binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"), stages: [], checks: [], runs: [],
  scope: "Independent production-View component fixture; no actual directory-service or main-application wiring",
  limits: ["All data are explicit bounded UI fixtures, not filesystem or remote directory results.",
    "Background native-window screenshots and synthetic Harness input do not establish physical input/IME correctness.",
    "The component is captured at the Figma workspace rectangle size; application chrome is outside this fixture.",
    "Own-process SIGTERM cleanup is separate from normal application close lifecycle evidence."],
};
function shown(n: any): boolean { return !!n?.rect && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect.w > 0 && n.rect.h > 0; }
function flatten(n: any): any[] { return !n || n.hidden === true || n.visible === false ? [] : [n, ...(n.children ?? []).flatMap(flatten)]; }
async function visible(id: string): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null, 20000); }
async function capture(name: string): Promise<Record<string, any>> {
  await sleep(120);
  const nodes = Object.fromEntries(await Promise.all(["files.workspace", "files.local", "files.remote", "files.breadcrumb", "files.rows", "files.data_clip", "files.columns", "files.error", "files.transfer", "files.new_folder"].map(async id => [id, await query(id)])));
  const path = join(output, `${name}.png`);
  assert((await screenshot(path)).ok, `Native capture ${name}`);
  await writeFile(join(output, `${name}.tree.json`), JSON.stringify(nodes["files.workspace"], null, 2));
  await writeFile(join(output, `${name}.queries.json`), JSON.stringify(nodes, null, 2));
  report.stages.push({ name, at: new Date().toISOString(), screenshot: path, tree: join(output, `${name}.tree.json`) });
  return nodes;
}
async function run(state: "normal" | "empty" | "failed", inspect: () => Promise<void>): Promise<void> {
  const isolated = await mkdtemp(join(tmpdir(), "zerowork-files-fixture-")), rpc = join(isolated, "rpc");
  await mkdir(rpc);
  process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
  const log = await open(join(output, `${state}.app.log`), "w");
  const child = spawn(binary, [`--state=${state}`], { cwd: process.cwd(), env: {
    ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1",
  }, stdio: ["ignore", log.fd, log.fd] });
  const ended = new Promise<void>(done => child.once("close", () => done()));
  const record: Record<string, any> = { state, pid: child.pid, isolated };
  report.runs.push(record);
  try {
    await waitForServerReady();
    const owner = JSON.parse(await readFile(join(rpc, "owner.json"), "utf8"));
    assert.equal(Number(owner.pid), child.pid, "Only this owned background fixture may receive input");
    await visible("files.workspace");
    await inspect();
  } catch (error) {
    record.error = String(error);
    if (child.exitCode === null && child.signalCode === null) {
      try { await capture(`failure-${state}`); } catch (captureError) { record.capture_error = String(captureError); }
    }
    throw error;
  } finally {
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
    await Promise.race([ended, sleep(2000)]);
    if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await ended; }
    record.cleanup = { exit_code: child.exitCode, signal: child.signalCode };
    await log.close();
  }
}
let failure: unknown;
try {
  await run("normal", async () => {
    assert((await resizeWindow(1194, 794)).ok);
    const normal = await capture("00-normal-wide");
    const left = normal["files.local"].find(shown), right = normal["files.remote"].find(shown);
    assert.equal(left.rect.w, 594); assert.equal(right.rect.w, 594);
    assert.equal(left.rect.h, 794); assert.equal(right.rect.x - left.rect.x - left.rect.w, 6);
    assert(flatten(left).filter(n => n.test_id === "files.row" && shown(n)).length > 0, "Actual native file rows");
    report.checks.push("Native wide cards are 594×794 with 6 point gap; production file rows render");
    assert((await resizeWindow(790, 374)).ok);
    const compact = await capture("01-normal-compact");
    const compactLeft = compact["files.local"].find(shown);
    assert.equal(compactLeft.rect.w, 392); assert.equal(compactLeft.rect.h, 374);
    const bodies = compact["files.rows"].filter(shown), columns = compact["files.columns"].filter(shown);
    const clips = compact["files.data_clip"].filter(shown);
    assert.equal(columns[0].rect.w, 490); assert.equal(columns[1].rect.w, 490);
    assert.equal(clips[0].rect.h, 142); assert.equal(clips[1].rect.h, 142);
    assert.equal(clips[0].rect.y + clips[0].rect.h, bodies[0].rect.y + bodies[0].rect.h - 12);
    const x = bodies[0].rect.x + 60, y = bodies[0].rect.y + 45;
    assert((await scrollAt(x, y, -1000, -200)).ok);
    const scrolled = await capture("02-compact-left-scrolled");
    const moved = scrolled["files.columns"].filter(shown);
    assert(moved[0].rect.x < columns[0].rect.x, "Left header follows real horizontal scroll");
    assert.equal(moved[1].rect.x, columns[1].rect.x, "Right card scroll remains independent");
    assert.equal(scrolled["files.breadcrumb"].filter(shown)[0].rect.y, compact["files.breadcrumb"].filter(shown)[0].rect.y);
    report.checks.push("Native 392×374 cards retain 490 point columns; left horizontal scroll moves its header independently and paths remain fixed; actual data clips reserve the 12 point horizontal rail");
  });
  await run("empty", async () => {
    const nodes = await capture("03-empty-remote");
    const remote = nodes["files.remote"].find(shown), all = flatten(remote);
    assert(all.some(n => n.text === "目录为空" && shown(n)));
    assert.equal(all.filter(n => n.test_id === "files.row" && shown(n)).length, 0);
    assert.equal(nodes["files.error"].filter(shown).length, 0);
    report.checks.push("Actual native empty remote has zero rows and a distinct empty state without error");
  });
  await run("failed", async () => {
    const nodes = await capture("04-failed-stale-remote");
    const remote = nodes["files.remote"].find(shown), all = flatten(remote);
    assert(all.some(n => n.test_id === "files.row" && shown(n)), "Original rows remain after read failure");
    const error = nodes["files.error"].find(shown);
    assert.equal(error.rect.h, 108);
    assert(flatten(error).some(n => (n.text ?? "").includes("Connection lost")));
    report.checks.push("Actual native failed remote preserves old rows and renders the 108 point Connection lost recovery region");
  });
  report.status = "passed";
} catch (error) { failure = error; report.status = "failed"; report.error = String(error); }
finally { report.finished_at = new Date().toISOString(); await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2)); }
console.log(`${report.status}: ${join(output, "report.json")}`);
if (failure) throw failure;
