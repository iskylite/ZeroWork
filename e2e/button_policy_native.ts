import {nativeThemeData} from './native_theme_data.mjs';
/** Retained production views/recipes in the isolated native button acceptance window. */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, realpath, readFile, writeFile, open, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const prefix = resolve(process.argv[2]), out = resolve(process.argv[3]);
const h = await import(pathToFileURL(join(prefix, "share/zenit/harness/client.ts")).href);
const binary = join(prefix, "bin/button-policy-preview");
const themes = Object.keys(nativeThemeData.themes);
const selected = new Set(["dark", "light", "sauber", "mist", "nord", "solarized-light", "reference-light"]);
await mkdir(out, { recursive: true });
const iso = await realpath(await mkdtemp("/tmp/zw-button-policy-"));
const rpc = join(iso, "rpc");
await mkdir(rpc);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
const log = await open(join(out, "app.log"), "w");
const app = spawn(binary, [], { env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_ISOLATE_POINTER: "1", ZENIT_E2E_BACKGROUND: "1" }, stdio: ["ignore", log.fd, log.fd] });
const ended = new Promise<void>(done => app.once("close", () => done()));
const alive = () => app.exitCode === null && app.signalCode === null;
const report: any = { status: "running", binary, sha256: createHash("sha256").update(await readFile(binary)).digest("hex"), themes: [], captures: [], scope: "Production remote notice and recovery views, copy feedback, and production execution/transfer/notification button recipes. Synthetic receipts; no model, PTY, credentials or business IO." };
const shown = (n: any) => n?.rect && !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect.w > 0 && n.rect.h > 0;
const visible = async (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null);
const click = async (id: string) => { await visible(id); assert((await h.clickTestId(id)).ok, id); };
const flat = (n: any): any[] => shown(n) ? [n, ...(n.children ?? []).flatMap(flat)] : [];
const text = (n: any) => flat(n).map((n: any) => n.text ?? "").join("");
const ids = ["fixture.theme", "remote.notice", "remote.notice.close", "remote.notice.reconnect", "sample.execution", "sample.transfer", "sample.notification", "sample.blocked", "sample.copy", "ai.recovery"];
function fits(button: any) {
  for (const n of flat(button).filter((n: any) => n.text)) {
    assert(n.rect.x >= button.rect.x - .5 && n.rect.x + n.rect.w <= button.rect.x + button.rect.w + .5, `Clipped action text: ${n.text}`);
    assert(n.rect.y >= button.rect.y - .5 && n.rect.y + n.rect.h <= button.rect.y + button.rect.h + .5);
  }
}
async function capture(theme: string, state: string) {
  await h.sleep(220);
  const nodes = Object.fromEntries(await Promise.all(ids.map(async id => [id, await h.query(id)])));
  const name = `${theme}-${state}`;
  await writeFile(join(out, `${name}.json`), JSON.stringify(nodes, null, 2));
  assert((await h.screenshot(join(out, `${name}.png`))).ok);
  report.captures.push(name);
}
try {
  await h.waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), app.pid);
  await h.resizeWindow(1100, 600);
  const identity = (await visible("remote.notice.close")).id;
  for (let i = 0; i < themes.length; i++) {
    const theme = text(await visible("fixture.theme"));
    assert(themes.includes(theme) && !report.themes.includes(theme), `Unexpected/repeated palette: ${theme}`);
    report.themes.push(theme);
    const close = await visible("remote.notice.close"), reconnect = await visible("remote.notice.reconnect");
    assert.equal(close.id, identity, "Theme changes must retain the original native control");
    fits(close); fits(reconnect);
    assert.equal(close.rect.h, reconnect.rect.h);
    for (const id of ["sample.execution", "sample.transfer", "sample.notification", "sample.blocked"]) fits(await visible(id));
    const blocked = await visible("sample.blocked");
    assert(blocked.effective_opacity < 1, "Disabled secondary action stays visually distinct");
    await h.clickAt(blocked.rect.x + blocked.rect.w / 2, blocked.rect.y + blocked.rect.h / 2);
    assert.equal(text(await visible("fixture.outcome")), "idle", "Disabled action must not invoke the handler");
    await click("fixture.copy-ok");
    if (selected.has(theme)) {
      await h.mouseMove(1090, 580);
      await capture(theme, "normal");
      await h.mouseMove(close.rect.x + close.rect.w / 2, close.rect.y + close.rect.h / 2);
      await capture(theme, "hover");
      await h.mouseDown(close.rect.x + close.rect.w / 2, close.rect.y + close.rect.h / 2);
      await capture(theme, "pressed");
      await h.mouseMove(1090, 580);
      await h.mouseUp(1090, 580);
      await click("fixture.copy-failed");
      await h.resizeWindow(600, 400);
      fits(await visible("remote.notice.close")); fits(await visible("remote.notice.reconnect"));
      await capture(theme, "compact");
      await h.resizeWindow(1100, 600);
    }
    await click("fixture.next");
    await h.waitFor(async () => text(await visible("fixture.theme")) !== theme || null);
  }
  assert.deepEqual(new Set(report.themes), new Set(themes));
  await click("fixture.quit");
  await Promise.race([ended, h.sleep(8000)]);
  assert(!alive() && app.exitCode === 0, "Normal native window shutdown required");
  report.status = "passed";
} catch (error) {
  report.status = "failed";
  report.error = String(error);
  if (alive()) await capture("failure", "state").catch(() => {});
  process.exitCode = 1;
} finally {
  if (alive()) {
    await click("fixture.quit").catch(() => {});
    await Promise.race([ended, h.sleep(2000)]);
  }
  if (alive()) { report.forced_cleanup = true; app.kill("SIGTERM"); await ended; }
  report.exit_code = app.exitCode;
  await log.close();
  await rm(iso, { recursive: true, force: true });
  await writeFile(join(out, "report.json"), JSON.stringify(report, null, 2));
  console.log(`${report.status}: ${join(out, "report.json")}`);
}
