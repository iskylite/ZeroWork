/** Frozen V3 appearance acceptance using a privately prefixed test-mode binary.
 * node e2e/appearance.ts --out DIR [--binary PATH]
 * Seeds ordinary isolated config + a valid PNG; this does NOT test a native picker.
 * Uses public Harness input/query APIs and real Metal screenshots, never the full tree.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, writeFile, rm, realpath } from "node:fs/promises";
import { deflateSync } from "node:zlib";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const prefix = process.env.ZW_APPEARANCE_TEST_PREFIX ?? "/tmp/zw-appearance-v3";
const { waitForServerReady, waitFor, query, inputState, clickTestId, key, type_, resizeWindow, screenshot, sleep, scrollAt } = await import(join(prefix, "share/zenit/harness/client.ts"));

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2), options: Record<string, string> = {};
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--out"].includes(args[i]) && args[i + 1], `Invalid option ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--out"], "--out is required");
const output = resolve(options["--out"]);
const binary = resolve(options["--binary"] ?? join(prefix,"bin/zerowork"));
const binaryHash = createHash("sha256").update(await readFile(binary)).digest("hex");
const isolated = await realpath(await mkdtemp(join(tmpdir(), "zerowork-appearance-v3-")));
const rpc = join(isolated, "rpc"), data = join(isolated, "data");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data)]);
const image = join(data, "background.png"), configPath = join(data, "config.toml");
// Geometric, non-photographic 240×160 quadrants expose fit/alignment/blur.
function crc32(bytes: Buffer): number { let crc=0xffffffff;for(const byte of bytes){crc^=byte;for(let i=0;i<8;i++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}return (crc^0xffffffff)>>>0; }
function chunk(kind: string, body: Buffer): Buffer {const type=Buffer.from(kind),len=Buffer.alloc(4),crc=Buffer.alloc(4);len.writeUInt32BE(body.length);crc.writeUInt32BE(crc32(Buffer.concat([type,body])));return Buffer.concat([len,type,body,crc]);}
const raw=Buffer.alloc(160*(1+240*4));for(let y=0;y<160;y++)for(let x=0;x<240;x++){const at=y*961+1+x*4;const color=y<80?(x<120?[235,74,67]:[68,190,105]):(x<120?[71,129,232]:[242,192,65]);raw.set([...color,255],at);}
const ihdr=Buffer.alloc(13);ihdr.writeUInt32BE(240);ihdr.writeUInt32BE(160,4);ihdr[8]=8;ihdr[9]=6;
const fixtureBytes=Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),chunk('IHDR',ihdr),chunk('IDAT',deflateSync(raw)),chunk('IEND',Buffer.alloc(0))]);
await writeFile(image,fixtureBytes);
const fixtureHash=createHash('sha256').update(fixtureBytes).digest('hex');
const baseline = `[meta]
config_revision = 1
[ui]
theme = "dark"
font_family = "Menlo"
font_size = 14
font_weight = "regular"
line_height = 1.5
[ui.materials]
blur_px = 4
[ui.materials.background]
enabled = true
path = ${JSON.stringify(image)}
fit = "fill"
alignment_x = "center"
alignment_y = "center"
transparency = 25
`;
await writeFile(configPath, baseline);
await writeFile(join(output, "config-before.toml"), baseline);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(output, "app.log"), "w");
const child = spawn(binary, [], { cwd: root, env: {
  ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_ISOLATE_POINTER: "1",
  ZENIT_E2E_BACKGROUND: "1", ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: "0",
}, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>((done) => child.once("close", () => done()));
let launchError: Error | undefined;
child.once("error", (error) => { launchError = error; });
const report: Record<string, unknown> = {
  status: "running", binary, binary_sha256: binaryHash, pid: child.pid,
  started_at: new Date().toISOString(), storage: "isolated temporary config, image and file RPC",
  background_source: "normal saved config fixture; real application worker decodes and prepares it",
  checks: [], captures: [], fixture_sha256: fixtureHash, limits: [
    "Native image/theme file picker, cancellation and replacement require separate native UI acceptance; no picker success is claimed.",
    "Harness synthetic text/key events do not prove real IME or physical modifier release.",
    "Screenshots are captured for visual review; this script does not assert pixel parity with the frozen HTML.",
    "Own-process SIGTERM cleanup is not evidence of normal application shutdown.",
  ],
};
const checks = report.checks as string[];
type Node = Awaited<ReturnType<typeof query>>[number] & { hidden?: boolean; effective_opacity?: number };
function shown(node: Node): boolean {
  return node.hidden !== true && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0;
}
async function visible(id: string): Promise<Node> {
  return await waitFor(async () => (await query(id)).find(shown) ?? null);
}
async function hidden(id: string): Promise<void> {
  await waitFor(async () => !(await query(id)).some(shown) || null);
}
async function click(id: string): Promise<void> {
  await visible(id);
  // The public click API brings the target into its real ScrollArea viewport.
  assert((await clickTestId(id)).ok, `Click ${id}`);
}
async function expectInput(id: string, value: string): Promise<void> {
  await waitFor(async () => (await inputState(id)).buffer === value || null);
}
async function edit(id: string, value: string): Promise<void> {
  await click(id);
  assert((await key("a", { cmd: true })).ok);
  assert((await type_(value)).ok);
  assert((await key("return")).ok);
  await expectInput(id, value);
}
async function footer(value: string): Promise<void> {
  await waitFor(async () => (await visible("settings.footer.state")).text === value || null);
}
async function openSettings(): Promise<void> {
  await click("toolbar.settings");
  await click("settings.nav.appearance");
  await visible("settings.appearance.font.header");
}
function descendants(): { pid: number; parent: number; command: string }[] {
  const all = execFileSync("/bin/ps", ["-axo", "pid=,ppid=,comm="], { encoding: "utf8" }).trim().split("\n").flatMap((line) => {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/);
    return match ? [{ pid: Number(match[1]), parent: Number(match[2]), command: match[3] }] : [];
  });
  const owned = new Set([child.pid]);
  for (let i = 0; i < all.length; i++) {
    let changed = false;
    for (const process of all) if (owned.has(process.parent) && !owned.has(process.pid)) { owned.add(process.pid); changed = true; }
    if (!changed) break;
  }
  return all.filter((process) => process.pid !== child.pid && owned.has(process.pid));
}
const evidenceIds = [
  "settings.header.title", "settings.close", "settings.footer.state", "settings.appearance.font.header", "settings.background.preview", "settings.background.material.surface", "settings.background.material.layer", "settings.font.preview.caret", "settings.theme.remove.current", "settings.theme.import",
  "settings.field.font_family", "settings.field.font_size", "settings.field.line_height",
  "settings.font.status", "settings.background.state", "settings.field.transparency",
  "settings.field.blur_px", "settings.materials.preview.actions", "settings.confirmation",
];
async function capture(name: string): Promise<void> {
  await sleep(250);
  const path = join(output, `${name}.png`);
  assert((await screenshot(path)).ok, `Screenshot ${name}`);
  const queries = Object.fromEntries(await Promise.all(evidenceIds.map(async (id) => [id, await query(id)])));
  await writeFile(join(output, `${name}.queries.json`), JSON.stringify(queries, null, 2));
  (report.captures as string[]).push(path);
}
function configValue(source: string, section: string, field: string): unknown {
  let current = "";
  for (const raw of source.split("\n")) {
    const line = raw.trim();
    if (line.startsWith("[")) { current = line.slice(1, -1); continue; }
    if (current !== section) continue;
    const match = line.match(/^([a-z_]+)\s*=\s*(.+)$/);
    if (match?.[1] === field) return JSON.parse(match[2]);
  }
  throw new Error(`Missing persisted ${section}.${field}`);
}
let failure: unknown;
try {
  await waitForServerReady();
  const owner = JSON.parse(await readFile(join(rpc,"owner.json"),"utf8"));assert.equal(Number(owner.pid),child.pid);
  assert((await resizeWindow(1440,900)).ok);await openSettings();await click("settings.materials.header");
  await waitFor(async()=>(await visible("settings.background.state")).text?.includes("240 × 160")||null);
  const initialPreview=await visible("settings.background.preview");assert.equal(initialPreview.rect.h,116);
  const protectedDelete=await visible("settings.theme.remove.current");assert.notEqual(protectedDelete.focusable,true);
  await capture("01-dark-inline");checks.push("Prepared normal-config PNG and inline preview116; builtin current delete protected; text itermcolors entry");
  await click("settings.field.fit");await click("settings.option.fit.fit");await click("settings.field.alignment");await click("settings.alignment.右下");
  await edit("settings.field.transparency","0");await edit("settings.field.blur_px","0");await click("settings.background.preview");await capture("02-fit-bottom-right");
  await click("settings.field.fit");await click("settings.option.fit.tile");await edit("settings.field.blur_px","12");await edit("settings.field.transparency","42");await click("settings.background.preview");await capture("03-tile-blurred");
  assert.equal(await readFile(configPath,"utf8"),baseline);assert.equal(createHash('sha256').update(await readFile(image)).digest('hex'),fixtureHash);
  await click("settings.toggle.enabled");await visible("settings.field.transparency");await capture("04-background-off-editable");await click("settings.toggle.enabled");
  await click("settings.materials.preview.full");await visible("settings.materials.preview.actions");await click("settings.materials.preview.return");await visible("settings.close");
  await click("settings.appearance.font.header");await edit("settings.field.font_size","18");await click("settings.option.cursor_style.bar");
  await click("settings.font.preview");const caretStates=new Set<number>();for(let i=0;i<12;i++){const n=(await query("settings.font.preview.caret"))[0] as any;caretStates.add(n?.opacity??n?.effective_opacity??1);await sleep(120);}assert(caretStates.size>1,"caret must blink");await click("settings.font.preview");await capture("05-font-bar");
  await click("settings.close");await click("settings.confirmation.cancel");await expectInput("settings.field.font_size","18");await click("settings.close");await click("settings.confirmation.discard");await hidden("settings.close");assert.equal(await readFile(configPath,"utf8"),baseline);
  await openSettings();await expectInput("settings.field.font_size","14");await edit("settings.field.transparency","42");await click("settings.save");await footer("已保存");const saved=await readFile(configPath,"utf8");assert.equal(configValue(saved,"ui.materials.background","transparency"),42);checks.push("Fit, bottom-right, tile, blur12, transparency42, disabled-editability, full-window return, cursor selection/blink, Cancel/Discard and Save checked via real native actions");
  const settingsBody=await visible("settings.viewport");await scrollAt(settingsBody.rect.x+settingsBody.rect.w/2,settingsBody.rect.y+settingsBody.rect.h/2,0,3000);await sleep(150);if (!(await query("settings.theme.strip")).some(shown)) await click("settings.appearance.themes.header");await click("settings.theme.light");await click("settings.save");await footer("已保存");await click("settings.toggle.enabled");await click("settings.save");await footer("已保存");await click("settings.background.preview");await capture("06-light");
  assert((await resizeWindow(860,480)).ok);await click("settings.materials.header");await click("settings.materials.header");await visible("settings.background.preview");await click("settings.background.preview");await capture("07-minimum-scrolled");assert.equal((await visible("settings.background.preview")).rect.h,116);
  assert.equal(createHash('sha256').update(await readFile(image)).digest('hex'),fixtureHash);checks.push("Saved Light with background off, minimum860×480 native scroll/preview116 and source fixture unchanged");
  report.status = "passed";
} catch (error) {
  failure = launchError ?? error;
  report.status = "failed";
  report.error = String(failure);
  if (child.exitCode === null && child.signalCode === null) {
    await Promise.allSettled([capture("failure"), writeFile(join(output, "remaining-processes.json"), JSON.stringify(descendants(), null, 2))]);
  }
} finally {
  // Only this runner's process tree; termination is cleanup, not normal-close proof.
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
