/** BMC Select surface acceptance: private synthetic preview, no BMC transport. */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { copyFile, mkdir, mkdtemp, open, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { clickAt, clickTestId, key, query, request, resizeWindow, screenshot, scrollAt, sleep,
  waitFor, waitForServerReady } from "../vendor/zenit/e2e/client.ts";

const args: Record<string, string> = {};
for (let i = 2; i < process.argv.length; i += 2) {
  assert(["--binary", "--out"].includes(process.argv[i]) && process.argv[i + 1]);
  args[process.argv[i]] = process.argv[i + 1];
}
assert(args["--binary"] && args["--out"], "--binary and --out are required");
const out = resolve(args["--out"]), binary = join(out, "bmc-select-preview-frozen");
await mkdir(out, { recursive: true }); await copyFile(resolve(args["--binary"]), binary);
const report: any = { status: "running", binary, sizes: [[1440, 900], [860, 480]], runs: [], captures: [],
  scope: "Production BMC Select and Popover with synthetic original service interfaces; no network, credentials or management writes",
  limits: "Harness input and independent theme mounts; does not prove physical keyboard/OS focus or live BMC connectivity" };
const shown = (n: any) => n.hidden !== true && n.visible !== false && (n.effective_opacity ?? 1) > .98 && n.rect.w > 0 && n.rect.h > 0;
const visible = async (id: string) => waitFor(async () => (await query(id)).find(shown) ?? null, 6000);
async function click(id: string) { assert((await clickTestId(id)).ok, id); await sleep(220); }
async function closed(id: string) { await waitFor(async () => !(await query(id)).some(shown), 5000); }
async function capture(name: string, ids: string[]) {
  const path = join(out, `${name}.png`); assert((await screenshot(path)).ok);
  const geometry = Object.fromEntries(await Promise.all(ids.map(async id => [id, await query(id)])));
  await writeFile(join(out, `${name}.json`), JSON.stringify(geometry, null, 2));
  report.captures.push({ name, screenshot: path });
}
try {
  for (const theme of ["dark", "light", "sauber"]) {
    const base = await mkdtemp("/tmp/bmc-select-surface-"), rpc = join(base, "rpc"), data = join(base, "data");
    await mkdir(rpc); await mkdir(data); process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
    const log = await open(join(out, `${theme}.log`), "w");
    const app = spawn(binary, [`--theme=${theme}`, "--state=controlled"], { env: { ...process.env,
      ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1", ZENIT_E2E_ISOLATE_KEYBOARD: "1", ZEROWORK_DATA_DIR: data },
      stdio: ["ignore", log.fd, log.fd] });
    const exited = new Promise<void>(done => app.once("close", () => done()));
    const run: any = { theme, pid: app.pid, rpc, checks: [] }; report.runs.push(run);
    try {
      await waitForServerReady();
      assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), app.pid);
      await visible("bmc.frame");
      for (const [width, height] of report.sizes) {
        assert((await resizeWindow(width, height)).ok); await sleep(220);
        for (const menu of ["control", "keys", "display", "power", "boot"]) {
          await click(`bmc.${menu}`); const panel = await visible(`bmc.${menu}.popover`);
          assert(panel.rect.x >= 11 && panel.rect.x + panel.rect.w <= width - 11);
          assert(panel.rect.y >= 11 && panel.rect.y + panel.rect.h <= height - 11);
          await click(`bmc.${menu}.close`); await closed(`bmc.${menu}.popover`);
        }
        await click("bmc.boot"); await click("bmc.boot.target.trigger");
        const dropdown = await visible("bmc.boot.target.dropdown");
        assert(dropdown.rect.y >= 7 && dropdown.rect.y + dropdown.rect.h <= height - 7, `bounded ${theme} ${width} target list`);
        const lastBefore = (await query("bmc.boot.option.none"))[0];
        assert(lastBefore, "eight native options published");
        const inside = async (id: string) => {
          const item = await visible(id), viewport = await visible("bmc.boot.target.dropdown");
          assert(item.rect.y >= viewport.rect.y + 4 && item.rect.y + item.rect.h <= viewport.rect.y + viewport.rect.h - 4, `keyboard row visible ${theme} ${width} ${id}`);
        };
        await key("end"); await sleep(220); await inside("bmc.boot.option.none");
        await capture(`${theme}-${width}x${height}-keyboard-end`, ["bmc.boot.target.dropdown", "bmc.boot.option.none"]);
        await key("home"); await sleep(220); await inside("bmc.boot.option.disabled");
        for (let index = 0; index < 7; index++) { await key("down"); await sleep(50); }
        await inside("bmc.boot.option.none");
        await key("return"); await closed("bmc.boot.target.dropdown");
        assert.equal((await request("GET", "/app/bmc-fixture/menus")).open[4], true, "keyboard commit preserves boot panel");
        await click("bmc.boot.target.trigger"); await visible("bmc.boot.target.dropdown");
        await key("home"); await sleep(220);
        const pointerScrollStart = (await query("bmc.boot.option.none"))[0];
        await capture(`${theme}-${width}x${height}-target`, ["bmc.boot.popover", "bmc.boot.target.dropdown", "bmc.boot.option.disabled", "bmc.boot.option.none"]);
        const x = dropdown.rect.x + dropdown.rect.w / 2, y = dropdown.rect.y + dropdown.rect.h / 2;
        assert((await scrollAt(x, y, 0, -600)).ok); await sleep(150);
        const lastAfter = await visible("bmc.boot.option.none");
        assert(lastAfter.rect.y + lastAfter.rect.h <= dropdown.rect.y + dropdown.rect.h - 4);
        assert(lastAfter.rect.y >= dropdown.rect.y + 4);
        if (width === 860) assert(lastAfter.rect.y < pointerScrollStart.rect.y - 10, "small-window list scrolls to last option");
        const before = await request("GET", "/app/bmc-fixture/menus"); assert.equal(before.open[4], true);
        await click("bmc.boot.option.none"); await closed("bmc.boot.target.dropdown");
        assert.equal((await request("GET", "/app/bmc-fixture/menus")).open[4], true, "local selection preserves boot panel");
        // A click outside the child menu but within its parent closes only the child.
        await click("bmc.boot.target.trigger"); await visible("bmc.boot.target.dropdown");
        const head = await visible("bmc.boot.close"); await clickAt(head.rect.x - 140, head.rect.y + head.rect.h / 2); await sleep(220);
        await closed("bmc.boot.target.dropdown"); assert.equal((await request("GET", "/app/bmc-fixture/menus")).open[4], true);
        await click("bmc.boot.mode.trigger"); await visible("bmc.boot.mode.dropdown"); await key("escape"); await sleep(220);
        await closed("bmc.boot.mode.dropdown"); assert.equal((await request("GET", "/app/bmc-fixture/menus")).open[4], true);
        await click("bmc.boot.close"); await closed("bmc.boot.popover");
        await click("bmc.power"); await click("bmc.power.action.trigger"); await visible("bmc.power.action.dropdown");
        await capture(`${theme}-${width}x${height}-power`, ["bmc.power.popover", "bmc.power.action.dropdown"]);
        await key("escape"); await sleep(220); await closed("bmc.power.action.dropdown");
        assert.equal((await request("GET", "/app/bmc-fixture/menus")).open[3], true);
        await click("bmc.power.close"); await closed("bmc.power.popover");
        run.checks.push(`${width}x${height}: five Popovers, three Selects, End/Home/Down highlighted-row visibility and Enter, independent pointer scroll, option hit, child Escape/outside dismissal and retained parent`);
      }
      run.stats = await request("GET", "/app/bmc-fixture/stats");
      assert.equal(run.stats.power_writes, 0); assert.equal(run.stats.boot_writes, 0);
      assert((await request("POST", "/quit")).ok); await Promise.race([exited, sleep(5000)]);
      assert.equal(app.exitCode, 0); run.normal_close = true;
    } catch (error) {
      run.error = String(error); try { await screenshot(join(out, `${theme}-failure.png`)); } catch {} throw error;
    } finally {
      if (app.exitCode === null && app.signalCode === null) { try { await request("POST", "/quit"); } catch {} await Promise.race([exited, sleep(2000)]); }
      if (app.exitCode === null && app.signalCode === null) { app.kill("SIGTERM"); await exited; }
      run.exit_code = app.exitCode; await log.close();
    }
  }
  report.status = "passed";
} catch (error) { report.status = "failed"; report.error = String(error); process.exitCode = 1; }
finally { await writeFile(join(out, "report.json"), JSON.stringify(report, null, 2)); }
console.log(JSON.stringify({ status: report.status, report: join(out, "report.json"), error: report.error }));
