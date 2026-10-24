/** Theme-library acceptance against an existing test-mode binary.
 * node e2e/theme_library.ts --out DIR [--binary PATH]
 * Seeds one already-installed managed theme and an ordinary saved background.
 * This does not exercise the native import picker or claim Figma pixel parity.
 */
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { waitForServerReady, waitFor, query, inputState, clickTestId, key, type_, resizeWindow, screenshot, sleep } from "../zig-out/share/zenit/harness/client.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2), options: Record<string, string> = {};
for (let i = 0; i < args.length; i += 2) {
  assert(["--binary", "--out"].includes(args[i]) && args[i + 1], `Invalid option ${args[i]}`);
  options[args[i]] = args[i + 1];
}
assert(options["--out"], "--out is required");
const output = resolve(options["--out"]);
const binary = resolve(options["--binary"] ?? join(root, "zig-out/bin/zerowork"));
const binaryHash = createHash("sha256").update(await readFile(binary)).digest("hex");
const isolated = await mkdtemp(join(tmpdir(), "zerowork-theme-library-ui-"));
const rpc = join(isolated, "rpc"), data = join(isolated, "data");
await Promise.all([mkdir(output, { recursive: true }), mkdir(rpc), mkdir(data)]);
await mkdir(join(data, "themes"));

