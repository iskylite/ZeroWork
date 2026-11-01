/** Production BMC renderer + original typed services + real Metal FrameSink.
 * Synthetic background Harness events; no Runtime, network, credentials or
 * physical keyboard/pointer. node e2e/bmc_kvm_native.ts --binary PATH --out DIR
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, open, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const opts: Record<string, string> = {};
for (let i = 2; i < process.argv.length; i += 2) {
  assert(["--binary", "--out", "--client"].includes(process.argv[i]) && process.argv[i + 1], `Invalid option ${process.argv[i]}`);
  opts[process.argv[i]] = process.argv[i + 1];
}
assert(opts["--binary"] && opts["--out"], "--binary bmc-kvm-preview and --out are required");
const client = opts["--client"] ? pathToFileURL(resolve(opts["--client"])).href : new URL("../vendor/zenit/e2e/client.ts", import.meta.url).href;
const { clickAt, clickTestId, focused, key, mouseDown, mouseMove, mouseUp, query, request,
  resizeWindow, screenshot, scrollAt, sleep, type_, waitFor, waitForServerReady } = await import(client);
const out = resolve(opts["--out"]), source = resolve(opts["--binary"]);
await mkdir(out, { recursive: true });
const binary = join(out, "bmc-kvm-preview-frozen");
await copyFile(source, binary);
const report: any = { status: "running", started_at: new Date().toISOString(), source_binary: source, binary,
  harness_client: client,
  binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"), runs: [], checks: [], captures: [],
  scope: "Production views.mount + original typed framebuffer/input/power/boot/console definitions; real shared ImageTextureStore + FrameSink",
  fixture: "1920×1200 local synthetic RGBA, 20 explicit local BootOrder strings, no credentials, target connection or network transport",
  reference: "/tmp/zerowork-v032-kvm-reference/measurements.json",
  limits: ["Independent native component fixture does not prove production device connectivity or main-app wiring.",
    "Input and focus changes are synthetic Harness/renderer-owner callbacks, not physical mouse, keyboard, OS focus or IME evidence.",
    "The header and status row only reserve the HTML shell geometry; they are labelled fixture scaffolding.",
    "Production renderer intentionally disables management writes and Boot draft controls; this run checks read-only preservation, not executable management.",
    "Background fixture does not request native fullscreen or exercise the application's live theme-switch flow; themes are mounted independently.",
    "Synthetic RGB pixels intentionally differ from the reference BIOS fixture; compare content geometry, toolbar and popup layout."] };
const menus = ["control", "keys", "display", "power", "boot"];
function shown(n: any): boolean { return !!n?.rect && n.hidden !== true && n.visible !== false && (n.effective_opacity ?? 1) > 0.98 && n.rect.w > 0 && n.rect.h > 0; }
function flatten(n: any): any[] { return !n || n.hidden === true ? [] : [n, ...(n.children ?? []).flatMap(flatten)]; }
async function visible(id: string): Promise<any> { return waitFor(async () => (await query(id)).find(shown) ?? null, 10000); }
async function click(id: string) { assert((await clickTestId(id)).ok, `click ${id}`); await sleep(180); }
async function attemptReadOnly(id: string) {
  await waitFor(async () => (await query(id)).find(n => n.hidden !== true && (n.effective_opacity ?? 1) > 0 && n.rect.w > 0 && n.rect.h > 0) ?? null, 5000);
  const outcome = await clickTestId(id);
  report.disabled_attempts ??= [];
  report.disabled_attempts.push({ id, outcome });
  await sleep(80);
}
async function stats() {
  const value = await request("GET", "/app/bmc-fixture/stats"); assert(!value.error, JSON.stringify(value));
  const input = await request("GET", "/app/bmc-fixture/input-stats"); assert(!input.error, JSON.stringify(input));
  return { ...value, ...input };
}
async function state(value: string) { assert((await request("POST", "/app/bmc-fixture/state", { state: value })).ok); await sleep(1100); }
function near(actual: number, expected: number, name: string, tolerance = 0.55) { assert(Math.abs(actual - expected) <= tolerance, `${name}: ${actual} vs ${expected}`); }
async function keyPair(value: string, mods: any = {}) {
  assert((await key(value, mods)).ok);
  assert((await request("POST", "/key_up", { key: value, ...mods })).ok);
}
async function closeMenu(menu: string) {
  await click(`bmc.${menu}.close`);
  await waitFor(async () => (await query(`bmc.${menu}.popover`)).every(n => n.hidden === true || (n.effective_opacity ?? 1) <= 0.01), 5000);
}
async function capture(name: string, width: number, height: number) {
  await sleep(100);
  const path = join(out, `${name}.png`);
  assert((await screenshot(path)).ok, `Metal screenshot ${name}`);
  const bytes = await readFile(path), physical = { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  near(physical.width / width, physical.height / height, "uniform backing scale", 0.01);
  const ids = ["fixture.window", "fixture.content_slot", "bmc.content", "bmc.viewport", "bmc.frame", ...menus.flatMap(m => [`bmc.${m}`, `bmc.${m}.popover`, `bmc.${m}.close`]), "bmc.boot.order_modal", "bmc.boot.order_list"];
  const geometry = Object.fromEntries(await Promise.all(ids.map(async id => [id, (await query(id)).filter(shown)])));
  const current = await stats();
  await writeFile(join(out, `${name}.json`), JSON.stringify({ logical: { width, height }, physical, geometry, state: current }, null, 2));
  report.captures.push({ name, screenshot: path, logical: { width, height }, physical, backing_scale: physical.width / width, metadata: join(out, `${name}.json`) });
  return geometry;
}
async function geometry(width: number, height: number) {
  const root = await visible("fixture.window"), content = await visible("bmc.content"), viewport = await visible("bmc.viewport"), frame = await visible("bmc.frame");
  near(root.rect.w, width, "window width"); near(root.rect.h, height, "window height");
  near(content.rect.x, 8, "content x"); near(content.rect.y, 50, "content y");
  near(content.rect.w, width - 16, "content width"); near(content.rect.h, height - 90, "content height");
  near(viewport.rect.x, 8, "video x"); near(viewport.rect.y, 94, "video y");
  near(viewport.rect.w, width - 16, "video width"); near(viewport.rect.h, height - 134, "video height");
  near(frame.rect.h, height - 134, "fit image height"); near(frame.rect.w, (height - 134) * 1.6, "fit image width");
  near(frame.rect.x, (width - frame.rect.w) / 2, "fit centered x"); near(frame.rect.y, 94, "fit centered y");
  for (const menu of menus) { const tool = await visible(`bmc.${menu}`); near(tool.rect.w, width < 1000 ? 74 : 82, `${menu} tool width`); near(tool.rect.h, 24, `${menu} tool height`); }
  report.checks.push(`${width}×${height}: actual content bounds, 44 point toolbar, all five tools, 1920×1200 fit ratio and centered real texture`);
}
async function inspectMenus(theme: string, width: number, height: number) {
  for (const menu of menus) {
    await click(`bmc.${menu}`);
    const popup = await visible(`bmc.${menu}.popover`), close = await visible(`bmc.${menu}.close`);
    assert(popup.rect.x >= 11.5 && popup.rect.x + popup.rect.w <= width - 11.5, `${menu} horizontal viewport clamp`);
    assert(close.rect.y >= 0 && close.rect.y + close.rect.h <= height, `${menu} close is reachable`);
    assert(close.rect.x >= popup.rect.x && close.rect.x + close.rect.w <= width - 11.5);
    assert.equal((await stats()).captured, false, `${menu} opens after input release`);
    await capture(`${theme}-${width}x${height}-${menu}`, width, height);
    await closeMenu(menu);
  }
  report.checks.push(`${theme} ${width}×${height}: five real Popovers open/close; viewport clamp and input release`);
}
async function run(theme: string, inspect: () => Promise<void>) {
  const base = await mkdtemp("/tmp/zerowork-bmc-native-"), rpc = join(base, "rpc"), data = join(base, "data");
  await mkdir(rpc); await mkdir(data);
  process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
  const logPath = join(out, `${theme}.app.log`), log = await open(logPath, "w");
  const app = spawn(binary, [`--theme=${theme}`, "--state=controlled"], { env: { ...process.env,
    ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1", ZENIT_E2E_ISOLATE_KEYBOARD: "1", ZEROWORK_DATA_DIR: data },
    stdio: ["ignore", log.fd, log.fd] });
  const ended = new Promise<void>(done => app.once("close", () => done()));
  const record: any = { theme, pid: app.pid, base, rpc, data, log: logPath }; report.runs.push(record);
  let normalQuit = false;
  try {
    await waitForServerReady();
    assert.equal(Number(JSON.parse(await readFile(join(rpc, "owner.json"), "utf8")).pid), app.pid, "owned private RPC server");
    await visible("bmc.frame");
    const initial = await stats();
    assert(initial.texture && initial.frame_generation === 1 && initial.frame_revision === 1, "real uploaded texture immediately available");
    assert(initial.owner_guards && initial.type_guards && initial.lease_guards, "typed owner/type and FrameLease barrier verified");
    await inspect();
    record.final = await stats();
    assert.equal(record.final.power_writes, 0); assert.equal(record.final.boot_writes, 0);
    assert((await request("POST", "/quit")).ok); normalQuit = true;
    await Promise.race([ended, sleep(5000)]);
    assert.equal(app.exitCode, 0, "normal owned native close succeeds");
    const logs = await readFile(logPath, "utf8");
    assert(/BMC_FIXTURE_CLEANUP budget_used=0 keys=0 buttons=0 power_writes=0 boot_writes=0/.test(logs), "released leases, CPU/GPU budget and input on close");
    record.normal_close = true;
  } catch (error) {
    record.error = String(error);
    if (app.exitCode === null && app.signalCode === null) {
      try { record.menu_diagnostics = await request("GET", "/app/bmc-fixture/menus"); await writeFile(join(out, `${theme}-failure.menus.json`), JSON.stringify(record.menu_diagnostics, null, 2)); } catch {}
      try { await screenshot(join(out, `${theme}-failure.png`)); } catch {}
    }
    throw error;
  } finally {
    if (app.exitCode === null && app.signalCode === null) {
      if (!normalQuit) { try { await request("POST", "/quit"); } catch {} }
      await Promise.race([ended, sleep(2000)]);
    }
    if (app.exitCode === null && app.signalCode === null) { app.kill("SIGTERM"); await Promise.race([ended, sleep(2000)]); }
    if (app.exitCode === null && app.signalCode === null) { app.kill("SIGKILL"); await ended; }
    record.cleanup = { exit_code: app.exitCode, signal: app.signalCode };
    await log.close();
  }
}

let failure: unknown;
try {
  for (const theme of ["dark", "light", "sauber"]) await run(theme, async () => {
    await resizeWindow(1440, 900); await sleep(150); await geometry(1440, 900);
    await inspectMenus(theme, 1440, 900);
    await resizeWindow(860, 480); await sleep(180); await geometry(860, 480);
    await inspectMenus(theme, 860, 480);
    await click("bmc.boot");
    const before = await stats();
    for (const id of ["bmc.boot.target.trigger", "bmc.boot.continuous", "bmc.boot.mode.trigger", "bmc.boot.execute"]) await attemptReadOnly(id);
    const preserved = await stats();
    assert.deepEqual(preserved.draft, before.draft); assert.equal(preserved.draft_dirty, false); assert.equal(preserved.boot_writes, 0);
    await click("bmc.boot.order");
    const list = await visible("bmc.boot.order_list"), modal = await visible("bmc.boot.order_modal");
    near(list.rect.h, 240, "BootOrder scroll viewport"); assert(modal.rect.y >= 11.5 && modal.rect.y + modal.rect.h <= 468.5);
    await keyPair("end"); await sleep(100);
    const end = await stats(); assert(end.order_max_y > 0); near(end.order_scroll_y, end.order_max_y, "End scrolls to last BootOrder entry");
    await capture(`${theme}-860x480-boot-order-end`, 860, 480);
    await keyPair("home"); near((await stats()).order_scroll_y, 0, "Home returns BootOrder to start");
    await click("bmc.boot.order_close");
    report.checks.push(`${theme}: read-only Boot draft survives target/mode/switch/execute clicks; 20-entry actual Modal + 240 point ScrollArea supports Home/End`);
    if (theme !== "dark") return;

    // Original-size scroll is local while released. Capture converts local
    // viewport coordinates plus actual scroll into remote logical pixels.
    await click("bmc.display"); await click("bmc.display.original"); await closeMenu("display");
    const original = await visible("bmc.frame"); near(original.rect.w, 1920, "original width"); near(original.rect.h, 1200, "original height");
    const vp = (await visible("bmc.viewport")).rect;
    await scrollAt(vp.x + 100, vp.y + 100, -200, -300); await sleep(120);
    const scrolled = await stats(); assert(scrolled.scroll_x > 0 && scrolled.scroll_y > 0, "100% native ScrollArea moves both axes");
    await capture("dark-860x480-original-scrolled", 860, 480);
    await clickAt(vp.x + 100, vp.y + 100); await sleep(100);
    const captured = await stats(); assert.equal(captured.captured, true);
    near(captured.last_pointer.x, Math.round(100 + scrolled.scroll_x), "100% pointer x after scroll", 1);
    near(captured.last_pointer.y, Math.round(100 + scrolled.scroll_y), "100% pointer y after scroll", 1);
    await keyPair("escape"); const remoteEsc = await stats(); assert(remoteEsc.keys >= captured.keys + 2); assert.equal(remoteEsc.last_key.keysym, 0xff1b); assert.equal(remoteEsc.captured, true);
    const imeBefore = remoteEsc.keys; await type_("本地 IME text"); assert.equal((await stats()).keys, imeBefore, "text input is not guessed into remote keys");
    await keyPair("escape", { ctrl: true, alt: true }); const released = await stats(); assert.equal(released.captured, false); assert.equal(released.pressed_keys, 0); assert.equal(released.pressed_buttons, 0);
    assert.equal(released.keys, imeBefore, "reserved Ctrl+Alt+Escape never reaches remote");
    await click("bmc.keys"); const chordBefore = await stats(); await click("bmc.keys.ctrl_alt_delete"); const chordAfter = await stats();
    assert.equal(chordAfter.chords, chordBefore.chords + 1); assert.deepEqual(chordAfter.last_chord.keys.slice(0, 3), [0xffe3, 0xffe9, 0xffff]); assert.equal(chordAfter.captured, false);
    await click("bmc.keys.f12"); const f12 = await stats(); assert.equal(f12.chords, chordAfter.chords + 1); assert.equal(f12.last_chord.count, 1); assert.equal(f12.last_chord.keys[0], 0xffc9);
    await click("bmc.keys.ctrl_alt_f12"); const ctrlF12 = await stats(); assert.equal(ctrlF12.chords, f12.chords + 1); assert.deepEqual(ctrlF12.last_chord.keys.slice(0, 3), [0xffe3, 0xffe9, 0xffc9]);
    await capture("dark-860x480-keys-lower-actions", 860, 480);
    const keysPopup = (await visible("bmc.keys.popover")).rect, keysClose = (await visible("bmc.keys.close")).rect;
    assert(keysClose.y >= keysPopup.y && keysClose.y + keysClose.h <= keysPopup.y + 60, "sticky Keys header close stays inside popup after scrolling to lower actions");
    assert((await clickAt(keysClose.x + keysClose.w / 2, keysClose.y + keysClose.h / 2)).ok);
    await waitFor(async () => !(await query("bmc.keys.popover")).some(shown), 5000);
    await click("bmc.display"); await click("bmc.display.fit"); await closeMenu("display"); await geometry(860, 480);
    const fitFrame = (await visible("bmc.frame")).rect;
    // The same production View must discard its frozen capture authority at
    // each real Service epoch/control/transport barrier. These are explicit
    // local service fixtures, not claims about native OS focus or device IO.
    for (const transition of ["input_epoch", "revoke_control", "reconnect"]) {
      await clickAt(fitFrame.x + 100, fitFrame.y + 100); await sleep(80);
      const held = await stats(); assert.equal(held.captured, true);
      assert.deepEqual(held.capture_authority, { binding_generation: 7, input_epoch: held.input.input_epoch,
        control_generation: held.input.control_generation, transport_generation: held.input.transport_generation,
        frame_generation: held.frame_generation });
      await key("left_shift"); await mouseDown(fitFrame.x + 100, fitFrame.y + 100); await sleep(60);
      assert((await stats()).pressed_keys > 0, `${transition}: held Shift reaches original Service`);
      assert((await request("POST", "/app/bmc-fixture/transition", { action: transition })).ok);
      await waitFor(async () => !(await stats()).captured, 3000);
      const invalidated = await stats();
      assert.equal(invalidated.capture_authority, null); assert.equal(invalidated.view_pressed_keys, 0);
      assert.equal(invalidated.view_buttons, 0); assert.equal(invalidated.pressed_keys, 0); assert.equal(invalidated.pressed_buttons, 0);
      await request("POST", "/key_up", { key: "left_shift" }); await mouseUp(fitFrame.x + 100, fitFrame.y + 100);
      await keyPair("a"); assert.equal((await stats()).keys, invalidated.keys, `${transition}: no implicit recapture`);
      if (transition === "revoke_control") assert((await request("POST", "/app/bmc-fixture/transition", { action: "grant_control" })).ok);
      await sleep(100);
      await clickAt(fitFrame.x + 100, fitFrame.y + 100); await keyPair("left_shift"); await sleep(100);
      const renewed = await stats(); assert.equal(renewed.captured, true);
      assert(renewed.input.last_sent_input_sequence >= renewed.view_input_sequence, `${transition}: exact View events sent by original RFB Service`);
      assert.equal(renewed.input.last_sent_transport_generation, renewed.input.transport_generation);
      assert(renewed.wire_messages > held.wire_messages, `${transition}: original sender made local Wire writes`);
      await keyPair("escape", { ctrl: true, alt: true });
    }
    report.checks.push("Synthetic epoch, control revocation/regrant and transport reconnect invalidate frozen View capture; held Shift/button clear; new capture uses current generations and original RFB sent watermarks");
    await clickAt(fitFrame.x + fitFrame.w / 2, fitFrame.y + fitFrame.h / 2); assert.equal((await stats()).captured, true);
    await key("a"); await mouseDown(fitFrame.x + 100, fitFrame.y + 100); await sleep(80);
    assert((await stats()).pressed_keys > 0);
    assert((await request("POST", "/app/bmc-fixture/focus", { focused: false })).ok); await sleep(100);
    const blurred = await stats(); assert.equal(blurred.captured, false); assert.equal(blurred.pressed_keys, 0); assert.equal(blurred.pressed_buttons, 0); assert.equal(blurred.last_release, "lost_focus");
    await request("POST", "/app/bmc-fixture/focus", { focused: true }); await mouseUp(fitFrame.x + 100, fitFrame.y + 100);
    await request("POST", "/key_up", { key: "a" });
    await click("bmc.control"); await click("bmc.control.view_only");
    await clickAt(fitFrame.x + fitFrame.w / 2, fitFrame.y + fitFrame.h / 2); await sleep(100);
    assert.equal((await stats()).captured, false, "explicit local view-only survives ordinary video clicks");
    await click("bmc.control"); await click("bmc.control.capture");
    await waitFor(async () => (await stats()).captured, 5000);
    await keyPair("escape", { ctrl: true, alt: true }); assert.equal((await stats()).captured, false);
    report.checks.push("100% scroll and remote coordinate mapping; normal Escape routes remote; Ctrl+Alt+Escape releases locally; explicit Ctrl+Alt+Delete/F12/Ctrl+Alt+F12 reach local Wire without capture; text input suppressed; owner focus loss releases held key/button; local view-only persists until explicit capture");
    for (const fixture of ["read_only", "no_signal", "disconnected", "partial", "unknown"]) {
      await state(fixture);
      await click("bmc.boot");
      const current = await stats(); assert.equal(current.boot_writes, 0); assert.equal(current.power_writes, 0);
      if (fixture === "read_only") {
        await closeMenu("boot"); await click("bmc.keys"); const disabledBefore = await stats(); await attemptReadOnly("bmc.keys.escape"); assert.equal((await stats()).chords, disabledBefore.chords); await closeMenu("keys");
        await click("bmc.boot");
      }
      if (fixture === "unknown") assert.equal(current.draft.target, "VendorOriginalText", "unknown raw boot value retained");
      await capture(`dark-860x480-${fixture}-boot`, 860, 480); await closeMenu("boot");
      if (fixture === "no_signal") assert(!(await query("bmc.frame")).some(shown), "no-signal status hides synthetic frame");
    }
    await state("controlled");
    await click("bmc.power"); const powerBefore = await stats(); await attemptReadOnly("bmc.power.execute"); assert.equal((await stats()).power_writes, powerBefore.power_writes); await closeMenu("power");
    // Escape closes and restores the original trigger focus via real Popover.
    await click("bmc.boot"); await keyPair("escape"); await sleep(150); assert(!(await query("bmc.boot.popover")).some(shown)); assert.equal((await focused()).test_id, "bmc.boot");
    await click("bmc.power"); await clickAt(24, 25); await sleep(180); assert(!(await query("bmc.power.popover")).some(shown), "outside pointer dismisses Popover");
    report.checks.push("read-only/no-signal/disconnected/partial/unknown fixtures remain local; disabled power/boot never invoke services; Popover Escape restores trigger focus");
  });
  report.status = "passed";
} catch (error) { failure = error; report.status = "failed"; report.error = String(error); }
finally { report.finished_at = new Date().toISOString(); await writeFile(join(out, "report.json"), JSON.stringify(report, null, 2)); }
console.log(JSON.stringify({ status: report.status, out, report: join(out, "report.json"), checks: report.checks.length, captures: report.captures.length }));
if (failure) throw failure;