// Normal persisted-library fixture, loaded by the production loadInstalled path.
// The source and its SHA-256 identity follow imported_theme.Managed exactly.
const colors = [...Array.from({ length: 16 }, (_, index) => `Ansi ${index} Color`), "Background Color", "Foreground Color", "Cursor Color"];
const source = '<?xml version="1.0"?><plist version="1.0"><dict>' + colors.map((name, index) => {
  const value = index === 16 ? 0.1 : index === 17 ? 0.9 : 0.6;
  return `<key>${name}</key><dict><key>Red Component</key><real>${value}</real><key>Green Component</key><real>${value}</real><key>Blue Component</key><real>${value}</real></dict>`;
}).join("") + "</dict></plist>";
const digest = createHash("sha256").update(source).digest("hex");
const installedId = `import:${digest}`;
const managedPath = join(data, "themes", `${digest}.json`);
const managed = JSON.stringify({ name: "E2E Installed Theme", source });
await writeFile(managedPath, managed);
const image = join(data, "background.png"), configPath = join(data, "config.toml");
await writeFile(image, Buffer.from(
  "89504e470d0a1a0a0000000d49484452" + "000000010000000108060000001f15c489" +
  "0000000d49444154789c63f8cfc0f01f00050001ff89993d1d" + "0000000049454e44ae426082", "hex"));
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
const checks: string[] = [], captures: string[] = [];
const report: Record<string, unknown> = {
  status: "running", binary, binary_sha256: binaryHash, pid: child.pid,
  started_at: new Date().toISOString(), storage: "isolated temporary config, installed theme, background and file RPC",
  fixture: { installed_theme_id: installedId, installation: "pre-existing managed-library fixture; not a picker import" },
  functional: { status: "running", checks },
  visual: { status: "not_reviewed", captures, limitation: "Actual Metal captures are evidence for manual review; no pixel parity or Figma comparison is asserted." },
  system_limits: [
    "Native theme/image picker success, cancellation and replacement are not exercised; they require separate native acceptance.",
    "Synthetic Harness input does not prove real IME, physical modifier release or OS file-dialog behavior.",
    "Runner termination is process cleanup, not evidence of normal application shutdown.",
  ],
};
type Node = Awaited<ReturnType<typeof query>>[number] & { hidden?: boolean; effective_opacity?: number };
const builtins = ["dark", "light", "sauber", "catppuccin-mocha", "dracula", "dark-pro", "solarized-dark", "nord"];
const themeIds = [...builtins, installedId];
const tileIds = new Set(themeIds.map((id) => `settings.theme.${id}`));
function shown(node: Node): boolean {
  return node.hidden !== true && node.visible !== false && (node.effective_opacity ?? 1) > 0 && node.rect.w > 0 && node.rect.h > 0;
}
function text(node: Node): string {
  return (node.text ?? "") + (node.children ?? []).map((child) => text(child)).join("");
}
async function visible(id: string): Promise<Node> {
  return await waitFor(async () => (await query(id)).find(shown) ?? null);
}
async function hidden(id: string): Promise<void> {
  await waitFor(async () => !(await query(id)).some(shown) || null);
}
async function click(id: string): Promise<void> {
  await visible(id);
  assert((await clickTestId(id)).ok, `Click ${id}`);
}
async function expectInput(id: string, value: string): Promise<void> {
  await waitFor(async () => (await inputState(id)).buffer === value || null);
}
async function edit(id: string, value: string, commit = true): Promise<void> {
  await click(id);
  assert((await key("a", { cmd: true })).ok);
  assert((await key("backspace")).ok);
  if (value) assert((await type_(value)).ok);
  if (commit) assert((await key("return")).ok);
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
async function openLibrary(): Promise<void> {
  if (!(await query("settings.theme.search")).some(shown)) await click("settings.theme.library.open");
  await visible("settings.theme.search");
}
async function listed(): Promise<string[]> {
  const grid = await visible("settings.theme.grid");
  const result: string[] = [];
  const visit = (node: Node): void => {
    if (tileIds.has(node.test_id ?? "")) result.push(node.test_id!.slice("settings.theme.".length));
    for (const child of node.children ?? []) visit(child);
  };
  visit(grid);
  return result.sort(); // Includes grid records below the ScrollArea viewport.
}
async function expectListed(expected: string[]): Promise<void> {
  await waitFor(async () => JSON.stringify(await listed()) === JSON.stringify([...expected].sort()) || null);
}
function configValue(source: string, section: string, field: string): unknown {
  let current = "";
  for (const raw of source.split("\n")) {
    const line = raw.trim();
    if (line.startsWith("[")) { current = line.slice(1, -1); continue; }
    const match = line.match(/^([a-z_]+)\s*=\s*(.+)$/);
    if (current === section && match?.[1] === field) return JSON.parse(match[2]);
  }
  throw new Error(`Missing persisted ${section}.${field}`);
}
async function persisted(theme: string, fontSize: number): Promise<string> {
  return await waitFor(async () => {
    const source = await readFile(configPath, "utf8");
    return configValue(source, "ui", "theme") === theme && configValue(source, "ui", "font_size") === fontSize ? source : null;
  });
}
const evidenceIds = [
  "settings.theme.current", "settings.theme.dismissed", "settings.theme.search", "settings.theme.grid", "settings.theme.empty",
  "settings.theme.filter.all", "settings.theme.filter.favorites", "settings.theme.filter.imported", `settings.theme.remove.${installedId}`,
  "settings.footer.state", "settings.confirmation", "settings.field.font_size", "settings.font.status",
  "settings.materials.preview.actions", "local.status.theme", "status.theme", "status.theme.feedback",
];
async function capture(name: string): Promise<void> {
  await sleep(250);
  const path = join(output, `${name}.png`);
  assert((await screenshot(path)).ok, `Screenshot ${name}`);
  const queries = Object.fromEntries(await Promise.all(evidenceIds.map(async (id) => [id, await query(id)])));
  await writeFile(join(output, `${name}.queries.json`), JSON.stringify(queries, null, 2));
  captures.push(path);
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
let failure: unknown;
try {
  await waitForServerReady();
  const owner = JSON.parse(await readFile(join(rpc, "owner.json"), "utf8"));
  assert.equal(Number(owner.pid), child.pid, "Harness must belong to this isolated process");
  assert((await resizeWindow(1440, 900)).ok);
  await click("workspace.empty.local");
  await visible("local.status.theme");
  await openSettings();
  await openLibrary();
  await expectListed(themeIds);
  await footer("已保存");
  await edit("settings.theme.search", "nOrD", false);
  await expectListed(["nord"]);
  await click("settings.theme.library.close");
  await hidden("settings.theme.search");
  await openLibrary();
  await expectInput("settings.theme.search", "nOrD");
  await expectListed(["nord"]);
  await edit("settings.theme.search", "zerowork-no-matching-theme", false);
  await visible("settings.theme.empty");
  await expectListed([]);
  assert((await key("return")).ok);
  await edit("settings.theme.search", "", false);
  await expectListed(themeIds);
  await click("settings.theme.favorite.nord");
  await waitFor(async () => {
    try {
      const metadata = JSON.parse(await readFile(join(data, "themes/favorites.json"), "utf8"));
      return metadata.some((entry: { id: string; favorite: boolean }) => entry.id === "nord" && entry.favorite) || null;
    } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return null; throw error; }
  });
  await click("settings.theme.filter.favorites");
  await expectListed(["nord"]);
  await capture("library-favorite-filter");
  await click("settings.theme.filter.imported");
  await expectListed([installedId]);
  await footer("已保存");
  assert.equal(await readFile(configPath, "utf8"), baseline, "Search, filters and favorites must not dirty or publish Config");
  checks.push("Production library loads 8 built-ins plus the installed fixture; case-insensitive search, no-match Enter, retained query, Favorites and Imported filters preserve saved Config");

  await click(`settings.theme.${installedId}`);
  await visible(`settings.theme.selected.${installedId}`);
  await waitFor(async () => text(await visible(`settings.theme.${installedId}`)).includes("预览中") || null);
  await footer("未保存");
  assert.equal(await readFile(configPath, "utf8"), baseline, "Theme selection is a draft until Save");
  await capture("library-theme-draft");
  await click("settings.close");
  await click("settings.confirmation.discard");
  await hidden("settings.close");
  assert.equal(await readFile(configPath, "utf8"), baseline, "Discard must not publish the selected theme");
  await openSettings();
  await openLibrary();
  await click("settings.theme.filter.all");
  await edit("settings.theme.search", "", false);
  await visible("settings.theme.selected.dark");
  await click(`settings.theme.${installedId}`);
  await click("settings.save");
  await footer("已保存");
  const saved = await persisted(installedId, 14);
  const savedRevision = Number(configValue(saved, "meta", "config_revision"));
  assert(savedRevision > 1, "Saving the selected theme must advance Config revision");
  await writeFile(join(output, "config-library-saved.toml"), saved);
  await waitFor(async () => text(await visible(`settings.theme.${installedId}`)).includes("使用中") || null);
  const remove = await visible(`settings.theme.remove.${installedId}`);
  assert.notEqual(remove.focusable, true, "Current imported theme must expose a disabled Remove control");
  await click(`settings.theme.remove.${installedId}`);
  await sleep(250);
  assert.equal(await readFile(managedPath, "utf8"), managed, "Protected current theme must keep its managed file");
  assert.equal(await readFile(configPath, "utf8"), saved, "Protected Remove must not change saved Config");
  await visible(`settings.theme.selected.${installedId}`);
  await capture("library-saved-current-protected");
  checks.push("Selecting an installed theme remains a draft; Discard restores Dark; Save persists the stable imported identity; clicking its protected current-theme Remove preserves the library and Config");

  await click("settings.theme.library.close");
  if (!(await query("settings.field.font_size")).some(shown)) await click("settings.appearance.font.header");
  await expectInput("settings.field.font_size", "14");
  await edit("settings.field.font_size", "18");
  await footer("未保存");
  await waitFor(async () => text(await visible("settings.background.state")).includes("本地 · 1 × 1") || null);
  // The production material-preview route exposes the footer without discarding
  // the open settings draft. No direct internal controller or hidden-node click.
  await click("settings.materials.preview.open");
  await visible("settings.materials.preview.actions");
  await hidden("settings.close");
  await click("local.status.theme");
  await visible("status.theme");
  await click("status.theme.item.nord");
  const immediate = await persisted("nord", 14);
  assert(Number(configValue(immediate, "meta", "config_revision")) > savedRevision);
  await waitFor(async () => text(await visible("status.theme.feedback")).includes("已应用") || null);
  await writeFile(join(output, "config-immediate-theme.toml"), immediate);
  await capture("footer-immediate-theme");
  await click("status.theme.close");
  await click("settings.materials.preview.return");
  await visible("settings.close");
  await expectInput("settings.field.font_size", "18");
  await footer("未保存");
  await capture("font-draft-after-immediate-theme");
  await click("settings.save");
  await footer("已保存");
  const merged = await persisted("nord", 18);
  assert.equal(configValue(merged, "ui", "font_family"), "Menlo");
  assert(Number(configValue(merged, "meta", "config_revision")) > Number(configValue(immediate, "meta", "config_revision")));
  await writeFile(join(output, "config-after.toml"), merged);
  await capture("theme-and-font-saved");
  checks.push("Through real material preview, the Local footer commits Nord with saved font size 14; returning keeps the unsaved 18 draft; Save merges size 18 without overwriting the newer global Nord selection");
  report.status = "passed";
  (report.functional as { status: string }).status = "passed";
} catch (error) {
  failure = launchError ?? error;
  report.status = "failed";
  (report.functional as { status: string }).status = "failed";
  report.error = String(failure);
  if (child.exitCode === null && child.signalCode === null) await Promise.allSettled([capture("failure")]);
} finally {
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
